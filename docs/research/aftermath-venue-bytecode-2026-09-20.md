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

## Finding applied the same day after review

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

**Applied:** venue-feed identity. The two `PriceInfoObject` arguments, the
Pyth port, `snapshot::pyth_price`, `normalize_feed_price`, `seconds_to_millis`
and two error codes are gone. `Binding` now carries the origin object id
(`PriceFeed.from`) of each feed the market priced with at activation, checked
on every capture next to the six object ids; the storages are checked against
the market's storage ids; the venue's named price functions (which the
bytecode pins to the bound feed's raw price after the venue's own staleness
and, for collateral, index/TWAP checks) are the price, and the feed's raw
price must equal them. Confidence is reported as zero. A classic-Pyth
tolerance check was considered and not adopted: a different property (two
sources, two update times) needing tolerance parameters, from the same
publisher network as Lazer.

## Finding applied with the shutdown reconciliation change (2026-09-20, evening)

### F5. A frozen clearing house cannot settle; a closed one can

`freeze_clearing_house` (clearing house 1196–1226) adds the `frozen_version`
dynamic field and writes `version := u64::MAX`; `unfreeze_clearing_house`
(1152–1184) removes the field and restores the stored version.
`assert_package_version` (8510–8519) requires `version <= 1` and runs first in
every mutator, `close_position_at_settlement_prices` (2806–2808) included. So
while a clearing house is frozen nothing can be called on it, the settlement
close included, and `is_frozen` is not the terminal predicate.

The venue's terminal path is a *closed* market. `close_market` (1407–1445)
writes `paused := 1`, updates funding once more and adds
`SettlementPrices { base_price: none, collateral_price: none, enabled: false }`;
`set_settlement_prices` (1458–1512) requires the closed field and two positive
prices; `enable_settlement` (1522–1578) requires both prices and flips
`enabled`. `close_position_at_settlement_prices` then requires, in order, an
unfrozen version (abort `10`), `paused != 0` (abort `33`), the closed field
(abort `34`) and `enabled` (abort `36`); with an empty order vector it requires
no pending orders (abort `48`); it settles funding at the settlement
collateral price, closes the whole base at the settlement base price through
`add_base_to_position`, realizes the difference into the position collateral,
resets negative collateral to zero against the insurance fund (abort `31`),
subtracts the entire remaining position collateral and pays its `to_balance`
floor to the account (vault balance abort `23`). The position collateral is
therefore exactly zero after a settlement close; the sub-atomic remainder
stays in the market vault, not in the position.

Pause modes are `0` live, `1` paused and `2` cancel-only
(`assert_valid_pause_mode` 8575). `update_funding` (2147), `update_twaps`,
`settle_position_funding` (2207), `start_session` (3110),
`deallocate_collateral` (7745), `create_market_position` and
`allocate_collateral` all require `paused == 0` (abort `32`), so on a paused
market the only venue action left to the adapter is the settlement close, and
only once the market is closed and settlement is enabled.

The adapter branched its unwind on `is_frozen()` and its settlement proof
required `market_frozen`, so the settlement close could never run: a frozen
market aborted inside the venue on the version check, and a closed market took
the market path and aborted on the pause check. **Applied:** `unwind` refuses a
frozen clearing house (`venue_not_ready`), branches on `is_market_paused()`,
and `assert_direct_settlement_checkpoint` requires `market_pause_mode != 0`.
`is_market_paused` joins the ABI gate.

Re-read 2026-09-21: the settlement close has no zero-base guard (2806–3050).
With a flat position it skips the close, still subtracts the entire position
collateral and pays its floor to the account, and `deallocate_collateral`
aborts `32` on any paused market. So when the venue closes the market after the
close-only steps have flattened the position but before `finalize_shutdown`
has run, the settlement close is the only way the allocated collateral leaves.
**Applied:** the proof admits a flat position whose collateral is still
allocated; a flat, unallocated position is still refused, so the step cannot
be repeated as a no-op.

Read for the same change: `is_time_to_update(now, last, freq)` (market 1944)
is `now >= last - last % freq + freq` (1954–1968), exactly the adapter's
mirror; `update_funding` reads the base index and TWAP, asserts their
divergence, refreshes both TWAPs when due, then `try_update_fundings`, which
moves both cumulative rates by `premium_twap × period adjustment` and writes
`funding_last_upd_ms := now`; `settle_position_funding` requires an unfrozen,
unpaused market, reads `collateral_oracle_price` and settles through
`settle_position_funding_and_emit` (F1); `withdraw_collateral` (account 282)
checks only the registry version and the cap, so terminal cash leaves the
account while the market is paused or frozen once the position is flat.

