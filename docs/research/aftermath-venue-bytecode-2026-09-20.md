# Aftermath venue: on-chain bytecode read of every call the adapter makes

- Date: 2026-09-20
- Method: every module the adapter calls was fetched from mainnet through Sui
  GraphQL, its sha256 matched the hash `check_mainnet_abi.mjs` pins, and the
  endpoint's disassembly (Sui 1.77.2 toolchain) was read function by function.
  Live objects were read the same day at about 03:00 UTC. Where the adapter
  re-implements venue arithmetic, the bytecode was modelled in Python and the
  adapter's arithmetic checked against it on random inputs
  (`scratchpad/funding_chain/model.py` during the session; the model is
  reproduced in the appendix).
- Companion: [aftermath-ifixed-bytecode-2026-09-19.md](aftermath-ifixed-bytecode-2026-09-19.md)
  (the `ifixed` module), [ADR 0074](../decisions/0074-aftermath-vault-activation-and-health.md)
  (amended by this read).

## Modules read

| Package | Module | sha256 (pinned by the ABI gate) |
| --- | --- | --- |
| perpetuals `0x3ec740…efc7` v1 | `clearing_house` | `56290307…25eaf` |
| perpetuals | `market` | `7b487816…40985` |
| perpetuals | `account` | `e9491628…ec23e` |
| position `0x9196ff…8dec` v1 | `position` | `9dbf0ed5…26e7` |
| oracle-aggregator `0x923733…6ba4` v1 | `price_feed`, `price_feed_storage` | `6a5dae24…3aa8`, `f9c56ecf…56c0` |
| ifixed `0x4b4703…8760` v1 | `ifixed` | `ab7e23db…140e` (read 2026-09-19) |
| Pyth Lazer vendors `0xa5428d…9104`, `0x7ab174…35e8`, `0xc1fdd5…608e` | `price_feed_storage`, `feed_info_object` | not pinned; read for the oracle finding below |

## Findings that change the adapter

### F1. Funding settlement rounds on the 10^36 product, not on the USD result

`position::settle_position_funding(position, collateral_price, cum_long, cum_short)`
(position.dis 1816–2147), replayed exactly:

1. Take the held side: `base < 0` → `(cum_short, snapshot_short, |base|)`,
   else `(cum_long, snapshot_long, base)`.
2. If the rate did not move or the base is zero: collateral unchanged, USD
   funding `0`; snapshots are still overwritten with the market rates.
3. `delta = market − snapshot` as a sign and magnitude computed on raw bits
   (same sign: raw subtraction; different signs: sum of magnitudes).
4. `product = |delta| × |base|` — a 10^36-scaled USD amount; `Mul` aborts on
   overflow.
5. Credit (`sign(base) ≠ sign(delta)`): `c = product / price` (floor),
   `usd = product / 10^18`; if `c == 0` the collateral is **not** written.
6. Cost (`sign(base) = sign(delta)`): `c = (product + price − 1) / price`
   (ceil), `usd = −((product + 10^18 − 1) / 10^18)`.
7. `collateral ± c` with two's-complement sign handling and abort `2000` on
   signed overflow; both snapshots := market rates; return
   `(changed, usd, new_collateral)`.

`position::calculate_position_funding_internal` (2149–2182) is a different
computation: `ifixed::mul(ifixed::sub(market, snapshot), −base)`, i.e. the USD
amount already rounded to 10^18. The adapter used to convert that USD figure
to collateral with `usd_fixed_to_collateral_fixed`, which divides
`floor(product/10^18) × 10^18` by the price instead of `product`. The two
disagree whenever the discarded 10^18 remainder crosses a unit boundary after
the division:

| collateral price | old candidate ≠ venue (50,000 random settlements) |
| --- | --- |
| exactly 1.000000 | 0 |
| 0.99988492 (live USDC feed at the time of the read) | 49.9 % |

Every disagreement would classify as `Unexpected`, leaving the vault in
permanent drift. **Applied:** `checkpoint::classify_change` now replays steps
1–6 from the checkpoint's own fields (`signed_base`, the held side's snapshot
and market rate) at the captured venue collateral price; the venue candidate
call and its `usd_fixed_to_collateral_fixed` conversion are gone. The model
agrees with the replay on 200,000 random settlements over long and short
positions, positive and negative rates, zero crossings and four prices.

