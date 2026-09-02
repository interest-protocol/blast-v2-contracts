# Architecture

## Goal

Blast V2 currently has one Sui Move implementation. Other chain implementations
are deferred. Future parity is defined by observable behavior and economic
invariants, not by identical module or storage structure.

## Repository boundary

```text
contracts/
├── docs/                 shared protocol and engineering specification
├── deployments/          normalized public deployment records (when present)
└── sui/
│   ├── launchpad/        core blast_fun Move package
│   │   ├── sources/      core Move domain modules
│   │   │   └── lib/      package diagnostics and indexing infrastructure
│   │   ├── tests/
│   │   └── scripts/
│   ├── migrators/        independently deployed venue adapter packages
│   └── vesting/          independent global vesting package
```

Start with one core package/project per chain. A new package is justified only
by one of these boundaries:

- an external dependency that should not enter core;
- a separately governed or separately deployed component;
- an adapter with a venue-specific failure surface;
- test assets that must never ship with production code.

This keeps V2 smaller than the historical collection of interdependent packages
without forcing unrelated dependencies into the trusted core.

The Sui package set that follows from those boundaries is decided in
[decisions/0001-sui-package-and-module-layout.md](decisions/0001-sui-package-and-module-layout.md):
`blast_fun` core, one package per venue adapter, independently deployed vesting
packages, a separately governed settlement package, and a generated per-launch
coin package.

### Dependency direction

**Core imports no venue package, at launch or at migration.** Core defines the
neutral route and handoff types; every adapter depends inward on core. Composition
between core and an adapter happens **in the programmable transaction block, not in
core code**: a transaction threads core-defined values through an adapter call and
back into core, so venue preflight is possible without core naming any venue.

The values crossing that boundary are non-droppable, so the transaction cannot end
without returning to core for its post-conditions.

## Logical components

| Component | Responsibility | Must not own |
| --- | --- | --- |
| Package bootstrap | canonical OTW and one-time framework `Publisher` claim | protocol administration, feature state, or upgrade authority |
| Package administration | validated `Publisher` and raw `UpgradeCap` custody, exact-digest authorization, irreversible policy restriction, receipt commit, and one-way admin retirement | ACL membership storage, feature configuration, or state migration |
| Protocol ACL | root rotation and revocable routine-admin membership | feature configuration, backend keys, creator identity, or fees |
| Runtime config | one dedicated X-claim backend key and the live global protocol fee share | admin delegation, creator identity or issuance, cold launch policy, accrued balances, total trade-fee rates, or claim authority |
| Launch config | cold Table-backed virtual/terminal Quote parameters, Quote/Meme trade-fee rates, graduation defaults, and bounded external migrator witness admission for future launches | live launch repricing, quote currency-registry objects, DEX costs or dependencies, user balances, derived valuations, or hot trade configuration |
| Registry/config | global limits, other fee ceilings, emergency state | user balances or curve math |
| Launch ticket | generated OTW currency creation and pre-launch capability custody | supply minting, trades, metadata updates, or migration |
| Launch | key-only top-level shared asset identity, lifecycle, reserves, accounting, and transition guards | owned transfer, nesting, or venue-specific migration code |
| Basis-points unit | universal 0–10,000 rate validation, explicit up/down application, and complement math | domain ceilings, combined-rate policy, authority, storage ownership, or events |
| Curve math | pure quote and reserve transition formulas | authority, storage, transfers |
| Graduation math | pre-curve protocol Meme fee/liquidity provision and terminal Quote-fee balance partitioning | forecast valuations, lifecycle state, claims, venue costs, transfers, or DEX dependencies |
| Off-chain SDK | deterministic curve-release and native-Quote valuation previews from immutable launch facts | contract authority, balance mutation, migration permission, or a second source of truth |
| Fees | creator/protocol fee splitting, accrued accounting, and capability claims | arbitrary recipient execution or referral attribution |
| Allocation/vesting | bounded stakeholder schedules and claims | launch pricing |
| Migration interface | one-time handoff payload and settlement proof | DEX-specific object/storage details |
| Adapter | prepare and complete a migration for one venue | changing core economics |

