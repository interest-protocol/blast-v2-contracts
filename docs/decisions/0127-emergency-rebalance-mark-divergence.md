# Emergency rebalance admission during mark divergence

Status: accepted. Date: 2026-10-24.

## Problem and audit alignment

L-8 reports that a large difference between the venue mark and the base oracle
blocks emergency risk reduction, even though the core values equity and sizes
orders using the base and collateral oracles. Follow the auditor's primary
recommendation: exempt emergency reductions from this divergence check, as
shutdown closing already is. Keep the ordinary tolerance unchanged. Raising
it globally would weaken ordinary admission and would not remove the emergency
failure for larger gaps. The venue's index/TWAP tolerance is not necessarily
the same measurement as our composite-mark/base-oracle comparison.
This narrows ADR 0064's general mark-check requirement for exposure-changing
operations only for these emergency reductions.

The finding source is the repository's Asymptotic October audit restatement;
independent model review does not constitute original-auditor acceptance.

## Decision

Before classifying a rebalance, validate both oracle legs for freshness and
confidence, the position side, and positive shareholder NAV. Compute emergency
status from the exact starting notional/NAV ratio: strictly above the hard cap
qualifies; equality does not. Ordinary starts still require mark divergence
within the existing policy before band eligibility or execution. The keeper
readiness hint follows the same admission and classification.

Reuse the emergency decision already sealed in the transaction-local plan.
Every accepted fill of that emergency plan skips only the mark-divergence
check, including the final fill that restores the cap. Reclassifying the final
fill would roll back the very recovery this exception permits. Ordinary plans
cannot acquire the exception through adverse fills. A subsequent ordinary
transaction must pass the divergence check again.

Both oracle legs, side, positive NAV, fixed price/lot checkpoint, exact base
movement, order-size and execution-price limits, order budget and actual
progress requirements remain enforced. Adapter authentication, no-resting-order
and market-readiness checks remain. The existing stop-at-the-cap rule and
priority-gas policy are unchanged. No caller chooses the exception; no public
signature, stored state, plan layout, authority or error code changes.

Non-rebalance operations retain their existing guard order. Rebalance starts
now validate side and positive NAV before the conditional divergence check,
because those facts must be valid before emergency classification. Tests pin
that deliberate precedence.

## Evidence and limits

Regressions cover long/short emergencies, both mark-gap directions, multiple
fills through cap restoration, exact threshold comparisons, reserve-aware
classification, keeper readiness, strict ordinary/mint admission, stale and
uncertain prices, wrong side, invalid NAV and changed checkpoints. Adapter
capture tests exercise the same admission without opening-margin headroom.

This removes a local rejection, not every reason the venue can refuse a trade.
Funding/oracle operations, paused or frozen markets, missing liquidity, actual
costs and other venue rules can still prevent completion. Live Aftermath
execution remains a release gate; simulated captures prove local logic only.
Use fresh first-party publications under ADR 0115; this change does not patch
the historical deployment or authorize publication.
