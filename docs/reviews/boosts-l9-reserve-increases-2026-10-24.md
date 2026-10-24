# L9 reserve-aware increase review

Scope: L9 in the Asymptotic October audit restatement. Base main
`37611fcfca75a2a5e0ef9fc742ecf09dceff681e`. This records source remediation
and independent model review, not original-auditor acceptance.

## Auditor alignment

ADR 0128 follows the auditor's post-fill reserve recommendation. The recorded
reserve remains unchanged during maintenance. Every actual increase fill and
completion uses the reserve admitted at the resulting notional to check
leverage. Reserve-aware sizing extends that recommendation so smaller safe
orders can succeed instead of repeatedly failing the new guard.

The shared sizing also drives preparation, keeper readiness and the mint
catch-up eligibility check. The one-lot band exception survives with actual
post-reserve checks, and its flag is retained in the linear plan for final
validation. Mint catch-up retains its different funded-NAV and opening-admitted
reserve basis. L10 reduction reserve accounting remains separate. No stored
state, authority, public function signature or error code changes; the
transaction-local plan layout changes under the fresh-publication posture.

## Local evidence

On the unchanged base state module, 12 of the 16 new core regressions fail.
The audit's fill to notional 1,880,000 is accepted and the sizing test detects
unsafe leverage when the new reserve is counted. With the fix all 16 pass.

All 1,302 Move tests pass: 798 core, 501 adapter and three composition tests.
The full pre-review gate included 797 core tests; the complete core suite was
repeated after adding the seventeenth L9 regression. Final core lint, style,
generated-reference and hash checks also pass in `post-review-gates.log`,
which exits zero. Production executable lines are unchanged after review;
only the field comment and the new regression were added.
The new core tests include an independent enumeration over reserve saturation,
fees, fractional prices and lot sizes; long/short multi-order completion;
actual-fill and final-completion rejection; keeper/preparation agreement;
valid and invalid one-lot band landings; unchanged fully admitted reserves;
flat reopening; representation bounds; and mint catch-up's separate basis.
The adapter regression uses real capture admission with simulated venue facts
and completes capped increases for both sides.

Core and adapter builds and warning-as-error lint, calibration simulation,
source boundaries, keeper/IMR Node tests, ABI self-tests and live ABI reads,
activation-validator self-tests, Move style and its tests, generated references
and diff checks pass. The entire gate process exited zero. Heavy checks used
one worker under the shared host memory guard. Two existing L3 exact-abort
expectations now locate the unchanged opening-cap error in State's shared
capacity check.

Workspace evidence: `outputs/verification/2026-10-24-boosts-l9-reserve-increases/`.
`red.log` is the baseline reproduction; `core-focused.log` and `full-gates.log`
record passing checks. `implementation.sha256` identifies the tested Move
files. Prompts and raw JSON preserve the independent review provenance.

## Independent review

Fresh Opus 5.5 (`claude-opus-5-5`) reviewed the implementation against L9 in
session `fe1c92b9-6cdf-4f51-96e5-bf10a148f57d`. It confirmed the source fix
and found two Low follow-ups: a missing ordinary-fill-then-one-lot-exception
test and the reserve field's stale claim that every credit is clamped.
Added a long/short two-fill regression with a growing nonzero reserve and
corrected the comment. A first-fill-only mutation checks that the new
regression detects a lost final exception flag: it fails at completion with
code 52. Opus verified both corrections and found no remaining actionable L9
findings. Final staged whitespace checks cover the new tests and ADR, and
only the L9 tracker change is staged; the unrelated L7 note remains local.
Both responses confirm the exact requested model with no permission
denials. The final gate and staged-file checks are performed by the implementer;
Opus did not claim checks still running during review had passed.

## Remaining limits

The source fix does not guarantee execution: no safe whole lot, actual costs,
margin requirements, paused markets or missing liquidity can still prevent
progress. Simulated capture tests and live ABI reads do not replace live
Aftermath execution proof, which remains a release gate. L10 remains open.
The accepted first-party fresh-publication posture applies; historical
packages are unchanged and no deployment was performed.
