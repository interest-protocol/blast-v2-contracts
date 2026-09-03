# 0064: Aftermath-backed `SUI2L` and `SUI2S` leverage coins

- Status: proposed
- Date: 2026-08-31

## Sources

| Short ref | Full commit | Repository |
| --- | --- | --- |
| `interfaces@f62e74a` | `f62e74aa862ef65b8950a70d83aac8cb71c19837` | `AftermathFinance/move-interfaces` |
| `sdk@449f8e6` | `449f8e6e52a7829fd8b2fe3c9d3145beef5316f5` | `AftermathFinance/aftermath-ts-sdk` |

The primary-source and deployed-package review is in
[the Aftermath Perpetuals research report](../research/aftermath-perps-package-frontend-2026.md).
The public Move repository contains compilation interfaces whose function
bodies deliberately abort. It proves type layouts and call signatures, not the
implementation semantics behind them.

## Context

Blast wants two standalone fungible quote coins:

- `Coin<SUI2L>`, backed by an isolated approximately 2x long SUI-USDC
  perpetual position; and
- `Coin<SUI2S>`, backed by a different isolated approximately 2x short
  SUI-USDC perpetual position.

Each coin is its own protocol. The Blast launchpad may admit its exact coin
type as `Quote`, but does not price it, rebalance it, custody its margin, or
import its packages. Long and short supply need not match. Aftermath's order
book supplies the counterparty, so the two Series must never net positions,
share margin, or bail each other out.

The product cannot promise a constant 2x return, a one-dollar peg, or freedom
from liquidation. Funding, fees, slippage, rebalancing, liquidation, ADL,
socialized loss, and market settlement all change recoverable equity. A coin in
a wallet remains a claim on the Series after a loss; it is not deleted when the
backing account is liquidated.

Aftermath account authority is capability-based. Account creation returns an
`Account<T>`, an `AccountSharePolicy`, and an account admin capability
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/account.move:98-126`).
The capability has `key + store`, so an application package can wrap it
(`interfaces@f62e74a:packages/authority-cap/authority-cap/sources/authority.move:71-84`).
Deposits, withdrawals, margin allocation, and trading use that capability
instead of treating `tx_context::sender` as account ownership
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/account.move:180-228`,
`interfaces@f62e74a:packages/iperps/perpetuals/sources/clearing_house.move:907-955`).

The same authority can create assistant capabilities
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/account.move:192-217`).
Blast must not create one. An assistant would add a second path around the
Series risk policy.

## Decision

### Product and package boundary

Build two upgradeable packages and leave `blast_fun` unchanged:

```text
blast_fun
  accepts Coin<SUI2L> or Coin<SUI2S> only after quote allowlisting
  imports neither leverage package

blast_leverage_coins
  defines SUI2L, SUI2S, Series, lifecycle, share math, policy,
  treasury custody, sealed handoffs, events, and package administration
  imports no venue

blast_leverage_aftermath
  owns the Aftermath account capability and exact venue binding
  translates Aftermath state into normalized core receipts
  imports blast_leverage_coins and pinned Aftermath interfaces
```

This is a Bind-Handoff-Redeem adapter. Core records the original defining type
of the approved adapter witness. A public adapter operation obtains its
package-only witness, asks core for a no-ability instruction, performs the
exact Aftermath calls, and returns the no-ability completion token plus the
actual result to core. The operation completes inside one Move call and one
Sui transaction. Nothing can copy, drop, store, or carry an in-flight handoff
into another transaction.

Directly importing Aftermath into core is rejected. It would make coin supply,
share math, and lifecycle depend on venue ABI and licensing. A cross-transaction
request queue is also rejected for the first release because Aftermath exposes
same-transaction market execution and settlement.

### Product naming

Public coin metadata and product surfaces use `SUI 2x Bull` for `SUI2L` and
`SUI 2x Bear` for `SUI2S`. The compact symbols and Move types remain `SUI2L`
and `SUI2S`. Contract code, events, risk policy, and technical documentation
use `long` and `short` for position direction because those terms define the
immutable venue-side invariant. Bull and Bear are presentation names only and
must never select or authorize a position side.

Descriptions must say that each coin targets approximately 2x exposure. They
must not imply constant 2x performance, freedom from liquidation, or insurance
against venue loss.

### Coin and Series topology

`blast_leverage_coins` defines unrestricted nine-decimal `SUI2L` and `SUI2S`
currencies. Each has one shared `Series<Share, USDC>` and one separate shared
Aftermath `Account<USDC>`:

```text
Series<SUI2L, USDC>                 Series<SUI2S, USDC>
  TreasuryCap<SUI2L>                 TreasuryCap<SUI2S>
  side = long                        side = short
  target = 20_000 leverage-bps       target = 20_000 leverage-bps
  lower = proposed 18_000            lower = proposed 18_000
  upper = proposed 22_000            upper = proposed 22_000
  one adapter binding                one adapter binding
        |                                  |
VenueAccount<SUI2L, USDC>           VenueAccount<SUI2S, USDC>
  Account admin cap A                Account admin cap B
  account A + SUI market             account B + SUI market
