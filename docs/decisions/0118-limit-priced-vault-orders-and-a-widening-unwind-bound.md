# 0118: Limit-priced vault orders and a widening unwind bound

- Status: proposed
- Date: 2026-10-23
- Amends: [0084](0084-leverage-coin-design-after-perpsplexity-review.md),
  [0064](0064-aftermath-backed-leverage-coins.md),
  [0087](0087-vault-issuance-activated-in-one-transaction.md)

## Sources

| Reference | Location |
| --- | --- |
| Asymptotic audit of Blast Boosts, finding M-6 | [review notes](../reviews/boosts-asymptotic-2026-10.md), ticket 6 |
| Aftermath Perpetuals V2 `clearing_house::place_limit_order`, `execute_limit_order`, `market::tick_size` | `0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7`, interface revision `f62e74a`; order types read from the deployed bytecode on 2026-10-23 |
| Aftermath TypeScript SDK `PerpetualsOrderType` | `aftermath-ts-sdk` 6.3.0, `dist/index.d.ts` |

## Context

Every order a Boost Vault placed was an unpriced `place_market_order`, and the
only price check ran after the fill: the session's average price had to sit
within `max_slippage_bps` of the oracle, or within `emergency_max_slippage_bps`
when the rebalance plan began above the hard cap and for every shutdown close.
`rebalance` and `unwind` are permissionless and take no price or size, the next
order is predictable from state and the oracle, and the venue's public trading
calls return the shared `ClearingHouse`. One programmable transaction could
therefore take the honest liquidity off the book, rest a quote sized to the
Vault's order just inside the bound, and call `rebalance` or `unwind` against
it. Holders paid the difference; the composer staked nothing. The emergency
order was the worst case: sized toward target, capped only by the order cap,
and judged wholly under the wide bound, it sold far more under that bound than
restoring the cap needed. The deployed NVDA2L policy admits 30 bps ordinary and
100 bps emergency, and the policy is immutable.

## Decision

### D1. The core prices every order before it reaches the book

`policy::ExecutionBound` is the bound an order runs under, in basis points of
the oracle reference. Only `policy` constructs one, from the Vault's own
`RebalancePolicy`; the adapter can read it, price with it and prove against
it, never choose it:

- `limit_price(reference, is_ask, tick_size)` moves the reference by the bound
  against the order, up for a bid and down for an ask, and rounds to the
  market tick back toward the reference. The result is a tick multiple inside
  the bound; a tick wider than the bound leaves no admissible price and aborts
  with `execution_outside_max_slippage`. A zero reference or tick aborts first.
- `assert_execution(reference, executed)` is the inclusive post-fill check the
  old `assert_execution` performed, now bound to the same value that priced the
  limit, so a venue that honors the limit can never fail it on price.

`state::execution_bound` is the ordinary bound every mint, redemption and
ordinary rebalance order runs under, `Issuance::seed_execution_bound` the
same for seed orders, `RebalanceOrder::bound` the bound the core sized each
rebalance order under, and `state::unwind_constraints` returns the bound of a
shutdown close step. The core's public `assert_execution` and
`assert_seed_execution` are gone; nothing outside `policy` compares a price to
a bound.

### D2. The adapter places immediate-or-cancel limit orders only

`venue_account::execute_order` and `execute_order_with_cap` call
`clearing_house::place_limit_order(side, size, limit_price, 3, none,
reduce_only, none)`. Order type 3 is Aftermath's immediate-or-cancel: the
deployed `execute_limit_order` fills what rests at or inside the limit and
drops the remainder without posting, where type 0 posts the remainder, type 1
aborts unless the whole size fills and type 2 aborts on any fill. The adapter
pins the value in `constants::immediate_or_cancel_order_type` and the ABI gate
pins `place_limit_order` and `market::tick_size` against mainnet. A session
therefore never leaves a resting order, `active_fill`'s no-posted-orders check
stays a defensive invariant, and a thin book fills less of an order rather
than filling it worse. An order that finds nothing inside its limit aborts
inside the venue (an empty session), exactly as an unfillable market order did.

