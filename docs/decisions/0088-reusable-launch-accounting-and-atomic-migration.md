# 0088: Reusable launch accounting and atomic migration

- Status: accepted; amended by [0089](0089-migrators-own-post-migration-and-start-launches.md)
  (recurring LP-fee routing and policy move to the migrators, launches start in the adapter
  through a launch initializer, and the creator chooses the pool tier)
- Date: 2026-09-22
- Revised: 2026-09-22, rewritten in place after the founder rulings of the same day, then
  amended the same day after the real Cetus and Bluefin bytecode was run locally against the
  migration seam (migrators stay upgradeable; the ticket binds its adapter; the adapter supplies
  the pool ID); amended 2026-09-23 to remove the nonconforming Aftermath, MMT, and Turbos adapters,
  then to record the venue-operator trust assumptions and the migrators upgrade-policy rule;
  amended 2026-09-23 again for the owner's rulings (the upgrade finalizer checks the version
  first; Bluefin receives an empty Meme icon; launch intake bounds the Meme symbol at 32 bytes;
  launchpad policy narrowing is removed)
- Supersedes: [0036](0036-fixed-nine-decimal-generated-memes.md),
  [0068](0068-compact-lp-fee-principal-snapshot.md),
  [0081](0081-separate-lp-fee-share-policy.md), and
  [0083](0083-migrators-own-lp-fee-policy-and-authority.md)
