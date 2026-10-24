# L10 reserve-consistent emergency reduction review

Scope: L10 in the Asymptotic October audit restatement. Base main
`ec193ec7acc2d1c7fceeca2d79c89492256d91be`. This records source remediation
and independent model review, not original-auditor acceptance.

## Auditor alignment

ADR 0129 combines the auditor's current-position reserve and genuine
emergency notional-reduction remedies. Each position uses the same reserve
admission rule at its own notional. Sizing, fill admission, next-order stopping,
ordinary capacity projection and completion agree. The temporary issuance
restriction and dedicated opening-reserve-crossing error are not used because
the core basis is corrected.

Emergency completion requires less base and oracle-valued notional with
positive actual holder value. Partial batches need not meet the ordinary
minimum, restore the hard cap or improve the ratio. Ordinary progress rules
remain. Target sizing accounts for the reserve at the remaining position and
stops at the actual hard cap, avoiding excessive sales under emergency pricing.

An additional emergency cost limit protects every partial fill: bounded price
cost and the ordinary taker fee must fit strictly inside current admitted NAV.
Reprice it after every fill. If that conservative limit cannot afford one lot,
exactly one lot may use its own reserve release when post-cost holder value
remains positive. A flat close retains the full recorded reserve. When no
lot is affordable, stop and retain prior valid reductions. Recorded reserve,
supply and admin cash are unchanged. L9 increases, mint catch-up, L8 admission,
M9 gas rules, execution limits and checkpoint proofs remain.

## Local evidence

The initial three regressions fail on unchanged base production: both the
next-order and completion paths abort against the opening reserve, and a
costly partial emergency close fails the old progress requirement. The final
reserve-crossing tests use two affordable fills and still cross the original
reserve before next-order sizing and completion.

The independent review identified a further batch failure. At notional
1,000,000, equity 10,000 and a 2% execution allowance, the old sizing spends
all remaining equity on its fifth close and reverts the earlier valid fills.
`red-emergency-batch.log` reproduces that failure on base source. The fixed
core test completes five fills with equity 3 and notional 500,650 despite two extra
rounding-cost atoms per fill, then sizes
zero. Adapter capture tests repeat the loop with venue units and below-margin,
mark-divergent observations. They simulate execution; they are not live fills.

All 1,328 Move tests pass: 821 core, 504 adapter and three composition tests.
The 23 L10 core tests cover long/short reserve-crossing and costly partial
completion, actual-cap stopping, ordinary progress/capacity, independent
whole-lot sizing enumeration, flat reserve/fee boundaries, zero NAV, no fill,
unchanged oracle notional, inverse-quote overflow, retained-order rejection,
sequential-cost affordability, partial fills before reserve release, the
single-lot affordability exception, sub-price-atom oracle loss, and both ordinary projection-exhaustion
branches. Three adapter tests cover both sides. A supplemental arithmetic
check matches target sizing to 6,638 exhaustive-reference cases.

Core/adapter builds and warning-as-error lint, calibration simulation, source
boundaries, Node keeper/IMR tests, ABI self-tests and live ABI reads, activation
proof self-tests, Move style and its tests, generated references and diff
checks all pass. The final gate hashes every changed Move file before running,
checks those hashes afterward, and exits zero with `FULL_GATE_EXIT=0`.
Heavy checks use one worker under the shared host memory guard.

Workspace evidence: `outputs/verification/2026-10-24-boosts-l10-reductions/`.
The authoritative run is `final-gates.log`; `implementation.sha256` identifies
its source and tests. Earlier logs are retained and distinguished in the
artifact README. Prompts and raw JSON preserve model review provenance.

## Independent review

Fresh Opus 5.5 (`claude-opus-5-5`) reviewed against L10 in session
`5229d7e5-0964-414c-8ffb-6495e73f3543`. It found two Low follow-ups and an
informational comment issue: sequential permitted costs could undo a batch;
the ordinary projection exhaustion branches lacked tests; and the adapter
keeper-hint comment had not followed the new sizing behavior. Added the
emergency affordability limit, full and partial batch regressions, both exact
ordinary exhaustion tests, and corrected the comment and related guidance.

Opus confirmed those corrections and identified one additional Low precision
gap: a binding order could spend value omitted by oracle normalization and
equity capture rounding. The final cost helper now adds the full value of one
normalized price atom per base unit, its fee, and three collateral atoms for
capture conversions. It applies to emergency sizing and the single-lot/flat
checks. Tests include two extra actual-cost atoms per fill and a low-price
long fixture with a full oracle 50% above its truncated observation.

Opus verified that the precision finding is closed and no actionable L10
source defect remains. It independently recomputed the allowance, monotonicity,
flat and single-lot boundaries, and reviewed the completed 1,328-test gate and
all nine file-hash checks. Its final non-blocking guide wording request is
corrected: precision and capture allowances also apply to ordinary flat closes.
The low-price fixture stresses the cost upper bound; the venue tick would make
its actual minimum-price fill less adverse, so it is not live execution proof.
All three review responses confirm the exact requested model with no permission
denials. Original-auditor approval remains separate. Final staged generated
references are checked without first regenerating them.

## Remaining limits

Emergency exposure reduction can worsen leverage or physical margin and
consume nearly all holder value. An order with no fill still reverts the
adapter transaction. Missing liquidity, invalid prices, venue restrictions,
actual costs beyond the projection and priority-gas surcharges can still
prevent completion. An unaffordable last lot may need separately authorized
shutdown. The conservative cost limit does not promise the largest possible
full fill after reserve release.

Live Aftermath execution remains a release gate; local tests, ABI reads and
model review do not replace it. Fresh first-party publications follow ADR
0115. No deployment, historical package upgrade or merge was performed.
