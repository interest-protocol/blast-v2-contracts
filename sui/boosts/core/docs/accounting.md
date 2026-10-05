# Series1 accounting library

The package-private accounting modules inside
`blast_boosts_core` implement the stable arithmetic accepted in
[ADR 0064](../../../../docs/decisions/0064-aftermath-backed-leverage-coins.md).
They own no state or authority. Future Vault transitions authenticate inputs,
call this math, and apply its results atomically.

Before changing this math, read
[the leverage implementation lessons](../../../../docs/leverage-implementation-lessons.md)
and the latest audit record under `docs/research/`.

## Product naming

The intended public display names are `SUI 2x Bull` for `SUI2L` and
`SUI 2x Bear` for `SUI2S`. The symbols remain `SUI2L` and `SUI2S`; their Move
currency types are distinct adapter-owned `Vault<Product>` instantiations.
Protocol code uses `long` and `short` for the immutable position side. Bull and
Bear are metadata and UI terms only. Product descriptions must say that the
coins target approximately 2x exposure and can be liquidated.

## Modules

- `lib/accounting_math.move` — pure share, fee, leverage, exposure, shareholder-NAV,
  reserve-credit, and exact negative-funding absorption arithmetic. The mint and
  redemption quotes derive shareholder NAV from venue equity and reserve; the
  leverage, target-notional, and mint-exposure formulas take a shareholder NAV
  that State computes once per checkpoint through `shareholder_nav`. This
  module cannot authenticate venue funding; the adapter and the Series
  transition own that obligation.

## Units, bounds, and rounding

| Quantity | Unit | Note |
| --- | --- | --- |
| venue equity, shareholder NAV, maintenance reserve | atomic collateral (USDC) | `shareholder_nav = venue_equity - maintenance_reserve` |
| deposit, fee, payout, funding cost | atomic collateral (USDC) | one price pair per operation |
| shares | atomic Share units | `SUI2L` or `SUI2S` |
| base exposure | absolute atomic venue base units | direction is never encoded here |
| fee rate | basis points below 10,000 | proves `fee <= amount` |
| leverage rate | basis points of 1x | `20_000` is 2x; no 10,000 ceiling |
| depositor share floor | atomic Share units | `min_shares_out`, supplied per mint by the depositor; zero means no floor |
| minimum operation size | live venue lots | `min_order_lots`, an immutable Series policy value at most 1,000,000 lots; this package selects no value for it |
| NAV cap | atomic collateral | positive live `State` value, set at issuance and adjustable by the risk admin, whose max-leverage notional fits in `u64`; simulation selects its value |
| price freshness window | milliseconds | `max_price_age_ms` and `max_price_ahead_ms`, both immutable policy values on the on-chain millisecond scale |
| price confidence | absolute interval in the price's own units | bounded by `max_confidence_bps` basis points of that price |
| mark divergence | absolute difference in the index's own units | bounded by `max_mark_divergence_bps` basis points of the index |

Every input is a `u64`. Every product uses a `u128` or wider intermediate, so a
`u64` times a `u64` cannot wrap. Every potentially unbounded result passes the
checked narrowing helper and aborts with code 15 outside the `u64` range. Other
casts follow a documented bound that keeps their source value inside `u64`.

Share rounding never favors the transacting holder at the expense of existing
shares. Exposure rounding favors lower risk but can create underexposure:

| Function | Rounding | Who keeps the remainder |
| --- | --- | --- |
| `fee_up` | up | the maintenance reserve |
| `mint_quote` shares | down | existing holders |
| `redemption_quote` kept equity | up | remaining holders |
| `leverage_bps_up` | up | risk reporting stays conservative |
| `target_notional_down` | down | the planned order stays under target |
| `allocated_mint_quote` contribution cap | `min(NAV rise, deposit - fee)` | existing holders keep a favorable fill's excess |
| `redemption_quote` gross cap | `min(nav_after_sell, nav_before) - equity_keep` | remaining holders keep a favorable sell's excess |
| `mint_base_to_buy_down` | down to the live lot | unopened sub-lot exposure, below `1 / min_order_lots` of the target |
| `mint_base_bounds` | `[actual, planned]`; the capped contribution keeps `actual <= planned` | a partial fill may leave at most the actual contribution's exposure unopened |
| `redemption_base_bounds` keep | down | remaining holders |
| `redemption_base_bounds` planned reduction | up to the live lot, capped at flat | over-reduction below one lot and below `1 / min_order_lots` of the required reduction |

### Mint contribution cap

A depositor is credited at most what they paid. With `D` the deposit,
`protocol_fee` the ceiling-rounded fee on `D` (its admin allocation is retained
locally and its reserve allocation is credited to the reserve), `N0` and `N1`
the shareholder NAV before and after the mint at one price pair, and `S0`
the supply, `allocated_mint_quote` credits:

```text
contribution = min(N1 - N0, D - protocol_fee)
shares_out   = floor(S0 * contribution / N0)
```

`N1 <= N0` still aborts with the nonpositive-contribution code, so execution
cost reaches the depositor exactly as before. When a venue fill is better than
the oracle price, the excess `N1 - N0 - (D - protocol_fee)` mints no shares and
stays with the existing holders, whose NAV per share rises. The cap lives
inside the quote, so no Series transition can bypass it, and it needs no
policy value (ADR 0084 D3). `allocated_mint_quote` applies the same cap as
`min(N1 - N0, D - F)`.

Because the credited contribution can no longer exceed the expected one, the
mint exposure range `mint_base_bounds` is `[delta(actual), delta(expected)]`
with `actual <= expected`; when the cap binds the range collapses to the
planned fill.

This cap does not authenticate an execution price and does not replace the
user's slippage bound or the adapter's strict and emergency execution
tolerances. Those checks remain separate integration gates.

### Redemption gross cap

A redeemer is paid at most their proportional share. For `x` burned shares
with `keep = ceil(N0 * (S0 - x) / S0)`, `claim = N0 - keep`, and `Nu` the
shareholder NAV after the proportional sell at the same price pair,
`redemption_quote` pays:

```text
gross = min(Nu, N0) - keep
fee   = ceil(gross * redeem_fee_bps / 10_000)
net   = gross - fee
```

so `gross <= claim`. A sell that costs the Series pays `Nu - keep`; one
that gains pays exactly `claim`, and the gain stays with the remaining holders.
With one share of a million burned against a 100-unit pool-wide gain the claim
is 1 and the gross is 1, not 101. `min(Nu, N0) <= keep` aborts with the
nonpositive-gross code, so the redeemer's payoff is bounded on both sides and a
favorable sell cannot rescue a claim the rounded-up kept equity consumed.

`redemption_accounting_quote` returns `nav_kept = Nu - gross`, the shareholder
NAV that actually remains, beside `proportional_claim`; `nav_kept` is at least
`keep`, and the Series derives the required final venue equity from it. Fee,
net, reserve credit, and `min_usdc_out` apply to the capped gross unchanged.

### Depositor share floor and seed sizing

`mint_quote` floors `shares_out`, so a depositor can lose up to one pre-mint
share of NAV to rounding. That loss is bounded only by the share price, which
the locked seed sets: a one-share pool at NAV 1e9 mints one share for a
1,999,999,999 deposit, a 25 percent loss, and one unit less aborts as zero
shares. `allocated_mint_quote` takes `min_shares_out` so the depositor can
bound the loss themselves; the Series must pass the depositor's value through
unchanged. Independently, the seed must keep one share economically dust: to
cap any depositor's rounding loss at `X` bps, the seed supply `S` must satisfy
`floor(S * c / N) >= 10_000 / X` for the smallest legal contribution `c`, which
with the minimum operation size is `S >= (10_000 / X) * base / (lot_size *
min_order_lots)`. That sizing is a release gate on the seed slice.