- Amends: [0001](0001-sui-package-and-module-layout.md),
  [0007](0007-acl-pause-and-versioning.md),
  [0015](0015-protocol-authority-and-x-signer-state.md),
  [0022](0022-dual-asset-fee-ledger-and-claims.md),
  [0032](0032-admin-authorized-upgrade-cap-custody.md),
  [0034](0034-remove-premature-governance-cutover.md),
  [0035](0035-initializer-finalized-meme-supply.md),
  [0042](0042-key-only-shared-launch.md),
  [0043](0043-versioned-launch-trading-and-atomic-migration.md),
  [0046](0046-witness-authorized-migration-redemption.md),
  [0054](0054-v3-dex-migrators-and-locked-lp-fees.md),
  [0059](0059-production-launchpad-abi-and-sdk-parity.md),
  [0063](0063-aftermath-weighted-pool-migrator.md),
  [0067](0067-retire-full-sail-migrator.md),
  [0069](0069-consolidate-launch-graduation-and-move-migration-math.md),
  [0075](0075-independent-holder-fee-distributor.md),
  [0079](0079-compact-launch-state-and-events.md), and
  [0082](0082-revocable-creator-and-lp-fee-capabilities.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `blast-v2@94e9a54` | `94e9a5419bac7d1860136ee32273a1802d5becf9` | `interest-protocol/blast-v2-contracts` |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | `MystenLabs/sui` |
| Cetus CLMM v15 | mainnet package `0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084` (`factory`, `pool_creator`, `config` bytecode) | Cetus |
| Bluefin Spot v17 | mainnet package `0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c` (`config`, `pool` bytecode) | Bluefin |

## Context

The unpublished launchpad lineage fixes Meme precision at nine decimals,
selects one administrator-pinned venue tier, and routes recurring LP fees
through migrator-owned creator/protocol authority. That design cannot express
reusable 6-or-9-decimal launches, immutable one-time allocation tables,
creator-selected graduation targets, protected public buys, or independent
per-asset recurring routes paid to their destinations.

A separate release published `blast_admin` and the Boosts core, products, and
Aftermath adapter packages to mainnet on 2026-09-22; their package IDs are in each
package's `Published.toml` and the release records under
`deployments/sui/mainnet/`. The deployment search was repeated after that
release, on 2026-09-22. None of the four affected packages (`blast_fun`,
`blast_fun_migrators`, `blast_fun_distributor`, `meme_template`) has a
`Published.toml`, each manifest keeps its `0x0` placeholder address, and the
release records name only the admin and Boosts packages. Read-only GraphQL
queries for the configured deployer found only those mainnet publications, none
containing an affected package's modules, and no transaction on testnet or
devnet. This decision therefore authorizes a coordinated pre-publication
lineage only. Discovery of any affected package, `UpgradeCap`, or shared object
on chain stops implementation and requires a separate migration decision.

`blast_admin` was made immutable in its publishing transaction. The launchpad
and migrators link against that published package and use its API as
published; changing it would mean a new package, not an upgrade.

## Decision

Founder rulings of 2026-09-22 shaped this decision: contracts stay minimal,
payouts are pushed rather than custodied, and nothing re-checks what a type
already guarantees. Nothing is published, so every layout, signature, and event
below is a pre-publication choice with no migration path.

### Package and dependency boundary

`blast_fun` owns reusable token, launch, allocation, route, and lifecycle
accounting. `blast_fun_migrators` depends inward and owns venue calls, position
custody, and collection. Core never imports a venue package. The distributor is
an ordinary payout destination. The generated Meme template and the existing
vesting package compose with the single launch path; neither creates a
project-specific mode.

Launchpad, migrators, distributor, and Meme template are one coordinated
pre-publication release. Their versions, dependency pins, ABI checks, and
consumer cutover are a single release gate. Old and new accounting lineages may
not mix. Every entry that mutates shared state checks its package's current
version object first; the owned-ticket functions (construction, binding, and the
treasury-capability borrow) take no version. The final post-release custody is
package-specific and keeps the accepted authority boundaries:

| Package | `Publisher` / `UpgradeCap` posture | Operational version gate |
| --- | --- | --- |
| launchpad | ADR 0032, amended: canonical `Publisher` and raw `UpgradeCap` are permanently wrapped in shared `PackageAdmin`, with no policy-narrowing path (owner, 2026-09-23), because a narrowed cap could never commit and advance again; `make_immutable` remains the deliberate end of upgrades | shared launchpad package version is checked first; the upgrade finalizer checks the next generation before the role |
| migrators | canonical `Publisher` and raw `UpgradeCap` enter the migrators' shared `PackageAdmin` and stay there, with no policy-narrowing or immutability path: the package remains upgradeable so it can relink when a venue raises its version gate or a launchpad cutover advances its package version | migrators package version is checked before venue or core state; the upgrade finalizer checks the next generation before the role |
| distributor | ADR 0075 unchanged: the owner retains the native `UpgradeCap`; singleton `AdminCap` controls pause and stored-version migration | every entry checks the distributor `Version` first, then pause |
| each generated Meme package | no `Publisher` is claimed; the publisher keeps the `UpgradeCap`, so the package stays upgradeable unless the publishing transaction makes it immutable | one-time initializer; the Sui verifier forbids packing the one-time witness in any later version |

A generated package that stays upgradeable exposes no protocol authority: its
supply becomes fixed or burn-only at launch intake, its `MetadataCap` lives
inside `Launch`, and no deny cap exists. The publisher can add unrelated code
under the package ID; that is a trust signal, not a security boundary.

### Supply, allocation, and rounding

Each generated Meme selects an administratively allowlisted precision,
initially six or nine decimals, and creates exactly one billion whole tokens;
a precision whose supply exceeds `u64` aborts. The generated package's
initializer mints that supply into the launch ticket, which keeps the treasury
capability until launch intake. Intake checks that the ticket balance and the
whole minted supply are exactly the canonical supply, then consumes the
capability into the ticket's fixed or burn-only mode, so no mint authority
survives intake. Immutable Meme and terminal-Quote
allocation tables each total 10,000 basis points and share at most sixteen
named channels. Channel zero is the curve and appears only in the Meme table;
exactly one channel is the liquidity channel.

All balances are atomic `u64` values; products widen to `u128`. Allocation and
recurring routing protect the Blast amount first with ceiling division, give
every other entry its floor, and then award the residue one unit each by
descending fractional remainder, breaking ties by ascending channel ID (routes:
ascending destination). Every operation conserves each asset exactly.

### Launch lifecycle and authority

Launch construction is an owned, key-only composition phase. It creates the
launch's one fee router, may make one ordinary curve purchase that cannot
graduate, may pass the returned Meme to the existing vesting package, and then
shares the launch and its router in one terminal call. Public time and
optional purchase protection begin at share; protection counts gross public
curve output per sender and never claims to constrain wallet balances. Despite
its name, the per-transaction limit bounds each purchase call on its own: one
transaction can repeat purchases, and only the cumulative per-sender limit
bounds their total.

The one-time witness makes each generated Meme type unique, so at most one
`Launch<Meme, Quote>`, one `FeeRouter<Meme, Quote>`, one
`RouterConfigCap<Meme, Quote>`, and one `Migration<Meme, Quote>` can ever exist
per Meme type. Core therefore stores no cross-object binding the type already
proves: the router records only which launch created it, the configuration cap
carries no router ID, and launch and router never re-check each other.

| Capability | May do | Must not do | Issuance and sink |
| --- | --- | --- | --- |
| `RouterConfigCap` | replace Pending routes; with the bound adapter's witness, settle and replace active routes | collect, migrate, move value, or change Blast shares | one per launch, wrapped in the launch until the authenticated creator claim or a creator-administrator takeover delivers it; `key, store`; no recovery or reissue |
| existing `CurveFeeCap` | existing creator curve-fee claim | any launch, migration, or router authority | unchanged |
| existing `BlastMetadataCap` | existing metadata authority | accounting or migration authority | unchanged |

There is no core role registry, delegate set, recovery, proposal queue, or
built-in delay; a creator who wants a delay places the cap in external custody.
A permissionless migration caller receives no balance, position, residual,
migration value, or capability.

### Venues

Before intake the creator binds the launch ticket to one adapter and one Quote.
Only the adapter module can construct its witness, so binding always runs
adapter code, and binding and every treasury-capability borrow require the
administrative allowlist to name that witness, so only admitted adapter code can
borrow the ticket's treasury capability and no Meme exists outside the ticket
before intake; removing an adapter from the allowlist also stops it borrowing
for tickets already bound to it. Admitting an adapter requires that it never
release Meme minted through the lent capability, even transiently. Intake admits
the ticket only if it was bound for the launch's Quote and the allowlist still
names the bound witness, and the launch stores that witness type. The allowlist
rejects primitive, vector, and `0x1`/`0x2` framework types, because a migration
witness receives the launch's liquidity principal. Tiers come from the
migrators' administrator-pinned `venue_config` (ADR 0057): the Cetus adapter
reserves its pinned tier while binding and migrates at the reserved tier, and
the Bluefin adapter reads and validates its tier at migration. There is no venue
selection object, creator tier choice, or per-launch tier authority.

An adapter whose venue must be prepared before any Meme can reach a third party
prepares it while binding. Cetus lets anyone holding a coin create that coin's
pool at a free tier, and its create aborts when the pool exists, so a buyer could
otherwise create the pool first and strand the launch in `MigrationReady`.
Cetus also lets the holder of the coin's treasury capability mint the coin's
single `PoolCreationCap` and register the pair and tier so that only that cap
or Cetus's pool-manager role can create the pool; the Cetus adapter does this
for the bound Quote while binding and migrates at the reserved tier. Cetus's
registration does not check whether the pool already exists; admitted binding
is what guarantees it cannot. The pool-manager role belongs to the Cetus
operator, so the reservation trusts that operator: if the role creates a
reserved pool first, that launch's migration aborts and it stays
`MigrationReady` until a migrators upgrade adds a recovery path.
Bluefin keeps no pool registry and needs no preparation; it charges its
pool-creation fee only in SUI at the exact configured amount, so its route
takes that fee as a caller-supplied SUI coin. Bluefin also records the
transaction sender as the new pool's manager. Migration stays permissionless,
so whoever migrates holds that role; it can fund reward emissions with its own
coins, extend existing emissions, and hand itself on, and it reaches no
principal, position, fee, price, or tier. The owner accepted this on
2026-09-22, as memez-gg's Bluefin migrator does. The Bluefin route passes the
Meme `Currency`'s fixed symbol into the pool but an empty icon URL, as Cetus
does (owner, 2026-09-23): Bluefin's `Position` stores the URL it is given, and
the `BlastMetadataCap` holder can lengthen the Meme icon URL to about 256 KB,
which would push the `Position` past Sui's object size limit and hold the
launch in `MigrationReady`. The pool name Bluefin also stores twice in every
`Position` is built from the Meme symbol, which is fixed at creation, so launch
intake rejects a symbol longer than 32 bytes (owner, 2026-09-23). The Quote
side of the pool name and coin B's icon come from the admitted Quote's
`Currency`, so an admitted Quote's issuer is trusted like the venue operator:
lengthening that Quote's symbol or icon would hold its Bluefin launches in
`MigrationReady` until reverted or until a migrators upgrade. Neither adapter collects venue rewards, so any
reward a venue credits to a custodied position is not collected by these
adapters; only a migrators upgrade adding a collection path could recover it.

Venues gate callers by package version: Cetus aborts once its configuration
version exceeds the calling code's, and Bluefin requires the exact version. The
migrators package therefore stays upgradeable, so each venue upgrade is met by
relinking the adapters rather than stranding launches and routers. Committing a
migrators upgrade always advances the migrators generation, so every migrators
upgrade uses the compatible policy and bumps both compiled generation constants,
the current and the next; a build that keeps them freezes the package, because
its version check then rejects every later upgrade authorization. The migrators
custody therefore has no policy-narrowing or immutability path.

Cetus and Bluefin are this lineage's only adapters, and their witnesses are the
only ones the migrators package defines. No production witness is admitted until
its adapter's atomic migration route exists and is reviewed, because a launch
that snapshots an adapter without one reaches `MigrationReady` with no way out.
Aftermath, MMT, and Turbos lack the atomic migration and router collection
protocol, so they are removed before publication with their witness types,
interfaces, and dependency pins; no release can admit them. A future adapter
first defines and tests its pinned-tier rule, its ticket binding with any venue
preparation, `LpVault` custody with no exposed withdrawal path, its atomic
route, collection, settled route update, and event conformance; there is no
generic plug-in constructor. Each adapter must prove its venue accepts the
smallest and largest liquidity amounts and price ratios that intake admits.
That proof covers only the admitted Meme precisions, so admitting a new
precision requires rerunning that proof on each enabled venue first.

### Graduation target

A launch selects its own graduation target; it is the threshold for leaving the
launchpad, and DEX-side numbers are best effort. The curve caps the final buy so
the terminal Quote reserve equals the target exactly. Intake rejects a target
whose liquidity-channel Quote share rounds to zero, so every launch that reaches
`MigrationReady` has a nonzero liquidity handoff.

### Atomic migration

Graduation is one programmable transaction and one linear value:

1. `begin_migration<Witness>` checks the version, `MigrationReady`, and the
   stored witness type; splits the liquidity channel's Meme and Quote; sets
   `Migrating`; and returns both balances with one
   `Migration { source_meme, source_quote }` that has no abilities.
2. The adapter creates the pool, installs the position in the migrators'
   sealed `LpVault`, and keeps any residual there.
3. `complete_migration<Witness, Vault: key, Position: key>` takes the vault and
   position objects, the pool ID, the same witness, the migration value, the
   supplied amounts, the residual balances, and the liquidity. The adapter reads
   the pool ID from its venue position, because Cetus shares a new pool without
   returning it. Completion requires `supplied + residual == source` for both
   assets and positive liquidity, activates the router against the vault and
   position objects' own IDs and that pool ID, pays every non-liquidity
   allocation to its immutable destination, disposes of the pending burn and
   curve remainder, and commits `Migrated` last.

Consuming the migration value proves the launch is `Migrating`, which exists
only inside that transaction; any abort restores `MigrationReady` and every
balance. The allocation payout re-apportions both tables from their original
totals, and the launch's pooled balances must end empty. Adapters derive the
supplied amounts from venue balance changes, never from caller arguments.

### Recurring routing

`FeeRouter` holds no balances. Activation freezes the default-or-partner Blast
shares for each asset and the settlement binding: the adapter witness type and
the vault, pool, and position IDs. A collection takes the adapter's witness and
those three IDs, pays the protected protocol share to the live protocol
destination in `LpFeePolicy`, and pays every route destination its exact amount
in the same call. A zero collection moves nothing and emits nothing.

Routes are a flat `Routes { meme, quote }` of `Route { destination, bps }`,
sorted by destination, naming at most sixteen distinct destinations across both
tables, each table summing to 10,000. Pending routes change immediately under
the configuration cap. Active routes change only through
`settle_and_update_routes`, which pays the supplied collection under the current
routes and then commits the next generation, so fees accrued before a change
always follow the old routes. An identical proposal aborts before any payout.

### Push payouts and their accepted risk

Every payout is a `Coin` transfer to an address or object ID; core never calls a
destination. Receivers that are objects use `transfer::public_receive`; the
distributor receives pushed coins that way. Coins pushed to an object with no
receive path are lost, and that is the sender's configuration choice.

A transfer fails only when the Quote is a regulated coin whose deny list names
the destination, or whose global pause is on (deny list v2 in `sui@06734f6`
`crates/sui-framework/packages/sui-framework/sources/coin.move`). On
2026-09-22 the founder accepted in writing that, with such a Quote, a
deny-listed allocation destination strands a `MigrationReady` launch (every
migration transaction aborts and trading stays closed), and a deny-listed route
destination blocks that router's collections and settled updates. Skipping or
retaining undeliverable payouts would bring back the channel custody this
decision removes.

### Events, errors, and guard order

Package source owns exact layouts and signatures; tests and ABI artifacts pin
them. Launchpad keeps its wrapped event envelope. Events follow successful
mutation, carry atomic amounts and BPS, and replay without mutable-state reads:
launch creation carries the complete plan and Meme partition, router creation
and activation carry the routes, binding, and frozen shares, migration records
each nonzero allocation payout and the reconciliation, collections carry gross,
protocol, and per-route amounts aligned to the routes, and route and policy
changes carry old and new values. `blast_fun::errors` and its registry test own
the current sequential codes under the greenfield policy in `AGENTS.md`.

Guards run cheapest-first before any mutation: version, lifecycle, witness or
authority, shape, arithmetic and slippage, then mutation, then event. Migration
completion checks the witness and conservation before activation, payout,
disposal, and `Migrated`. A settled route update checks the version, the active
settlement binding, and a changed proposal before paying the old routes.

## Alternatives considered

**Project-specific `$UNDEAD` branch.** Rejected because token precision,
allocation, protection, migration, and routing are reusable protocol concerns.

**Keep the migrator LP-fee authority alongside `FeeRouter`.** Rejected because
two live recurring-fee paths let fees leave the committed routes. The legacy
vault fee ledger and its collectors are removed before any provider migration
ships.

**Custodied channels with claim capabilities.** Rejected by the founder: channel
caps, balances, claims, and cleanup add code and review surface, and push
payouts deliver the same allocations with less state.

**Immutable migrators.** Rejected on 2026-09-22 after the venue bytecode was
run locally: a migrators package linked to one venue version stops migrating and
collecting at that venue's next version bump, and every launchpad cutover would
strand launches and routers bound to adapters that cannot relink.

**Adopting a pre-created Cetus pool.** Rejected: the pool's creator sets its
price, so adoption moves launch value at that price or needs a repair swap the
creator can front-run. Cetus's own creation reservation removes the pool before
it can exist.

**Cross-object ID bindings.** Rejected because the one-time-witness type already
makes the launch, router, configuration cap, and migration value unique per
Meme type; the bindings could only fire in tests that forge duplicate launches.

**Allocation and venue-selection digests, creator tier selection.** Rejected by
the founder; events carry the canonical plan and routes, and adapters pin tiers.

**Administrative cap recovery or built-in governance.** Rejected because it
would widen authority beyond the capability's named concern.

## Consequences

- The affected packages undergo coordinated pre-publication object and ABI
  replacement; no in-place published-layout mutation is authorized.
- Curve pricing, curve-fee ownership, creator-recipient semantics, metadata
  authority, and distributor Merkle behavior remain intact except at the
  replaced seams.
- No old lineage was published, so retirement is source removal before
  release: the migrators' legacy LP-fee ledger and its collectors leave the
  source before the replacement package set is published; then SDK, indexer,
  frontend, and operators cut over to the new package IDs, and each package's
  `Publisher` and `UpgradeCap` take the posture in the table above.
- SDK, indexer, and frontend work stays outside this repository, but production
  release is blocked until each consumer proves compatibility with the final
  ABI, errors, events, and replay model.
- Maximum allocation payout and collection shapes, and each adapter's migration
  transaction, require measured evidence before release.

## Verification

- Repeat the deployment search and stop on any package or object lineage.
- Pin six- and nine-decimal supply, protected-first rounding, exact
  conservation, route capacity (zero destinations fail the sum; one and sixteen
  succeed; seventeen abort), and guard-precedence tests.
- Prove that the migration value has no abilities, that settlement matches
  exactly, that a failed migration transaction commits nothing, that the
  position has no exposed withdrawal path, and that the caller receives nothing.
- Prove each adapter's tier validation and its smallest and largest admissible
  amounts at migration against the venue's real bytecode, including the Cetus
  reservation and a third party's attempt to create the pool first.
- Replay every lifecycle and accounting event and compare all getters.
- Run launchpad, migrator, distributor, Meme-template, ABI, source-boundary,
  dependency-pin, test, programmable-transaction, and diff gates on one
  revision. Live ABI and dev-inspect checks remain environment-controlled
  release evidence.
