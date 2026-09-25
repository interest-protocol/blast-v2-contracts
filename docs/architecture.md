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
| Package administration | validated `Publisher` and raw `UpgradeCap` custody, exact-digest authorization under the compatible policy, receipt commit that advances the generation, and deliberate `make_immutable` | ACL membership storage, feature configuration, or state migration |
| Protocol ACL | root rotation and revocable routine-admin membership | feature configuration, backend keys, creator recipients, or fees |
| Runtime config | one dedicated creator-claim backend key and the live bonding-curve trade protocol fee share | admin delegation, creator recipient or issuance, cold launch policy, accrued balances, total trade-fee rates, or claim authority |
| LP fee policy | migrators-owned default and per-coin Blast shares per asset, read live at every collection, and the protocol destination every vault pays | trade fee shares, the creator's split, accrued balances, or launch state |
| Launch config | a table of admitted Quote types (the creator picks each launch's virtual Quote reserve), mutable generated-Meme decimal admission, Quote/Meme trade-fee rates, one-time protocol allocation policy, and bounded external migrator witness admission that gates which adapter may start a launch | live launch repricing, per-launch project allocation choices, quote currency-registry objects, DEX costs or dependencies, user balances, derived valuations, or hot trade configuration |
| Registry/config | global limits, other fee ceilings, emergency state | user balances or curve math |
| Launch ticket | one-time-witness currency creation, exact supply mint, and pre-launch capability custody | adapter binding, decimal policy, trades, metadata updates, or migration |
| Launch initializer | no-ability construction started by the adapter with its witness and the creator's tier; creator setters for target, plan, LP-fee split, and opening round; the adapter-only treasury-capability loan; `finalize` checks every invariant | persistence beyond its transaction or any post-migration behavior |
| Launch | key-only top-level shared asset identity, lifecycle, reserves, accounting, transition guards, and the creator's immutable post-migration settings (adapter, pool tier, LP-fee split) | owned transfer, nesting, venue-specific migration code, or any post-migration update |
| Basis-points unit | universal 0–10,000 rate validation, explicit up/down application, and complement math | domain ceilings, combined-rate policy, authority, storage ownership, or events |
| Curve math | pure quote and reserve transition formulas | authority, storage, transfers |
| Allocation math | the migration allocation plan, the LP-fee split, and their exact apportionment | lifecycle state, custody, claims, venue costs, transfers, or DEX dependencies |
| Off-chain SDK | deterministic curve-release and native-Quote valuation previews from immutable launch facts | contract authority, balance mutation, migration permission, or a second source of truth |
| Fees | creator/protocol curve-fee splitting and accrued accounting; the embedding launch checks its live curve-fee capability or bound custodian | recurring LP fees, arbitrary recipient execution, or referral attribution |
| LP vault (migrators) | permanent position custody and the generation-versioned fee split; every permissionless collection pays Blast's live share and the recipients, credits the creator and rewards balances, burns the burn share's Meme and keeps its Quote, and adds the auto-LP share back to the position; creator claims and split updates under the launch's live curve-fee cap; buyback-and-burn of the burn Quote under the buyback-admin role | launch pricing or pre-migration settings |
| Holder rewards (migrators) | Merkle rounds a Blast administrator funds from a vault's rewards balance, and one-time proof claims | holder accounting, which stays off-chain |
| Migration interface | one-time liquidity handoff, linear migration value, and reconciled completion | DEX-specific object/storage details |
| Adapter | start a launch at a venue-valid tier, prepare its venue, complete a migration, and collect the position's fees | changing core economics |

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
80% of Meme to the curve, 20% of Meme to the pool, and 100% of terminal Quote to
the pool. It yields a 10,000-SUI
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
target whose pool Quote share rounds to zero. Launch state copies the
virtual reserve, both administratively configured trade-fee rates, and the
original `TypeName` of the starting adapter's witness. Both registries are
admission decisions; the snapshot does not add a quote `Currency` shared-object
dependency or a DEX package dependency. See
[ADR 0025](decisions/0025-quote-whitelist-and-migration-targets.md) and
[ADR 0027](decisions/0027-graduation-economics-and-migration-witnesses.md) and
[ADR 0039](decisions/0039-deterministic-quote-valuations.md), and
[ADR 0041](decisions/0041-launch-config-owned-trade-fees.md).
The shared unit and rounding boundary are fixed by
[ADR 0044](decisions/0044-validated-basis-points-unit.md).

## One-time allocation and payouts

An `AllocationPlan` holds the curve's Meme share, the pool's Meme and Quote
shares (all positive), and at most sixteen recipients, each an address with a
Meme and a Quote share. The creator's plan leaves Blast out: `LaunchConfig`
holds Blast's allocation, set once by an administrator (Meme at most 9,998 BPS
and Quote at most 9,999 BPS so the curve and pool stay positive), and
finalization adds it as the first recipient. Each asset must then sum to exactly
10,000 BPS.

For each asset, allocation widens `total * bps` to `u128`. Blast's share takes
its ceiling; every other part takes its floor, and the remaining atomic units go
one each by descending fractional remainder, earlier parts first on ties. The amounts sum exactly to the input;
no terminal amount enters the trade-fee ledger.

