# 0045: Single package version

> Ownership and activation update (2026-08-29):
> [ADR 0049](0049-audit-hardened-package-version-and-launch-intake.md) keeps one
> operational version but moves it from `RuntimeConfig` to the dedicated
> `PackageVersion` singleton. Native receipt commit no longer advances it.

- Status: accepted
- Date: 2026-08-28
- Amends: [0007](0007-acl-pause-and-versioning.md),
  [0011](0011-event-schema-and-replay.md),
  [0040](0040-normalized-launch-state-intake.md),
  [0043](0043-versioned-launch-trading-and-atomic-migration.md), and
  [0044](0044-validated-basis-points-unit.md)

## Context

ADR 0043 added a global package version in `RuntimeConfig` and a separate
version field in every Launch object. Every Launch mutation checked both.

The Launch object has no independent schema-migration transition. Therefore,
the per-Launch value cannot advance through a supported operation. It only
duplicates the global cutover and creates a second version that operators,
indexers, the SDK, and tests must track.

## Decision

Blast uses one version only: `RuntimeConfig.package_version`. Every Launch
mutation and package-administration operation checks it before other work. A
successful native upgrade commit advances it exactly once.

Remove the per-Launch version field, constant, guard, creation-event field,
error, test helper, and mismatch test. Error code 69 is retired and must not be
reused.

Blast does not imply object migration by incrementing a counter. If a future
upgrade needs an object migration, that upgrade must define an explicit state
type and migration transition in its own ADR. Until then, the package version
is the only operational cutover.

## Alternatives considered

- Keep both values. Rejected because there is no independent Launch migration
  that can make the second value useful.
- Keep the Launch value only. Rejected because old package generations remain
  callable and the required cutover is package-wide.
- Add a generic object-version framework now. Rejected because no current
  transition requires it.

## Consequences

There is one version to deploy, advance, monitor, decode, and test. Launch
storage and the `LaunchCreated` event become smaller. A future object-layout
migration must be explicit and cannot rely on a pre-planted counter.

## Verification

- Every mutable core shared-object operation checks `PackageVersion` first.
- A stale package version still aborts before trade, claim, lifecycle, witness,
  and migration checks.
- Source checks reject a per-Launch version field, constant, guard, or event
  fact.
- Full lint, tests, coverage, and source-boundary checks remain mandatory.
