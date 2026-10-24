# Reserve-consistent reductions and emergency exposure progress

Status: accepted. Date: 2026-10-24.

## Problem and audit alignment

L-10 describes a closing trade accepted against its smaller current reserve,
then reverted by next-order sizing or completion against the larger opening
reserve. Positive shareholder value at the actual position is insufficient
when a later check subtracts a reserve amount that no longer applies.

Combine the auditor's two core remedies: admit the reserve at each position,
and allow a sealed emergency plan to complete on a genuine exposure decrease.
Extend them through order sizing, stopping, and ordinary capacity projection.
Changing only completion leaves earlier blockers and excessive close sizing.
Do not use the temporary issuance-policy restriction or a dedicated
opening-reserve-crossing error: those alternatives retain the inconsistent
basis. The finding source is the repository's Asymptotic audit restatement;
model review is independent verification, not original-auditor approval.

## Decision

Before-progress NAV uses the reserve admitted when the plan opens. Each
candidate, accepted fill, subsequent order, and final position admits the
reserve appropriate to its own notional under the same ADR 0086 rule:

```text
positive position: reserve = min(recorded reserve, floor(notional * ceiling_bps / 10,000))
flat position:     reserve = recorded reserve
shareholder NAV = actual equity - admitted reserve
```

The recorded reserve, supply and admin cash do not change during rebalance.
A lower admitted reserve relabels existing equity; it creates no collateral.
ADR 0128's increase checks and mint catch-up's distinct funded basis remain.

Reduction sizing finds the largest whole-lot remaining position at or below
ordinary target or emergency hard cap, valuing its own admitted reserve at
unchanged current equity. Search positive remaining positions monotonically:
more remaining exposure cannot lower reserve or leverage. Observations already require whole-lot positions. Cap each close under its execution-price allowance, with
the existing minimum-lot closing exception. Actual costs are not charged in
the target search: doing that would sell too much when fills are cheaper.
Recompute from actual equity and exposure after each fill. Rounding and
execution costs can require another order; favorable fills may overshoot.

Before placing an emergency order, also cap its bounded price cost plus the
ordinary taker fee strictly below current admitted NAV. This conservative
limit protects every possible partial fill, including fills before a recorded
reserve begins to exceed the shrinking ceiling. A full-fill-only cost check
would miss that intermediate loss. The cost predicate is monotone, while cost
minus reserve release can change direction and has rounding discontinuities.
Recompute affordability after each actual fill, so later orders benefit from
the released reserve rather than carrying the plan's opening reserve forward.

Affordability includes precision losses as well as the economic price bound.
The adapter floors the full oracle to its normalized price, so a long close
can lose up to one normalized price atom per base unit beyond the slippage
calculation. Add that full collateral value, rounded up, plus its fee; merely
applying slippage to an upper quote would not cover the loss. Apply the same
conservative allowance to both sides. Also add three collateral atoms for
the two signed equity components and their intermediate fixed-point collateral
conversion. The same cost helper serves emergency sizing, the single-lot
exception and flat preflight. None of these guards relies on a one-atom
margin in the unadjusted execution-cost model.

If that conservative cap cannot afford even one whole lot, allow exactly one
lot only when its own post-cost remaining-position NAV is positive. A smaller
nonzero whole-lot partial fill is then impossible. Stop when no affordable
lot remains and keep the valid emergency reductions already made. This does
not promise the largest order that could succeed on a favorable full fill;
it prevents a later bound-priced order from consuming all shareholder value
and undoing the batch. Ordinary reduction sizing retains its progress checks.

Flatness is a separate boundary because it admits the full recorded reserve.
Before selecting a close to zero, reserve its adverse price cost and ordinary
taker fee as well as the full reserve. If no positive shareholder value would
remain, leave one lot. This may end a batch with positive exposure; preparation
and keeper readiness use the same sizing and reject/report false when no lot
is actionable. Actual post-fill positive NAV remains mandatory, including on
completion. Priority-gas surcharges are not included in either affordability projection.

Emergency status remains sealed from the authenticated opening position,
strictly above the hard cap. A completed emergency plan must have at least
one accepted fill and strictly less base **and** oracle-valued notional. It
need not meet the ordinary minimum, restore the cap, fill every order, or
improve the leverage ratio. A real reduction with positive holder value may
worsen leverage or physical margin after costs; accepting that tradeoff avoids
reverting every possible close in the audit's thin-equity window. Stop sizing
as soon as actual leverage reaches the hard cap; subsequent maintenance is
an independently admitted ordinary plan. Each plan still accepts at most
sixteen fills.

Ordinary reductions retain the configured minimum or one-lot target rule.
Their full-sixteen-order capacity exception still requires canonical full
fills and net progress at least as good as a conservative projection. That
projection now admits the reserve at every projected remaining position,
including its final NAV. Reject nonpositive projected holder value or no net
improvement. An ordinary plan cannot promote itself to emergency after costs.
This amends ADR 0118's and ADR 0126's emergency completion rules.

Fresh oracle pair, exact side/checkpoint/base movement proofs, execution-price
limits, actual quote caps, venue readiness, and ordinary margin/mark/gas rules
remain. The emergency mark exception and gas-price policy from L8/M9 remain.
No stored layout, authority, public function signature or error code changes.
The existing not-actionable error now also covers reductions with no safe last
lot. Fresh first-party publications follow ADR 0115; no deployment is implied.

## Evidence and remaining limits

The audit regressions reproduce both old-reserve aborts and costly partial
emergency completion. Tests cover both sides, actual-cap stopping, ordinary
progress and capacity, reserve/lot/price enumeration, final-lot boundaries,
zero value, unchanged notional, sequential bound-priced costs, conservative
partial-fill affordability, unchanged raw reserve and adapter capture
admission below opening margin with divergent marks.

This removes the inconsistent-reserve and minimum-progress blockers, not all
closing failures. An order with no fill still aborts the adapter transaction,
including earlier fills. Missing liquidity, fresh-price failures, venue rules,
insolvency and priority-gas costs can still prevent progress. A last lot that
cannot retain the full reserve may require separately authorized shutdown;
this change does not silently discard that reserve. Once no affordable lot
remains, readiness is false and preparation rejects. Further progress can
require a price or funding change, a donation, or separately authorized
shutdown. Repeated expensive emergency reductions can consume holder value
even while reducing exposure.

Local capture tests simulate venue execution. Live Aftermath execution,
including priority fees, below-margin closes, and rollback behavior, remains
a release gate. No original auditor sign-off or deployment is claimed.
