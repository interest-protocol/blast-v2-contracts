# Architecture

## Goal

Blast V2 currently has one Sui Move implementation. Other chain implementations
are deferred. Future parity is defined by observable behavior and economic
invariants, not by identical module or storage structure.

## Package boundary

Start with one core package/project per chain. A new package is justified only
by one of these boundaries:

- an external dependency that should not enter core;
- a separately governed or separately deployed component;
- an adapter with a venue-specific failure surface;
- test assets that must never ship with production code.

This keeps V2 smaller than the historical collection of interdependent packages
without forcing unrelated dependencies into the trusted core.

The package boundaries are decided in
[decisions/0001-sui-package-and-module-layout.md](decisions/0001-sui-package-and-module-layout.md):
keep external dependencies and independently governed custody outside core.

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
| Protocol ACL | root rotation and revocable routine-admin membership | feature configuration, backend keys, creator recipients, or fees |
| Runtime config | one dedicated creator-claim backend key and the live bonding-curve trade protocol fee share | admin delegation, creator recipient or issuance, cold launch policy, accrued balances, total trade-fee rates, or claim authority |
| LP fee policy | launchpad-owned default and Meme-keyed partner Blast shares per asset, copied once into each router at activation, and the live protocol destination every router pays | trade fee shares, route tables, accrued balances, vault custody, or collection |
| Launch config | cold Table-backed virtual Quote reserves, mutable generated-Meme decimal admission, Quote/Meme trade-fee rates, one-time protocol allocation policy, and bounded external migrator witness admission that gates ticket binding, treasury-capability borrowing, and launch intake | live launch repricing, per-launch project allocation choices, quote currency-registry objects, DEX costs or dependencies, user balances, derived valuations, or hot trade configuration |
| Registry/config | global limits, other fee ceilings, emergency state | user balances or curve math |
| Launch ticket | one-time-witness currency creation, exact supply mint, admitted migration-adapter and Quote binding, and pre-launch capability custody | decimal policy, trades, metadata updates, or migration |
| Launch | key-only top-level shared asset identity, lifecycle, reserves, accounting, and transition guards | owned transfer, nesting, or venue-specific migration code |
| Basis-points unit | universal 0–10,000 rate validation, explicit up/down application, and complement math | domain ceilings, combined-rate policy, authority, storage ownership, or events |
| Curve math | pure quote and reserve transition formulas | authority, storage, transfers |
| Allocation math | canonical bounded Meme/Quote tables, canonical route tables, and protected-first exact apportionment | lifecycle state, custody, claims, venue costs, transfers, or DEX dependencies |
| Off-chain SDK | deterministic curve-release and native-Quote valuation previews from immutable launch facts | contract authority, balance mutation, migration permission, or a second source of truth |
| Fees | creator/protocol curve-fee splitting and accrued accounting; the embedding launch checks its live curve-fee capability or bound custodian | recurring LP fees, arbitrary recipient execution, or referral attribution |
| Fee router | frozen protocol shares, generation-versioned project routes, and immediate payout of every collection to its destinations | balance custody, launch pricing, or venue calls |
| Vesting | bounded stakeholder schedules and claims | launch pricing or migration allocation |
| Migration interface | one-time liquidity handoff, linear migration value, and reconciled completion | DEX-specific object/storage details |
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

The recommended SUI lane is an operational example: 8,000 SUI virtual Quote,
an 8,000-SUI migration target, and an immutable allocation plan that assigns
80% of Meme to channel zero (the curve), 20% of Meme to the liquidity channel,
and 100% of terminal Quote to that liquidity channel. It yields a 10,000-SUI
opening curve valuation and equal 40,000-SUI curve-terminal and DEX-opening
valuations. The percentages belong to that example plan, not to fixed protocol
fee or liquidity-provision fields, an immutable global default, or an on-chain
USD oracle. See [`vectors/graduation.json`](vectors/graduation.json).

Memez's balance-derived V3 price, Raydium's effective-reserve continuity, and
Pump and Hop graduation disclosures inform this comparison only. Blast cannot
move virtual Quote into a DEX pool, so it must disclose the real-balance DEX
valuation separately and must not present a USD comparison as a protocol rule.
See [ADR 0054](decisions/0054-v3-dex-migrators-and-locked-lp-fees.md).

## Asset pair