The price the venue divides by is `market::collateral_oracle_price(params,
collateral_storage, clock)` read inside `settle_position_funding` (clearing
house 2218–2247); the adapter reads the same function with the same objects
and clock in the same transaction before settling, so the two values are
identical. The capture now carries that raw value unconditionally; its u64
normalization is a separate representability question.

### F2. The quote notional carries the base's sign

`position::add_base_to_position(position, is_ask, base, quote)` (position.dis
299–689): a bid on a long-or-flat position does `base += base_fill` and
`quote += quote_fill`; an ask that opens or adds to a short writes
`base = −(|base| + base_fill)` and `quote = −(|quote| + quote_fill)`. A
reduction scales `|quote|` by the closed fraction (floor) and realizes the
difference. Live positions on the SUI-USDC clearing house confirm it: longs
show positive base and positive quote (`141330000000000000`,
`123194498418776990`), shorts negative on both.
`position::unrealized_pnl(price) = base × price − quote` (1762) only makes
sense under this convention.

The adapter assumed the opposite sign: `orders::quote_after` subtracted a
bid's quote and `snapshot::position_signs_coherent` required a long's quote to
be negative. On the live venue every strict capture would have read
`economics_valid = false` and every opening fill would have failed
`assert_trade_checkpoint`. **Applied:** one `filled_after` for base and
quote (bid adds, ask subtracts on both) and coherence `long ⇒ both
nonnegative, short ⇒ both negative`.

### F3. The market's collateral scale is a parameter, not a constant

`clearing_house::allocate_collateral` converts the deposited `u64` with
`ifixed::from_balance(amount, market::scaling_factor(params))`;
`deallocate_collateral`, `end_session` and `close_position_at_settlement_prices`
convert back with the same factor. The adapter hard-codes `10^12` for a
six-decimal collateral. The live SUI-USDC market's `scaling_factor` is
`1000000000000`. **Applied:** `initialize` now asserts
`market_params.scaling_factor() == 10^12` next to the currency-decimals
check, under the same error code.

## Findings that need a decision (not applied)

### F4. Aftermath prices its markets from Pyth Lazer, and no `PriceInfoObject` exists

Every live `PriceFeedStorage` (38 storages, read 2026-09-20) has feeds whose
`from` object is a `feed_info_object::FeedInfoObject { id, feed_id }` from
one of three vendor packages: `PYTH_LAZER` (`0xa5428d…`), `PYTH_LAZER_ROLLING`
(`0x7ab174…`) and `PYTH_LAZER_NORMALIZED` (`0xc1fdd5…`). The SUI-USDC market
binds storage 3 (SUIUSD) and storage 1 (USDCUSD), both source 1, both fed by
`0xa5428d…::price_feed_storage::update_price_feed_from_update`, which takes a
signed Lazer `Update` verified by `0x7b502c…::pyth_lazer::parse_and_verify_le_ecdsa_update`
in the updater's own transaction. The verified payload is not stored anywhere
on chain; the only on-chain copy of the price is Aftermath's feed.

The adapter's oracle chain (ADR 0074, "Confidence is not present…") binds a
classic Pyth `PriceInfoObject` whose id must equal `feed.from()` and requires
its price and publish time to equal the feed's. No such object exists for any
Aftermath feed, so `assert_pyth_price_info` can never pass: the adapter
cannot activate against the live venue. Two smaller consequences of the same
read:

- The feed's `price: u128` is an 18-decimal IFixed (`scaled_by_exponent`
  multiplies the Lazer magnitude by `10^18 / 10^|exponent|`; `market::
  collateral_oracle_price` returns it cast to `u256` unchanged; live SUI
  reads `821520640000000000`). `snapshot::normalize_feed_price` treats it as a
  9-decimal `u64`, so even with a matching Pyth object the feed/Pyth equality
  would fail for every nonzero price.
- The feed's `timestamp_ms` is the Lazer update timestamp in microseconds
  divided by 1000 (`to_ms`); live feeds read `…501600`. It is not a Pyth
  publish time in whole seconds, so the seconds×1000 equality is inapplicable.

Options for the founder:

1. **Drop the independent oracle cross-check.** Authenticate the feed by the
   storage-id and source-id binding the adapter already proves, and take
   the venue's price as the price. Bind the feed's `from` id at
   initialization (it identifies the Lazer feed the market prices with), and
   keep the venue's own staleness (`*_pfs_tolerance`, 15 s base / 30 s
   collateral) and index/TWAP divergence checks. Confidence is unavailable;
   the core's confidence bound would read zero.
