# 0117: Presale versioning and custody before activation

- Status: accepted
- Date: 2026-10-20
- Amends: [0099](0099-standalone-overflow-presale.md),
  [0104](0104-external-presale-migrators-and-vendor-packages.md)
- Follows: [0114](0114-launchpad-custody-before-activation.md)

## Decision

Presale follows launchpad's two-step activation. Publication transfers an owned,
key-only `blast_presale_package::Bootstrap` to the publisher. Its one-time witness
claims the canonical Publisher and seeds `OperationalVersion`. Publication shares
no usable `PackageVersion`. Partners can prepare integrations with the package ID,
but cannot create presales until the bootstrap holder supplies the matching fresh
UpgradeCap to `package_admin::wrap`.

Wrap validates Publisher provenance, the cap's original package ID and native
version 1 through `blast_admin::upgrade_custody`, then shares `PackageAdmin` and a
new `PackageVersion` atomically. The bootstrap is consumed once. No public path
releases either native capability or creates another operational version. The
provenance module is separate from the economic `blast_presale` module to avoid
cyclic dependencies with creation and fee policy modules.

Every public state-changing presale, policy, venue, vault and holder-reward call
requires the operational version immediately after its primary object and checks
it before any effects. Pure constructors/readers and deleting a caller-owned inert
PresaleCap remain ungated. External migrators pass the same version into core.
Partners cannot bypass admission using another migration witness.

UpgradeAdmin authorizes a digest under the cap's compatible policy. In one PTB,
`commit_upgrade_and_advance` verifies the next generation, commits the native
receipt and advances operational version. Every upgrade, including a dependency
relink, increments both compiled generation constants. Old bytecode rejects the
advanced shared version. The contract no longer narrows new caps to dependency-only;
there is no policy-narrowing, immutable, or capability-release API, retaining venue
relink capability. This changes the trust boundary: governed compatible upgrades
can change logic. Token mint authority consumed by Coin Registry remains consumed.

## Publication boundary

This requires a fresh publication: existing dependency-only caps cannot regain
compatible authority, and an upgrade does not rerun initialization. Existing
mainnet deployment records remain historical evidence, not deployments of this
source. PackageVersion is discovered in activation effects, not publication effects.
SDK deployment configuration must include it; old unversioned addresses cannot be
used by builders for this ABI.

As with launchpad, a publisher holding a raw cap can install different bytecode
before wrap. The reviewed intake rejects such an already-upgraded cap; it cannot
constrain malicious replacement code. Policy objects may exist before activation,
but confer no ability to mutate or create a sale without PackageVersion.

## Verification

Tests cover absent pre-activation version, bootstrap ownership and single use,
foreign and already-upgraded caps, compatible custody, atomic commit/advance,
stale and future generation rejection, and the existing economic/regulation suite.
Source gates pin every guarded mutation and the sole activation path. SDK ABI and
transaction tests pin the version argument and its read-only shared-object input.

## Sources

| Fact | Pinned source |
| --- | --- |
| Native cap policies and upgrade version behavior | [Sui package.move at 06734f6ff0af45d8632a14a4dc4b100197f6b1a2](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move) |
| Bootstrap and generation design | [Launchpad custody decision](0114-launchpad-custody-before-activation.md) and the matching source/test implementations in this repository |
