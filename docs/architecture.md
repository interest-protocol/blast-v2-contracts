# Architecture

## Goal

Blast V2 is one launch protocol with Sui and EVM implementations. Parity is
defined by observable behavior and economic invariants, not by identical module
or storage structure.

## Repository boundary

```text
contracts/
├── docs/                 shared protocol and engineering specification
├── deployments/          normalized public deployment records (when present)
├── sui/
│   ├── sources/          core Move domain modules
│   │   └── lib/          package diagnostics and indexing infrastructure
│   ├── tests/
│   └── scripts/
└── evm/
    ├── src/              core Solidity project
    ├── test/
    └── script/
```

Start with one package/project per chain. A new package is justified only by one
of these boundaries:

- an external dependency that should not enter core;
- a separately governed or separately deployed component;
- an adapter with a venue-specific failure surface;
- test assets that must never ship with production code.

This keeps V2 smaller than the historical collection of interdependent packages
without forcing unrelated dependencies into the trusted core.

The Sui package set that follows from those boundaries is decided in
[decisions/0001-sui-package-and-module-layout.md](decisions/0001-sui-package-and-module-layout.md):
`blast_fun` core, one package per venue adapter, a separately governed settlement
package, and a generated per-launch coin package.

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
| Protocol ACL | root rotation and revocable routine-admin membership | feature configuration, backend keys, creator identity, or fees |
| Signed-action config | one shared domain-specific backend key and signature authentication | admin delegation, domain transition state, or economic authority |
| Trade-fee config | live global protocol share and its bounded admin setter | accrued balances, launch-selected fee rates, or claim authority |
| Launch config | cold bounded quote targets, graduation defaults, and external migrator witness admission for future launches | live launch repricing, quote registry objects, DEX costs or dependencies, user balances, curve math, or hot trade configuration |
| Registry/config | global limits, other fee ceilings, emergency state | user balances or curve math |
| Launch ticket | generated OTW currency creation and pre-launch capability custody | supply minting, trades, metadata updates, or migration |
| Launch | asset identity, lifecycle, reserves, accounting, transition guards | venue-specific migration code |
| Curve math | pure quote and reserve transition formulas | authority, storage, transfers |
| Fees | creator/protocol fee splitting, accrued accounting, and capability claims | arbitrary recipient execution or referral attribution |
| Allocation/vesting | bounded stakeholder schedules and claims | launch pricing |
| Migration interface | one-time handoff payload and settlement proof | DEX-specific object/storage details |
| Adapter | prepare and complete a migration for one venue | changing core economics |

Modules may begin together in the single chain project. These are dependency
directions, not a demand for seven packages.

## Asset pair

A launch pairs its generated meme coin with a quote `Coin<Quote>`. Core admits
new pairs through the bounded quote portion of `LaunchConfig`, keyed by the
quote's original `TypeName`. Each entry supplies the nonzero real-quote migration
target. Launch state copies that target, both graduation rates, and the complete
selected migration witness's original `TypeName` once. Both whitelists are
admission decisions; the snapshot does not add a quote `Currency` shared-object
dependency or a DEX package dependency. See
[ADR 0025](decisions/0025-quote-whitelist-and-migration-targets.md) and
[ADR 0027](decisions/0027-graduation-economics-and-migration-witnesses.md).

One property remains invariant regardless of the admitted quote set:

- **Pair and migrator immutability.** The selected `(Meme, Quote)` pair and
  migration witness type are fixed at launch and never change through bonding,
  migration, recovery, or settlement.
See [ADR 0023](decisions/0023-generated-coin-supply-and-metadata-custody.md).

## Coin creation

The current Coin Registry OTW path is the only generated-coin creation primitive.
The generated package creates a zero-supply currency and a launch ticket holding
its empty `TreasuryCap<Meme>` and `MetadataCap<Meme>`. After permissionless
registration finalization, launch mints a nonzero supply capped at one billion
whole coins and consumes the treasury cap into owner-selected `Fixed` or
`BurnOnly` state. No mint authority survives in Blast core or an adapter. The
native metadata cap remains in Blast-defined custody until the one-time creator
claim returns it separately alongside `CreatorCap<Meme>`. See
[ADR 0023](decisions/0023-generated-coin-supply-and-metadata-custody.md).

## Lifecycle

The common lifecycle is intentionally small:

```text
Configured -> Live -> MigrationPending -> Migrated
                 \-> Cancelled (only if an approved recovery policy permits it)
```

- `Configured`: immutable launch identity and bounded parameters exist; trading
  has not started.
- `Live`: the approved curve accepts buys/sells while enforcing deadlines,
  slippage, fee, and reserve rules. On burnable launches, sell-designated burn
  remains in a separate pending balance rather than mutating registry supply.
- `MigrationPending`: the terminal threshold is reached, trading is closed, and
  the one-time migration payload is outstanding; accumulated pending burn is
  terminally destroyed before settlement.
- `Migrated`: the target venue has accepted the assets and the settlement result
  is final.

Every transition is single-use, evented, and tested against every other source
state. Recovery from `MigrationPending` must not recreate a second migration
right or allow an authority to redirect assets outside the approved policy.

## Migration boundary

The historical contracts correctly treated migration as a typed, one-time
handoff. V2 retains that property but narrows it:

1. Core closes trading and produces a single-use migration payload/claim.
2. A target adapter consumes the payload and supplies venue-specific inputs.
3. Core verifies the allowed target and records final settlement.
4. The adapter cannot mutate launch economics or retain unaccounted assets.

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

## Cross-chain parity

The parity specification covers:

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

- Sui: keep the public surface minimal, version shared state, and gate mutations
  so old package versions cannot bypass a fix.
- EVM: choose immutable deployment or a named proxy pattern before storage is
  committed. If upgradeable, document administrator, delay, rollback/escape
  policy, initializer behavior, and storage-layout checks.

The upgrade decision must be approved before the first public deployment.
