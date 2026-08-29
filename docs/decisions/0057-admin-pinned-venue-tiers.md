# 0057 — Admin-pinned venue tiers for permissionless migration

- Status: **accepted**
- Date: 2026-08-29
- Amends: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md)

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

Independent research (`docs/research/meme-launchpad-features-and-migration-fees-2026.md`)
deliberately declines to copy competitor tier percentages, and venue fee units
differ per venue, so compile-time tier constants would encode unverified
values and freeze them at `UpgradeCap` destruction.

## Decision

Add one shared singleton, `venue_config::VenueConfig`, to the aggregate
migrators package. It pins one production tier per venue:
`(tick_spacing, fee_rate)` for Bluefin and Turbos, `tick_spacing` for Cetus
and Full Sail (the venue fee follows its registered tier, and adopted pools
must match both), and `fee_rate` for MMT.

- Every migration route reads its tier from the singleton instead of trusting
  caller parameters; migrate signatures carry no tier inputs.
- A zero field is unset and every read aborts, so each venue fails closed
  until pinned. Setters reject zero values, reject no-op re-pins, bound the
  Turbos fee to `u32`, take only a borrowed live `acl::AdminWitness`, and emit
  old/new facts (`BluefinTierUpdated`, `CetusTickSpacingUpdated`,
  `FullSailTickSpacingUpdated`, `MmtFeeRateUpdated`, `TurbosTierUpdated`).
- Package initialization shares exactly one unset config and emits
  `VenueConfigCreated`; no other constructor exists, so a caller cannot forge
  a second policy object for a permissionless route.
- Tier reads are `public(package)`; there is no public getter. Offchain
  consumers reconstruct the live tier from the mutation events.
- Fee collection routes take no tier input; tier policy is irrelevant to
  draining fees from an already-pinned position.

The dev-inspect release gate must prove every pinned tier matches a tier the
venue actually registers, and a mismatched `Fee` object or adopted pool aborts.

## Alternatives considered

**Compile-time tier constants.** Rejected: values would be guessed in
venue-specific units, frozen forever at `UpgradeCap` destruction, and wrong
constants would strand every launch bound to that venue until an upgrade.

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

From `sui/migrators/`: `sui move test --lint` covers the set/read,
fail-closed, zero-bound, and no-op-rejection paths;
`bash scripts/check_source_boundaries.sh` pins the per-route tier reads and
rejects caller tier parameters on every public migrate signature; the mainnet
dev-inspect matrix in `DEPENDENCIES.md` proves the pinned tiers against the
live venues.
