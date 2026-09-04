# Claude Fable 5.1 audit of the Blast leverage coins Phase 1 package

Date: 2026-09-02

Status: security, math, and architecture audit of implemented code, with the
remediation applied the same day

Model: `claude-fable-5-1`

Authorized Claude account: `jose@ilovemochi.com`

Scope: `contracts/sui/leverage_coins` only. The launchpad, migrators, and
vesting packages were not audited. Toolchain `sui 1.77.2-51d177ad7d65`,
framework `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`.

This record complements the
[design review of 2026-09-01](claude-opus-5-leverage-design-audit-2026-09-01.md),
which reviewed the ADR before any Move code existed. This audit reviewed the
code. It is not a claim that the package can hold value; the package README
still says it cannot.

## Verdict

No exploitable defect in the code that existed. Every rounding site favored
existing holders or the reserve, every wide intermediate had a proven
narrowing bound, and the lifecycle could only degrade. Two medium design gaps
sat at the seam between the package and the unbuilt Series. Both were fixed in
the package the same day, together with three low items. One low item is
deferred to the Series because it needs a parameter that does not exist yet.

Overall score before remediation: 9 of 10 for the code that existed. After
remediation the two medium items are closed in the package and the mint
exposure surface rises from 6 to 9.

## What was verified

- Read in full: all production modules, all test modules, the boundary and
  verify scripts, the package README, ADR 0064, and the prior design review.
- Ran the pinned gate before and after remediation. Before: boundaries hold,
  both network builds succeed, lint with warnings-as-errors is clean, 167
  tests pass. After: 194 tests pass under the same gate.
- Checked the stdlib at the pinned revision: `mul_div` and `mul_div_ceil`
  widen to `u128` for `u64` and `u256` for `u128`; `div_ceil` handles a zero
  numerator; `checked_add` returns none on wrap.
- Ran five adversarial probes in a scratch copy of the package. Their results
  are cited under each finding. The two that mattered are now package
  regression tests.
- Cross-checked against the repository's Sui Move security, review, testing,
  and source-style standards.

## Scored surfaces

Scores are on what the package proved at audit time, not on what the ADR
promised.

| Surface | Score | Basis |
| --- | ---: | --- |
| Rounding direction policy | 10 | All eleven value-moving sites round toward holders or the reserve. |
| Overflow and narrowing | 10 | `u128` or `u256` intermediates, checked adds, one private narrowing helper with abort 15, boundary tests at `u64::MAX`. |
| Mint non-dilution (I9) | 10 | Floor shares, fee excluded once through the reserve checkpoint, exhaustive and split-mint tests. |
| Redemption non-dilution and fee recapture (I10, I19) | 10 | Ceil kept equity, redeemer bears the unwind cost, final NAV equals `equity_keep` exactly. |
| Reserve accounting (I7, I27) | 9 | Exact conservation, no clamp on impairment, non-aborting health predicate. |
| Redemption exposure bounds (I11, I26 redeem side) | 9 | Two-sided and re-derived from canonical inputs; dust redemptions had no cumulative cap (fixed). |
| Mint exposure bound (I26 mint side) | 6 | One-sided with a post-trade input and no relative cap (fixed; now 9). |
| Guard ordering and fail-fast | 9 | Cheap checks first, precedence pinned by tests; one nit (fixed). |
| Lifecycle state machine (I28) | 10 | Closed enum, three monotone transitions, every edge and permission cell tested. |
| Error registry and abort location | 9 | Append-only macros inlined into the owning module; cross-package doc did not list the registry (fixed). |
| Scope containment | 10 | No public functions, no dependencies, no custody or events, enforced by script. |
| Test evidence | 9 | Exhaustive small domains, boundaries, random seeds, split-versus-combined; drift and mint-bound regressions were missing (added). |
| Liquidation-avoidance architecture | 7 | Structure is right and conservative; band, cap, keeper policy, execution tolerance, and short asymmetry are unresolved. |

## Findings and remediation

### M1. Mint exposure sizing was one-sided and its documented input was post-trade

`mint_base_delta_down` documented `contribution` as the credited contribution
from the mint formula, which is `nav_after - nav_before` and exists only after
the trade. The order must be sized before the trade from `deposit - fee`.
Redemption had a two-sided range plus an assert helper; mint had one exact
value and no assert.

Evidence: with base 1,000,000, NAV 1,000,000,000, and lot 100, sizing from a
pre-trade contribution of 1,000,500 returned 1,000 while sizing from the actual
post-trade contribution of 999,000 returned 900.

Remediation: `share_math::mint_base_bounds` and
`assert_mint_base_within_bounds` with reserve-aware wrappers in
`maintenance_math`. The admitted final base is
`base_before + [min(delta(actual), delta(expected)), delta(expected)]`. New
codes 19 `mint_over_exposed` and 20 `mint_under_exposed`. The boundary script
fences the new NAV-taking functions. Tests pin the 1,000-versus-900 case, a
favorable fill demanding the complete plan, a dust actual contribution
aborting, the overflow of the upper bound, and an exhaustive small domain.

### M2. Cumulative lot-rounding drift had no relative cap

Each mint could open up to one lot less than proportional and each redemption
could close up to one lot more. Per operation that was bounded; across a
sequence it was not.

Evidence: on a 2.00x pool with NAV 10,000,000 and base 20,000,000 at lot 1,000,
mints contributing 999 units each (proportional target 1,998, rounded to
1,000) took leverage below the 1.80x band after 2,508 mints with NAV grown 25
percent. Every mint was non-dilutive by NAV and passed every guard.

Closed form: with `e` the per-mint relative under-exposure, leverage after a
sequence stays close to `L0 * (N0 / N)^e`. Each mint multiplies leverage by at
least `1 - e * C / (N0 + C)`.