## Session path, deallocation and account calls, re-read 2026-09-21

Read the morning before the mainnet rehearsal, from the same disassemblies,
plus `registry` (`2800bcd5…61a9`, not consumed directly). Nothing below
changed the adapter; the table further down stays the summary.

- `place_market_order` (version check; `assert_reduce_only` returns the
  size, clamped to the net position for a reduce-only order and abort `9`
  when the side does not reduce it or the position is flat; abort `19` for a
  size that is not a lot multiple and `1` for zero) then
  `execute_market_order`: walks the opposite book leaf by leaf, calling
  `process_fill_maker` per maker order, subtracts each fill from the
  remaining size and **aborts `45` if any size remains**. Expired makers,
  the taker's own orders and makers a fill would push into bad debt fill
  zero and are dropped. A market order never posts.
- `process_fill_maker`: a fill against an ask maker (order key below 2^127)
  is recorded in `base_filled_bid`/`quote_filled_bid`, against a bid maker in
  the ask fields, and mixing sides in one session aborts `51`; the quote is
  `fill_base_and_quote_deltas(price, size) = size × price` exactly, the
  base `size × 10^9`. So `filled_base_and_quote(true)` is a taker ask's
  fill, as `opens_with_ask` assumes.
- `end_session_`: session and account ids must match (`18`); a session
  without fills, posts or a liquidation aborts `11`; the taker fee is
  `taker_fee`, plus `priority_taker_fee` when the transaction's gas price
  exceeded the reference gas price at `start_session`; `apply_taker_fills_and_settle`
  applies asks then bids through `add_base_to_position`, charges
  `rate × quote / 10^18` toward zero per rate, and moves `realized − fees`
  into the position collateral at the session's collateral price. With both
  flags false no cash moves between account and market vault (`loc28 = 0`).
  After the trade, `requirement > margin` at the effective IMR is tolerated
  only through `position::ensure_margin_requirements`: the requirement may
  not have grown, the position may not have flipped, and when margin fell
  the margin-to-requirement ratio may not have worsened (`2001`/`2002`).
  Open-interest limits: `new_oi ≤ max_open_interest` or not above the
  previous (`15`), and when `new_oi` exceeds `max_open_interest_threshold`
  and `|base|` grew, `|base| / new_oi ≤ max_open_interest_position_percent`
  (`16`).
- `add_base_to_position`: reducing a long closes `ceil(quote × fill / base)`
  of the cost basis, reducing a short `floor(|quote| × fill / |base|)`, so
  realized PnL rounds against the trader; opening adds base and quote under
  one sign (F2); overflow aborts `2000`.
- `deallocate_collateral` → `deallocate_collateral_internal` (version, not
  paused, cap valid; reads both prices, asserts index/TWAP divergence,
  refreshes fundings and TWAPs when due) → `withdraw_free_collateral_to_account_balance`:
  settles the position's funding, computes `compute_free_collateral` at the
  venue mark and effective IMR, floors it to atoms with `to_balance`, aborts
  `0` on a zero request and `40` when the request exceeds that floor, then
  subtracts exactly `from_balance(amount, scaling_factor)` from the position
  and pays `amount` to the account, returning `amount`. A flat, order-free
  position's free collateral is `max(0, collateral)` with no haircut, so
  the finalize withdrawal of `floor(allocated)` is admissible and leaves the
  sub-atomic remainder the adapter expects.
- `clearing_house::mark_price` = `calculate_mark_price(state, params,
  base TWAP, book price or index, now)`: the book price clamped between
  the funding price and index plus spread TWAP. The adapter passes it
  through unchanged.