```

One leverage-bps unit is `1 / 10_000` of 1x, so `20_000` means 2x. This unit
must not reuse the ordinary fee `Bps` type, whose maximum is 10,000.

The preliminary 1.8x to 2.2x idle band is a product hypothesis, not an accepted
constant. Historical SUI price, order-book depth, funding, keeper latency, and
liquidation simulations must select the final band. The initial mainnet cap
must be small enough to unwind through executable depth, not headline open
interest.

Independent of those final values, every Series leverage policy satisfies:

```text
0 < lower < target < upper < hard cap
```

The strict upper-to-hard-cap gap ensures the ordinary reduction threshold is
reached before the terminal risk limit. `series.move` constructs a
typed `LeverageBounds` value and validates this relationship without compiling
any proposed economic value into the package.

The planned Move abilities make custody and temporary authority explicit:

| Type | Abilities | Ownership and purpose |
| --- | --- | --- |
| `Series<Share, USDC>` | `key` | Shared core supply and lifecycle authority; cannot be wrapped or transferred as a child. |
| `VenueAccount<Share, USDC>` | `key` | Shared adapter custody for the one Aftermath admin cap; cannot be wrapped or transferred as a child. |
| `SeriesPolicy` | `copy, drop, store` | Immutable validated numeric and direction values stored inside Series. |
| `LeverageBounds` | `copy, drop, store` | Strictly ordered lower, target, upper, and hard-cap leverage values constructed and stored within the future Series policy. |
| `ValuationPolicy` | `copy, drop, store` | Immutable validated freshness, confidence, and mark-divergence bounds stored by the future Series policy. |
| `PositionCheckpoint` | `copy, drop, store` | Venue mutation primitives stored inside VenueAccount. |
| `Lifecycle` | `drop, store` | Closed non-copyable internal state enum. |
| `AdapterWitness` | `drop` | Ephemeral package-authentic witness with a package-only constructor. |
| operation handoffs and completions | none | Linear same-call obligations that cannot escape. |
| admin and guardian witnesses | `drop` | Ephemeral proof of current package-local ACL membership. |

The package marker one-time witnesses follow the native currency pattern. No
public wrapper gives `store` to Series, VenueAccount, or a handoff.

### Consensus state

`Series<Share, Collateral>` owns only facts required for supply, authorization,
and invariant enforcement:

- the `TreasuryCap<Share>`;
- immutable direction and normalized risk bounds;
- mint and redeem fee rates, the minimum operation size in live venue lots
  (`min_exposure_lots`), and a hard Series NAV cap;
- the separately accounted maintenance-reserve balance;
- lifecycle: `Active`, `ReduceOnly`, `ShutdownPending`, or `ShutdownSettled`;
- the approved adapter witness type and exact venue-account binding;
- the adapter object id that owns the mutation-sensitive venue checkpoint.

It does not store display NAV, token price, current leverage, a SUI price, or a
market-cap projection. These are derived from current venue state. The
contract calculates them during a transition, and the SDK mirrors the same
integer math for previews.

Core and adapter `PackageVersion` objects are separate shared singletons. A
Series does not duplicate their versions. Mint fees, redemption fees, the
target band, hard leverage limit, margin buffer, and hard NAV cap are immutable
for the first Series deployment. A guardian can stop new risk but cannot edit
economics. Any later mutability requires a new accepted ADR with explicit
bounds, delay, authority, and event coverage.

`VenueAccount<Share, Collateral>` owns:

- the single `AuthorityCap<ACCOUNT, ADMIN>`;
- the exact Series, Aftermath account, registry, clearing-house, market, base
  oracle, and collateral oracle bindings;
- an immutable expected side; and
- the latest position checkpoint required to detect liquidation, ADL,
  settlement, order creation, collateral movement, or other out-of-band
  mutation.

Construction and every sensitive call verify that `authority::for(cap)` is the
bound account id. The interface exposes this binding read
(`interfaces@f62e74a:packages/authority-cap/authority-cap/sources/authority.move:140-143`).

No function returns or borrows the admin capability, chooses another account,
chooses another market, creates an assistant, places a caller-shaped order, or
withdraws collateral outside a completed core redemption.

The checkpoint records only mutation-sensitive primitives needed by on-chain
checks: account balance, allocated collateral, signed base and quote amounts,
the authoritative funding accumulator or settlement snapshots, and
pending-order state. It does not persist the current oracle price or derived
NAV. The integration spike must prove which exact Aftermath fields change under
funding settlement, liquidation, ADL, and socialized loss before the final
layout is accepted. A total-equity delta is never sufficient evidence of a
funding payment because it can also contain price PnL, execution loss,
liquidation, or socialized loss.

### Construction and permanent seed

There is no publicly shared bootstrap state. After the two packages and coin
types exist, one Series-construction transaction:

1. creates the Aftermath account and admin cap;
2. binds the exact SUI-USDC clearing house and oracle sources;
3. deposits protocol-funded USDC;
4. creates the one position and configures the accepted position margin rule;
5. opens the required long or short exposure;
6. verifies the final account, side, position, margin, and empty-order state;
7. selects a protocol-funded initial reserve `R_seed < E_seed`, computes final
   post-opening shareholder NAV `N_seed = E_seed - R_seed`, creates the Series, mints
   `floor(N_seed * 10^9 / 10^6)` atomic seed shares at the initial one-USDC
   display scale, and transfers all seed shares to `@0x0`;
8. consumes the account share policy and shares the fully bound account,
   adapter object, and Series; and
9. emits the creation event only after every child and binding is complete.

The locked shares and their backing are permanent first-loss protocol capital.
They keep total supply positive, prevent a final-holder drain and zero-supply
restart, and receive their pro-rata part of any reserve released only during
final shutdown settlement. There is no normal `x == total_supply` redemption
because the zero-address shares can never be presented.

### Canonical valuation checkpoint

Every supply-changing or exposure-changing operation first updates and settles
funding, verifies current oracle and market inputs, and captures one immutable
base-index and collateral-oracle valuation pair for the operation. The pair
comes from the exact sources pinned in the Aftermath market parameters. The
pre- and post-operation valuations use that same pair. The adapter separately
checks the venue mark and its allowed index divergence for margin safety. A
caller cannot choose either price. The adapter normalizes the venue's signed
fixed-point values into core units with `u256` intermediates and explicit sign
handling.

After funding settlement, normalized venue equity in atomic USDC is:

```text
E = free account USDC
  + allocated position collateral in USDC
  + signed unrealized PnL converted conservatively to USDC
