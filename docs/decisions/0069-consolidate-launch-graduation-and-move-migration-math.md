# 0069: Consolidate launch graduation and move migration math into migrators

- Status: **accepted; amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)**
- Date: 2026-09-03
- Amends: [0027](0027-graduation-economics-and-migration-witnesses.md),
  [0049](0049-audit-hardened-package-version-and-launch-intake.md),
  [0054](0054-v3-dex-migrators-and-locked-lp-fees.md), and
  [0059](0059-production-launchpad-abi-and-sdk-parity.md)

## Context

The launchpad had two single-purpose arithmetic modules. `graduation` contained
only the balance partitions used by `launch`, while `migration_math` had no
launchpad caller. Only the external venue adapters used its seed-price,
price-deviation, utilization, and residual calculations.

The old placement made the launchpad publish adapter policy that it did not use.
It also made launch lifecycle accounting look independent from the `Launch`
custody transition that owns it. The aggregate migrators package has no recorded
production publication, so the boundary can still be corrected before release.

## Decision

Move the Meme and Quote graduation partition functions into `launch.move` as
private functions. `launch::new` owns the initial Meme partition, and the
migration transition owns the terminal Quote partition. Keep test-only wrappers
only for focused arithmetic tests. Delete `graduation.move`.

Move `migration_math.move`, its tests, its constants, and its errors to the
aggregate migrators package. The four operations are `public(package)` because
only venue modules in that package consume them. The launchpad continues to
authorize the selected witness and release the exact Meme and Quote balances;
it does not derive a venue price, approve an adopted-pool deviation, or judge
venue utilization and residuals.

Use one module-local, contiguous error space for migrator arithmetic:

| Code | Error | Failure |
| ---: | --- | --- |
| 0 | `EInvalidBps` | A deviation or residual limit exceeds 10,000 basis points. |
| 1 | `EInvalidMigrationSeedBalance` | Either migration seed balance is zero. |
| 2 | `EMigrationPriceDeviationExceeded` | An observed pool price exceeds the accepted seed-price deviation. |
| 3 | `EMigrationResidualExceeded` | A venue residual exceeds the accepted share of migration principal. |

Launchpad codes 79 through 81 remain reserved as moved pre-release registry
entries. New launchpad errors continue at 82, so no old diagnostic number can
silently acquire a different meaning.

Regenerate the frozen launchpad/migrators ABI artifact as an approved
pre-release amendment. The deleted launchpad modules disappear from the public
surface; migrator arithmetic does not enter it because the functions are
package-only. The SDK keeps its exact arithmetic mirror for previews and tests,
but contract execution remains authoritative.

## Alternatives considered

**Keep migration arithmetic in core as reusable public utilities.** Rejected
because no launch transition or independent external package consumes it. It is
venue enforcement owned by the aggregate adapter package.

**Duplicate the arithmetic in each venue module.** Rejected because every CLMM
adapter enforces the same seed-ratio and residual invariants. One package-local
implementation prevents drift without widening the public ABI.

**Keep `graduation.move` as a pure helper module.** Rejected because it has one
production consumer and no separate authority, state, or dependency boundary.

## Consequences

- The launchpad sends witness-bound liquidity without owning venue arithmetic.
- Migrator venue checks and their diagnostics move together.
- Graduation accounting remains consensus-critical but is private to its one
  launch lifecycle owner.
- No arithmetic behavior or rounding rule changes.
- The pre-release public ABI becomes smaller.

## Verification

- Launchpad source gates reject `graduation.move` and `migration_math.move` and
  pin both private partition rules in `launch.move`.
- Migrator source gates require exactly four package-only arithmetic operations,
  bind codes 0 through 3 to their named failures, and reject launchpad-owned
  constants, errors, state, or asset types.
- Focused negative tests pin each arithmetic abort to
  `blast_fun_migrators::migration_math` and its exact code.
- Both Move packages pass build, warning-as-error lint, tests, and source gates.
- SDK ABI generation and parity checks pass with the approved amendment.
