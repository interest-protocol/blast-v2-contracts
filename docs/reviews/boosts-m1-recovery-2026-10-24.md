# M-1 recovery: implementation and fresh Fable review

Date: 2026-10-24. Base: `2afb2d333b0bd48971e03f745f7e77d92c38c668`.
Scope: M-1 only; repository audit restatement, not the original Asymptotic
report. No original-auditor sign-off and no contract deployment.

## Recommendation and review outcome

**Adopted from the auditor:** a RiskAdmin-gated, live-data rebaseline for a
reviewed forced reduction, while ordinary synchronization remains fail-closed.
[ADR 0121](../decisions/0121-reviewed-recovery-after-a-forced-venue-reduction.md)
explicitly explains the additions: profitable ADL, isolated local funding
accounting, and recording recovery without opening-margin headroom.

Two independent fresh Claude sessions used `claude-fable-5-1`, read-only tools,
no resumed conversation and the repository's required Move review standards.
The initial review found three substantive gaps in the first implementation:
profit-shaped ADL was rejected, opening margin gated recovery, and local funding
was mixed with the historical loss. All three were corrected before the final
review. Emergency-reduction and guard-precedence tests were also added.

The final review returned **no blocker**. Its production-code verdict applies
to the implementation committed with this report. Follow-up changes affect only
tests and documentation:

- Updated the M-1 audit status with source/release limits.
- Documented that mark/oracle divergence can temporarily defer recovery; any
  exemption stays with L-8.
- Added flat recovery with locally refreshed funding snapshots and short-side
  local funding cost and credit tests.
- Retained the documented atomic ordering: local funding changes the reserve
  before final NAV validation; any failure rolls back all state and events.
  The suggested ordering refactor is optional and was not required for safety.

## Verification

Before: a forced reduction remained unexplained and ordinary operations kept
rejecting the stored checkpoint. After: recovery adopts the current position
and preserves ordinary permissions, pricing and trade restrictions.

The initial full run passed adapter 445, core 638 and composition 3 tests, plus
keeper 9, ABI tooling 11 and activation tooling 19 self-tests. Builds, lint,
source boundaries, Move style and generated integrator references passed. The
final adapter rerun passed **448/448**, including all **50 recovery tests** and
the three requested follow-up cases. Runtime code is unchanged from the final
Fable review.

Live ABI verification passed for 5 packages and 73 functions. Inspection of the
pinned liquidation/ADL bytecode confirmed mutation of the existing position,
no free-account cash move, market-IMR liquidation targets, funding settlement and
realized PnL in allocated collateral. This is inspection, not live execution.

Local tests substitute external captures because venue interfaces are ABI ports.
A controlled liquidation/ADL plus the real ACL/rebaseline transaction remains a
release gate. Historical mixed funding remains in holder NAV; its reserve split
cannot be reconstructed from checkpoints alone. M-5 is unchanged. This is a
fresh package lineage and does not upgrade the live NVDA vault.

## Final Fable report (verbatim, before follow-up documentation/tests)

**Verdict: no blocker.** The M-1 source fix is safe to open as a PR with the documented release limits. I found no accepted or rejected shape error, no funding or reserve misbooking, and no authority or composition defect. Four low findings follow, then external evidence gaps.

## Findings

**1. Low, documentation. Audit restatement still marks M-1 open.**
`docs/reviews/boosts-asymptotic-2026-10.md:92` (summary row) and `:173` (ticket status) still say liquidation and ADL "still do" block and the trigger "is open". Other closed tickets (M-4, M-8, M-9) carry a "Resolved in source (ADR …)" status in their PRs. Minimal fix: update both lines to "Resolved in source (ADR 0121); RiskAdmin review, venue-event release gate and shutdown fallback remain", with no sign-off claim.

**2. Low, guard precedence. Checkpoint mutation and emission precede the core recovery check.**
`sui/boosts/aftermath_adapter/sources/operations.move:855-858` replaces the checkpoint, emits `CheckpointRebaselined`, books funding and emits `FundingSettled`, and only then runs `assert_recoverable_position` (stale price, side, positive NAV). Abort rolls everything back, and the ADR documents this, so it is not a safety defect. It is a late check the security standard asks to avoid. Minimal fix, if wanted: split the settlement out of `apply_post_capture` for this path so the order is settle funding, assert recoverable, then replace both checkpoints and emit. Otherwise leave as is.

**3. Low, undocumented residual liveness. Mark divergence can defer recovery.**
Recovery consumes the full price policy through `validated_active_position` at `sui/boosts/core/sources/state.move:1069`, which includes `assert_mark_within_oracle_divergence` (`state.move:1108-1111`). Liquidations cluster in fast moves, exactly when the TWAP mark lags spot. Recovery places no trade and never prices on the mark, so the gate buys nothing here and can refuse recovery until the TWAP converges. It heals by itself, so this is the same liveness shape as L-8. Minimal fix now: add one sentence to ADR 0121's limits. Decide the exemption together with L-8 later.

