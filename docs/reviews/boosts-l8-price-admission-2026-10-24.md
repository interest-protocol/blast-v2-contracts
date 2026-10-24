# L8 emergency price admission review

Scope: L8 in the Asymptotic October audit restatement. Base main
`8bd44ea8d1752bbbe71e37ebd860cde4a8daf6ab`. This is source remediation and
independent model review, not original-auditor acceptance.

## Auditor alignment

ADR 0127 follows the auditor's primary recommendation: exempt emergency
reductions from mark/oracle divergence, without widening ordinary tolerance.
Validate both oracle legs, side and positive holder backing before deriving
emergency status from the exact starting leverage. Keep that decision through
the final cap-restoring fill. The keeper hint uses the same admission.

Ordinary plans cannot acquire the exemption from their own fills; equality at
the hard cap is ordinary. Other priced paths stay strict. Price and order
limits, checkpoints, exact fills, progress, market readiness and priority-gas
rules remain. No public signature, stored or plan layout, error or authority
changes. The adapter adds only a test-only mark fixture.

## Local evidence

Two regressions fail with divergence code 31 on unchanged production: emergency
completion and the keeper hint. Both pass with the fix.

All 1,284 Move tests pass: 781 core, 500 adapter and three composition tests.
The 35 new core and six adapter regressions cover long/short positions, both
mark-gap directions, multiple fills through cap restoration, exact cap and
mark-tolerance boundaries, reserve-aware classification, ordinary/mint/redeem
admission, oracle freshness/confidence, wrong side, invalid NAV, checkpoint
changes, exact base movement and actual progress.

Builds and warning-as-error lint, simulation, source boundaries, keeper/IMR
Node tests, ABI self-tests and live ABI checks, activation-validator self-tests,
Move style and its tests, generated references and diff checks pass. All
compilation/test gates used one worker under the shared host memory guard.
The complete gate process exited zero. Post-review documentation regeneration
and its current-reference check are recorded separately; implementation and
tests were unchanged after the full gate.

Evidence is retained in the shared workspace under
`outputs/verification/2026-10-24-boosts-l8-price-check/`: `before.log`,
`focused-expanded.log`, `adapter-focused.log`, `full-gates.log`,
`post-review-docs.log` and the Opus prompts/responses. The implementation hash
manifest identifies the four tested Move files.

## Independent review

Fresh Opus 5.5 (`claude-opus-5-5`) reviewed the implementation against L8 in
session `a345145f-7039-467b-89cb-cdb86ee21c2c`. It found no code defects and one
Low documentation inconsistency: the guide's general price rules still said
all priced operations require mark agreement. Corrected that sentence and
regenerated both references. ADR 0127 also explicitly narrows ADR 0064's general
mark-check requirement. Opus verified the correction and found no remaining actionable L8 findings.
Both responses confirm the requested model and no permission denials. The
minor keeper-specific diagnostic-precedence coverage gap was nonblocking: its
shared validation helper is exercised directly by the execution tests.
The final staged diff check also covers the newly added tests and ADR.

## Remaining limits

Captures are simulated; live Aftermath execution under divergence is still a
release gate. Venue funding/oracle rules, pauses/freezes, unavailable liquidity
and actual costs can still block a trade. The fix removes our divergence check
only. The core requires fresh publication under ADR 0115; historical deployments
are unchanged. No package was published and this is not original-auditor sign-off.