```

Funding is included exactly once. If settlement has moved funding into
position collateral, the calculation must not also add unrealized funding.
Gross notional is never an asset. Protocol or keeper fees that are withdrawable
by another party are not venue equity.

Let `R` be the separately accounted maintenance reserve. It is actual USDC
collateral in the same isolated Aftermath account, but share pricing excludes
it:

```text
N = E - R
```

`N` is shareholder NAV. It is the only NAV used for minting, redemption,
accounting leverage, target-notional sizing, and the hard Series NAV cap. The
reserve still contributes to Aftermath venue equity and liquidation margin.
Ordinary priced operations require `R <= E`; they may not saturate a negative
result to zero and continue. A separate successful health transition handles a
breach. Equality produces zero shareholder NAV for loss and shutdown handling,
but minting and risk increase require positive `N`.

This shareholder NAV is distinct from venue risk equity. Aftermath's current
mark, collateral haircut, effective IMR, MMR, and margin functions determine
whether an account may safely trade. Both checks must pass: oracle-valued NAV
prices shares, while the venue calculation and a stricter protocol buffer gate
risk. One must never substitute for the other.

Shareholder NAV must be positive before minting or increasing risk. An
unrepresentable, zero, or negative result causes an objective transition to
`ReduceOnly` or `Shutdown` through a separate sync call.

The `ValuationPolicy` type in `series.move` fixes the locally enforceable
shape of these rules without selecting a value or naming a source. It stores
four immutable `u64` bounds and applies them through three gates:

- price freshness is the closed interval
  `[reference - max_price_age_ms, reference + max_price_ahead_ms]` on the
  operation's single millisecond time reading, so an update is rejected both
  when it is too old and when it is stamped too far ahead, with a distinct
  abort code for each side;
- a source's absolute confidence interval must satisfy
  `confidence * 10_000 <= max_confidence_bps * price`; and
- the venue mark must satisfy
  `abs(mark - index) * 10_000 <= max_mark_divergence_bps * index`.

The first two gates apply to each share-pricing source, so every priced
operation and every risk increase runs them for both the base index and the
collateral oracle. The third is a venue margin-safety gate only; its input
never reaches shareholder NAV, share pricing, or accounting leverage, which the
package's source-boundary script enforces mechanically.

Every bound is inclusive, `max_price_age_ms` must be positive because the
structural policy requires nonzero historical-age tolerance, the two relative
bounds may be zero but must stay below 10,000 so a degenerate observation is
always rejected, and both gated prices must be positive. Positivity does not
prove that the selected age supports the deployed source cadence; that remains
a live integration and simulation gate. Both relative gates cross-multiply
through `u128`, and the freshness comparison branches on operand order, so
neither can wrap or underflow at maximum `u64` width.

Three things stay open. The operation-scoped linear valuation carrier that
would prove one captured pair priced both sides of an operation cannot be built
before the adapter handoff design is accepted: only the adapter can construct
such a value, that requires a public core seam the pre-Series package does not
have, and its field layout depends on the signed fixed-point normalization of
premise P17. Exact source identity, binding, and authentication remain with
`VenueAccount` and the adapter. Every millisecond and basis-point value remains
a simulation and live-market selection.

### Mint accounting

Let:

- `N0` be pre-mint NAV;
- `R0` be the pre-mint maintenance reserve;
- `S0` be total share supply;
- `D` be the exact USDC deposited;
- `F = ceil(D * mint_fee_bps / 10_000)` be the maintenance fee;
- `R1 = R0 + F`; and
- `N1 = E1 - R1` be actual post-deposit, post-trade shareholder NAV at the
  same oracle valuation pair.

The depositor's credited contribution is:

```text
C          = N1 - N0
shares_out = floor(S0 * C / N0)
S1         = S0 + shares_out
```

The fee is already excluded from `N1` through `R1`; subtracting it again would
charge the depositor twice. With no venue fee or slippage,
`N1 = N0 + D - F`. Actual venue fees and slippage reduce `N1` further, so the
depositor pays them.

The production call path uses `accounting_math::mint_accounting_quote` with
`E0`, `E1`, and `R0`. It derives `R1`, `N0`, and `N1` together before calling
the low-level share formula and returns both NAV inputs for the proportional
exposure and final-leverage checks. A Series transition may not derive both NAV
values from the same reserve checkpoint or pass reserve-inclusive venue equity
to exposure sizing.

`C` and `shares_out` must both be positive. The user supplies a deadline,
`min_shares_out`, and an execution-price or slippage bound. Core chooses the
trade side and maximum size. The adapter deposits all `D`, executes at most the
required one-direction market order, closes the Aftermath session, and reports
the actual fill and session status. Venue fees are reflected in actual `N1`;
they are not accepted from the caller. Core mints only after it validates the
final account, order count, direction, leverage, margin, NAV, and
`SessionSummary`.

Both fee rates are less than 10,000. Fee calculation must prove `F <= D` for a
mint and `F <= gross` for a redemption before subtraction.

The retained `F` stays in the same Aftermath account, improves venue margin,
and is excluded from shareholder NAV and target exposure. With floor share
minting:

```text
N1 / S1 >= N0 / S0
```

No caller-supplied expected NAV, price, side, or size is authoritative.

NAV non-dilution alone does not preserve exposure per share. A mint whose
proportional exposure increase rounds to zero would deposit collateral, mint
shares, and open no position, and a later holder-funded rebalance would pay for
the exposure that cohort should have opened. The mint therefore also computes
the proportional base delta from the live venue lot size:

```text
delta_base = floor_to_lot(floor(Q0 * C / N0))
```

The order is sized before the trade from the expected contribution
`D - F`. A mint whose proportional target is below `min_exposure_lots` live
lots is rejected, so the unopened remainder is below `1 / min_exposure_lots`
of the target. After the fill, core verifies the final absolute base against
the two-sided range `Q0 + [min(delta(C), delta(D - F)), delta(D - F)]`, where
`delta` is the lot-rounded proportional formula: a full fill of the plan always
passes, a partial fill may not leave the actual contribution's exposure
unopened, a fill above the plan aborts, and an actual contribution below the
minimum aborts even when the plan cleared it. The per-operation relative cap is
what bounds cumulative drift: each legal mint multiplies accounting leverage by
at least `1 - C / ((N0 + C) * min_exposure_lots)`, so a sequence of mints from
leverage `L0` and NAV `N0` stays close to `L0 * (N0 / N)^(1 / min_exposure_lots)`.
Simulation selects `min_exposure_lots` per Series. The final leverage, margin,
and `SessionSummary` checks stay authoritative.

### Redemption accounting

Let `x` be the shares presented, where `0 < x < S0`. Before paying USDC, the
adapter settles funding and reduces at least the proportional exposure. If the
pre-redemption absolute base is `Q0`, the remaining absolute base must be no
greater than:

```text
Q_keep = floor(Q0 * (S0 - x) / S0)
```

Risk reduction rounds toward more reduction but is capped at flat and may
never cross into the opposite direction. The bound is two-sided. The planned
order rounds the required reduction up to the live lot size and caps it at
flat, which gives a permitted range for the final absolute base:

```text
Q_min = Q0 - min(ceil_to_lot(Q0 - Q_keep), Q0)
Q_min <= Q_final <= Q_keep
```

`Q_keep - Q_min` is always below one lot. The flat cap can bind only when
`Q_keep` is itself below one lot, and it then makes `Q_min` zero. Unless the
redemption reaches flat, the required reduction `Q0 - Q_keep` must be at least
`min_exposure_lots` live lots, so the over-reduction is also below
`1 / min_exposure_lots` of the required reduction and a stream of dust
redemptions cannot each close a whole lot. A redemption therefore cannot leave
more than the proportional exposure, and it cannot deliberately dump a lot or
more of extra exposure on the remaining holders.

`Q_final <= Q_keep` is mandatory after every fill, full or partial. The
partial-fill conditions elsewhere in this record are cumulative additions to
it, never an exception: a reduce-only fill that does not reach `Q_keep` aborts
the complete redemption, so no payout occurs.

After the unwind, let `R0` be the current maintenance reserve and `Nu` be
shareholder NAV before the user payout and before the redemption fee is
credited to the reserve. Core computes:

```text
equity_keep = ceil(N0 * (S0 - x) / S0)
gross       = Nu - equity_keep
F           = ceil(gross * redeem_fee_bps / 10_000)
net         = gross - F
S1          = S0 - x
```

`Nu` must be greater than `equity_keep`, and `net` must be positive and at
least the user's `min_usdc_out`. The adapter may withdraw exactly `net`, not a
caller-selected amount. Core burns `x` only after receiving that exact
`Coin<USDC>` and validating the final checkpoint.

After payment:

```text
R_final = R0 + F
E_final = E_unwound - net
N_final = E_final - R_final = equity_keep
N_final / S1 >= N0 / S0
```

The redeemer therefore bears the marginal unwind cost. A redeemer cannot take
idle collateral while leaving all exposure and execution loss to remaining
holders. The fee cannot be recaptured by a later redemption because it no
longer participates in share pricing. If the book cannot produce the minimum
safe exit, the transaction aborts instead of silently diluting the Series.

The production call path uses
`accounting_math::redemption_accounting_quote`. It derives both pre-redemption
and post-unwind NAV with `R0`, calculates the claim, and only then derives
`R_final`. This ordering is not left to the Series caller.

The complete redemption postconditions are cumulative. Before the transaction
commits, all of these must hold:

- `Q_min <= Q_final <= Q_keep`;
- the final direction is the original Series direction or flat;
- post-payout accounting leverage does not exceed the pre-redemption leverage
  or the hard leverage cap; and
- final venue margin is above the protocol buffer.

The last two are later adapter obligations. They need the live venue margin
functions and the hard cap that economic simulation must still select, so no
implementation may claim them before those gates close.

### Fees, collateral donations, and the volume flywheel

Mint and redemption fees are paid in USDC and stay inside the Series account.
They credit the maintenance reserve, increase venue equity and margin, and are
excluded from shareholder NAV and target exposure. There is no admin, keeper,
protocol-treasury, or fee-recipient claim path.

During normal operation, the reserve may be debited only by an exact negative
funding settlement authenticated from Aftermath's authoritative funding
accumulator or equivalent checkpoint. With funding cost `K`:

```text
absorbed      = min(R0, K)
R1            = R0 - absorbed
uncovered     = K - absorbed
E1            = E0 - K
N1            = N0 - uncovered
```

The adapter may not infer `K` from a total-equity delta. Trading fees,
slippage, price PnL, liquidation, ADL, bad debt, and socialized loss cannot be
presented as funding or voluntarily debited from the reserve. Positive funding
leaves `R` unchanged and increases shareholder NAV. The funding checkpoint and
reserve mutation commit atomically, so one venue settlement can be accounted
for exactly once.

The adapter proves the transition with a no-ability funding completion that
contains the bound account and Series identity plus the old and new
authoritative funding accumulator. Only the adapter can construct it, and core
consumes it while it updates the stored checkpoint and reserve. A bare `u64`
chosen by a caller is never sufficient authority to debit the reserve.

The reserve is an accounting tranche inside the margin account, not segregated
or bankruptcy-remote cash. A sufficiently large non-funding loss can physically
impair the account below the recorded reserve. That breach blocks ordinary
pricing and triggers a separate successful `sync_health` transition; it is not
silently relabeled as funding and it does not permit risk increase.

A permissionless `donate_collateral` path may also deposit positive USDC and
mint no shares. A donation increases shareholder NAV; it does not credit the
funding-only reserve. It cannot auto-resume a damaged Series. Resume requires
an independent fresh health check and cannot restore an old NAV or compensate
a past holder.

A launchpad fee received as `SUI2L` or `SUI2S` is not new collateral. Burning
the fee coin only reduces supply; it does not create USDC in the Aftermath
account. Converting such a fee into collateral requires an external sale or a
normal redemption, with its own price impact and accounting. The first release
does not build a circular fee-token collateral path.

A direct `Meme/SUI2L` or `Meme/SUI2S` launchpad swap also does not call the
Series and creates no mint or redemption fee. Only the separate USDC-to-Share
and Share-to-USDC paths feed retained USDC into the maintenance reserve. A
frontend Zap may compose those paths with a launchpad swap, but Zap output never
changes the contract equations.

### Rebalance policy

For positive shareholder NAV `N` and oracle-valued absolute notional `V`,
accounting leverage is rounded up:

```text
leverage_bps = ceil(V * 10_000 / N)
```

Rounding up prevents an unsafe position from appearing safer. This accounting
ratio controls the product band. The venue's effective margin ratio and the
protocol margin buffer are independent, simultaneous risk gates. A
permissionless rebalance accepts no side or size from its caller:

- above the upper band, it uses a reduce-only order sized with risk-reducing
  rounding and cannot cross flat;
- below the lower band, it may increase only the immutable Series direction,
  rounds order size down, and targets 2x instead of the lower edge; and
- inside the band, it performs no trade.

For target leverage `T`, core first computes target notional with wide
intermediates:

```text
V_target = floor(N * T / 10_000)
```

If exposure must increase, the notional and base deltas round down to the venue
lot size. If exposure must decrease, the base delta rounds up to the lot size
and is capped at the complete current base. The actual post-trade NAV changes
with execution cost, so the final leverage and margin checks remain
authoritative; the pre-trade target is not a guarantee.

Every risk increase requires `Active`, current package versions, fresh and
matching oracle sources, an active and unfrozen market, no pending orders, no
unexplained checkpoint change, safe live venue parameters, remaining NAV and
notional capacity, acceptable execution, a final leverage below the hard cap,
and margin above the protocol buffer. A change in Aftermath IMR, MMR, oracle
ids, tolerance, fee, lot size, tick size, or open-interest limits may make a
previously valid operation invalid. These values are read from live market
state; the interface exposes their getters
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/market.move:456-569`).