2. **Cross-check against classic Pyth as an external reference.** Keep a
   `PriceInfoObject` argument for SUI/USD and USDC/USD from Pyth's own Sui
   deployment (not linked to Aftermath), and require the venue's feed price to
   sit within a tolerance of it with both timestamps within a window. This is
   a *different* property from today's equality (two sources, two update
   times) and needs tolerance parameters.
3. **Both**: option 1 for identity, option 2 as a health bound.

Either way `snapshot::pyth_price`, `normalize_feed_price`, `seconds_to_millis`
and the Pyth port in `interfaces/pyth` change or go; ADR 0074's oracle
paragraphs and the atomicity/dev-inspect fixtures that carry two
`PriceInfoObject` inputs follow.

## Everything else the adapter calls, and what it relies on

Read→act→read→prove means most calls are proven by the checkpoint after them;
the table records what each call does that the proof does not already pin.

| Call | What the bytecode does | Adapter reliance |
| --- | --- | --- |
| `account::create_account` | new derived-id `Account` with zero balance, its `AccountSharePolicy`, and an `ACCOUNT/ADMIN` cap | none beyond the signature |
| `account::deposit_collateral` | joins the coin into `Account.collateral` (a zero coin is destroyed) | proven by `assert_deposit_checkpoint` |
| `account::withdraw_collateral` | `coin::take` from the balance (zero → zero coin) | proven by `assert_withdrawal_checkpoint` |
| `account::account_id`, `collateral_balance` | field reads | checkpoint fields |
| `clearing_house::allocate_collateral` | moves `amount` from the account balance to the market vault; `position.collateral += from_balance(amount, scaling_factor)`; aborts on zero | F3; proven by `assert_allocated_deposit_checkpoint` |
| `clearing_house::deallocate_collateral` | settles funding first, computes free collateral at mark/IMR, aborts `40` above it, `position.collateral −= from_balance(amount, scaling_factor)`, vault → account | proven by `assert_withdrawal_checkpoint`; funding is a no-op after `synchronize` |
| `clearing_house::create_market_position` | `Position` with zero base/quote/collateral, snapshots at the market rates, **IMR = 1.0** | the adapter sets the IMR next; `set_initial_margin_ratio` accepts `market_IMR ≤ ratio ≤ 1` (abort `2003`) |
| `clearing_house::set_position_initial_margin_ratio` | as above | `assert_position_imr_unchanged` re-reads it after the seed |
| `clearing_house::start_session` | paused/version checks; `start_session_`: reads both prices, `try_update_fundings_and_twaps` (funding only if `is_time_to_update`), computes mark, **settles the position's funding**, computes margin/requirement into the hot potato | funding is a no-op because `synchronize` ran first in the same transaction and the adapter's `is_time_to_update_funding` mirrors `market::is_time_to_update` (`now ≥ last − last % freq + freq`) |
| `clearing_house::place_market_order(is_ask, size, reduce_only)` | `size` is base at 9 decimals (`from_balance(size, 10^9)`), must be a lot multiple and nonzero; reduce-only clamps to the net position and aborts `9` on the wrong side; `execute_market_order` walks the book and **aborts `45` if any size is left unfilled** — never posts | fills are all-or-nothing; `active_fill`'s posted/partial checks are defensive |
| `clearing_house::end_session(_, _, false, false)` | applies liquidation fills, then `apply_taker_fills_and_settle(position, collateral_price, ask_base, ask_quote, bid_base, bid_quote, taker_fee, integrator_fee)`; with both flags false no collateral moves between account and position; requirement > margin aborts (`57` / `ensure_margin_requirements`) unless the trade reduced risk | `assert_trade_checkpoint` leaves `allocated` free (realized PnL − fees) and pins `free_collateral` |
| `SessionSummary::filled_base_and_quote`, `base_filled_*`, `execution_price`, `posted_orders`, `liquidated_size`, `liquidation_bad_debt` | field reads; `quote_filled = Σ size × maker_price` (u64 × u64, exact 18-dec); `execution_price = quote / base` via `ifixed::div` | the fill facts the trade proof is built from; F2 for the sign |
| `clearing_house::settle_position_funding` | F1; also requires the market unpaused | — |
| `clearing_house::update_funding` | `try_update_funding`: premium/spread TWAP updates when due, then `try_update_fundings` (both cumulative rates move by the same `premium_twap × period adjustment`, so long and short rates are always equal) | `update_funding_when_due` |
| `clearing_house::mark_price` | `calculate_mark_price(state, params, index, book_or_index, now)`: funding price + spread TWAP, clipped | passed to `compute_margin_and_requirement` exactly as `end_session` does |
| `clearing_house::settlement_valuation_prices` | reads the `SettlementPrices` dynamic field: `(enabled, base, collateral)` or `(false, 0, 0)` | shutdown path |
| `clearing_house::close_position_at_settlement_prices` | requires paused and closed; cancels the named orders (empty vector: requires none pending, abort `48`); settles funding; closes the position at the settlement prices; realizes into collateral; negative collateral resets to zero; moves the floor of the collateral to the account | proven by `assert_direct_settlement_checkpoint` |
| `clearing_house::share`, `position`, `market_params`, `market_state`, `market_pause_mode`, `is_frozen` | `share_object`; dynamic-field borrow by account id; field reads; `is_frozen` = a `frozen_version` dynamic field exists | checkpoint fields |
| `market::*_oracle_price` | storage-id check (abort `1001`/`1002`), feed by source id, staleness against `*_pfs_tolerance` (abort `1000`); the collateral read also checks index/TWAP divergence; returns the feed's raw `u128` price as `u256` | F4 |
| `market::lot_size`, `margin_ratio_*`, `collateral_haircut`, `*_storage_id`, `*_source_id`, `scaling_factor`, `taker_fee`, `priority_taker_fee`, `funding_params` (frequency, period), `funding_last_upd_ms`, `cum_funding_rates` | field reads | checkpoint fields, fee bound, funding timing |
| `market::resolve_priority_taker_fee` | unwraps the option, abort `1004` on none | fee bound |
| `position::collateral`, `base_and_quote_amounts`, `funding_rate_snapshots`, `pending_base_amounts_by_side`, `pending_order_count`, `initial_margin_ratio` | field reads (fields 1, 0/2, 5/6, 3/4, 7, 8) | checkpoint fields |
| `position::is_long_or_flat` | `!is_neg(base)` | side |
| `position::effective_initial_margin_ratio(m)` | `ifixed::max(position IMR, m)` | margin |
| `position::compute_margin_and_requirement(cp, mark, imr, haircut)` | `margin = collateral × cp × (1 − haircut if collateral ≥ 0) + unrealized_pnl(mark)`, `requirement = abs_net_base × mark × imr` where `abs_net_base = max(|base + bids|, |base − asks|)` | `margin_safe` = margin ≥ IMR requirement, the venue's own opening bound |
| `position::unrealized_pnl(price)` | `base × price − quote` | equity; F2 |
| `oracle_aggregator::price_feed_storage::storage_id`, `price_feed(source)` | field read; binary search then borrow | binding |
| `oracle_aggregator::price_feed::source_id`, `from`, `price_and_timestamp_ms` | field reads | binding; F4 |
| `ifixed::one`, `is_neg`, `abs`, `add`, `sub` | read 2026-09-19 | encoding |
| `authority::for` | field read | custody binding |