Initial Meme is physically split at construction: the curve's share becomes the
curve reserve and the rest is pooled in the launch. When migration begins, the
terminal real-Quote reserve is apportioned by the same plan, every recipient is
paid its Meme and Quote as coins, and only the pool's share is handed to the
adapter, so nothing is custodied or claimed afterwards.
Only a regulated Quote whose deny list names a destination can make that
transfer fail, which strands the launch; the founder accepted that risk.
`LaunchCreated` carries the complete plan, the pool tier, the LP-fee split,
and the opening-round length, one `MigrationAllocationPaid` records each
payout, the migrators' `VaultCreated` records the vault, pool, and position
identities with the split, the residuals it keeps, and the position's liquidity,
and `Migrated` records the handoff and disposal amounts. Each LP-fee collection's `FeesCollected`
records Blast's share and every part of the split, `AutoLiquidityAdded`
what went back into the position, and `BuybackBurned` each buyback. See
[ADR 0088](decisions/0088-reusable-launch-accounting-and-atomic-migration.md) and
[ADR 0089](decisions/0089-migrators-own-post-migration-and-start-launches.md), and
[ADR 0091](decisions/0091-fee-split-buyback-and-burn.md).

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
The creator starts the launch through one admitted migration adapter's `new`,
which validates the creator's pool tier against its venue and calls
`launch::new` with the adapter's witness. That returns a `LaunchInitializer`
with no abilities: only the starting adapter's witness can borrow its treasury
cap, which the adapter uses to prepare its venue before any Meme can leave the
launch (the Cetus adapter reserves pool creation). The creator sets the
graduation target, allocation plan, LP-fee split, and optional opening round, and
`finalize` checks them all. Because a generated package's initializer cannot
read launch policy, starting checks the decimals, the Quote, and the adapter
against the current policy, and finalization checks the Meme symbol against its
32-byte bound and, since a ticket may come from an older launchpad version, the
sell-burn rate and the whole minted supply again, then consumes the treasury cap into the
selected mode, so no mint authority survives finalization. The native `Currency` is delivered to the Coin Registry
address, and completing its registration is permissionless; intake needs it.
The creator recipient may be a wallet address or an opaque Blast account
commitment and may differ from the launcher. The native metadata cap never
leaves `Launch`. The creator claim issues a `CurveFeeCap<Meme>` for curve fees
and a `BlastMetadataCap<Meme>` for metadata updates through the launch; a
creator administrator can reassign each independently
([ADR 0082](decisions/0082-revocable-creator-and-lp-fee-capabilities.md)). The
creator always keeps the curve-fee cap: after migration it also claims the
creator's LP-fee share from the migrators' `LpVault` and changes the split
([ADR 0089](decisions/0089-migrators-own-post-migration-and-start-launches.md)).
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
[OpeningRound ->] Live -> MigrationReady -> Migrated
```

- `OpeningRound`: only when the creator set one. Bids join one pot, the
  creator's before share included, until the round's end after share; nothing
  trades. Anyone then settles it: one curve purchase with the whole pot, whose
  Meme and refunded Quote anyone may deliver pro rata to each bidder, in any
  later state.
- `Live`: the curve accepts buys and sells while enforcing slippage, fee, and
  reserve rules. Without an opening round, the owner may `buy` before the launch
  is shared; sell-designated burn waits in a pending balance.
- `MigrationReady`: a buy or the round's settlement reached the target, closed
  trading, and returned excess Quote; a buy before sharing may do this. Only the
  adapter whose witness the launch stored can migrate it.
- `Migrated`: set by the one `migrate` call, which also completes terminal
  disposal.

Every transition is single-use and evented.

## Migration boundary

The historical contracts correctly treated migration as a typed, one-time
handoff. V2 retains that property but narrows it:

1. An exact-target buy returns excess Quote and closes trading.
2. The adapter calls `migrate` with its sealed witness. Core verifies the
   witness type the launch stored, pays every recipient, burns the curve's
   unsold Meme and the pending sell-burn (or sends them to `@0x0` under a fixed
   supply), marks the launch `Migrated`, and hands off only the pool's Meme and
   Quote.
3. The adapter seeds the pool and installs the position, which must hold
   liquidity, in the migrators' sealed `LpVault` with the launch's LP-fee split,
   keeping any residual there. Any failure rolls back the whole transaction.
   From then on the migrators own the position and its fees.

Incomplete adapters never ship as aborting production functions. An unavailable
venue stays outside the release. A venue whose dependency cannot yet be pinned to an
immutable commit is a **release gate on that adapter, not a reason to omit its
design**.

Every adapter creates a fresh pool. Where anyone holding Meme could create the
pool first (Cetus), the adapter reserves creation while starting the launch,
before the curve opens. No adapter adopts a pool someone else created. A
mismatch is an atomic abort that leaves the launch `MigrationReady` with every
balance in place. The initial price is derived from the terminal atomic
reserves and is never a configured constant. See
[decisions/0010-migration-and-venue-adapters.md](decisions/0010-migration-and-venue-adapters.md).

## Future chain parity

Any future chain implementation must preserve:

- lifecycle transitions and authorization outcomes;
- quote, fee, allocation, and migration arithmetic;
- slippage, deadline, opening-round, pause, and limit behavior;
- event meaning and reconstructable state;
- error categories, even when numeric representations differ.

Chain-specific differences are expected for ownership, transaction composition,
gas, token behavior, address representation, and upgrade mechanics. Record each
intentional semantic difference in an ADR and in shared differential vectors.

## Upgrade posture

Upgradeability is a product/security decision, not a default convenience.

- Sui: Blast's canonical `Publisher` and raw `UpgradeCap` enter one shared
  `PackageAdmin` after module/package provenance checks. A live `AdminWitness`
  authorizes an exact digest under the cap's compatible policy, which no path
  narrows (ADR 0088); the native receipt then commits against the same cap and
  advances the generation, and `make_immutable` is the deliberate end of
  upgrades. A future governance design retires the routine-admin package path
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