### Proportional exposure and the minimum operation size

`mint_base_to_buy_down`, `mint_base_bounds`, and `redemption_base_bounds` are
the arithmetic of invariant I26. Every proportional exposure change must be at
least `lot_size * min_order_lots`, except a redemption that reaches flat.

A mint is sized before its trade from the expected contribution
`deposit - fee`. After the trade the Series must call
`assert_mint_base_within_bounds` with both the expected contribution and the
actual contribution `nav_after - nav_before`. The admitted final base is
`base_before + [min(actual_delta, planned_delta), planned_delta]`: a full fill
of the plan always passes, a partial fill may not leave the actual
contribution's exposure unopened, and a fill above the plan is rejected. Both
contributions must clear the minimum, so a mint whose actual credited
contribution is dust aborts even if its plan was not. The range does not bound
the over-exposure created by execution cost; the Series' final leverage gate
and the user's slippage bound own that residual.

A redemption returns a two-sided range: the final absolute base must not exceed
the proportional keep `Q_keep` of I11, and it must not be more than one lot
below it. `assert_redemption_base_within_bounds` re-derives both bounds from
the canonical inputs and rejects an actual final base outside them, so every
partial-fill condition is cumulative.

The mint range does not bound execution-cost over-exposure, and the residual
is large: from 2.0x with a deposit equal to NAV, a fill that loses half the
deposit still admits the complete plan and leaves the pool at 2.67x, and a 95
percent loss admits 3.81x. The Series' post-trade leverage gate is a hard
release blocker, not an optional check.

The minimum has a sharp lock condition. The required reduction is largest when
a redemption burns all but one share, where it equals
`base_before - floor(base_before / shares_before)`. When that is below
`lot_size * min_order_lots` and `base_before >= shares_before`, every burn
count aborts with code 12 and the position is locked for every holder; the
flat exemption is unreachable because a zero proportional keep needs
`base_before < shares_before`. With base 100,000, supply 1,000, lot 1,000 and
a hundred-lot minimum, none of the 999 burn counts is legal. The state is
reachable: a leveraged long that rebalances after a drawdown shrinks base
toward zero, and once base is zero with live shares no mint can pass
`mint_base_to_buy_down` either. Initialization uses
`is_base_above_min_order`; ordinary redemptions enforce the exact
bounds in `redemption_base_bounds`. Health synchronization does not change
lifecycle for unavailable ordinary operations. Explicit terminal handling is
a separate lifecycle contract.

The minimum operation size is what turns the per-operation lot tolerance into
a cumulative bound. With relative under-exposure below
`e = 1 / min_order_lots`, each legal mint multiplies accounting leverage by
at least `1 - e * contribution / (nav_before + contribution)`, so after any
sequence of mints from leverage `L0` and NAV `N0` the leverage stays close to
`L0 * (N0 / N)^e` where `N` is the final NAV. The closed form is a lower bound;
the attained worst case is `e = 1 / (min_order_lots + 1)`. The regression
test `repeated_worst_case_mints_leave_the_band_with_a_one_lot_minimum` pins
that a one-lot minimum lets worst-case mints move a 2.0x pool below 1.8x on
mint 2,229, with the pool at 1.7397x and NAV up 32 percent after 3,000 mints;
its twin pins that a hundred-lot minimum keeps the same sequence at 1.9455x
after 3,000 mints and NAV growth of sixteen times. The
Series must select `min_order_lots` from simulation, keep
`lot_size * min_order_lots` small in collateral terms so exits are not
stranded, and verify the live lot size against the deployed market (P16).

These pure modules cannot observe NAV, supply, reserve state, or venue exposure.
Each caller must supply values from one canonical price pair. The later
adapter must settle and authenticate funding exactly once first. Signed
direction, reduce-only flags, and the final signed-position check belong to the
later adapter.

