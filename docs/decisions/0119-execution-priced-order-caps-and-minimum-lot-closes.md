# 0119: Execution-priced order caps and minimum-lot closes

- Status: accepted
- Date: 2026-10-23
- Amends: [0118](0118-limit-priced-vault-orders-and-a-widening-unwind-bound.md)
- Source: [Asymptotic review](../reviews/boosts-asymptotic-2026-10.md), M-4 and M-8

## Context

Sizing a trade at the oracle price and checking its actual filled quote
against the same cap rejects an otherwise admissible higher fill. Discounting
size solves that mismatch, but can make an already small cap buy less than
one venue lot. A fixed cap can also become smaller than one lot after prices
or the venue's lot size change. Validation at configuration time alone cannot
preserve the ability to close.

## Decision

Every sizing site uses the execution bound that will check that order:
ordinary for seed, mint, redemption and ordinary rebalance; emergency for a
cap-restoring reduction; the elapsed-time bound for shutdown. Both directions
reserve the upper admitted price, because a sell can receive a higher price
and still consume more of the quote cap. Aftermath's normalized sell price
rounds down, so sizing adds one normalized price atom to cover the discarded
fraction. The inverse uses wide arithmetic, rounds to whole lots and saturates
at the largest representable whole-lot base before narrowing. Rebalance
increases search this capped range and still enforce their post-cost target.

The adapter retains its actual filled-quote cap check, excluding trading fees,
and its separate execution-price check. Seed and all opening trades obey the
configured cap strictly. A reduce-only fill of exactly one live venue lot is
the sole cap exception. The authenticated order terms, whole-lot fill check
and position-delta proof establish that it closes exposure. Larger fills and
opening fills cannot use the exception. Price limits, funding reconciliation,
checkpoint checks and the sixteen-order work bound continue to apply.

Initialization and each RiskAdmin cap update require the cap to cover
`min_order_lots` live lots in one ordinary-bound order. The update moves to
`operations::set_max_order_notional`, which authenticates the bound account,
registry, clearing house and oracle sources. Core validation checks fresh,
admitted prices and lot capacity before writing. It does not require positive
NAV, safe opening margin or an unchanged accepted checkpoint: an administrator
must be able to raise a cap while recovering a distressed vault. Updates stay
immediate and available in every lifecycle. Values are collateral atoms.

## Consequences and remaining risks

Allowed fills above the oracle no longer fail merely because sizing ignored
execution headroom. The cap's meaning stays exact for openings; the intentional
exception bounds an over-cap close to one venue lot, whose dollar cost can be
large. This is the accepted tradeoff for preserving a small closing step.

Later price or lot growth can still block opening trades. A normal redemption
can still need more than sixteen orders, even at its minimum proportional size.
RiskAdmin can raise the cap; ShutdownAdmin can instead begin shutdown and
anyone can repeat unwind in separate transactions. This is conditional progress,
not a guaranteed exit: stale prices, an unfillable tick/price bound, unavailable
liquidity, venue freezes and other venue rules can still prevent execution.
The change does not resolve the remaining margin, liquidation or shutdown
issues elsewhere in the audit, or the calibration and live-fill evidence gaps
recorded for M-6.

## Evidence

Core regressions compare whole-lot capacity against directly enumerated quote
costs, including fractional sell prices; exercise wide arithmetic and a large
target at a tiny price; reject invalid cap changes and opening exceptions;
and close both directions across repeated shutdown calls after a lot increase.
The harness now computes actual quote from the fill price and enforces the cap
on unwind as well as active paths. A one-lot exception still rejects an
out-of-bound fill. Adapter tests cover ordinary and emergency sizing under
sealed execution bounds. These are local source and fixture tests; the vendored
venue interface cannot provide live Aftermath fill evidence.
