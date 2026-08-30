# 0049: Audit-hardened package cutover and launch intake

> Constant ownership update (2026-08-29):
> [ADR 0050](0050-module-local-package-version-constant.md) keeps the compiled
> generation as a private constant in `package_version.move` rather than the
> package-wide constants registry.
> Event update (2026-08-30):
> [ADR 0058](0058-eventless-package-initialization.md) removes the
> `PackageVersionCreated` and `RuntimeConfigCreated` payloads; publication
> effects and the compiled constants carry those facts.

- Status: accepted
- Date: 2026-08-29
- Amends: [0007](0007-acl-pause-and-versioning.md),
  [0011](0011-event-schema-and-replay.md),
  [0028](0028-hot-cold-runtime-configuration.md),
  [0032](0032-admin-authorized-upgrade-cap-custody.md),
  [0043](0043-versioned-launch-trading-and-atomic-migration.md), and
  [0045](0045-single-package-version.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

## Context

The first launchpad audit found three upgrade hazards. First, native upgrade
commit advanced the operational package version without proving that the new
bytecode contained the next compiled version. A wrong constant disabled every
old and new guarded function, including the function that authorizes a repair.
Second, additive and dependency-only policies cannot change existing function
bodies, but commit still advanced the operational version. Third,
`ProtocolAuthority` and `LaunchConfig` mutations had no package-version gate, so
old bytecode could continue to mutate those shared objects.

`RuntimeConfig` cannot remain the version owner while it imports
`AdminWitness`: making `acl` import `RuntimeConfig` would create a Move module
dependency cycle. Blast still requires one operational version, not independent
state versions.

The audit also found three intake hazards. A ticket from an old package
generation could carry a noncanonical supply, a launch could select the same
type for Meme and Quote, and the migration-witness allowlist admitted primitive
or vector types that anyone can construct. Finally, migration repeated a
launch-time fee-ceiling check against current bytecode and could strand an old
immutable snapshot after a ceiling decrease.

The pinned framework defines additive policy as adding code or changing
dependencies without changing existing functions, and dependency-only policy as
changing dependencies only
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:70-77`).
It commits an `UpgradeReceipt` by updating the cap package and incrementing the
native cap version
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:299-308`).

## Decision

### One dedicated package-version singleton

Add `blast_fun::package_version` with one shared `PackageVersion { id, version }`.
This is the only operational package version. Remove `package_version` from
`RuntimeConfig`; do not add a per-object or state version.

Every public operation that mutates `ProtocolAuthority`, `LaunchConfig`,
`RuntimeConfig`, `PackageAdmin`, or `Launch` must borrow `PackageVersion` and
assert the stored value equals the owning module's `PACKAGE_VERSION` before any other
validation. Read-only destruction of an already retired root cap remains
ungated because it does not mutate shared state.

Neither the package-version singleton nor the runtime configuration emits a
creation payload: under ADR 0058 publication effects record both shared objects,
and the initial version and protocol fee share are compiled constants.

### Commit and activation are separate

`package_admin::commit_upgrade` validates the active package version and commits
the framework receipt. It does not change the operational package version.

`package_admin::activate_package_version` is a separate `AdminWitness`-authorized
operation. It calls the package-only version transition, which computes
`stored + 1`, rejects overflow, requires that result to equal the compiled
package version, then stores and emits the new version. A wrong build therefore
leaves the old generation active and able to authorize a corrective upgrade.

An additive or dependency-only upgrade leaves the compiled and stored
operational versions unchanged and skips activation. Those policies cannot
replace existing guarded function bodies, so they cannot perform a bytecode
cutover. Native `UpgradeCap.version` and Blast's operational package version are
separate facts and need not advance together.

### Intake hardening

Before consuming launch policy, `launch::new` rejects equal original Meme and
Quote type identities. After opening the sealed ticket and before partitioning
assets, it requires the ticket balance to equal the canonical generated Meme
supply.

Migration-witness admission rejects every primitive and vector `TypeName`.
Administrators must still review each admitted struct and confirm that its
constructor is sealed inside the approved adapter module; Move does not expose
constructor visibility through `TypeName`.

`graduation::partition_quote` trusts its immutable validated `Bps` snapshot and
does not compare it with a later package generation's policy ceiling. The
ceiling remains enforced when `LaunchConfig` is changed.

### Deferred product policies

This audit change does not invent pause or migration-recovery behavior. Those
features remain deferred until their authority, timing, destination, and user
exit rules are accepted. External adapter code must call the current core
package for guarded `migrate`; it may call the deliberately ungated
`redeem_migration` seam after it receives the typed payload.

## Alternatives considered

**Keep the version inside RuntimeConfig.** Rejected because complete ACL gating
would create a module dependency cycle with `AdminWitness`.

**Store a version in every shared object.** Rejected because operators and
indexers would have several versions to coordinate. Blast uses one singleton.

**Advance during native commit and rely on release tooling.** Rejected because
a procedural check cannot recover assets after an incorrect onchain cutover.

**Leave only `acl::sign_in` gated.** Rejected because a transaction can create a
witness before cutover and use an old unguarded mutator after cutover. Each
shared mutation checks the version at its own use site.

**Determine whether every witness struct has a private constructor onchain.**
Rejected because `TypeName` exposes type identity and primitive classification,
not constructor visibility. Admission review remains a privileged release step.

## Consequences

- A bad upgrade cannot disable the active generation merely by committing its
  native receipt.
- Additive and dependency-only upgrades no longer cause deterministic cutover
  deadlock.
- Old bytecode cannot mutate any Blast shared protocol object after activation.
- Trades add one immutable shared `PackageVersion` input. This is the minimum
  state needed to break the ACL dependency cycle while keeping one version.
- Old tickets with incompatible supply cannot enter current launch custody.
- A self-quoted launch cannot lock its complete generated supply in an inert
  market.
- Obvious publicly constructible migration witness categories cannot be
  admitted, but administrators must still review custom witness constructors.
- Existing launch snapshots remain valid if a later package lowers a
  configuration ceiling.

## Verification

- Native commit changes the wrapped cap version but not `PackageVersion`.
- Activation succeeds only when `stored + 1` equals the compiled version and
  rejects mismatch and `u64` overflow.
- Every shared-object mutator has a version-first structural check, with
  behavioral precedence tests across ACL, policy, runtime, package-admin, and
  launch operation classes.
- Launch intake rejects equal Meme/Quote types and a noncanonical ticket supply.
- Migration-witness admission rejects a primitive and a vector type.
- A migration snapshot above a later compile-time ceiling remains partitionable.
- The actual initializer `finalize` path is exercised for both Fixed and
  BurnOnly supply, and migration consumes the resulting authoritative
  `Currency<Meme>` state. The pinned framework exposes no unit-test constructor
  for the fixed-id system registry, so `finalize_registration` remains a
  publication-environment integration check rather than a local Move unit test.
- Full-balance sell-back tests include claimed Meme fees and both zero and
  configured fee modes.
- Build, lint, source-boundary checks, all tests, and 100% source coverage pass.