## Maintenance reserve accounting

The maintenance reserve is actual USDC collateral in the same isolated venue
account. It improves venue equity and liquidation margin, but it is excluded
from shareholder NAV, share price, accounting leverage NAV, and target-notional
sizing:

```text
shareholder_nav = venue_equity - maintenance_reserve
```

Mint and redemption fees credit the reserve. `prepare_mint` computes the fee
once through `fee_allocation`; `allocated_mint_quote` then derives post-mint
NAV with the credited reserve, requires a positive contribution, and only then
calls the share formula, so the fee is excluded exactly once and cannot be
subtracted twice. `redemption_accounting_quote` derives post-sell NAV with the old
reserve, then credits the new fee. Final shareholder NAV is exactly
`equity_keep`, not `equity_keep + fee`. The pure sequence removes the
split-redemption fee-recapture path; the later atomic state transition must use
these canonical functions and reconcile their outputs.

The raw NAV-taking formulas are private inside `accounting_math`, so the Move
compiler rejects any future production module that tries to bypass the
reserve-aware operations. The source-boundary gate separately rejects any
production caller of bare funding-cost absorption until the typed
funding-completion path exists.

Only an exact authenticated negative funding settlement may debit the reserve
during normal operation:

```text
absorbed      = min(reserve_before, funding_cost)
reserve_after = reserve_before - absorbed
uncovered     = funding_cost - absorbed
```

If venue equity has already fallen by `funding_cost`, shareholder NAV falls
only by `uncovered`, and `uncovered` accumulates in the State's
`uncovered_deficit`. A later positive settlement repays that deficit first:

```text
restored      = min(credit, uncovered_deficit)
deficit_after = uncovered_deficit - restored
reserve_after = reserve_before + credit - restored
```

Because the venue already added the whole credit to equity, keeping
`restored` out of the reserve is what raises shareholder NAV by exactly that
amount; only the remainder rebuilds the reserve. A cost of 150 against a
reserve of 100 followed by a credit of 300 therefore leaves NAV whole and the
reserve at 250. The repayment goes to current holders, as every reserve
movement does; the vault keeps no per-holder ledger. Trading
fees, slippage, price PnL, liquidation, ADL, and socialized loss are not funding
costs. The future adapter must derive the exact cost from an authoritative
Aftermath funding accumulator or checkpoint; it may not infer funding from a
total-equity delta. The reserve mutation and checkpoint update must be atomic
and exactly once.

The reserve is bookkeeping inside a margin account, not bankruptcy-remote
custody. A non-funding loss can physically impair the account. Ordinary priced
operations require `maintenance_reserve <= venue_equity`; an observed breach
fails priced operations closed, without clamping NAV or changing lifecycle.
Health reports authenticated checkpoint faults without declaring liquidation.
Only a shutdown-role witness starts the irreversible Active → Unwinding →
Settled path. No admin or keeper can claim the reserve book entry.

Finalization consumes that entry into actual recovered holder cash only after
the adapter proves exact flat exposure, no orders, settled funding and
liabilities, and complete cash withdrawal. Final claims use native treasury
supply minus locked seed, not active shareholder NAV or a second supply ledger.
They floor each remaining-cash fraction, charge no fee and give the final
eligible claimant all remaining cash. With no eligible supply, the adapter
keeps all recovered cash as admin cash. Admin collateral is separate and never enters
the holder pool.

### Priced-operation predicates and health synchronization

Reserve backing, positive shareholder NAV, price, and proportional exposure
bounds are enforced by priced operations. Health synchronization consumes its
authenticated capture inside the adapter and uses the checkpoint for aggregate
funding settlement; drift is reported by event, never stored. It does not
construct a Series1 position observation or persist lifecycle degradation on temporary
economic faults.