Modules may begin together in the single chain project. These are dependency
directions, not a demand for seven packages.

## On-chain and SDK responsibility

Blast contracts contain only logic required for consensus-critical transitions,
authorization, asset custody/conservation, trustless synchronous composition,
and canonical facts that outside consumers cannot otherwise reconstruct. The SDK
owns deterministic projections, valuation previews, aggregation, formatting,
transaction construction, and convenient reads derived from those facts.

A derivable value may still be recomputed inside a state-changing contract
operation when it enforces a threshold, fee, slippage bound, or conservation
rule. It is not stored or published merely because a UI wants to display it.
Contract balances and completed events are authoritative; SDK results are
previews. See [ADR 0039](decisions/0039-deterministic-quote-valuations.md).

## Migration valuation disclosure

The recommended SUI lane is an operational pre-launch configuration: 8,000 SUI
virtual Quote, an 8,000-SUI migration target, zero terminal fees, and a 20%
Meme pool provision. It yields a 10,000-SUI opening curve valuation and equal
40,000-SUI curve-terminal and DEX-opening valuations. An administrator selects
this Quote-denominated configuration before each eligible launch; it is not an
immutable global default or an on-chain USD oracle.

Memez's balance-derived V3 price, Raydium's effective-reserve continuity, and
Pump and Hop graduation disclosures inform this comparison only. Blast cannot
move virtual Quote into a DEX pool, so it must disclose the real-balance DEX
valuation separately and must not present a USD comparison as a protocol rule.
See [ADR 0054](decisions/0054-v3-dex-migrators-and-locked-lp-fees.md).

## Asset pair

A launch pairs its generated meme coin with a quote `Coin<Quote>`. Stored rates
use the validated `Bps` unit; public configuration inputs and replay events use
raw `u64` primitive values. Core admits
new pairs through the Table-backed quote portion of `LaunchConfig`, keyed by the
quote's original `TypeName`. Each entry supplies a nonzero virtual Quote reserve
and nonzero real-Quote migration target. Launch state copies that pair, both
administratively configured trade-fee rates, all three graduation rates — the
Quote migration fee, the protocol Meme graduation fee, and the nonzero
destination-pool Meme liquidity provision — and the complete
selected migration witness's original `TypeName` once. Both registries are
admission decisions; the snapshot does not add a quote `Currency` shared-object
dependency or a DEX package dependency. See
[ADR 0025](decisions/0025-quote-whitelist-and-migration-targets.md) and
[ADR 0027](decisions/0027-graduation-economics-and-migration-witnesses.md) and
[ADR 0039](decisions/0039-deterministic-quote-valuations.md), and
[ADR 0041](decisions/0041-launch-config-owned-trade-fees.md).
The shared unit and rounding boundary are fixed by
[ADR 0044](decisions/0044-validated-basis-points-unit.md).

One property remains invariant regardless of the admitted quote set:

- **Pair and migrator immutability.** The selected `(Meme, Quote)` pair and
  migration witness type are fixed at launch and never change through bonding,
  migration, recovery, or settlement.
See [ADR 0023](decisions/0023-generated-coin-supply-and-metadata-custody.md).

## Coin creation