Risk reduction remains callable when a risk increase is blocked. A full fill
is required for mint and ordinary risk increase. A partial reduce-only fill may
be accepted only if it strictly reduces leverage, keeps the direction, creates
no posted order, and passes the user's redemption bound when part of an exit.
These conditions are cumulative with the redemption postconditions above. A
partial fill that leaves the final absolute base outside `Q_min` to `Q_keep`
aborts the complete transaction.

The first version places market orders only. Aftermath sessions return fill,
posted-order, liquidation, and bad-debt facts in `SessionSummary`
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/clearing_house.move:200-232`).
Core rejects unexpected posted orders, liquidation, bad debt, or the wrong fill.
The adapter must end every session; `start_session`, `place_market_order`, and
`end_session` form the enforced hot-potato flow
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/clearing_house.move:984-1036`).

### Lifecycle and loss handling

The Series lifecycle has four states. Pending shutdown and settled shutdown are
different states because ordinary NAV redemption must stop before the final
cash snapshot becomes redeemable:

| State | Mint | Increase risk | Reduce risk | Redeem | Donate or sync |
| --- | --- | --- | --- | --- | --- |
| `Active` | yes | yes | yes | ordinary redemption | yes |
| `ReduceOnly` | no | no | yes | ordinary redemption when the venue permits | yes |
| `ShutdownPending` | no | no | close or settle only | no payout | sync; late-inflow policy remains a Series gate |
| `ShutdownSettled` | no | no | no venue position remains | pro-rata settled cash only | sync; no second settlement snapshot |