A redemption whose proportional claim is smaller than its sell cost aborts
with code 7 rather than a size code, because the minimum-size guard lives in
`redemption_base_bounds`, which the canonical quote does not call. The Series
must size the sell through `redemption_base_bounds` before it quotes.

## Valuation gates

The `PricePolicy` type in `blast_boosts_core::policy` fixes the locally enforceable shape
of the freshness,
confidence, and index-versus-mark rules that ADR 0064 I25 requires. It holds
four immutable `u64` bounds and applies them through three gates. It selects no
value, reads no source, and binds no source identity.

| Gate | Rule | Applies to |
| --- | --- | --- |
| `assert_price_fresh` | `publish_time_ms` lies in the closed interval `[now_ms - max_price_age_ms, now_ms + max_price_ahead_ms]` | each share-pricing source, so every priced operation and every risk increase |
| `assert_confidence_within_bound` | `confidence * 10_000 <= max_confidence_bps * price` | each share-pricing source, so every priced operation and every risk increase |
| `assert_mark_within_oracle_divergence` | `abs(mark_price - oracle_price) * 10_000 <= max_mark_divergence_bps * oracle_price` | venue margin safety only; never share pricing, NAV, or accounting leverage |

Share pricing stays base-index plus collateral-oracle price. The venue mark
is only the separate margin-safety and divergence check, so the boundary script
rejects standalone and snake-case `mark` identifiers in `accounting_math`.
This lexical gate supports review; it does not authenticate the economic origin
of an arbitrarily named numeric input.

Boundary and width semantics:

- Every bound is inclusive. An observation exactly at a bound is admitted and
  the first rejected value is one unit past it.
- Freshness branches on the order of its two operands, so neither subtraction
  can underflow, and the window saturates instead of wrapping at `u64` width.
- Both relative bounds cross-multiply through `u128` rather than dividing, so a
  maximum-width price with a maximum-width interval cannot wrap and no result
  needs narrowing.
- A stale update and a future-dated update abort with different codes because an
  outage and a skewed or misreporting source need different responses.
- Both gated prices must be positive. A zero price makes a relative bound
  meaningless and is itself a source failure, so it fails closed before the
  bound is read.

Zero-policy validity:

- `max_price_age_ms` must be positive because the structural policy requires a
  nonzero historical-age tolerance. Positivity alone does not prove that the
  selected value supports the deployed source cadence; that remains a live
  integration and simulation gate.
- `max_price_ahead_ms` may be zero. Zero is the strictest clock-skew policy and
  rejects the first millisecond after the reference time.
- `max_confidence_bps` and `max_mark_divergence_bps` may be zero, which demands
  an exact price and an exact mark. Both must stay below 10,000: at or above the
  denominator a confidence interval may span the complete price and a divergence
  bound admits a zero mark, so the gate would stop constraining the observation.
- No upper millisecond bound is structural. The deployed source cadence, keeper
  latency, venue margin parameters, and simulation select every value.

Each assertion uses its matching non-aborting predicate:
`is_price_fresh`, `is_confidence_within_bound`, and
`is_mark_within_oracle_divergence`. Priced operations reject failures before
financial mutation; health synchronization does not use these predicates to
change lifecycle.

What this module does not close:

- the operation-scoped linear price carrier that would make one captured
  pair provably the same for the pre- and post-operation checks. Its field
  layout depends on the future Vault handoff and the unresolved signed
  fixed-point normalization of premise P17;
- exact source identity, binding, and authentication, which stay with the future
  Vault and adapter. Nothing here proves which source produced an observation
  or that a caller did not choose among historical updates;
- the numbers. Every millisecond and basis-point value is a simulation and
  live-market gate.

## Package integration

Verification commands and deferred stateful work are recorded in the parent
[README](../README.md); `lib/errors.move` is the package abort registry. The future financial
transitions in `state.move` are the only production consumers of these
calculations. Venue adapters provide authenticated execution facts; they do
not price shares or select accounting inputs.
