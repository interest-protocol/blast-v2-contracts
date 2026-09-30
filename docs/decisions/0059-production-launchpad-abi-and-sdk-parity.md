# 0059 — Production launchpad ABI and first SDK parity boundary

- Status: **accepted; amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)**
- Date: 2026-08-30
- Amends: [0011](0011-event-schema-and-replay.md),
  [0054](0054-v3-dex-migrators-and-locked-lp-fees.md), and
  [0057](0057-admin-pinned-venue-tiers.md)
- Amended by: [0062](0062-table-backed-quote-registry.md),
  [0066](0066-aftermath-dao-fee-pool.md), and
  [0067](0067-retire-full-sail-migrator.md),
  [0068](0068-compact-lp-fee-principal-snapshot.md), and
  [0069](0069-consolidate-launch-graduation-and-move-migration-math.md),
  [0079](0079-compact-launch-state-and-events.md), and
  [0100](0100-single-cetus-route-with-checked-retype.md) (one generic Cetus route per operation)

> ADR 0079 regenerates the pre-publication launchpad object and event ABI with
> compact, replay-complete layouts.

> ADR 0088 replaces the frozen package counts, adapter set, migration and
> collection calls, returned objects, event schemas, and SDK parity surface.
> Only the current-package/original-type identity rules, shared-object input
> metadata, native event position metadata, and requirement for one generated
> ABI/parity gate remain authoritative. The replacement gate covers only the
> launchpad, Meme template, migrators with Cetus and Bluefin, and distributor.

> ADR 0062 changes the pre-publication `LaunchConfig.quotes` field from
> `VecMap` to `Table`. The ABI artifact and SDK parity baseline must be
> regenerated before the first release; no deployed object is migrated in
> place.
>
> ADR 0069 removes the empty public `graduation` and `migration_math` launchpad
> modules from the pre-publication surface. Migration arithmetic now has
> package-only visibility in `blast_fun_migrators`. The ABI artifact is
> regenerated as an approved amendment.

## Context

The first frontend-ready launchpad slice needs one stable contract boundary
before the SDK adds complete venue migration, LP-fee, event, and replay support.
Freezing only the calls already wrapped by the SDK would leave independently
deployed migrator functions, returned or shared objects, event envelopes, type
origins, and shared-object mutability as implicit release commitments.

The reviewed contract baseline is commit
`a5ed34ad49c6c001af2db5b9cbcb206075704412`. At the freeze decision, the working
tree differed from that commit only by `sui/meme_template/Move.lock` and the
untracked research document
`docs/research/sui-deepbook-indexer-architecture-2026.md`. Neither difference
changed a production function, type, object ability, or event schema.

## Decision

### Frozen production boundary

Freeze the complete production public ABI of these root packages:

- `sui/launchpad` (`blast_fun`): 47 public production functions, client-used
  shared or returned objects, 30 event payloads, and the generic
  `events_wrapper::Event<T>` envelope;
- `sui/meme_template` (`meme_template`): the generated `MEME` witness and its
  initializer-defined launch-ticket result; and
- `sui/migrators` (`blast_fun_migrators`): 31 public production functions,
  `VenueConfig`, `LpVault<Meme, Quote>`, and six direct event payloads.

`#[test_only]` functions and the vendored Bluefin, Cetus, Full Sail, MMT, and
Turbos venue interface modules are excluded. Those interfaces retain their
separate pinned-mainnet ABI gate under ADR 0054.

The machine-readable freeze artifact must be derived from production
`sui move summary` output and normalized to the root package modules above. It
must retain function visibility, type parameters and constraints, parameter
types and references, return types, struct abilities and fields, enum variants,
and event-envelope shape. A parity check must fail when the normalized contract
surface and the SDK coverage declaration differ.

### Package identity and shared-object references

- A Move call target uses the current package ID that contains the callable
  bytecode.
- A type tag, object schema, event payload or envelope, migration witness, and
  venue-tier dynamic-field key uses the type's original package ID.
- Every SDK shared-object input records `objectId`, `initialSharedVersion`, and
  the exact `&` versus `&mut` requirement from the frozen function signature.
- Turbos keeps its route-specific `FeeType` argument. The other venue routes use
  only `Meme` and `Quote`; orientation and new-versus-existing pool select the
  concrete function.

### First SDK parity slice

The frontend product boundary includes the existing generated-Meme, launch,
trade, creator-claim, and launch-fee behavior plus:

- all 17 supported Bluefin, Cetus, MMT, Turbos, Full Sail, and Aftermath
  migration routes;
- all ten venue LP-fee collection or accrual routes and both LP-vault fee
  claims;
- LP-vault object reads and venue-tier default/override reads;
- deployment validation and helpers for the migrators package and its shared
  objects;
- typed decoding for all 30 wrapped launchpad and nine direct migrator payloads;
  and
- deterministic, idempotent reducers over native checkpoint, transaction
  digest, and event-index metadata.

Routine administration, package upgrades, `blast_sui`, and indexer/API/web
processes remain outside this slice. Public math
and fee functions used by external Move composition do not receive transaction
builders. Core `launch::migrate` and `launch::redeem_migration` remain available
as compositional SDK calls for non-bundled adapters.

### Event-derived and native facts stay distinct

Reducers reconstruct launch lifecycle, reserves, trade and migration fees,
migration settlement, LP-vault identity, and LP-fee totals from ordered Blast
events. They do not present native Sui facts as Blast-event facts.

The following remain explicit native inputs:

- package-initialized singleton discovery from publication effects;
- current ownership of transferable `CreatorCap<Meme>` objects; and
- final recipients of coins returned by creator or protocol claims.

## Consequences

- A later contract change to any frozen production signature, ability, object
  layout, payload, or envelope is an ABI or event-schema migration.
- SDK event decoding covers administrative payloads even when routine
  administrative transaction builders are intentionally absent.
- Migration builders cannot substitute prices or venue tiers. They only select
  a frozen adapter route and supply objects required by that route.
- No deployment registry entry may contain placeholder package or object IDs.

## Verification at freeze

The following passed on the reviewed working tree with Sui CLI
`1.77.2-51d177ad7d65`:

- launchpad build, warning-as-error lint, 221 Move tests, and source boundaries;
- generated Meme template build, warning-as-error lint, and source boundaries;
- migrator mainnet ABI self-test (61/61) and live checks for six external
  packages, covering 31 modules, 66 functions, 27 structs, and type origins;
- migrator build in default and mainnet environments, warning-as-error lint,
  15 Move tests, source boundaries, and Turbos and Full Sail dependency pins.