## Consequences

- The funding classifier is now the venue's arithmetic, so the funding-credit
  and funding-cost cases of the controlled health gate rehearse a proof
  rather than test an assumption.
- The Pyth chain is the open item: the adapter cannot run against mainnet
  until F4 is decided and implemented.
- The ABI gate now lists every function the adapter calls (six were missing;
  `calculate_position_funding_internal` is no longer called).

## Appendix: settlement model

```python
ONE = 10**18; SIGN = 1 << 255; MASK = (1 << 256) - 1
def neg(x): return (-x) & MASK
def is_neg(r): return r >= SIGN
def venue_settle(base, coll, snap_l, snap_s, price, cum_l, cum_s):
    base_neg = is_neg(base)
    mkt, snap, b = (cum_s, snap_s, neg(base)) if base_neg else (cum_l, snap_l, base)
    if mkt == snap or b == 0: return coll
    mneg, sneg = is_neg(mkt), is_neg(snap)
    if mneg == sneg: d, dneg = (mkt - snap, False) if mkt >= snap else (snap - mkt, True)
    else: dneg = mneg; d = ((neg(mkt) + snap) if mneg else (neg(snap) + mkt)) & MASK
    prod = d * b; assert prod <= MASK
    if base_neg != dneg:
        c = prod // price
        if c == 0: return coll
        if is_neg(coll): m = neg(coll); return c - m if c >= m else (coll + c) & MASK
        new = coll + c; assert new < SIGN; return new
    c = (prod + price - 1) // price
    if is_neg(coll): new = coll - c; assert new >= SIGN; return new
    return coll - c if coll >= c else neg(c - coll)
```