The current Coin Registry OTW path is the only generated-coin creation primitive.
The generated package's Blast constructor fixes precision at nine decimals,
mints exactly one billion whole coins, and consumes the treasury cap into
owner-selected `Fixed` or `BurnOnly` state
before finalizing the initializer. Its launch ticket holds the complete
`Balance<Meme>`, `MetadataCap<Meme>`, and bounded sell-burn rate; no mint authority survives in Blast core
or an adapter, and launch intake does not need the shared Meme currency merely to
finalize supply. The native metadata cap remains in Blast-defined custody until
the one-time creator claim returns it separately alongside `CreatorCap<Meme>`.
See [ADR 0035](decisions/0035-initializer-finalized-meme-supply.md),
[ADR 0036](decisions/0036-fixed-nine-decimal-generated-memes.md), and
[ADR 0047](decisions/0047-coin-registry-authoritative-supply-mode.md).
The ticket binds sell-burn policy only. Terminal migration reads the
authoritative supply mode from Coin Registry.

## Lifecycle

The common lifecycle is intentionally small:

```text
Live -> MigrationReady -> Migrated
```

- `Live`: the approved curve accepts buys/sells while enforcing slippage, fee,
  and reserve rules. Sell-designated burn remains in a separate
  pending balance rather than mutating registry supply.
- `MigrationReady`: an exact-target buy closed trading and returned excess
  Quote; any caller may request a payload bound to the selected witness type.
- `Migrated`: terminal disposal is complete and a non-droppable typed payload
  has been returned to the external adapter in the same transaction.

Every transition is single-use and evented. Failure to consume the linear
migration handoff aborts the transaction and rolls the transition back.

## Migration boundary

The historical contracts correctly treated migration as a typed, one-time
handoff. V2 retains that property but narrows it:

1. An exact-target buy returns excess Quote and closes trading.
2. Core verifies the launch-selected witness type, partitions terminal assets,
   and completes mode-specific disposal.
3. Core marks the launch migrated and returns a witness-typed, non-droppable
   payload in the same transaction.
4. The external adapter redeems the payload with its sealed witness and supplies
   venue-specific inputs; any failure rolls back the core transition.

Incomplete adapters never ship as aborting production functions. An unavailable
venue stays outside the release. A venue whose dependency cannot yet be pinned to an
immutable commit is a **release gate on that adapter, not a reason to omit its
design**.

Migration selects one of three routes, in order of preference: a reservation taken
before the curve opens where the venue offers one; a fresh pool creation; or
adoption of an existing pool only within a bounded price and parameter acceptance
band. A mismatch is an atomic abort that leaves exactly one migration right
outstanding, never two. The initial price is derived from the terminal atomic
reserves and is never a configured constant. See
[decisions/0010-migration-and-venue-adapters.md](decisions/0010-migration-and-venue-adapters.md).

## Future chain parity

Any future chain implementation must preserve:

- lifecycle transitions and authorization outcomes;
- quote, fee, allocation, vesting, and migration arithmetic;
- slippage, deadline, protection, pause, and limit behavior;
- event meaning and reconstructable state;
- error categories, even when numeric representations differ.

Chain-specific differences are expected for ownership, transaction composition,
gas, token behavior, address representation, and upgrade mechanics. Record each
intentional semantic difference in an ADR and in shared differential vectors.

## Upgrade posture

Upgradeability is a product/security decision, not a default convenience.

- Sui: Blast's canonical `Publisher` and raw `UpgradeCap` enter one shared
  `PackageAdmin` after module/package provenance checks. A live `AdminWitness`
  authorizes an exact digest under the cap's current policy and may
  irreversibly narrow that policy; the native receipt then commits against the
  same cap. A future governance design retires the routine-admin package path
  through the mandatory shared-object version gate after installing replacement
  authorization (ADR 0034); no pre-planted cutover flag exists.
  One dedicated shared `PackageVersion` gates every mutable core shared object.
  Native receipt commit does not activate bytecode. A separate live-admin
  operation activates only the exact next compiled operational version;
  additive and dependency-only upgrades do not activate a new generation.

The Sui custody and interim authority decision is accepted in
[ADR 0032](decisions/0032-admin-authorized-upgrade-cap-custody.md). Replacement
governance, delay, recovery, and remaining shared-state cutover coverage require
approval before the first public deployment.