`series.move` owns the closed enum, lifecycle predicates, operation guards, and
only these monotone transitions:

```text
Active     -> ReduceOnly
Active     -> ShutdownPending
ReduceOnly -> ShutdownPending
```

The module deliberately does not expose `ReduceOnly -> Active` or
`ShutdownPending -> ShutdownSettled`. A source-state check cannot prove the
cooldown, authority, venue health, cash custody, funding settlement, or reserve
reclassification required by those upgrades. The future `Series` transitions
must validate those complete proofs before adding the corresponding lifecycle
operations in the same owner. No other production module may construct a
lifecycle variant or consume the Series policy and lifecycle rules.

An objective `sync_health` can enter `ReduceOnly` when it observes stale or
mismatched external state, unsafe market parameters, liquidation, ADL,
unexpected orders, insufficient margin, or a leverage breach. This must be a
separate successful transition: an aborting mint cannot persist a lifecycle
change because Sui rolls back the complete transaction.

A guardian may also enter `ReduceOnly` or `Shutdown`. No guardian can set NAV,
mint, withdraw collateral, change the Series side, or restore `Active`.

Returning from `ReduceOnly` to `Active` requires all of:

- a bounded cooldown;
- a current-version admin witness;
- a fresh adapter health receipt;
- positive shareholder NAV, a fully backed reserve, no pending orders, and the
  intended position direction;
- leverage inside the safe band and margin above the protocol buffer;
- unchanged exact market, account, collateral, and oracle bindings; and
- no unresolved external-state mismatch.

Liquidation, ADL, uncovered funding loss, or socialized loss reduces shareholder
NAV. Exact negative funding consumes the maintenance reserve first; positive
funding increases shareholder NAV. None of these transitions reduces coin
balances in user wallets or creates a debt owed by Blast. Re-levering after a
loss changes future exposure; it is not recapitalization. New retained USDC
fees add reserve, while donations add shareholder NAV.

If Aftermath is unavailable, a direct account cannot produce a trustless USDC
redemption. The contract fails closed and waits for the venue's reduction or
settlement path. It does not issue an IOU or create an unbounded asynchronous
withdrawal queue in version one.

Shutdown has two explicit lifecycle states. From `ShutdownPending`,
`settle_shutdown` cancels orders, closes or settles
the position, deallocates all possible margin, and verifies a flat, cash-only
account with no pending orders and no unsettled funding. Only then does it
terminally reclassify the recoverable maintenance reserve into shutdown cash
and set the reserve to zero before entering `ShutdownSettled`. This is not a
normal reserve debit and no admin or keeper receives it. The transition mints
no share and pays no user. It can execute only once. After that checkpoint,
burning `x` shares returns:

```text
shutdown_out = floor(cash_before * x / supply_before)
```

There is no shutdown redemption fee and no exposure trade per redeemer. Floor
rounding protects remaining holders. The cash for permanently locked seed
shares remains permanent protocol capital. If final recoverable cash is zero,
a separate worthless-share burn may consume a holder's coins but returns no
asset and cannot change lifecycle.

### Upgrade posture

Both packages are evolving shared-state packages. Each has its own
`PackageVersion`, wrapped `UpgradeCap`, exact-digest authorization, and
operational activation step. Every mutator checks the current version before
mutation. This is required because old Sui bytecode remains callable after an
upgrade.

The adapter upgrade authority is as sensitive as the core authority: upgraded
adapter code could misuse the account admin capability. Production custody
therefore requires disclosed multisig and delay controls. There is no generic
cap release, arbitrary venue rebind, or account migration API. An incompatible
Aftermath replacement first forces `ReduceOnly`; a separately reviewed upgrade
may add one typed migration handoff.

