# L12 funding conservation review

Scope: L12, Ticket 21 in the Asymptotic October audit restatement. Base main
`40ddbc5c2ffa92270f063ffe62044e6269ffac59`. Source remediation and model review
are separate from original-auditor acceptance and deployment.

## Auditor alignment

Follow the auditor directly: widen all four conservation operands to `u128`
before adding them. Keep `checked_add` as the guard for the actual `u64`
reserve. Credits still repay holders' recorded deficit first and put only the
remainder into reserves. Storage, APIs, events, error numbers, allocation and
rounding are unchanged. No new protocol decision requires an ADR.

## Local evidence

The new regression uses ordinary initialization, a funding cost and a donation
to leave a reserve and an open deficit. On the original production code, a
credit whose checking total exceeds `u64::MAX` fails even though its final
reserve fits. After the fix, both directions pass at and above that boundary,
with the exact restored amount, reserve, cleared deficit and active lifecycle.
A paired test proves an actual reserve above the limit still fails with
`EArithmeticOverflow` in the state module.

All 1,368 Move tests pass: 838 core, 527 adapter and three composition tests.
Core/adapter builds and warning-as-error lint, calibration, source boundaries,
28 Node tests, ABI checks, activation proof self-tests, Python checks,
repository-wide dot syntax/style, oracle routing and generated references pass.
The full run hashes both changed Move files before and after checking them.

Workspace evidence is `outputs/verification/2026-10-24-boosts-l12-funding-conservation/`.
`red-core.log`, `green-core.log`, `full-gates.log` and `implementation.sha256`
record the original regression and full passing run. Heavy work uses the
shared host memory guard and one compiler/test worker.

## Independent review

Fresh Opus 5.5 (`claude-opus-5-5`) reviewed the source, callers, audit restatement,
required standards and completed test evidence in session
`15977ba9-c7ae-4f42-82d7-eb4b68f9adc3`. The response identifies the requested
model and reports no permission denials or inaccessible guidance. It found no
correctness defect and confirmed L12 is addressed in source.

Three follow-ups are included: record the completed implementation and review
while keeping merge pending; explicitly check the staged diff, because the
original unstaged diff check did not cover the staged L12 patch; and end the
expected-failure test with the repository's `abort` convention. The latter
changes only the failure-test fallback; production code is unchanged.
Both focused tests pass after that adjustment, together with style, generated
references and both staged and unstaged diff checks. `post-review-checks.log`
ends with `POST_REVIEW_EXIT=0`; `reviewed-implementation.sha256` binds the
production source and revised test file. The original full-run manifest is
retained separately.
Opus's follow-up confirmed all three items addressed and no actionable defect
remaining. Both review responses identify `claude-opus-5-5` with no permission
denials.

## Remaining limits

An actual resulting reserve above `u64::MAX` still aborts. This fix removes
only overflow in the checking totals, which require an extreme combination
of reserve and credit. It changes no limits or funding economics. Off-chain
consumers recomputing these totals must also use sufficiently wide integers.

The original PDF was unavailable; the review used the repository's audit
restatement. No original-auditor acceptance or live venue execution is claimed.
The intentionally immutable core needs new publication and dependent-package
integration to use the fix. No deployment is included. Closed-market funding
attribution remains the separate A4 finding.