A launch pairs its generated meme coin with a quote `Coin<Quote>`. Stored rates
and public fee-rate configuration inputs use the validated `Bps` unit; replay
events use raw `u64` primitive values. Core admits
new pairs through the Table-backed quote portion of `LaunchConfig`, keyed by the
quote's original `TypeName`. Each entry supplies a nonzero virtual Quote
reserve. Each launch chooses its own graduation target, and intake rejects a
target whose liquidity Quote share rounds to zero. Launch state copies the
virtual reserve, both administratively configured trade-fee rates, and the
original `TypeName` of the ticket's bound migration witness. The constructor also validates
and stores one caller-supplied canonical allocation plan against the config's
single-write protocol-allocation policy. Both registries are
admission decisions; the snapshot does not add a quote `Currency` shared-object
dependency or a DEX package dependency. See
[ADR 0025](decisions/0025-quote-whitelist-and-migration-targets.md) and
[ADR 0027](decisions/0027-graduation-economics-and-migration-witnesses.md) and
[ADR 0039](decisions/0039-deterministic-quote-valuations.md), and
[ADR 0041](decisions/0041-launch-config-owned-trade-fees.md).
The shared unit and rounding boundary are fixed by
[ADR 0044](decisions/0044-validated-basis-points-unit.md).

## One-time allocation and payouts

An `AllocationPlan` contains one canonical ascending list of at most sixteen
nonzero channel identities plus independent Meme and terminal-Quote weight
tables. Channel zero is reserved for the curve, appears only in the Meme table,
and must have positive weight. Exactly one named channel has the liquidity role
and has positive weight in both tables. Other named channels may be protocol or
external destinations and must participate in at least one table. Every table
contains only positive entries and sums to exactly 10,000 BPS.

`LaunchConfig` accepts the protocol identity, immutable destination, and
per-asset weights exactly once. Every later plan must reproduce that policy. A
zero/zero policy means the plan omits the protocol channel; it does not create a
zero-weight entry or a hidden fee. Protocol Meme is capped at 9,998 BPS so the
required positive curve and liquidity entries remain representable; protocol
Quote is capped at 9,999 BPS so liquidity remains positive. Project and
liquidity allocations otherwise remain per-launch choices within the canonical
table invariants. The successful write emits one
`ProtocolAllocationConfigured` fact containing the complete identity,
destination, and per-asset weights; there is no update event because there is
no second write.

For each asset, allocation widens `total * bps` to `u128`. The protocol channel,
when present, is protected first with ceiling division. Every other entry takes
its floor. Remaining atomic units are then assigned once each by descending
fractional remainder, with ascending channel ID as the deterministic tie break.
The final amounts sum exactly to the input balance; no terminal amount enters
the trade-fee ledger.

Initial Meme is physically split at construction: channel zero becomes the
curve reserve and every named allocation is pooled in the launch. At migration,
the complete terminal real-Quote reserve is apportioned by the same plan. Only
the liquidity amounts enter the migration handoff; in the same successful
completion transaction every other allocation is transferred as a coin to the
plan's immutable destination, so nothing is custodied or claimed afterwards.
Only a regulated Quote whose deny list names a destination can make that
transfer fail, which strands the launch; the founder accepted that risk.
`LaunchCreated` carries the complete plan and the Meme partition, one
`MigrationAllocationPaid` records each nonzero payout, `RouterActivated` records
the vault, pool, and position identities, and `Migrated` records the supplied,
residual, liquidity, and disposal amounts. Recurring fees follow the same rule:
each collection pays the protocol destination and every route destination
immediately. See
[ADR 0088](decisions/0088-reusable-launch-accounting-and-atomic-migration.md).

One property remains invariant regardless of the admitted quote set:

- **Pair and migrator immutability.** The selected `(Meme, Quote)` pair and
  migration witness type are fixed at launch and never change through bonding,
  migration, recovery, or settlement.
See [ADR 0023](decisions/0023-generated-coin-supply-and-metadata-custody.md).

## Coin creation