Dependencies use full immutable revisions. Publication is blocked until the
live package lineage and normalized ABI fingerprint match the reviewed
deployment. The interface's BUSL terms, Aftermath support for contract-held
account capabilities, implementation source, and exact audit scope are release
gates rather than assumptions hidden in code.

### Module and public-API plan

`blast_leverage_coins`:

```text
blast.move                package OTW and Publisher intake
sui2l.move                SUI2L OTW, currency, and metadata
sui2s.move                SUI2S OTW, currency, and metadata
series.move               immutable policy, lifecycle, and future Series transitions
accounting_math.move      pure share, exposure, reserve, and shareholder-NAV accounting
venue_handoff.move        no-ability instructions and completion tokens
acl.move                  routine admin and guardian witnesses
package_admin.move        Publisher, UpgradeCap, and metadata-cap custody
package_version.move      old-bytecode gate
lib/constants.move        immutable product and numeric bounds
lib/errors.move           stable numeric abort registry
lib/events.move           concrete payloads
lib/events_wrapper.move   generic package event envelope
```

`blast_leverage_aftermath`:

```text
aftermath_adapter.move    mint, redeem, rebalance, donate, sync, settle
venue_account.move        cap custody and exact one-Series binding
snapshot.move             private Aftermath fixed-point normalization
acl.move                  adapter administration witnesses
package_admin.move        adapter upgrade custody
package_version.move      adapter old-bytecode gate
lib/errors.move           adapter and venue error registry
lib/events.move           venue execution payloads
lib/events_wrapper.move   adapter event envelope
```

Public functions take the required shared objects and return owned coins. They
do not self-transfer user outputs. The adapter has one public route per allowed
operation. It exposes no generic order, withdrawal, capability-borrow, market,
or account function. Read APIs expose stored primitive facts only; SDK code
derives current presentation values.

The intended mutation surface is:

| Function family | Caller | May mint or burn | May increase risk |
| --- | --- | --- | --- |
| `mint` | anyone | mint after completion | yes, within all gates |
| `redeem` | anyone holding shares | burn after USDC return | no |
| `rebalance` | anyone | no | only in `Active` and below the lower band |
| `donate_collateral` | anyone holding USDC | no | no; a later rebalance is separate |
| `sync_health` | anyone | no | no; may only degrade lifecycle |
| `settle_shutdown` / `redeem_shutdown` | anyone | burn on redemption only | no |
| `enter_reduce_only` / `enter_shutdown` | guardian | no | no |
| `resume_active` | current admin plus fresh adapter receipt | no | no in the resume call |
| package upgrade and activation | current package admin | no directly | no directly |

Core `begin_*` and `complete_*` calls are public only for adapter composition.
They require the exact bound witness type and linear handoff. They are not
independent user entry points.

### Events and errors

Core events are wrapped and emitted after final state mutation:

- `SeriesCreated<Share>` records immutable bindings, policy, bootstrap venue
  equity, initial maintenance reserve, and locked shares;
- `SharesMinted<Share>` records gross USDC, retained fee, credited NAV,
  shares, final supply, reserve after the credit, and the final primitive
  checkpoint;
- `SharesRedeemed<Share>` records burned shares, gross claim, retained fee,
  net USDC, final supply, reserve after the credit, and checkpoint;
- `FundingSettled<Share>` records the old and new authoritative funding
  checkpoint, direction and exact amount, reserve absorbed, uncovered cost,
  reserve after settlement, and the final primitive checkpoint;
- `PositionRebalanced<Share>` records old and new position primitives, actual
  fill, and whether risk increased;
- `CollateralDonated<Share>` records the exact USDC added and final checkpoint;
- `LifecycleChanged<Share>` records old state, new state, a stable reason code,
  and final checkpoint; and
- package changes record old and new values. Fee, risk, and capacity changes
  need a later accepted decision before any setter exists.

The adapter creation event records the exact Aftermath account and market ids.
Later adapter events do not repeat those stable bindings. They record only the
minimal session result needed to join core operations to venue facts. Events do
not repeat `ctx.sender`, calculated display prices, or values that can be
derived from the emitted primitives.

Errors are package-wide numeric codes grouped by arithmetic, lifecycle,
binding, authority, market, oracle, order, execution, position, external-state,
and version failures. Checks follow one documented precedence: version and
authority, object binding, lifecycle, input bounds, external health, arithmetic,
then post-execution reconciliation. Tests assert exact code and aborting module.

## Invariant ledger

The implementation is not complete until each invariant has one enforcement
site and at least one adversarial test.