Remediation: a `min_exposure_lots` parameter on `mint_base_delta_down`,
`mint_base_bounds`, `redemption_base_bounds`, and their wrappers. A
proportional exposure change below `lot_size * min_exposure_lots` aborts with
the existing code 12, whose meaning now covers both mint and redemption; a
redemption that reaches flat is exempt. New code 21
`invalid_min_exposure_lots`. Relative under-exposure and over-reduction are
both proven below `1 / min_exposure_lots` across the small domain. Two
regression tests pin the drift: a one-lot minimum leaves the band within 3,000
worst-case mints; a hundred-lot minimum keeps the same sequence above 1.93x.
The package still holds no value for the parameter; the Series supplies it
from immutable policy after simulation.

### L1. No sanity bound on contribution versus deposit (deferred to the Series)

`mint_quote` requires only a positive contribution. A deposit of 10 with a
contribution of 900 minted 900 shares. Under the ADR's single valuation pair
the contribution can exceed `deposit - fee` only through a fill better than the
index, which the divergence gate bounds, so a strict `C <= D` check would
spuriously abort a legitimate favorable fill. The guard belongs in the Series
and is parameterized by the divergence gate. It is recorded as rule 1.3 in
`docs/leverage-implementation-lessons.md`.

### L2. The fee was computed twice per canonical mint (fixed)

`mint_accounting_quote` computed the fee for the reserve checkpoint, then the
low-level formula recomputed it and the outer function discarded the copy.
`mint_quote` now takes `(contribution, nav_before, shares_before)` and returns
`(shares_out, shares_after)`; the positive-contribution guard (code 5) is
raised by `maintenance_math` on the canonical path and by `share_math` for
direct callers. The moved precedence tests live in the reserve-accounting
suite.

### L3. A wide multiplication ran before a cheap range check (fixed)

`redemption_quote` now checks the fee rate before computing the kept equity.
Pinned precedence (share bound, then fee, then gross) is unchanged.

### L4. Package error registries are independent (fixed)

Each package's `errors.move` owns its numeric space.

## Rounding and width inventory after remediation

| Site | Expression | Rounds | Remainder goes to | Width proof |
| --- | --- | --- | --- | --- |
| `fee_up` | `amount * bps / 10_000` | up | maintenance reserve | `u128`; result `<= amount` |
| `mint_quote` shares | `S0 * C / N0` | down | existing holders | `u128`; narrow aborts 15 |
| `mint_quote` supply | `S0 + out` | checked | — | `checked_add`, abort 15 |
| `redemption_quote` kept equity | `N0 * S1 / S0` | up | remaining holders | `u128 mul_div_ceil`; `<= N0` |
| `redemption_quote` fee | `gross * bps / 10_000` | up | maintenance reserve | `<= gross`; net `> 0` |
| `leverage_bps_up` | `V * 10_000 / N` | up | conservative report | `u256`; narrow aborts 15 |
| `target_notional_down` | `N * T / 10_000` | down | under target | `u128`; narrow aborts 15 |
| `mint_base_delta_down` | `Q0 * C / N0`, floor to lot | down | unopened exposure below `1 / min_exposure_lots` | `u128`; minimum uses `u128` |
| `mint_base_bounds` | `[min(actual, planned), planned]` | — | partial-fill tolerance | inherits; upper sum checked |
| `redemption_base_bounds` keep | `Q0 * S1 / S0` | down | remaining holders | `u128 mul_div`; `<= Q0` |
| `redemption_base_bounds` planned | `min(ceil(r / lot) * lot, Q0)` | up, capped | more reduction, never past flat | `u128 < 2^65`, capped |
| `shareholder_nav` | `E - R` | exact | — | `R <= E` asserted, abort 16 |
| `credit_fee` | `R + F` | checked | — | `checked_add`, abort 15 |
| `absorb_funding_cost` | `min(R, K)` | exact | — | conservation identities |

Verdict: consistent with strict holder-and-reserve-favorable rounding.

## Liquidation posture

The structure is right. The reserve stays in the margin account but out of
NAV, so venue leverage is always below accounting leverage and every fee widens
the liquidation distance. Leverage rounds up and target notional rounds down.
Redemption de-risks before it pays. Mint cannot add shares without exposure.
The lifecycle only degrades and impairment fails closed.

At an illustrative 5 percent maintenance margin, the long has about 47 percent
of adverse move before liquidation from target and 43 percent from the upper
band, while a rebalance is due at 8 percent. The short is liquidated four to
five points earlier at every leverage. Keeper liveness during a crash is the
largest residual risk. The six design additions that lower liquidation odds
further, with owners, are section 2 of
`docs/leverage-implementation-lessons.md`.

## Files changed by the remediation

- `sui/leverage_coins/sources/share_math.move`: three-input `mint_quote`,
  fee check before kept equity, `min_exposure_lots` on every exposure
  function, `mint_base_bounds`, `assert_mint_base_within_bounds`.
- `sui/leverage_coins/sources/maintenance_math.move`: single fee computation,
  contribution guard, `min_exposure_lots` pass-through, mint-bound wrappers.
- `sui/leverage_coins/sources/lib/errors.move`: codes 19, 20, 21; meaning of
  5 and 12 updated.
- `sui/leverage_coins/scripts/check_source_boundaries.sh`: new functions
  fenced.
- `sui/leverage_coins/tests/*`: 194 tests, up from 167.
- `sui/leverage_coins/README.md`, `AGENTS.md`,
  `docs/decisions/0064-aftermath-backed-leverage-coins.md`,
  `docs/leverage-implementation-lessons.md`.
