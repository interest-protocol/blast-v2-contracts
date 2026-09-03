# Claude Fable 5.1 audit of the Blast leverage coins Series1 package

Date: 2026-09-03

Status: line-by-line security and math audit of the current working tree,
with the in-package remediation applied the same day (see the final section)

Model: `claude-fable-5-1` orchestrating five `claude-opus-5` auditors, each
reading every line of its slice plus the tests and docs that cover it

Scope: `contracts/sui/leverage_coins/series_one` only (the working tree that
moves the package under `series_one/`, adds `policy.move`, and merges the
former `share_math` and `maintenance_math` modules into
`lib/accounting_math.move`). Toolchain `sui 1.77.2-51d177ad7d65`, framework
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`. This record follows the
[design review of 2026-09-01](claude-opus-5-leverage-design-audit-2026-09-01.md)
and the [Phase 1 code audit of 2026-09-02](claude-fable-5-1-leverage-coins-audit-2026-09-02.md).
It is not a claim that the package can hold value; the package README still
says it cannot.

## Verdict

The arithmetic is sound. No overflow, underflow, division by zero, cast, guard
ordering, or abort code defect was found in any production line. Every
value-moving rounding site favours remaining holders or the reserve. Mint and
redeem round trips cannot profit, and splitting an operation never beats doing
it once; both were proven algebraically and brute forced. The lifecycle is a
closed monotone lattice with all 35 state-by-operation cells tested. The policy
predicates nest consistently with zero violations over an exhaustive sweep.
The gate is green: build with zero warnings, 290 of 290 tests, lint clean,
boundaries hold.

The risk sits in what the package declines to bound and in the frame around
the code rather than in the formulas. One finding should gate the Series slice:
the redemption path has no analogue of the mint side's favourable-divergence
bound, so any equity that appears between the two NAV reads is paid in full to
the redeemer regardless of stake. Three auditors reached this independently.
The source-boundary script, which is the only mechanical enforcement of the
package's "no public surface" model, has an inert public/entry gate; the
orchestrator confirmed this by hand. Several policy values are stored and
validated but have no gate in the module that owns every other gate.

Overall score: 9 of 10 for the code as written; 7 of 10 for the enforcement
frame around it until the two Medium script findings are fixed.

## What was verified

- Read in full by at least one auditor: every production module, every test
  module, both scripts, both READMEs, `docs/accounting.md`, `Move.toml`,
  `Move.lock`. `accounting_math.move` was read in full by three auditors.
- `sui move build` (zero warnings), `sui move test` (290 pass), and
  `scripts/verify.sh all` (boundaries, testnet and mainnet builds, lint with
  warnings as errors, tests with lint) all pass on a scratch copy.
- Stdlib at the pinned revision: `u64::mul_div` and `mul_div_ceil` widen to
  `u128`, `u128` variants to `u256`; every narrowing cast back is provably in
  range or routed through `narrow_to_u64` (abort 15).
- Python replicas of every exposure and share formula reproduced every pinned
  test expectation exactly, then brute forced the documented invariants over
  roughly one million tuples with zero violations.
- The boundary script's public/entry gate was tested empirically: a column-0
  `public fun` and an `entry fun` appended to production sources both pass
  with "Source boundaries hold."

## Findings

Severity reflects impact on the eventual Series, since the package alone has
no callers and holds no value.

### H1. Redemption has no favourable-divergence postcondition; mint does

`sources/lib/accounting_math.move:623-631`. `equity_keep` is anchored to
`nav_before`, `gross = nav_unwound - equity_keep`, and the only guard is
`nav_unwound > equity_keep`. Whatever `nav_unwound` exceeds `nav_before` by
flows entirely to the redeemer. The mint side bounds exactly this shape through
`policy::assert_mint_contribution_within_bound` (code 32). There is no
redemption counterpart anywhere in `policy.move`.

Evidence: `redemption_accounting_quote(1, 1_000_000, 1_000_100, 0, 1_000_000, 0)`
returns `equity_keep 999_999`, `gross 101`, `net 101`. The redeemer's
proportional claim is 1 unit. Remaining holders are pinned at exactly
`equity_keep` whether the unwound reading is honest or inflated, so the
non-dilution tests pass. An unwind loss larger than the claim aborts with code
7 while an unwind gain of any size is paid: bounded downside, unbounded upside,
repeatable with one-share burns. At 10 bps NAV overstatement on a 1e12 vault a
0.01 percent redeemer is paid eleven times their claim while the same
divergence on a mint is rejected.

Mitigating context: inside one atomic operation with a single valuation pair,
the excess is limited to execution gain on the redeemer's own unwind slice,
which the exposure bounds and the mark-divergence gate keep small. The package
cannot prove that pairing, and the mint side did not rely on the caller for
the symmetric case.

Coverage gap: `nav_unwound > nav_before` is never exercised on the canonical
path. `tests/maintenance_math_tests.move:933-970` builds
`nav_unwound = nav_before - execution_loss` only.

Fix: add `max_redemption_gross_divergence_bps` to `TierPolicy`, assert it
inside `redemption_accounting_quote` before `redemption_quote` (cross-multiply
through `u256`, new code 38), and add tests at, one below, and one above the
bound. Record it in `docs/accounting.md` beside the mint bound.

### M1. The boundary script's public/entry gate never fires on real declarations

`scripts/check_source_boundaries.sh:78-82`. `grep_move_sources` emits
`path:line:content`, and the second grep requires `public` or `entry` to be
preceded by whitespace or start of line. Every real Move declaration sits at
column 0, where the preceding character is the colon of the prefix. Only an
indented declaration is caught.

Evidence (orchestrator): piping `sources/lifecycle.move:200:public fun leak()`
through the gate's regex matches nothing; an indented twin matches. The
lifecycle auditor appended a real `public fun` and a real `entry fun` and the
script reported "Source boundaries hold."

Two neighbours share the weakness. The activation gate at lines 90-93 inspects
only `*self =` lines, so a production `fun active_lifecycle(): Lifecycle {
Lifecycle::Active }` passes. The Vault-absence check at line 54 tests the
literal path `sources/vault.move`, so `sources/lib/vault.move` passes.

Fix: match on content with one grep such as
`^[[:space:]]*(#\[[^]]*\][[:space:]]*)*(public|entry)[[:space:]]+((macro|native|entry)[[:space:]]+)*fun[[:space:]]`
(`public(package)` is excluded because `(` follows). Assert that the set of
non-test `Lifecycle::` construction sites equals the whitelist. Reject any
`vault.move` under `sources/`.

### M2. A position below `lot_size * min_exposure_lots` locks every redemption; flat is mint-dead

`sources/lib/accounting_math.move:318-323` and `:738-741`. Both minimum-size
guards require moving at least `L / base_before` of the vault with
`L = lot_size * min_exposure_lots`. When `base_before >= shares_before` and
`base_before - floor(base_before / shares_before) < L`, every legal
`shares_burned` aborts with code 12. The flat exemption needs
`base_before < shares_before`, which such a position does not satisfy.

Evidence: `base 100_000, shares 1_000, lot 1_000, min 100` gives 0 of 999 legal
burns. `base 900, shares 100, lot 1_000, min 1` gives 0 of 99. With
`base = 4 lots` and `min 100` the only legal redemption burns 99.9751 percent
of supply. Once `base_before == 0` with live shares, `mint_base_delta_down`
aborts with code 11 for every contribution, forever.

This state is reachable: a leveraged long that rebalances after a drawdown
shrinks `base` toward zero. `exposure_math_tests.move:657-666` pins one
instance under the name "a one lot position cannot be partially redeemed",
which understates it.

Fix: state the exact lock condition in `docs/accounting.md` and the README.
Have the Series treat `base_before <= L` as an objective health-degradation
trigger rather than an abort, add an explicit open-from-flat primitive, and
keep the shutdown path as the guaranteed exit.

### M3. Lifecycle monotonicity is convention, not type enforcement

`sources/lifecycle.move:16` and `:32-34`. `Lifecycle` has `drop` (needed by the
`*self = ...` style) and `new_lifecycle()` is an unrestricted
`public(package)` constructor. Any future in-package module can write
`vault.lifecycle = lifecycle::new_lifecycle()` and take a `ShutdownSettled`
vault back to `Uninitialized` with no abort and no event. Because the package's
whole enforcement model is `public(package)` plus the script in M1, and a
package upgrade adds modules to the same package, this is the reset primitive
an upgrade would use.

Fix: make transitions linear (`fun enter_reduce_only(self: Lifecycle):
Lifecycle`) and remove `drop`, or gate `new_lifecycle` behind a one-shot
witness, and add a boundary rule rejecting assignment to a `lifecycle` field.

### M4. The documented health path still aborts at zero NAV

`sources/lib/accounting_math.move:36-41`, `:48-58`, `:648-657`.
`is_reserve_backed` is true at `venue_equity == reserve`, `shareholder_nav`
returns 0, and `leverage_bps_up` then aborts with code 2. A health transition
following the docstring recipe rolls back instead of degrading the lifecycle.
Every other gate in the package ships a non-aborting twin; leverage has none.

Fix: add a non-aborting leverage predicate that returns false or saturates at
`nav == 0`, and amend the `is_reserve_backed` docstring.

### M5. Four policy values have getters but no gate

`sources/policy.move:161-171` and `:280-282`. `strict_tolerance_bps`,
`emergency_tolerance_bps`, `minimum_improvement_bps`, and `nav_cap` are
validated at construction, exposed by getters, and used nowhere.
`minimum_improvement_bps` is the only anti-grief control on the permissionless
trigger `is_public_allowed`, and with no predicate a keeper can re-trigger a
rebalance that does not clear the band and bleed NAV through venue fees.

Fix: add `is_improvement_sufficient`, `is_within_nav_cap`, and tolerance
predicates with `assert_` twins, mirroring `ValuationPolicy`.

### M6. No `min_shares_out`; inflation loss is bounded only by the seed

`sources/lib/accounting_math.move:560-566`. Zero shares abort (code 6), which
closes the total-loss variant. The sub-share case remains: the minter's loss is
strictly below one pre-mint share of NAV, and that ceiling is the share price,
which this package cannot constrain. Evidence: `mint_quote(1_999_999_999,
1_000_000_000, 1)` mints 1 share for a 25 percent loss to the incumbent. A
contribution one unit lower aborts, so there is a one-share-wide griefable DoS
band. Loss is empirically bounded by `1 / (shares_out + 1)`.

Fix: take `min_shares_out` on `mint_accounting_quote`, and record the seed
invariant in `docs/accounting.md`: to cap rounding loss at X bps the seed
supply must satisfy `S >= (10_000 / X) * base / L` for the smallest legal mint.

### Low findings

- L1. `assert_mint_contribution_within_bound(deposit, contribution)` fails open
  when its two `u64` arguments are transposed, because the `contribution <=
  deposit` short circuit returns true (`policy.move:539-555`). The confidence
  guard fails closed under the same swap. Wrap the operands or take the quote.
- L2. `assert_mark_within_index_divergence` transposition is silent and
  fail-open; at `bps 9_999, index 100` the admitted mark widens from 199 to
  1_000_000 (`policy.move:494-534`).
- L3. `new_valuation` accepts a swapped freshness pair, rejecting 30-second-old
  prices while accepting 30-second-future ones (`policy.move:345-370`). Add the
  invariant `max_price_ahead_ms <= max_price_age_ms`.
- L4. `min_exposure_lots` and `nav_cap` are unbounded above and mutually
  transposable; the resulting immutable `TierPolicy` is a permanent brick
  (`policy.move:230-237`). `nav_cap` above `2^63 - 1` also overflows
  `target_notional_down` at 2x (code 15). Bound both structurally.
- L5. `target_bps` is unbounded above and scales the mint-contribution
  allowance; `public_lower_bps = 0` silently disables the lower public trigger
  (`policy.move:102-122`, `:191-197`).
- L6. `enter_reduce_only` and `enter_shutdown_pending` abort on an already
  degraded state (code 17), contradicting the non-aborting health-transition
  design (`lifecycle.move:72-89`). Add idempotent degrade variants.
- L7. No lifecycle state models an impaired vault; `ReduceOnly` still permits
  full-NAV redemption, and `docs/accounting.md:196-199` names a loss lifecycle
  that does not exist.
- L8. `Uninitialized` is a trap state with no exit; seed collateral placed
  before activation would be stranded (`lifecycle.move:73`, `:84`).
- L9. `docs/accounting.md:134-138` says 2,508 worst-case mints and 25 percent
  NAV growth; replaying the test harness gives first breach at mint 2,229 with
  23.5 percent growth. The hundred-lot claim is correct. The test asserts only
  `lowest < 18_000`, so nothing pins the figure.
- L10. The mint over-exposure residual is larger than the prose suggests: with
  the post-trade leverage gate absent, `assert_mint_base_within_bounds` admits
  2.0x to 2.67x on a NAV-sized deposit at 50 percent execution loss and 3.81x at
  95 percent (`accounting_math.move:765-792`). The gate is a hard release
  blocker.
- L11. Absolute base cannot detect a sign flip; a short overshot into a small
  long within one lot passes `assert_redemption_base_within_bounds`.
- L12. The reserve is senior to 100 percent of shareholder NAV with no release
  path; a wipeout strands holders' own prepaid fees. Document the seniority.
- L13. A redemption whose claim is smaller than its unwind cost aborts with the
  opaque code 7 instead of a size code; the size guard lives in a function the
  canonical quote never calls.

### Info

- `PositionSide` is written and never read; no gate consults it.
- `mint_base_bounds` cannot distinguish plan-dust from fill-dust (both code 12).
- The returned `max_delta` may not be addable to `base_before`; only the
  assert helper uses `checked_add`.
- `mint_base_delta_down` has three adjacent same-typed `u64` parameters with
  `nav` third, while `mint_quote` puts `nav` second.
- No events; transitions are not replayable. Deliberate for the slice.
- The sibling adapter package cannot read any lifecycle or policy accessor,
  since all are `public(package)`; the Vault must re-expose them as `public`,
  which is exactly the surface M1's gate should review.
- Rounding drift is strictly one-directional toward lower leverage. Safe, but
  the product structurally under-delivers leverage between rebalances.
- Coverage gaps: no repeated worst-case redemption drift regression, no
  favourable-mint test in `accounting_math`, no test reaching the `> u64`
  planned-reduction intermediate.

## Ruled out

- Mint then redeem round trip profit: zero cases over exhaustive small domains
  and 400k random cases with fees in {0, 1, 5, 30, 50, 500, 9999} bps.
- NAV-per-share decrease for remaining holders on mint or redeem: zero cases
  over 400k random operations up to `u64` scale.
- Split mint or split redemption extraction: zero cases over 240k random
  splits with fees and reserve.
- Sandwiching a rebalance by minting before and redeeming after: strictly
  negative for the sandwicher at every size, because they buy their share of
  the cost. The residue folds into H1.
- Redemption over-reduction griefing: 99 back-to-back minimum-size
  redemptions drift base by 0.005 percent, as the docs claim.
- Overflow anywhere: every wide intermediate is bounded or narrowed to code 15;
  policy gates peak at 1.8e23 in `u128` and 1.8e27 in `u256`.
- Extreme inputs: zero amount, zero NAV, fee-consumed deposits, zero net payout,
  and reserve underwater all abort where they should and never clamp.

## Caller obligations carried forward

Everything below is required of the Series and adapter. None of it is enforced
in this package.

- Call `new_lifecycle()` once and never assign to the lifecycle field again.
- Guard activation on `is_uninitialized()`; never implement resume.
- Pre-check `is_active()` before degrading, or the transition aborts.
- Wire `is_price_fresh`, `is_confidence_within_bound`,
  `is_mark_within_index_divergence`, `is_hard_emergency`, `is_reserve_backed`,
  and a `shareholder_nav > 0` check to degradation.
- Authenticate that both venue-equity readings come from one operation-scoped
  valuation pair. This is the root enabler of H1.
- Supply `min_exposure_lots` from the immutable policy and prove
  `base_before > lot_size * min_exposure_lots` is a health trigger, not an abort.
- Implement the post-trade leverage gate and the signed-direction check.
- Emit events on every transition; destroy or lock the `UpgradeCap` before the
  vault holds value.
- Fix `check_source_boundaries.sh` before treating it as a release gate.

## Comparison with the 2026-09-02 audit

The prior audit's M1 and M2 remediations hold: the two-sided mint bound and
`min_exposure_lots` behave exactly as documented, and the drift closed form is
a valid lower bound. Two prior scores move. "Scope containment" drops from 10
to 7 because the script that enforces it is partly inert (M1). "Test evidence"
stays at 9 but the favourable-unwind branch is now a named gap (H1). The
prior deferral of the contribution-versus-deposit guard to the Series is closed
in-package by `policy.move` for mint, which is what exposed its absence for
redemption.

## Remediation applied 2026-09-03

Applied in the package the same day and gated green with
`scripts/verify.sh all`: boundaries hold, testnet and mainnet builds succeed,
lint with warnings as errors is clean, and 384 tests pass, up from 328. Error
codes 55 through 61 were appended; the next code is 62. Every new code ships
with a registry pin, an `expected_failure` test that pins the raising module,
and a README row.

| Finding | Change |
| --- | --- |
| H1 | `redemption_accounting_quote` now returns `proportional_claim = nav_before - equity_keep` beside `gross`. `TierPolicy` gained `max_redemption_gross_divergence_bps` (code 56 at construction) and `policy::assert_redemption_gross_within_bound(proportional_claim, gross)` (code 55), which shares one `is_within_leveraged_allowance` helper with the mint bound. Tests pin the exact bound, one unit past it, the audit's one-share-in-a-million case, a zero claim, and a small-domain reference; the canonical suite now exercises `nav_unwound > nav_before`. |
| M1 | The working tree's rewritten script already anchored the public/entry gate on content, but it stopped reading each file at the `Test-Only Functions` comment marker, so a production `public fun` or `entry fun` appended after that marker passed. The gate is now attribute-aware: `production_lines` skips only top-level items under `#[test_only]`, wherever they sit. Added: a whitelist of non-test `Lifecycle::` construction sites so a constructor-shaped helper cannot hand out `Active` or `ShutdownSettled`, rejection of any `vault*.move` path under `sources/`, rejection of any `.lifecycle =` assignment in production sources, and at most one `new_lifecycle()` call outside `lifecycle.move`. Eight injected violations were each rejected on a scratch copy, and the clean tree still passes. |
| M2 | `accounting_math::is_redemption_possible` (exact, brute-force verified) and `is_exposure_above_minimum_operation` (sufficient) are non-aborting predicates for the health transition. The lock condition, the mint-dead flat state, and the reachable path are documented. The misnamed test now says the position cannot be redeemed at any size, and new tests pin the lock. |
| M3 | Enforced by the script rules above. `Lifecycle` keeps `drop` because a stored field cannot be moved out of `&mut` without it, so linear transitions were not practical for the future shared Vault. The hazard is documented on the type. |
| M4 | `accounting_math::is_shareholder_nav_positive` added; the `is_reserve_backed` docstring and the accounting spec state the health-path order. A test pins that a wiped account is backed, has no positive NAV, and aborts leverage with code 2. |
| M5 | `is_improvement_sufficient` and `assert_improvement_sufficient` (code 58) measure the decrease in distance from target. `is_execution_within_strict_tolerance`, `is_execution_within_emergency_tolerance`, and their asserts (code 60, zero reference code 29). `is_within_nav_cap` and `assert_within_nav_cap` (code 59). |
| M6 | `mint_accounting_quote` takes `min_shares_out` and aborts with code 57 below it, after every share guard. The seed-sizing invariant is in the accounting spec. |
| L3 | `new_valuation` requires `max_price_ahead_ms <= max_price_age_ms` (code 61). |
| L4 | `min_exposure_lots` is at most `constants::max_min_exposure_lots` (1,000,000, code 21) and `nav_cap * hard_cap_bps / 10_000` must fit in `u64` (code 23). A transposed pair is rejected. |
| L5 | `hard_cap_bps` is at most `constants::max_leverage_bps` (1,000,000 bps, code 22), which bounds the leveraged allowances. A zero public lower threshold is kept as a valid configuration and documented as disabling the lower public trigger. |
| L6 | `lifecycle::degrade_to_reduce_only` and `degrade_to_shutdown_pending` are idempotent past their target state and abort only from `Uninitialized`. |
| L9 | The drift harness returns the first breach index and final NAV; tests pin mint 2,229, 17,397 bps, and NAV 13,221,338 for one lot, and 19,455 bps with NAV 164,485,245 for a hundred lots. The spec figures were corrected. |
| L10, L11, L12, L13, Info | Documented in the accounting spec and the lessons file: the over-exposure residual magnitude, the signed-direction gap, reserve seniority, the opaque code 7 for a sub-cost redemption, and the coverage gaps now closed. |

Not applied, by decision:

- L1 and L2. Wrapper types for the transposable `u64` pairs are a Vault API
  design; lessons rule 1.12 requires a swap test at each call site instead.
- L7. A loss lifecycle state is a Series design decision; the spec now says
  the choice is between the two existing degraded states until it is made.
- L8. An exit from `Uninitialized` depends on whether value can exist before
  activation; the open-gates list carries it.
- The nav-positivity check is a predicate, not a saturating leverage formula.
