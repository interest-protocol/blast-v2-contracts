# 0057 — Admin-pinned venue tiers for permissionless migration

- Status: **accepted; amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)**
- Date: 2026-08-29
- Amends: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md)
- Amended by: [0067](0067-retire-full-sail-migrator.md) and
  [0088](0088-reusable-launch-accounting-and-atomic-migration.md)

> ADR 0088 keeps the administrator-pinned `venue_config` tiers but changes three
> things. The migrators package stays upgradeable and its `UpgradeCap` is never
> destroyed, so the statements below about tiers freezing or staying correctable
> after `UpgradeCap` destruction and about permanently locked positions no longer
> apply. Cetus reserves the pinned tier when a ticket is bound and migrates at
> that reserved tier, so a later pin affects only later Cetus bindings; Bluefin
> still reads its tier at migration. No adapter adopts an existing pool, so the
> adopted-pool rules below are historical.

## Context

ADR 0046 makes `launch::migrate` permissionless: any caller may complete a
`MigrationReady` launch with the selected witness type. ADR 0054's migrator
routes originally accepted the venue fee tier as caller input — `tick_spacing`
on Cetus and Full Sail, a `Fee<FeeType>` object on Turbos, `fee_rate` on MMT,
and both raw values on Bluefin. Because migration is one-shot and the position
is permanently locked, the first caller irreversibly chose the fee tier of the
pool that produces the vault's entire LP revenue stream. A griefer could
graduate and migrate in one transaction into the venue's lowest or highest
registered tier with no recovery path.

Venue fee units differ per venue, so compile-time tier constants require
venue-specific evidence and would freeze at `UpgradeCap` destruction.

## Decision

Add one shared singleton, `venue_config::VenueConfig`, to the aggregate
migrators package. It holds one full `(tick_spacing, fee_rate)` entry per
venue as a **dynamic field** keyed by the sealed `TierKey<Venue>` name, so an
upgrade-added venue module can register its own tier without touching the
singleton's frozen struct layout, and each entry can only be written by the
module that constructs that venue's witness.

- Every migration route reads its effective tier from the singleton instead of
  trusting caller parameters; migrate signatures carry no tier inputs.
- Each venue module compiles a researched default and falls back to it while
  no pin exists, so every route works from publication with no setup
  transaction. Meme pools take the venue's highest tier; the defaults were
  read from the live mainnet registries on 2026-08-30 — Bluefin `(200,
  10_000)` (no registry exists; the dominant production tier), Cetus `(260,
  40_000)`, Full Sail `(20, 10_000)`, MMT `(400, 20_000)`, Turbos `(800,
  40_000)` — and are recorded with sources in the package README.
- The package-only write consumes the venue's sealed witness, and each venue
  module's public `set_tier` additionally requires a borrowed live
  `acl::AdminWitness`. Writes reject zero values and no-op re-pins; Turbos
  bounds its fee pin to `u32`. Every write emits one `VenueTierUpdated` fact
  carrying the venue witness type name and old/new values, where zero old
  values mean the compiled default was active.
- Cetus and Full Sail new pools additionally require the venue's registered
  fee for the effective spacing to equal the effective fee, binding the pin to
  the venue registry. Full Sail adjusts live pool fees dynamically, so its
  adopted pools match on tick spacing alone; Cetus adopted pools match the
  full pair; MMT asserts the venue-derived spacing of the created pool;
  Turbos requires the supplied `Fee` object or adopted pool to match exactly.
- Package initialization shares exactly one empty config; no other
  constructor exists, so a caller cannot forge a second policy object for a
  permissionless route. There is no creation event — Sui transaction effects
  natively record the shared object and its type at publication.
- Tier reads are `public(package)`; there is no public getter. Offchain
  consumers overlay the documented defaults with the `VenueTierUpdated`
  stream.
- Fee collection routes take no tier input; tier policy is irrelevant to
  draining fees from an already-pinned position.

The dev-inspect release gate must prove every effective tier matches a tier
the venue actually registers, and a mismatched `Fee` object or adopted pool
aborts.

## Alternatives considered

**Compile-time tier constants as the only mechanism.** Rejected: frozen
forever at `UpgradeCap` destruction, and a wrong constant would strand every
launch bound to that venue. Adopted instead as **overridable defaults**: the
values are researched from live venue registries rather than guessed, they
make every route work from publication, and the dynamic-field pin corrects
them on mainnet at any time.

**Struct fields on `VenueConfig`.** Rejected: upgrade compatibility freezes a
shared object's struct layout, so a future venue module could never add its
tier without a new config object. Dynamic fields keyed by the sealed venue
witness keep registration open to upgrade-added modules and seal each entry to
its owner.

**Admin-gated migration.** Rejected: ADR 0046's permissionless migration is a
deliberate liveness property; gating the caller reintroduces a trusted
operator for every graduation.

**Per-launch tier snapshot in core `launch_config`.** Deferred: it widens the
core cold-policy ABI for a value only the adapter package consumes. The global
per-venue pin covers the approved product scope; a per-quote refinement would
amend this ADR.

## Consequences

- No unauthenticated party can choose the economics of locked LP principal.
- Tier policy stays correctable on mainnet without a package upgrade,
  including after the migrators `UpgradeCap` is destroyed; changes affect only
  later migrations and can never touch custodied principal or accrued
  ownership.
- Routes gain one shared read dependency; a migration transaction now takes
  the shared `VenueConfig` alongside `RuntimeConfig`.

## Verification

From `sui/migrators/`: `sui move test --lint` covers the sealed set/read
substrate, the per-venue compiled defaults and their admin overrides, the
zero-bound and no-op rejections, and the Turbos `u32` fee bound;
`bash scripts/check_source_boundaries.sh` pins the per-route tier reads and
rejects caller tier parameters on every public migrate signature; the mainnet
dev-inspect matrix in `DEPENDENCIES.md` proves the pinned tiers against the
live venues.