The limit is read from the venue's live `tick_size` at placement, as the lot
size already is (ADR 0115).

### D3. An emergency reduction sells only what restores the hard cap

A rebalance plan that begins above `max_leverage_bps` sizes each order to the
whole-lot base that brings leverage back to the cap, at least one lot and at
most the per-order cap, under the emergency bound, and ends as soon as leverage
is no longer above the cap. Under
[ADR 0129](0129-reserve-consistent-emergency-reductions.md), sizing and checks
use the reserve admitted at the remaining position. A plan may complete
while still above the cap after any genuine base and notional reduction
with positive holder value, including partial fills and costs that worsen
leverage. Ordinary reductions retain ADR 0126's progress rules. The remaining reduction toward
target runs in a later, ordinary plan under the ordinary bound, so the wide
bound covers no more notional than the cap needs and a wide market can still
not revert the orders placed above the cap (ADR 0084's stop-at-the-cap rule is
kept).

### D4. A shutdown close widens its bound with time

`begin_shutdown` records the clock reading it happens at
(`Lifecycle::Unwinding { began_at_ms }`; `vault::begin_shutdown` takes the
`Clock`). `unwind_constraints` prices each close step under
`RebalancePolicy::unwind_execution_bound(elapsed)`: `max_slippage_bps` at
first, widening linearly, rounded down to whole basis points, to
`emergency_max_slippage_bps` at `constants::unwind_bound_widening_duration_ms`
(24 hours), where it stays. A composer cannot bring the wide bound forward,
and the ordinary bound cannot hold the exit at its initial tolerance forever.
An exit still requires liquidity inside the maximum bound or a venue settlement
path; the ramp does not guarantee a fill. The ramp length is a core
constant, not a policy value: it is an escalation schedule every product shares, and
the two bounds it interpolates between remain per-Vault policy.

### D5. `OrderFilled` records the limit

The event replaces its `emergency` flag with `limit_price`, the 9-decimal
price the order was placed with. With the reference price it states the bound
that applied; an indexer no longer needs to infer it from the plan.

### D6. Permissionless maintenance ends market use in private entry calls

`operations::rebalance` and `operations::unwind` are private `entry` functions.
They take the shared `ClearingHouse` by value, complete the operation, call
Aftermath `clearing_house::share` internally and return nothing. Anyone can
still submit either call; no keeper capability is introduced.

This cuts the audited atomic sweep, post and maintenance sequence at its
handoff. Sui rejects a non-public entry argument after that shared object has
already been consumed by value in the PTB. Aftermath trading requires
`start_session` to consume the market, so `end_session` cannot return a market
that maintenance will accept. Internal sharing consumes the market, preventing
later commands from trading with it. Making the function public would permit
a Move wrapper; returning the market would permit reuse after maintenance.
Both boundaries are intentional.

This is not complete transaction isolation. Prior mutable-reference calls,
including cancellation of the caller's own venue orders, may remain possible;
liquidity planted in previous transactions also remains possible. The execution
bounds, cap-sized emergency reductions and unwind ramp therefore remain in
force. A limit at the existing slippage guard alone would still admit the
audited quote at that limit when trading and maintenance compose.

