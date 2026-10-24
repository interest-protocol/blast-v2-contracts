# 0121: Reviewed recovery after a forced venue reduction

- Status: accepted
- Date: 2026-10-24
- Amends: [0115](0115-venue-policy-from-the-bound-clearing-house.md)

## Auditor recommendation adopted

M-1 reports that liquidation or automatic deleveraging can leave a persistent
position change which ordinary synchronization refuses forever. ADR 0115
already accepts market-wide policy updates, but deliberately rejects account
changes.

We adopt the RiskAdmin-gated rebaseline recommended in the project's audit
restatement: read and validate the live venue, accept a reviewed forced
reduction, and emit the old and new checkpoints. Ordinary callers continue to
fail closed on unexplained drift. The original Asymptotic report was not
available for this change; the attribution is to the repository's restatement,
not a newly verified quotation or auditor sign-off.

## Explicit additions and differences

1. **Allow realized profit, loss or unchanged allocated collateral.** The
   restatement says collateral fell. Aftermath's
   [liquidation documentation](https://docs.aftermath.finance/perpetuals/architecture/liquidations)
   says ADL closes highly profitable positions. Requiring a loss would reject
   that named M-1 trigger. Only the bound venue supplies the amount; free cash
   still cannot move, and base must strictly shrink without changing side.
2. **Separate locally proven funding from the historical change.** Capture
   immediately before and after this call's funding settlement. Prove that
   isolated edge with the ordinary funding classifier and book it under the
   existing reserve/deficit rules. Historical PnL, fees and funding mixed with
   the forced reduction are not invented into a funding entitlement.
3. **Do not require opening margin merely to record recovery.** Recovery
   places no trade. It retains fresh-price, representation, no-orders,
   operational-venue, correct-side and positive shareholder-NAV checks.
   A partial liquidation targets market IMR, not the position's possibly
   stricter IMR (the pinned `settle_liquidated_position` bytecode passes
   `market::margin_ratio_initial` to its size and health calculations).
   Ordinary trade checks stay intact; M-5's reducing-trade restriction remains
   separate work.

## Decision

`operations::rebaseline` accepts no replacement balance, price, position,
checkpoint or loss amount from the caller. Current adapter generation and
Active lifecycle are required before venue access. The complete bound object
graph and current oracle storages are authenticated before funding is refreshed
and settled.

The final checkpoint must show a strictly smaller position on the same side,
or a flat position with zero entry quote. Entry quote cannot increase or switch
sign. Stored and live checkpoints must be order-free. Free collateral, lot
size and position-specific IMR stay exact. Both final funding snapshots must
equal current market rates. Market-wide policy remains live under ADR 0115.
The isolated local settlement must exactly match the venue funding arithmetic.

The existing reserve rules apply only to that proven settlement. The final
valuation must have positive shareholder NAV using the resulting reserve.
Supply, fee settings, admin cash and lifecycle stay unchanged. No NAV is
cached: subsequent operations value the actual remaining position.

`CheckpointRebaselined` records the historical edge from the stored checkpoint
to the capture immediately before local settlement. If that settlement changes
the checkpoint, the following `FundingSettled` records the edge to the final
checkpoint and its reserve allocation. Indexers must process both events in
transaction order; all changes and events roll back on any failure. Native
metadata identifies the administrator. An identical retry fails because it is
no longer a strict reduction.

## Authority and remaining limits

The on-chain shape cannot prove why Aftermath reduced the position. RiskAdmin
must inspect venue history before acknowledging it. The expanded authority is
bounded by live data and the checks above; it is not a general checkpoint setter
and cannot transfer collateral or mint shares. Historical mixed funding is
not recoverable from checkpoint snapshots alone; its net effect remains in
holder NAV. This conservative attribution can differ from the reserve split
that a timely ordinary funding settlement would have produced.

Free-cash moves, changed lot or position IMR, unexplained orders and socialized
losses without a position reduction remain outside this recovery shape. They
require separate review and, if needed, the existing shutdown path. Insolvency,
stale prices or a paused/frozen venue are not repaired by accepting a checkpoint.
The existing mark-versus-oracle divergence guard can also defer recovery during
fast price moves until prices converge; any exemption belongs with L-8.
Recovery cannot revive a shutdown vault. A recovered position below opening
margin may still need shutdown until M-5 is fixed: M-1 removes the stale
checkpoint block, not every independent trade-health restriction.

Local tests execute the actual classifier, core checks, native Vault completion
and event reducers with substituted external reads. They do not execute venue
liquidation, ADL or funding calls. Production release still requires a controlled
venue event and the real multi-command transaction under target-network rules.
This belongs to the fresh package lineage; it does not upgrade or repair the
existing NVDA deployment.
