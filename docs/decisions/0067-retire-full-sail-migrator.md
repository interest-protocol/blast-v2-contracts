# 0067: Retire the Full Sail migrator before release

> ADR 0088 further narrows the replacement lineage to Cetus and Bluefin.
> This ADR's Full Sail removal remains authoritative; its five-venue counts and
> remaining-route inventory are historical and no longer define a release
> surface.

- Status: **accepted; remaining-venue release surface amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)**
- Date: 2026-09-02
- Amends: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md),
  [0057](0057-admin-pinned-venue-tiers.md),
  [0059](0059-production-launchpad-abi-and-sdk-parity.md), and
  [0063](0063-aftermath-weighted-pool-migrator.md)

## Context

The repository owner has directed Blast to stop supporting Full Sail because
the venue has closed its protocol. Full Sail is currently implemented as one
module in the aggregate migrators package, with two local interface packages,
four migration routes, two fee-collection routes, a venue-tier key, dedicated
release checks, and SDK transaction builders.

The repository contains no migrator deployment record. The package README and
release gates still describe the aggregate migrators package as awaiting its
first production publication and irreversible `UpgradeCap` destruction.
Keeping a closed venue in that release would add dependency and custody risk
without a valid migration destination.

## Decision

Remove Full Sail from the pre-release aggregate migrators package and SDK:

- delete the `fullsail` Move module and its CLMM and IntegerMate interface
  packages;
- remove both dependencies from `Move.toml`, `Move.lock`, the live ABI verifier,
  and source-boundary and dependency-pin gates;
- remove the four migration routes, two fee-collection routes, venue-tier
  defaults, Move tests, SDK builders, and SDK venue type;
- regenerate the frozen production ABI artifact as an approved pre-release ABI
  amendment; and
- remove Full Sail from current package, dependency, release, and SDK
  documentation while retaining historical ADRs and implementation plans as
  records of the earlier decision.

Do not add a deprecated function, aborting tombstone, feature flag, or empty
adapter. The package has not been recorded as published, so a compatibility
surface would preserve risk without preserving a live user path.

The launchpad core remains venue-neutral. It does not gain a Full Sail denylist
or another venue-specific state field. Operators must not admit or select a
Full Sail witness in production launch configuration.

## Alternatives considered

**Keep the code but hide it in the SDK.** Rejected: direct Move calls would
remain available, and the closed venue would stay in the package dependency and
release surface.

**Keep aborting compatibility functions.** Rejected: the migrators package has
no recorded deployment, so there is no published ABI that needs a tombstone.
Production abort stubs are prohibited and would strand a selected launch.

**Add an on-chain venue disable flag.** Rejected: the core already admits
sealed migration witness types through configuration. A hard-coded venue flag
would duplicate policy and add state only for a pre-release adapter removal.

## Consequences

- Before ADR 0088, the aggregate package supported five venues, with 13
  migration routes and eight fee-accrual or collection routes; those counts do
  not describe the replacement lineage.
- Full Sail package lineage, ABI fingerprints, configuration objects, and
  IntegerMate are no longer release dependencies.
- Existing historical documents can still mention Full Sail, but current
  support matrices and SDK APIs cannot.
- If an unrecorded deployment or launch selected a Full Sail witness, this
  source change cannot disable old immutable bytecode or repair that launch.
  Operators must audit that state before release and resolve it explicitly.

## Verification

- `Move.toml`, both lock environments, the ABI verifier, and source boundaries
  contain no Full Sail dependency or module.
- `sui move build`, warning-as-error lint, and `sui move test --lint` pass for
  the aggregate migrators package.
- The ABI verifier self-test and live mainnet check pass for the remaining six
  external packages.
- The regenerated SDK ABI artifact contains no `fullsail` module, and SDK
  format, lint, typecheck, and tests pass.
- A runtime-source and test search finds no Full Sail support. Remaining mentions
  are historical records or approved ABI-retirement metadata.