Reference: [Sui non-public entry restrictions](https://www.docs.sui.io/develop/transactions/ptbs/prog-txn-blocks#non-public-entry-function-restrictions).

## Alternatives considered

**Keep market orders and tighten the policy values.** A tighter
`max_slippage_bps` shrinks the take but keeps the price a post-fill fact: the
composer still chooses what the Vault fills at up to the bound, and the
emergency order still sells to target under the wide bound. Rejected.

**A limit bound tighter than the post-fill guard.** The guard checks the
session's average price, which a venue honoring the per-fill limit can never
move outside the limit, so a second, wider number would only describe a venue
bug. One tight bound prices and proves each order. Retaining a wide value and
using it as a limit does not meet the auditor's economic objective: a quote at
that value can still extract the accepted slippage. New issuances must select
and justify executable bounds against venue spreads, fees, depth, oracle
uncertainty and stressed exits. That calibration remains an issuance gate;
neither this record nor private entry establishes suitable numerical values.

**Restrict `rebalance` and `unwind` to a keeper.** Trades the permissionless
backstop ADR 0084 relies on for a role that must stay live during an incident.
Rejected; private entry calls block the audited trading-session composition
without introducing a keeper role, and limits bound the remaining price risk.

**Fill-or-kill orders.** Type 1 aborts unless the whole order fills, so a book
with honest depth for part of an order would refuse all of it. Immediate-or-
cancel fills the honest part and the next order carries the rest.

**A keeper-only window before `unwind` becomes permissionless.** Needs a new
authority and a role rotation path for an exit that must survive the team's
absence. The time ramp gives the same first-hours protection with no new role.

## Consequences

- Core and adapter are republished: `State`'s public surface, the
  `RebalancePolicy` package API, `Lifecycle`'s layout, `vault::begin_shutdown`
  and `OrderFilled` change; `rebalance` and `unwind` become private entry calls
  without return values. The deployed NVDA2L package is not upgraded by this
  change; its vault keeps market orders and the 30/100 bps post-fill guard
  until it is wound down or re-issued.
- Keeper transactions for `begin_shutdown` pass the `Clock` (`0x6`); the
  `active_ptb.mjs` builder does. Rebalance and unwind plans contain one call
  with no result assignment or subsequent share command. Same-market
  maintenance batching, rebalance followed by mint, and unwind followed by
  finalization require separate transactions.
- A thin book now produces partial fills instead of worse prices. Mint and
  redemption loops already carry a remainder to the next order; the 16-order
  budget bounds the work as before, and an order that fills nothing still
  aborts the transaction.
- An emergency rebalance that restores the cap leaves leverage above the band;
  keepers follow with an ordinary `rebalance`, as they already do after any
  partial reduction.
- At shutdown the close starts at the ordinary bound and widens over the first
  day; liquidity requiring a wider bound waits until the ramp admits it. Holders are locked for that
  time as they were before, since `redeem` stops at `begin_shutdown`.
- Policy values selected for new issuances should sit near venue costs: a
  quote already on the book can still fill at the limit, so the bound remains
  the per-order price loss the protocol accepts. Private entry blocks the
  audited atomic trading sequence, not cross-transaction book manipulation.

## Verification

- Core: `ExecutionBound` tests pin inclusive bounds, zero-reference
  precedence, limit rounding on both sides against an exhaustive small-domain
  reference, the tick-wider-than-bound and zero-tick aborts, `u64` width; the
  unwind ramp at zero, mid-way, a day, after a day and with equal bounds;
  `Lifecycle` records and reports the shutdown start; `State` sizes an
  emergency order to the cap, completes on genuine exposure reduction under
  ADR 0129, and
  widens the close bound from the recorded start.
- Adapter: `OrderFilled` carries the limit; order terms carry the ordinary
  bound; the unwind terms carry the ordinary bound at shutdown and the
  emergency bound a day later from the clock `begin_shutdown` read; the
  immediate-or-cancel type is pinned; the mainnet ABI gate pins
  `place_limit_order` and `tick_size`.
- Both packages pass `sui move test --lint --warnings-are-errors`, the source
  boundary gates and the Move style check.
- A private localnet fixture on Sui 1.77.2 / protocol 133 verifies the ownership
  boundary: session then public maintenance succeeds; session then private
  entry fails with `InvalidArgumentToPrivateEntryFunction`; direct private
  entry succeeds and leaves the market shared; reuse after internal sharing
  fails with `ArgumentWithoutValue`. Prior mutable-reference mutation still
  succeeds. The fixture models the venue's ownership shape, not its trading
  implementation. Keeper plans contain no returned-market assignment or
  subsequent share command.
- Not established here: a live fill through `place_limit_order` on mainnet.
  The vendored interfaces abort, so the first activation on the new package
  must run the activation evidence scripts as ADR 0064 requires.