- `account::create_account` (registry version `5000`, collateral registered
  `4002`, derived id, one `ACCOUNT/ADMIN` cap), `consume_policy_and_share_account`
  (policy id must be the account's, `4003`), `deposit_collateral` and
  `withdraw_collateral` (registry version, `assert_authority_cap_is_valid`:
  `cap.for == account.id` and role `ADMIN`, or an active assistant; zero
  amounts are no-ops).
- `market::base_oracle_price` / `collateral_oracle_price`: storage id
  (`1001`/`1002`), feed by source id (binary search, abort if absent),
  `timestamp ≥ now − tolerance` (`1000`), the raw `u128` price as `u256`;
  the collateral read also asserts index/TWAP divergence (`1003`).
- `position` getters and `authority::for` are field reads; `Position` is
  `{collateral, base, quote, snapshot_long, snapshot_short, asks, bids,
  pending_orders, initial_margin_ratio}`; `create_position` starts every
  position at IMR `1.0`.

### Operational facts for launch

- Both `ClearingHouse.version` and `Registry.version` must be `≤ 1`. An
  Aftermath upgrade that raises either blocks every adapter call, exits
  included, until the adapter is relinked against the new ABI; the ABI gate
  reports the drift first.
- The venue refuses an increase that pushes the vault past
  `max_open_interest_position_percent` once open interest exceeds
  `max_open_interest_threshold` (abort `16`); the NAV cap must respect the
  market's limits.
- A redemption's payout is deallocated against venue free collateral at the
  position IMR floor. With the floor at the inverse of the hard cap, free
  collateral is about zero at the cap, so a redemption there aborts `40`
  until a rebalance brings leverage down.
- A reducing trade may end under IMR only if the margin ratio did not
  worsen, which holds unless margin is below the taker fee on the sold
  notional.
- If the venue closes the market between the last close-only step and
  `finalize_shutdown`, run `unwind` once more: the settlement close releases
  the allocated collateral into the account, and `finalize_shutdown` then
  withdraws it without a deallocation, which a paused market refuses.

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
| `clearing_house::close_position_at_settlement_prices` | requires an unfrozen version (abort `10`), `paused != 0` (abort `33`), the closed field (abort `34`) and `enabled` (abort `36`); cancels the named orders (empty vector: requires none pending, abort `48`); settles funding at the settlement collateral price; closes the position at the settlement base price; realizes into collateral; negative collateral resets to zero against the insurance fund (abort `31`); subtracts the whole position collateral and pays its floor to the account (abort `23`) | F5; proven by `assert_direct_settlement_checkpoint` |
| `clearing_house::share`, `position`, `market_params`, `market_state`, `market_pause_mode`, `is_frozen`, `is_market_paused` | `share_object`; dynamic-field borrow by account id; field reads; `is_frozen` = a `frozen_version` dynamic field exists, and freezing also writes `version := u64::MAX` (F5); `is_market_paused` = `paused != 0` | checkpoint fields; the unwind branch |
| `market::*_oracle_price` | storage-id check (abort `1001`/`1002`), feed by source id, staleness against `*_pfs_tolerance` (abort `1000`); the collateral read also checks index/TWAP divergence; returns the feed's raw `u128` price as `u256` | F4 |
| `market::lot_size`, `margin_ratio_*`, `collateral_haircut`, `*_storage_id`, `*_source_id`, `scaling_factor`, `taker_fee`, `priority_taker_fee`, `funding_params` (frequency, period), `funding_last_upd_ms`, `cum_funding_rates` | field reads | checkpoint fields, fee bound, funding timing |
| `market::resolve_priority_taker_fee` | unwraps the option, abort `1004` on none | fee bound |
| `position::collateral`, `base_and_quote_amounts`, `funding_rate_snapshots`, `pending_base_amounts_by_side`, `pending_order_count`, `initial_margin_ratio` | field reads (fields 1, 0/2, 5/6, 3/4, 7, 8) | checkpoint fields |
| `position::is_long_or_flat` | `!is_neg(base)` | side |
| `position::effective_initial_margin_ratio(m)` | `ifixed::max(position IMR, m)` | margin |
| `position::compute_margin_and_requirement(cp, mark, imr, haircut)` | `margin = collateral × cp × (1 − haircut if collateral ≥ 0) + unrealized_pnl(mark)`, `requirement = abs_net_base × mark × imr` where `abs_net_base = max(|base + bids|, |base − asks|)` | `margin_safe` = margin ≥ IMR requirement, the venue's own opening bound |
| `position::unrealized_pnl(price)` | `base × price − quote` | equity; F2 |
| `oracle_aggregator::price_feed_storage::storage_id`, `price_feed(source)` | field read; binary search then borrow | binding |
| `oracle_aggregator::price_feed::from`, `price_and_timestamp_ms` | field reads | feed-origin binding; the price leg |
| `ifixed::one`, `is_neg`, `abs`, `add`, `sub` | read 2026-09-19 | encoding |
| `authority::for` | field read | custody binding |

## Consequences

- The funding classifier is now the venue's arithmetic, so the funding-credit
  and funding-cost cases of the controlled health gate rehearse a proof
  rather than test an assumption.
- The ABI gate now lists every function the adapter calls (six were missing;
  `calculate_position_funding_internal`, `price_feed::source_id` and the Pyth
  modules are no longer called).

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