Generated coins use Coin Registry's one-time-witness path. The generated
package's initializer passes its witness to the sole launchpad constructor,
which computes exactly one billion whole tokens in `u64` arithmetic that aborts
on overflow, creates the currency at the requested decimals, mints that supply,
and finalizes metadata; the initializer transfers the persistable launch ticket
to the publisher. The ticket holds the complete `Balance<Meme>`, the treasury
cap, `MetadataCap<Meme>`, the decimals, the owner-selected `Fixed` or
`BurnOnly` mode, and the creator-selected fixed sell-burn rate capped at 50%.
Before intake the creator binds the ticket to one admitted migration adapter
and one Quote; only that adapter's witness can borrow the treasury cap, which it
uses to prepare its venue for that Quote before any Meme can leave the launch
(the Cetus adapter reserves pool creation). Because an initializer cannot read
launch policy, launch intake checks the decimals against the current allowlist,
the bound Quote against the launch's Quote, the bound adapter against the
witness allowlist, the balance and the whole minted supply against the
canonical supply, and the sell-burn rate against this generation's ceiling,
then consumes the treasury cap into the selected mode, so no mint authority
survives intake. The native `Currency` is delivered to the Coin Registry
address, and completing its registration is permissionless; intake needs it.
The creator recipient may be a wallet address or an opaque Blast account
commitment and may differ from the launcher. The native metadata cap never
leaves `Launch`. The creator claim issues a `CurveFeeCap<Meme>` for curve fees
and a `BlastMetadataCap<Meme>` for metadata updates through the launch; a
creator administrator can reassign each independently. A holder may destroy the
curve-fee cap to bind curve fees permanently to a custodian module, named by the
drop-only witness type only it can construct, such as the distributor, after
which it can never be reassigned
([ADR 0082](decisions/0082-revocable-creator-and-lp-fee-capabilities.md)).
Recurring LP fees have no claim capability: the launch's `FeeRouter` pays every
collection to its destinations
([ADR 0088](decisions/0088-reusable-launch-accounting-and-atomic-migration.md)).
See [ADR 0035](decisions/0035-initializer-finalized-meme-supply.md),
[ADR 0036](decisions/0036-fixed-nine-decimal-generated-memes.md), and
[ADR 0047](decisions/0047-coin-registry-authoritative-supply-mode.md), and
[ADR 0080](decisions/0080-provider-independent-creator-recipient.md), as amended
by [ADR 0088](decisions/0088-reusable-launch-accounting-and-atomic-migration.md).
The ticket records its decimals and sell-burn policy; launch intake recomputes
the canonical supply. Terminal migration reads the authoritative supply mode
from Coin Registry.

## Lifecycle

The common lifecycle is intentionally small:

```text
Live -> MigrationReady -> (Migrating) -> Migrated
```

- `Live`: the approved curve accepts buys/sells while enforcing slippage, fee,
  and reserve rules. Sell-designated burn remains in a separate
  pending balance rather than mutating registry supply.
- `MigrationReady`: an exact-target buy closed trading and returned excess
  Quote; only the adapter whose witness the launch stored at intake can begin
  migration.
- `Migrating`: exists only inside the migration transaction, between the
  liquidity handoff and completion.
- `Migrated`: custody is installed, the router is active, every allocation is
  paid, and terminal disposal is complete.

Every transition is single-use and evented. Failure to consume the linear
migration value aborts the transaction and rolls the transition back.

## Migration boundary

The historical contracts correctly treated migration as a typed, one-time
handoff. V2 retains that property but narrows it:

1. An exact-target buy returns excess Quote and closes trading.
2. The adapter calls `begin_migration` with its sealed witness. Core verifies
   the witness type the launch stored, hands off only the liquidity channel's
   Meme and Quote, marks the launch `Migrating`, and returns a `Migration` value
   with no abilities.
3. The adapter installs the pool position in the migrators' sealed `LpVault`
   and keeps any residual there.
4. The adapter calls `complete_migration` with the same witness, its custody
   objects, the pool ID it read from its venue position, and the supplied and
   residual amounts. Core checks that they reconcile to the handoff, activates
   the router against those IDs,
   pays every other allocation, completes mode-specific disposal, and commits
   `Migrated` last. Any failure rolls back the whole transaction.

Incomplete adapters never ship as aborting production functions. An unavailable
venue stays outside the release. A venue whose dependency cannot yet be pinned to an
immutable commit is a **release gate on that adapter, not a reason to omit its
design**.

Every adapter creates a fresh pool. Where anyone holding Meme could create the
pool first (Cetus), the adapter reserves creation while binding the ticket,
before the curve opens. No adapter adopts a pool someone else created. A
mismatch is an atomic abort that leaves the launch `MigrationReady` with every
balance in place. The initial price is derived from the terminal atomic
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
  The only upgrade finalizer commits the native receipt and advances the
  operational version to the exact next compiled generation in the same call;
  there is no separate activation step.
- The migrators package keeps its `UpgradeCap` in its own `PackageAdmin` and is
  never made immutable: Cetus and Bluefin gate callers by package version and
  launchpad cutovers advance the launchpad version, so the adapters must always
  be able to relink (ADR 0088). Every migrators upgrade uses the compatible
  policy and bumps both compiled generation constants; its custody has no
  policy-narrowing or immutability path.

The Sui custody and interim authority decision is accepted in
[ADR 0032](decisions/0032-admin-authorized-upgrade-cap-custody.md). Replacement
governance, delay, recovery, and remaining shared-state cutover coverage require
approval before the first public deployment.