| ID | Invariant | Enforcement |
| --- | --- | --- |
| I1 | One Series owns the only treasury cap for its Share type. | Consuming construction; no cap-return path. |
| I2 | One VenueAccount owns the only Aftermath admin cap for its account. | Consuming bind, `authority::for` check, and no borrow or release API. |
| I3 | No assistant capability exists. | Fresh-account construction, no adapter call to its constructor, source gate, and deployment-state check. |
| I4 | Long and short accounts, collateral, loss, and supply are isolated. | Separate objects and exact generic bindings; no cross-Series call. |
| I5 | Only the fixed account, market, collateral, oracles, and side are usable. | Stored ids and type checks before every venue call. |
| I6 | Supply is permanently positive. | Protocol seed shares locked at `@0x0`. |
| I7 | Shareholder NAV is `venue_equity - maintenance_reserve`, includes recoverable equity once, and never includes gross notional. | One normalized venue snapshot plus reserve exclusion; reserve-aware leverage, target, and mint-exposure functions; math vectors and venue parity tests. |
| I8 | Funding is applied exactly once before supply or risk changes; only exact negative funding can consume reserve. | Authoritative funding checkpoint, atomic reserve mutation, and before/after funding tests. |
| I9 | Mint cannot lower existing NAV per share or subtract its reserve fee twice. | Credit fee to reserve, derive `N1`, use `C = N1 - N0`, and floor share mint. |
| I10 | Redemption cannot lower remaining NAV per share or let a redeemer recapture reserve fees. | ceil `equity_keep`; credit fee to reserve; final shareholder NAV equals `equity_keep`. |
| I11 | Redemption removes at least proportional exposure. | floor remaining base target; risk-reducing rounding. |
| I12 | A risk-increasing trade cannot reverse direction or exceed its computed size. | Core instruction plus sealed adapter witness. |
| I13 | A risk-reducing trade cannot cross flat. | Reduce-only venue flag and final signed-position check. |
| I14 | Share-changing operations start and finish with no pending order. | Pre-check and `SessionSummary` post-check. |
| I15 | User slippage and minimum-output bounds hold on actual execution. | Post-session reconciliation before mint, burn, or payout. |
| I16 | Risk increase ends within hard leverage and margin bounds. | Final snapshot; whole-transaction rollback on failure. |
| I17 | Risk reduction remains available when risk increase is disabled. | Scoped lifecycle gates; no global pause on reduction. |
| I18 | Out-of-band liquidation, ADL, settlement, collateral, or order mutation cannot be treated as an ordinary mint state. | Mutation checkpoint plus objective health sync. |
| I19 | Mint and redemption fees are collateral credited to a reserve excluded from share pricing, target exposure, and every external claim path. | Stored reserve, fee reconciliation, no reserve withdrawal API, and split-redemption tests. |
| I20 | Burning Share tokens cannot manufacture collateral. | USDC movement is independently reconciled. |
| I21 | No in-flight adapter instruction can escape its transaction. | No-ability handoff and completion types. |
| I22 | Old core or adapter bytecode cannot mutate current state. | Operational version gate at every mutator. |
| I23 | The launchpad cannot influence NAV, leverage, or venue authority. | No dependency; exact Quote allowlist only. |
| I24 | Shutdown redemption can distribute only verified cash, including any terminally released reserve, and cannot reopen exposure. | Flat cash-only, empty-order, settled-funding checkpoint; reserve reclassification; floor pro-rata payout; no fee. |
| I25 | Share pricing cannot use caller-selected or book-only prices. | Fixed market-bound oracle pair for pre/post NAV; separate mark and margin checks. The `ValuationPolicy` type in `series.move` enforces the two-sided freshness window, the confidence bound, and the mark-versus-index divergence bound, and the source-boundary script rejects mark-identified inputs in `accounting_math`; semantic review must still trace arbitrarily named numeric inputs. The linear valuation carrier and exact source binding remain open. |
| I26 | A share-changing operation preserves proportional exposure within the operation-captured live-lot rounding bound, and repeated operations cannot evade the selected cumulative drift limit. | Mint and redemption reject a proportional exposure change below `min_exposure_lots` live lots unless a redemption reaches flat; mint sizes from `D - F` and admits a final base only inside `Q0 + [min(delta(C), delta(D - F)), delta(D - F)]`; redemption admits a final base only inside `Q_min` to `Q_keep`. The relative cap bounds cumulative drift to about `L0 * (N0 / N)^(1 / min_exposure_lots)`. Simulation selects `min_exposure_lots`, and mint must still enforce the final leverage-band gate. |
| I27 | A total-equity delta cannot masquerade as funding or hide a reserve impairment. | Exact funding-accumulator proof; `R <= E` for priced operations; separate objective loss sync. |
| I28 | Lifecycle degradation is monotone until a complete Series proof authorizes an upgrade. | Closed four-state enum; only `Active -> ReduceOnly`, `Active -> ShutdownPending`, and `ReduceOnly -> ShutdownPending` exist before Series integration; resume and settlement finalization require their full proofs. |
| I29 | Every constructed leverage policy has a positive, strictly ordered operating band below its hard cap. | `series.move` exclusively constructs private `LeverageBounds` fields while creating `SeriesPolicy` and enforces `0 < lower < target < upper < hard cap` before every other policy guard. |
| I30 | Every constructed preliminary Series policy fixes a long or short direction, embeds validated leverage bounds, keeps both fee rates below 10,000, and has positive minimum exposure lots and NAV cap. | Private `SeriesPolicy` fields, the closed `PositionSide` enum, its package constructor, and the source-boundary gate; production values and the remaining policy fields stay blocked until their design and simulation gates close. |
| I31 | Every constructed valuation policy fixes a two-sided freshness window with positive historical-age tolerance, keeps the confidence and mark-divergence bounds below 10,000 basis points, and its gates reject a stale, future-dated, zero-priced, low-confidence, or divergent observation without wrapping or underflowing at `u64` width. | Private `ValuationPolicy` fields, its `series::new_valuation` package constructor, and its three package gates, with every assertion defined on the same non-aborting predicate the objective health transition observes; the source-boundary gate keeps mark-identified inputs out of the shareholder-NAV and share-pricing math. The operation-scoped linear valuation carrier, exact source binding and authentication, selected millisecond and basis-point values, and proof that the age supports the live source cadence stay blocked on the adapter handoff design, premises P16 through P20, and simulation. |

## Alternatives considered

**Use one account for long and short.** Rejected. Netting destroys product
isolation and makes one coin's supply depend on the other's flow and funding.

**Wrap Aftermath's market-making vault share.** Rejected. `UserLpCoin` is an
owned object with balance, time, and cost basis rather than a plain `Coin`, and
the vault supports multi-market strategies and delayed withdrawals
(`interfaces@f62e74a:packages/iperps-vaults/market-making-vault/sources/vault.move:644-700`).

**Store the Aftermath cap directly in core.** Rejected. It makes core import the
venue and gives venue ABI or licensing changes a direct path into share and
currency authority. The cap remains protocol-custodied, but in the one-to-one
adapter object.

**Maintain exact 2x after every price change.** Rejected. A shared object cannot
update itself. Permissionless keepers rebalance only when called, and constant
rebalancing would add churn, fees, and manipulation surface.

**Guarantee no liquidation with protocol fees.** Rejected. Fees add venue
equity, improve margin, and absorb bounded funding costs, but adverse gaps,
non-funding loss, oracle behavior, market unavailability, and execution depth
can still defeat a keeper. The contract guarantees accounting truth and bounded
actions, not survival.

**Burn launchpad-collected leverage coins to add collateral.** Rejected. A burn
reduces a liability but moves no USDC into the venue account. It can improve NAV
per remaining share, but cannot increase liquidation margin by itself.

