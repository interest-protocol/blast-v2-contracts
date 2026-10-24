# L11 protected exit review

Scope: L11 in the Asymptotic October audit restatement, Ticket 20. Base main
`5ba4d8ebefa319f69ab8a8d8fc91d8bad8a58f45`. Source remediation and model
review are not original-auditor acceptance or live venue execution evidence.

## Auditor alignment

[ADR 0130](../decisions/0130-protected-permissionless-shutdown.md) follows the
auditor's second option: a permissionless terminal trigger. The trigger is
refined to prove the largest circulating-share burn fails the ordinary size
guard, before lot rounding and with the existing zero-keep exemption. Checking
only total base against the minimum would miss some locks and admit positions
with an ordinary exit. Entry authenticates native supply and bound account
facts without prices, positive NAV or opening margin. Market-wide settings
may change; actual account changes must first be reconciled.

Payout protection extends the auditor's recommendation. Reusing the legacy
payout would let someone mint, withdraw almost everything, leave one share,
and collect the starter cash and reserve. Protected finalization retains the
full recorded reserve up to actual recovery, then gives circulating holders
their floor-rounded fraction of the remainder. The seed fraction and reserve
enter private protected cash. Claims and admin withdrawals cannot spend it.
The user explicitly chose to retain that cash after all holders exit, with
no beneficiary or sweep. Existing upgrade governance remains trusted.

## Local evidence

All 1,366 Move tests pass: 836 core, 527 adapter and three composition tests.
The 15 new core tests cover exact threshold and rounding boundaries, independent
enumeration of every accessible burn, wide arithmetic, zero/loss recovery,
recorded funding, a real mint/large-redemption/one-share sequence, a reducing
rebalance into a size lock, both directions, unchanged admin allocation and
irreversible lifecycle protections.

The 23 new adapter tests cover actual native share burns and cash claims,
protected balances after every claim and admin withdrawal, zero recovery,
shared event replay, both directions, seed-only and ordinary-exitable rejection,
orders, malformed exposure, account drift, changed lot, market pause/freeze,
funding already settled versus properly accounted, and overlapping protocol,
lifecycle and account errors. The capture seam substitutes external venue
reads; production protocol/lifecycle authorization and local completion run.

Core/adapter builds, warning-as-error lint, calibration, source boundaries,
28 Node transaction-builder/IMR tests, 11 ABI self-tests, read-only ABI checks
for five packages and 75 functions, 22 activation proof self-tests, Python
checks, repository-wide dot-syntax/style, oracle routing, generated references
and diff checks all pass. Heavy jobs use the shared host memory guard and one
compiler/test worker.

Workspace evidence is `outputs/verification/2026-10-24-boosts-l11-protected-exit/`.
`final-gates.log` ends with `FULL_GATE_EXIT=0`; `final-implementation.sha256`
and `final-hash-check.log` bind all 14 changed Move source/test files in that
run. Initial development logs are superseded and retained separately. After
review, only a finalization comment and documentation were clarified; generated
references and diff/style checks were rerun. No executable code changed.

## Independent review

A fresh Opus 5.5 (`claude-opus-5-5`) review ran in session
`70bc02bb-74ce-40e5-a2e4-3d0009a2ac43`, followed by a focused review of the
revisions and completed test evidence. Raw prompts and JSON preserve provenance;
both responses identify the requested model and have no permission denials.

The first review found a Medium liveness gap: exact equality included market
pause and funding settings, while synchronization can fail on paused markets.
Entry now requires unchanged account facts under the existing market-policy
classification and adopts the fresh market settings. Already-settled account
funding remains rejected until its reserve effect is booked. The planner does
not prepend synchronization unconditionally because that would block closed
markets again; the source and integrator guide explain when sync is required.

The Low findings were also addressed: upgrade-aware custody wording; one
authoritative finalization event with explicit protected amounts; shared event
replay and version/error-priority tests; and the clearer protected-shutdown API
name. The final follow-up found no new defect, confirmed every actionable finding
addressed, and confirmed L11 and the one-share capture are fixed on this path.
Its optional finalization comment clarification distinguishes seed-only admin
cash from holder cash and is included.

## Remaining limits

Anyone can intentionally leave tiny circulation and make irreversible closure
eligible. New issuance is needed to restart. Holders may need to combine shares
when their total still supports an ordinary exit. Full recorded reserve retention
can leave zero holder cash; losses and funding are not insured.

Closed-market settlement may settle funding without separately attributing it
to the reserve book. Actual recovered cash stays exact, but the protected split
uses the last recorded reserve. Funding settled immediately before a market
pause can still block protected entry until account reconciliation is possible.
Frozen markets can accept protected entry at the local capture seam, but unwind
and finalization remain blocked while frozen; live read availability is unproven.

Legacy admin shutdown keeps its old distribution and should not substitute for
an eligible protected exit. Unexplained account drift, lot changes and liquidation
still require administrative recovery. Missing close prices, liquidity, venue
restrictions and settlement availability can delay or prevent recovery.

Fresh core and adapter publication are required; this is not a compatible upgrade
to the published core or deployed vaults. No merge, deployment or live transaction
was performed. Original-auditor acceptance remains separate.
