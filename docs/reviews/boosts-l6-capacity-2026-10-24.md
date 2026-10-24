# L6 rebalance capacity review

Scope: L6 in the Asymptotic October audit restatement. Base main
`b5da7eefce6020179cc0181aa15c024a5e7ce10e`. This is the project's source
assessment; original-auditor acceptance is not established by this review.

## Auditor alignment and invariants

ADR 0126 preserves the auditor's emergency cap-restoration rule already present
under ADR 0118. It follows the auditor's sixteen-order configuration bound at
issuance, where both policy and caps exist, and both live cap setters. The
comparison is an optimistic necessary bound, not a promise of net execution.

It extends the recommendation at runtime because actual NAV can exceed the
deposit ceiling and trading costs reduce improvement. Only when the original
completion rules fail, project a full batch with existing sizing and conservative
per-order costs. Require exactly sixteen fills, each matching its entire freshly sized core
order, and actual progress toward target to match or exceed the projection. Exact
fraction comparisons retain improvements smaller than one basis point. Sixteen
tiny fills cannot qualify by exhausting the counter. Core owns and enforces
the same sixteen-fill budget the production adapter uses.

A boolean full-fill proof is added to the transaction-local plan. Stored state,
transaction signatures, fees, price bounds and maintenance entry boundaries
are unchanged. Ordinary minimum progress and
near-target completion remain available; emergency cap restoration remains
sufficient. The new exception only concerns reducing positions.

## Local evidence

Two initial regressions fail against unchanged production source: impossible
configuration is admitted, and a full batch at live NAV above the deposit cap
reverts useful progress. Both pass with the fix.

All 1,243 Move tests pass: 746 core, 494 adapter and three composition tests.
The 42 new L6 tests cover static equality/one-past limits and wide arithmetic,
both setters and guard precedence, long/short full and repeated simulated
batches, sub-basis-point progress, reserve exclusion, full emergency batches
still above the cap, early ordinary completion, partial fills, excessive costs,
no-progress projection and rejection of a seventeenth fill. The exact-distance
helper is compared with 1,296 independently enumerated small-integer cases.

Builds and warning-as-error lint, core/adapter source boundaries, calibration
(6), keeper/IMR tests (27), ABI checker self-tests (11), live ABI checks
(5 packages/75 functions), activation self-tests (22), Move style (202 modules/
10 tests), generated references and diff checks pass. Existing test setups were
adjusted to satisfy the new capacity invariant while retaining their original
assertions. The NAV update event test now uses a valid lower cap. All 42 focused L6 tests pass, including cheaper/favorable shrinking tails,
partial-tail and retained-order rejection, and both-side emergency simulation.

Evidence is retained in
`outputs/verification/2026-10-24-boosts-l6-capacity/` in the shared workspace:
`post-review-gates.log`, `post-review-focused.log`, the initial reproduction
logs and independent review metadata. Earlier logs retain intermediate fixture
failures and the initial source review; they are not final validation results.

## Independent review

Fresh Opus 5.5 reviewed the source against the audit restatement in session
`bdff27ee-5840-44b7-ae19-ea24ad752706`; both CLI responses confirm
`claude-opus-5-5`. Its initial review found one Medium and two Low issues:

- A cheaper fully filled emergency batch could fail an independent projected
  base threshold because its last order shrank. Reproduced its exact example
  with code 55, then replaced the base threshold with the explicit full-fill
  proof. The suggested cost-free floor also rejected some favorable-price
  sequences, so the final design proves each actual order against fresh sizing.
- The activation fixture violated the new capacity bound. Corrected it to exact
  equality and added BigInt preflight plus three failing-boundary self-tests.
- A comment still assigned order-budget ownership to the adapter. Corrected it.

Added both-side ordinary/emergency sweeps, favorable execution, an emergency
simulated-venue tail, partial-tail and smaller-retained-order rejection, a full
batch with an unusable cost projection, and three diagnostic-precedence tests.
Opus's follow-up accepted all corrections, judged the explicit full-fill proof
stronger than its proposed floor, and found no remaining actionable findings.
It accepted the documented adapter-runtime evidence limit without identifying
a viable missing local test.

The verdict was conditional on the final gate exiting zero and including the
last reducing-order check. Both are confirmed: that check was written before
launching `post-review-gates.sh`, and its complete run exited zero, including
current generated references and a clean diff check. Review metadata and raw
responses are retained with the logs. This is a model review, not acceptance by
the original auditor, and the simulations are evidence rather than a general
mathematical proof of every possible market path.

## Remaining limits

The fallback cannot guarantee liquidity. Partial fills, unavailable markets,
stale prices, insufficient equity or costs that erase projected improvement
can still abort. An administrator may need to raise the order cap or initiate
shutdown. Priority-gas surcharges are not in the ordinary taker-fee projection;
actual net-progress checks still apply. This does not resolve separate L9/L10
reserve-accounting findings.

Local venue interfaces cannot execute real trades. Live long/short Aftermath
fills, fees, priority surcharges, partial-fill handling and atomic rollback
remain release gates. Use fresh first-party packages under ADR 0115. No package
was deployed and the historical deployed vault is unchanged.