**Add a global insurance or long-short bailout pool.** Rejected. It creates
uncapped contagion and obscures which Series earned or lost value.

## Consequences

- `SUI2L` and `SUI2S` are normal fungible coins that can be paired in Blast,
  wallets, and other protocols.
- Their wallet price is a share of recoverable Series NAV, not a promised
  multiple of the current SUI price.
- Mint and redeem flows pay their own execution loss. Retained USDC fees add a
  funding-only reserve that improves venue margin but is excluded from share
  price and target exposure.
- A liquidation reduces NAV and may force `ReduceOnly` or `Shutdown`; it does
  not erase wallet coins.
- Venue availability, order-book depth, oracle quality, Aftermath governance,
  and adapter upgrades become material protocol dependencies.
- The extra package boundary adds deployment and version coordination, but
  confines the venue capability and keeps launchpad and share math independent.

## Named premises and falsification tests

**P16 — deployed ABI and same-transaction composition.** The reviewed interface
matches the production package, and one transaction can create/share the
account, retain the admin cap in `VenueAccount`, deposit, allocate, create a
position, start and end a session, and return all objects.

Falsification test: pin the production package and registry, compare normalized
module fingerprints, then dev-inspect the complete construction and one no-op
session against mainnet state. Any missing call, incompatible type, or object
ownership failure falsifies the premise.

**P17 — exact NAV, funding, and signed fixed-point normalization.** The adapter
can reproduce Aftermath account equity without double-counting collateral,
PnL, or funding, can conservatively convert it to atomic USDC, and can derive
each exact positive or negative funding settlement from an authoritative
accumulator or checkpoint rather than an equity delta.

Falsification test: obtain Aftermath's implementation formula or approved
reference vectors; compare adapter results across long, short, flat, positive
and negative PnL, both funding directions, repeated settlement, USDC oracle
deviations, and values around every rounding boundary. Require one accumulator
change to mutate the reserve at most once. One unit of unexplained divergence
blocks publication.

**P18 — custom position IMR.** `set_position_initial_margin_ratio` can enforce
the intended position-level initial-margin floor and behaves safely across
partial liquidation and market-parameter changes. The interface exposes the
setter and effective-IMR getter, but its aborting body does not establish those
semantics
(`interfaces@f62e74a:packages/iperps/perpetuals/sources/clearing_house.move:949-955`,
`interfaces@f62e74a:packages/iperps/position/sources/position.move:81-86`).

Falsification test: set the proposed floor on a test account, attempt orders on
both sides of the boundary, change the market IMR in a controlled fixture, and
exercise the documented liquidation path. If the floor can weaken unexpectedly,
remove it as a safety claim and enforce a lower protocol hard cap.

**P19 — external-mutation checkpoint.** The selected primitive checkpoint
detects every permissionless venue transition that can invalidate normal mint
accounting, including liquidation, ADL, settlement, bad debt, collateral
movement, and pending orders, while exact funding settlement remains separately
identifiable and reconcilable.

Falsification test: execute each transition in an instrumented venue fixture,
compare pre- and post-checkpoints, and require `sync_health` to enter the correct
lifecycle. A material equity or risk change that leaves the checkpoint equal
requires a wider checkpoint before layout freeze.

**P20 — reduction and settlement liveness.** When the market is paused, frozen,
or settled, Aftermath preserves at least one documented path to reduce or settle
the Series account without opening new risk.

Falsification test: run pause, freeze, settlement, oracle-stale, and liquidation
fixtures against each proposed exit function. The lifecycle table must be
narrowed to the operations that actually remain available.

## Verification and rollout

### Pure and package tests

- Table-test every fee, venue-equity, reserve, shareholder-NAV, share, leverage,
  funding-absorption, and proportional-unwind formula at zero, one, maximum,
  threshold, and near-insolvency values with `u256` intermediates.
- Property-test non-dilutive mint and redemption, split/merge equivalence,
  fee-recapture resistance, reserve conservation, repeated tiny operations,
  donation behavior, and round trips that cannot earn value from rounding.
- Measure repeated legal lot-rounded mints and dust redemptions until the lower
  leverage boundary and select `min_exposure_lots` from that drift using the
  closed-form bound; the package regression tests pin a one-lot minimum leaving
  the band and a hundred-lot minimum staying inside it.
- Test 1.8x, 2x, 2.2x, and hard-cap boundaries with both signs and every lot-size
  rounding direction.
- Cover every legal and illegal lifecycle edge, capability mismatch, wrong
  object id, wrong oracle, wrong side, stale/future price, pause, freeze,
  settlement, funding direction, and pending-order state.
- Inject full, partial, and zero fills, bad debt, liquidation, ADL, socialized
  loss, and an adapter abort after every external call. Any failure before final
  completion must roll back coins, caps, shares, and venue state.
- Prove no-ability handoffs cannot copy, drop, store, or escape, and that a
  different package cannot construct the adapter witness.
- Alternate old and new package call targets around upgrades and require old
  core and adapter mutators to fail after operational activation.
- Replay wrapped core and adapter events and compare the reducer's supply,
  lifecycle, bindings, and checkpoints with final object state.

### Integration and economic gates

1. Build pure core math and lifecycle against a malicious mock adapter.
2. Compile the pinned Aftermath interfaces and execute P16 through P20 against
   a controlled fixture and production dev-inspect.
3. Run historical SUI, funding, book-depth, gap, and keeper-delay simulations.
   Select the final band, hard cap, margin buffer, fees, seed, and Series NAV cap
   from those results.
4. Deploy `SUI2L` only with a small cap. Observe mint, redemption, funding,
   rebalance, pause, and loss reconciliation before deploying `SUI2S`.
5. Complete independent core, adapter, economic, and upgrade-authority audits.
   Obtain Aftermath confirmation of package support, licensing, source/audit
   scope, and capability-based contract integration.
6. Publish versioned deployment records and SDK integer-parity vectors.
7. Allowlist the exact coin types in Blast only after the canary and all release
   gates pass.

No mainnet release may describe the coins as non-liquidatable, guaranteed 2x,
or insured against Aftermath loss.