**4. Low, test gap. Two local-funding shapes are never driven through recovery.**
In `sui/boosts/aftermath_adapter/tests/operations_tests.move`, `recover`, `recover_short` and `recover_and_rebalance` pass identical before and after captures, so the before-to-after edge is `Unchanged` by equality. Missing:
- a flat final position (base 0) whose snapshots refresh locally (before snapshots trail market, after equal market, allocated unchanged). This pins that `classify_change` returns `Unchanged` through the zero-base branch and that the zero-amount `FundingSettled` is emitted and replayed.
- a short-side recovery with a nonzero local cost or credit, which exercises `side_funding_rates` on the short leg inside the recovery path.
Both are fixture-only additions to `recover_with_funding`.

**5. Informational.** The production body of `rebaseline` (`operations.move:373-382`: bound graph, funding update, two captures, venue settlement) is never executed locally; only `complete_rebaseline` runs under test. The ADR already names this.

## What I verified independently

- **Accepted shape.** `checkpoint.move:105-131` requires both checkpoints order-free, a non-flat origin, strictly smaller same-side base or exact flat with zero quote, non-growing coherent quote, exact free cash, lot and position IMR, snapshots equal to current market rates, and live market policy per ADR 0115. Allocated collateral is free to move in either direction. An identical retry fails on strict shrink. `with_venue_policy_of(after)` means a paused or frozen venue passes the shape and is then refused in `into_validated_observation` (`snapshot.move:199-202`), which the precedence test pins.
- **Local versus historical funding.** `complete_rebaseline` proves only the before-to-after edge with the ordinary classifier at the before capture's collateral price, the same price the venue used one call earlier. The stored-to-before edge is recorded, not booked. Reserve and deficit effects go through the unchanged `settle_funding` (`state.move:659-689`); the four `recover_with_funding` cases cover cost absorbed, cost uncovered, credit to reserve and credit repaying deficit, and the reducer replays both events in order.
- **Venue bytecode facts.** `settle_liquidated_position` (`clearing_house.dis:6266`) takes no `Account`, so free cash cannot move; it reads `market::margin_ratio_initial` (`:6328`) and passes it into `reduce_liquidated_position` (`:6492-6494`), which reduces via `add_base_to_position` (`:6700`) and then adjusts position collateral. Position IMR is never written. `add_base_to_position` reduces the quote by a ceiling-proportional slice and a full close leaves exactly zero quote (`position.dis:335-356`), so the quote rule and the flat rule hold. `settle_position_funding` writes both snapshot fields unconditionally, flat position included (`position.dis:2135-2142`), so full-liquidation recovery is not stranded by later rate advances. Its rounding (`:1944-1951`, `:2022-2029`) matches `settled_funding_change`. The ADL counterparty loop (`adl.dis:506-603`) settles funding, reduces via `add_base_to_position`, credits realized PnL and the loss share to position collateral, and never touches an `Account`.
- **Authority and composition.** Only `AdminWitness<RiskAdmin>` is accepted, generation and Active lifecycle gate before venue access, no caller value enters accounting, supply and admin cash and lifecycle are untouched (asserted in tests), the clearing house is borrowed rather than consumed, and the only account authority is the admin cap sealed in `VenueAccount`, so the shape is reachable only through venue-forced reductions.
- **Ordinary paths.** `synchronize_or_fail`, `needs_rebalance` and `into_observation` are unchanged; the forced reduction remains `Unexpected` to permissionless sync, and the opening-margin gate still applies to trades. M-5 is untouched.
- **Errors and events.** Code 38 appended and pinned; both raise sites are location-pinned in tests. `CheckpointRebaselined` carries vault id plus old/new pair; sender comes from native metadata.
- **Gates in the evidence folder.** Adapter 445 tests pass, core 638 pass, composition 3 pass, focused 47 pass, live ABI check passes, no lint or build errors in the logs.

## External evidence gaps

- No real liquidation, ADL or venue funding call runs locally. The short-side reduce branch of `add_base_to_position` and `handle_bad_debt` effects on counterparties were not read; socialized loss without base reduction is correctly outside the shape, but its exact checkpoint signature is unverified.
- The target-network controlled transaction (ACL witness and `rebaseline` in one PTB) remains the release gate.
- Generated references (`llms-full.txt`, `llms/`) regenerate separately; `docs/llms/boosts.md` is already updated.
- A venue pause after a liquidation defers recovery until resume; this is documented but unexercised live.
