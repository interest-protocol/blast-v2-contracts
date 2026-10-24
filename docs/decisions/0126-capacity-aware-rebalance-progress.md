# Capacity-aware rebalance progress

Status: accepted. Date: 2026-10-24.

## Problem and audit alignment

L-6 describes reductions whose stopping rule or sixteen-order budget cannot
meet the configured minimum improvement. Retrying reverts the same useful
trades. Follow the auditor's emergency rule already implemented under ADR
0118: a reduction that restores the hard cap and lowers base succeeds, even
if its improvement is smaller than the ordinary minimum.

Also follow the auditor's configuration bound. At issuance, when both policy
and caps are available, and whenever either live cap changes, require:

```text
minimum_improvement_bps * nav_cap <= 16 * max_order_notional * 10,000
```

Compare with wide exact arithmetic. This is a necessary, optimistic capacity
bound: even cost-free cap-sized orders must cover the minimum at the deposit
ceiling. It is not a promise of net progress after fees, lot rounding or scarce
liquidity. Keep the existing live minimum-order validation on order-cap updates.

Extend the recommendation with a runtime completion rule. NAV can exceed its
mint ceiling through profits, or the administrator can lower that ceiling.
Static validation alone therefore cannot prevent this trap. Execution costs
also reduce the leverage improvement from a given sale. The source of the
finding is the project's audit restatement, not original-auditor sign-off.

## Completion rule

Retain ordinary completion at the configured minimum, or within one lot of
target without moving away. Retain emergency completion once the cap is
restored with less base. Only if those checks fail, compare the actual result
with a full-batch conservative projection from the sealed starting position:

1. Use the core's existing ordinary or emergency sizing, prices, lot size,
   execution cap and fixed admitted reserve. Recalculate sizing after each
   projected fill, up to sixteen orders or the original stopping condition.
2. Charge each projected order its adverse price allowance and authenticated
   taker fee, rounding costs upward per order. Reject the exception if these
   costs consume NAV or the projected result does not move toward target.
3. Require all sixteen actual fills to match their full order amounts and fresh
   core sizing at each step. Record that proof in the transaction-local plan.
   Partial fills and smaller retained orders cannot qualify just by using every
   slot. Do not compare actual sold base to a separate projection: cheaper or
   favorable fills change NAV and shrink the last orders, so even a cost-free
   base floor can reject a fully executed batch.
4. Require actual progress toward target and a result at least as close as
   the projection, after actual costs. Compare exact fractions so a useful
   improvement smaller than one basis point is not rounded down to zero.

This applies to ordinary reductions and emergency batches still above the
hard cap after exhausting capacity. It never grants an increase exception.
A partial or shorter batch must still meet an original completion rule; merely
beating the conservative leverage projection is insufficient.

Core owns the sixteen-fill budget, exposes it to the adapter's rebalance
loop and rejects a seventeenth accepted fill. Mint, redeem and unwind budgets
are unchanged. A boolean is added only to the transaction-local rebalance plan;
stored state and adapter transaction signatures are unchanged. Fees, price
allowances and the private maintenance entry boundary are unchanged.

## Limits and release evidence

This is conditional progress, not guaranteed trading. Thin books, partial
fills, stale prices, market restrictions and insufficient margin or equity
can still abort. If conservative costs erase the projected improvement, the
fallback refuses it. Raising the order cap or administrator-triggered shutdown
may still be required. An abort rolls back venue and vault changes, except gas.

The projection uses the authenticated ordinary taker fee. An emergency trade's
priority-gas surcharge is an additional actual cost; it may prevent this
fallback from completing. Actual net-progress checks remain authoritative.
This decision does not change reserve accounting or resolve the separate
L-9/L-10 reserve findings.

Use fresh first-party publications under ADR 0115. Local tests cover boundary
configuration, long/short capped batches, repeated recovery, reserve exclusion,
sub-basis-point progress, partial fills and adverse costs. Real Aftermath
execution, including priority surcharges and atomic rollback, remains a release
gate; ABI checks and the simulated venue do not prove it.
