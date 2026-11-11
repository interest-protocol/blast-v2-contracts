# 0137: Shared launch stack: core, vault, and venues

- Status: proposed
- Date: 2026-11-04
- Owner decision: 2026-11-04, Jose accepted the design below with one exception (D7: each
  product keeps its own Quote allowlist and partner list)
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md) (dependency direction
  becomes symmetric), [0097](0097-one-singleton-acl-with-typed-roles.md) (one product role set,
  generic package roles), [0099](0099-standalone-overflow-presale.md) (presale no longer keeps its
  own copies), [0104](0104-external-presale-migrators-and-vendor-packages.md) (vendors redeem the
  hand-off), [0106](0106-presale-partners.md) (the partner also shares the token fee), and
  [0134](0134-delayed-administration-pause-and-table-acl.md) (one generic package administration;
  vault and venue postures)
- Supersedes: the earlier migrators, presale vault and venue, Bps, partner-cut and package-administration
  records, retired on 2026-11-05
- Design record: the 2026-11-04 Fable architecture review

## Context

A coin launches in one of two products: the launchpad (`blast_fun`, a bonding curve) or the presale
(`blast_presale`, an escrow sale). Both end the same way. When the sale's target is reached, Blast
and the named recipients are paid, the remaining supply and Quote seed a DEX pool, the LP position is
burnt or locked in a vault, and the vault keeps collecting LP fees for Blast, partners, recipients
and holder rewards.

ADR 0099 forbids presale from importing the launchpad, and the vault and venue adapters live in the
migrators package, which imports the launchpad. Presale therefore cloned them. The
2026-11-04 review measured about 2,300 to 2,600 near-duplicate production lines across the launch
stack (about 15,200 production lines): two LP vaults, two holder-reward engines, two Merkle verifiers,
two Cetus and two Bluefin adapters, three package-administration and version modules, three governed
treasury destinations, two basis-point units, two fee-split models, and four copies of partner
hold-and-pay. Each copy carries its own tests and its own audit reading, and a Cetus or Bluefin
version bump forces an upgrade of both the migrators (vault, rewards and policy) and the presale
escrow.

The ADR 0134 stack is a fresh lineage that holds no user assets, so layouts, ABIs, events and error
codes may all change. No backwards compatibility is kept.

## Decision

Keep the two sale products separate and move everything they share below both of them. Products and
venues never import each other; they meet through sealed values from a shared core.

### Packages

| Package | Responsibility | Posture |
| --- | --- | --- |
| `blast_admin` | ACL, delayed primitives, and one generic package version, pause-bit and 48-hour upgrade-custody implementation for every upgradeable package | immutable |
| `blast_partners` | partner identity, share terms, and payment | immutable |
| `blast_core` (new) | the shared money vocabulary: basis points, exact apportionment, recipients and the one payout primitive, the fee-split model, the protocol-fee ledger with the partner cut, the one treasury destination, Merkle proofs, the migration hand-off, the owner proof, and the shared product roles | immutable |
| `blast_fun` | the bonding-curve sale; `migrate` returns the hand-off | compatible-upgradeable |
| `blast_presale` | the escrow sale; `migrate` returns the hand-off | compatible-upgradeable |
| `blast_vault` (new) | permanent LP custody for both products: one fee split, Blast's share, the partner hold, holder-reward rounds, auto-LP and buyback balances, owner claims | compatible-upgradeable, slow cadence |
| `blast_venues` (new) | Cetus, Bluefin and Aftermath for both products: pool-creation preparation, hand-off redemption, pool creation and seeding, position locking, fee collection, auto-LP, buyback swaps | compatible-upgradeable, upgraded on venue version bumps |

`blast_fun_migrators` is removed. Each boundary is a real one: `blast_core` against `blast_vault`
separates immutable value types from upgradeable custody, `blast_vault` against `blast_venues`
isolates the volatile external venue dependencies from custody, and the two products keep their
separate custody, lifecycle and upgrade risk (ADR 0099).

Dependencies point inward only. Both products and the vault depend on `blast_core`; the venues depend
on `blast_core` and `blast_vault`; vendor migrators depend on `blast_core` and `blast_presale`. No
product imports the vault or a venue, and no venue imports a product.

### Transaction context in upgradeable lifecycle APIs

Reserve a trailing mutable `TxContext` in the upgradeable products' construction, sharing and
settlement transitions, venue preparation, vault construction and reward-round closure, even
when the implementation does not use it yet. Compatible upgrades cannot add an argument to an
existing public function. Direct Move callers forward their context; Sui injects it into PTB
calls. An unused context adds no authorization or PTB isolation. This decision applies to the
unpublished launch stack; Blast SUI and published Boosts are outside its scope.

### One implementation per money concept

- **Basis points and apportionment.** One `Bps` and one exact largest-remainder apportionment with an
  optional index that rounds up for Blast.
- **Recipients and payout.** One `Recipient` with optional vesting and one pay-or-vest primitive.
  Launch recipients, presale raise and token recipients, and vault address routes all use it.
- **Fee split.** One `FeeSplit` of typed routes (an address, the owner, auto-LP, holder rewards,
  burn) summing to 10,000 basis points under one validation and one apportionment.
- **Protocol fees and partners.** One ledger accrues Blast's fees, splits creator and protocol
  shares, and pays the treasury, holding Blast's part when a partner is bound until anyone pays the
  partner its cut. It is the only Blast caller of `blast_partners` payment.
- **Treasury.** One governed protocol destination replaces the launchpad, migrators and presale
  destinations and the migrators' return of residuals to the treasury administrator.
- **Merkle.** One verifier, with the leaf domain fixed per purpose (holder rewards, presale
  allowlists), not per product.
- **Holder rewards.** One round engine in the vault, paying Meme, Quote or both.
- **Package administration.** One generic version object with pause bits and one generic 48-hour
  upgrade custody in `blast_admin`, typed by each package's marker. Each product keeps only its own
  unpause guard over its own configurations.

### Sealed hand-off and atomic migration

A venue first prepares the coin while its supply is still unminted: it reserves any venue
pool-creation capability against the coin's `TreasuryCap`, records the pool tier, and returns a
non-droppable venue ticket sealed by its own witness and typed by the exact Meme and Quote pair it
prepared, so a ticket cannot start a sale of another coin or Quote whose migration would then find
no reserved pool authority. Preparation takes the coin's `TreasuryCap`, so only the coin's holder
can record its venue state. The product's `new` redeems the ticket, checks
its venue against its own delayed migrator allowlist, and stores it. The ordering is the same for both products:
the launchpad's coin template hands the creator the `TreasuryCap` beside the launch ticket, as a
presale creator already holds it, because a programmable transaction cannot pass a reference one
call returns into another; `launch::new` takes the cap by value, and the ticket's supply recheck at
`destroy` still guarantees the exact supply. Amended by
[0138](0138-sealed-treasury-caps-and-venue-admissions.md): the cap travels sealed under the
product's witness, and a venue borrows it only with that product's admission.

At migration the product runs its own checks and payouts, then returns a non-droppable `Migration`
hand-off carrying the pool's Meme and Quote, the stored venue, and the new vault's terms, sealed by
the product's own witness. Only the stored venue's witness can redeem it. The venue creates the pool
at the price the two balances imply, locks or burns the position, and creates the vault in the same
call, so the transaction completes whole or not at all. A stranger cannot forge a vault that claims
a launch, and an unadmitted venue cannot take a launch's liquidity.

The vault keeps one delayed list of admitted witnesses. `vault::new` requires both the calling
venue's witness and the witness that sealed the vault's terms to be on it: the launchpad and
presale are issuers, and each venue is a venue and, for the standalone vaults whose terms it seals
itself from Blast policy, an issuer. The list does not distinguish the two roles; every entry is
Blast-reviewed code, and products never create vaults themselves. Because `VaultTerms` is `copy`, an admitted venue obtains
terms only from the migration it redeems or by sealing its own, and never accepts them from its
caller; otherwise anyone holding a sale's terms could create a second vault for it. Gating issuers
keeps a stranger package, which could otherwise seal its own terms and migrate through an admitted
venue, from creating Blast vaults with a Blast share and partner of its choosing.

Each product keeps its own creator authority (the launchpad's reassignable curve-fee cap, the
presale's transferable cap). A product proves ownership to the vault with a non-droppable owner proof
sealed by its witness, so the vault imports neither product. Terms, owner proofs, and protocol-fee
ledgers borrow the originating object's `&UID` when issued and store its ID. The UID establishes
access to that object's identity; the private package witness identifies the issuer, and the
product still checks creator authority before issuing an owner proof. A bare ID remains suitable
when naming another object, such as an admitted cap or a pool, rather than attesting an origin.

### Authority, posture, events and errors

- The shared product roles (`TreasuryAdmin`, `FeeAdmin`, `ListingAdmin`, `AdapterAdmin`,
  `RewardsAdmin`, `BuybackAdmin`, `CreatorAdmin`, `ClaimSignerAdmin`, `CancelAdmin`) are declared
  once in `blast_core`. Package roles (`UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin` and the package's
  `CancelAdmin`) are generic over the package marker in `blast_admin`, so each package's grants stay
  separate.
- A venue needs two admissions: each product's own venue allowlist, which lets new sales name it,
  and the vault's witness list, which also lists each product's package witness as an issuer.
  Each product checks its venue list when creating a sale and issuing preparation admission
  for a sealed-cap borrow. Removing a venue from a product's list prevents new sales but does
  not change an existing sale's selected venue.
  Migration redeems that sale's sealed hand-off, and vault construction checks the live vault
  registry for both the venue and the issuing product. The vault therefore lists the products
  and a venue before any product admits it. Removing either from the vault registry strands
  migrations that need it until it is listed again; Blast reserves that removal for a venue or
  issuer found unsafe. Product migration pause remains a separate control over existing sales.
- Launches, presales and vaults have derived object IDs, so a client computes each from the coin
  type or the sale without an indexer: a launch from an id-only `LaunchRegistry` and
  `LaunchKey<Meme>`, a presale from `PresaleRegistry` and `PresaleKey<SaleToken>`, and a vault from
  the `VaultRegistry` and `VaultKey { issuer, origin }`. Keying the vault by the sealing witness as
  well as the sale keeps each issuer in its own namespace, so no venue can claim another issuer's
  sale's vault address first. A second claim of a key aborts, which makes one launch or presale per
  coin and one vault per sale structural; a presale that is cancelled keeps its coin's key, so that
  coin can never be presold again. Holder-reward rounds keep ordinary IDs; their claimants
  read the round from its publication event and its off-chain manifest.
- Products start fully paused and use pause bits create 1, trade or commit 2, migrate 4. The vault
  pauses only administrator operations; collection, owner claims and reward claims never pause. The
  venues have no pause bits: the product's migration bit gates migration, and collection must never
  freeze.
- Every package emits raw events from an `events` module; the launchpad's `Event<T>` envelope is
  dropped. Every package uses a numeric `errors` registry renumbered from zero, with exact-abort
  tests.

### Owner decisions

The owner accepted these behaviour changes on 2026-11-04:

1. **One vault and one fee-split model.** Presale vaults gain owner, auto-LP and burn routes;
   launchpad vaults may name address routes. Holder rewards accrue in both assets and rounds may pay
   either. The presale's routing of holder Meme to the treasury ends.
2. **Blast's LP share** is snapshotted at vault creation and changeable per vault after 48 hours'
   notice, the presale's earlier model. The launchpad's live defaults and per-coin overrides end,
   so Blast can no longer change every vault's share in one proposal.
3. **The partner takes its cut of every Blast fee**, including the presale token fee that ADR 0106
   excluded.
4. **Residuals.** A launch vault's migration residuals go to the treasury at vault creation, with
   the partner cut; a presale's stay claimable by its owner. One residual policy, executed once.
5. **Every venue for every product.** Aftermath, auto-LP and buyback become available to both; each
   product's migrator allowlist decides what it admits.
6. **Launchpad recipients may vest**, like presale recipients.
7. **Rejected: one Quote allowlist and one partner list.** Each product keeps its own Quote allowlist
   and partner acceptance list, so Blast can list a Quote or a partner for one product only.
8. **One product role set** for both products; the same administrator role governs both.
9. **One Merkle leaf domain per purpose**; the backend's manifests change their domain strings.
10. **One auto-LP side algorithm**, the margin-based one; Cetus compounding may differ by up to two
    atoms from today.
11. **No event envelope; numeric error registries everywhere.** On-chain abort messages are lost;
    the SDK maps codes.
12. **Unchanged:** the 2-hour round notice, the 48-hour fee-split notice, and the existing fee
    maximums. A vault's fee-split and Blast-share notices are fixed at 48 hours; no call changes
    them, so every change gives that notice.

## Alternatives considered

- **Merge the launchpad and the presale into one package.** Rejected: one generation and one upgrade
  for two products with different custody and failure modes (ADR 0099).
- **Presale depends on the migrators package.** Rejected: every migrators entry point takes
  launchpad types, so presale would couple to the launchpad lifecycle and still keep its vault.
- **Move presale's adapters into the migrators.** Rejected: the migrators would import both products
  and still carry two vault and two reward implementations.
- **Put the vault in the venues package.** Rejected: every venue version bump would re-ship custody.
- **Put money primitives in `blast_admin`.** Rejected: the governance package would grow money logic.
- **A generic venue plug-in object.** Rejected, as in ADR 0088: sealed witnesses and one hand-off
  type are enough.
- **Only share the holder-reward engine.** Considered first on 2026-11-04; it removes the largest
  copy but leaves two vaults, two venue layers and four partner payouts.

## Consequences

- Every concept the review found duplicated has one implementation, and the audit reads each money
  concept once. The review estimates the launch stack at about 10,700 production lines (about 27%
  fewer) and its tests at about 27,000 lines (from about 38,600), with more capability in both
  products.
- A Cetus or Bluefin version bump upgrades only `blast_venues`; no escrow or LP custody ships with it.
- A vault bug is fixed once for both products. A `blast_core` bug requires a fresh core and every
  package above it, as an ACL bug does today; the core is small, pure and property-tested, and its
  only shared objects change through delayed proposals.
- Immutable core enums (fee-split destinations, the residual policy) cannot gain variants without a
  new lineage, so their variant sets are chosen now.
- Owner actions on a vault take one extra PTB command (the owner proof); the SDK hides it.
- Each behaviour change above is proven with an old-against-new fixture run before its old code is
  deleted, and each implementation step deletes what it replaces in the same change.
- The SDK, the indexer decoders and the admin console change with the fresh lineage: new package
  IDs, hand-off and owner-proof PTB shapes, one vault and rewards event decoder, and one generic
  package-administration page.

## Implementation order

Each step is one reviewable change that compiles the workspace, passes the style and error-registry
gates and the affected tests, and deletes what it replaces.

1. `blast_admin`: generic package version and package administration.
2. `blast_core`: basis points, apportionment, recipients and payout, fee split and vault terms, the
   protocol-fee ledger, the treasury, Merkle, roles, events and errors.
3. `blast_vault`: the migrators vault and holder rewards ported onto core types, with a one-time
   differential fixture against today's launchpad and presale fee collections.
4. The hand-off and owner proof in both products. The existing venue modules redeem the hand-off
   and build `blast_vault` vaults in the same change, so both old vaults, both holder-reward
   engines, the LP-fee policy and the Merkle copies are deleted here, after the one-time
   differential fixture against them (owner decision, 2026-11-04).
5. `blast_venues`: Cetus and Bluefin from the migrators, Aftermath from presale, one venue math
   module, and standalone vault creation; the migrators package is removed.
6. The Aftermath DAO presale vendor redeems the hand-off.
7. Product slimming: both products adopt the generic version, core roles, numeric errors and raw
   events, and delete their copies.
8. Documentation, integrator references, deployment order, then the SDK, indexer and admin-console
   changes.

Steps 1 and 2 are independent; 3 and 4 need 2; 5 needs 3 and 4; 6 needs 4; 7 needs 1 to 5.

## Verification

- Exact-abort tests for venue mismatch at redemption, an unadmitted venue ticket at creation, and a
  hand-off or owner proof that is not consumed.
- Apportionment properties (sums preserved, the rounded-up index never loses a unit) and the existing
  graduation vectors reproduced on the core primitive.
- Partner-cut vectors equal to today's launchpad and vault outputs.
- Mainnet-fork PTB suites for launchpad, presale and standalone vaults on each venue, including
  preparation before supply leaves the ticket or `TreasuryCap`.

## Amendment 2026-11-05: one way to do each thing

### Context

Implementing steps 1 to 7 showed the stack above still had two ways to do several things: the
presale kept its own copy of the venues, the migrators package imported the launchpad, three
products carried their own package administration over `blast_admin`'s version and custody
primitives, a vendor wrapped the presale's version-gated calls, and a venue could also seal its own
vault terms. The owner asked on 2026-11-04 for one way to do each thing before the fresh publish
(epic #197). This amendment records what changed against the decision above.

### Decision

**Seven packages.** `blast_admin`, `blast_partners` and `blast_core` are published immutable.
`blast_fun` (launchpad), `blast_presale`, `blast_vault` and `blast_migrators` are
compatible-upgradeable. The per-coin templates and the one-off vendors sit outside the seven and
depend inward. Every boundary of the 2026-11-04 package review stays: everything in one package
exceeds Sui's 100 KiB package limit, and the vault stays apart from the venues so a DEX bump never
upgrades custody.

**`blast_migrators`, not `blast_venues`.** The one venue package is the existing `sui/launch/migrators`
directory under the name `blast_migrators`, the repository's own term (owner decision, 2026-11-04). The
earlier `blast_fun_migrators` name claimed one product and goes.

**Cetus and Bluefin only.** `blast_migrators` ships `cetus` and `bluefin` for both products. The
presale's venue copies, its venue configuration and its pool-price math are deleted; the seed price
and the seedable-price bounds both CLMMs share live once in `blast_core::migration`, the one package both the presale and the venues import. Aftermath
leaves the migrators and the presale (owner, 2026-11-04). The Aftermath DAO vendor
(`blast_aftermath_dao_presale`) is a plain venue over `blast_core` instead of a wrapper around the presale's version-gated calls: its `AdminCap` prepares a
sale token, binding the reservation to the issuer it names (the presale's package witness), and
returns the `VenueTicket` the presale redeems; its `migrate` takes the `Migration` from the PTB,
seeds the pool and pays the DAO fee to the partner's compiled treasury. It creates no vault, so only
the presale's creation policy admits it, never the vault registry. Because it imports no product, a
presale upgrade never strands it and its immutable publication costs nothing.

**Two-call migration through the PTB.** A product's `migrate` returns the sealed `Migration`; the
next PTB command passes it to the stored venue's `migrate`. Products and venues never import each
other, so a product upgrade forces no venue relink, and one venue serves both products.

**Standalone vaults are cut**, where a venue would have sealed its own vault terms. No caller existed, and sealing its own terms was the only reason
a venue would be an issuer. The vault registry therefore lists the two product package witnesses as
issuers and the venue witnesses as venues; a venue obtains terms only from the `Migration` it
redeems. Adding standalone vaults later is a migrators upgrade plus a registry entry.

**One package witness per package.** Each package declares one `PackageWitness`, pinned by its
publication in `blast_admin::package_version`. It is the one type through which the package seals
vault terms, creates its protocol-fee ledger, issues owner proofs, releases its pause bits, and
borrows its own `Publisher` from `PackageAdmin`. One witness per purpose would be several ways to
say the same thing, and each would need its own pin.

**One package administration.** Every upgradeable package uses the generic
`PackageVersion<OTW>` and `PackageAdmin<OTW>` and the package roles generic over its one-time witness (OTW);
the products' own package-administration modules, version objects and role sets are deleted, and
product roles come from `blast_core::blast_domain`. `blast_admin`'s former operational-version and
upgrade-custody modules fold into those two types, whose only constructor, `package_admin::wrap`,
consumes the package's unique `Publication`, so no package can
build a second version or PackageAdmin.

**`UpgradeAction` is `Upgrade(digest)` or `MakeImmutable`, with no repair action.** The generic
`PackageAdmin` reads no consumer version, so a release that compiled the wrong version
constant is corrected by scheduling the next upgrade under the same notice. A separate repair action
would be a second way to install code, with its own notice to audit.

**No upgrade-policy narrowing.** The additive and dependency-only restrictions are removed. Under
either policy a release cannot change existing modules, so it cannot compile the next version,
and after the next `commit_upgrade_and_advance` every version-gated call would abort forever.
`make_immutable` is the one terminal action, behind the upgrade notice.

**`make_immutable` is guarded by the package itself** (owner, 2026-11-05).
`blast_admin::package_admin::make_immutable` takes the package's own witness and its live
`PackageVersion`, so only code in the package can end its upgrades, through a wrapper that first
checks its compiled version. A release that forgot its version bump fails that check and can
never be made immutable. Only the vault has the wrapper (`blast_vault_package::make_immutable`,
for #195); any other package adds one by upgrade if it ever needs it.

**Each vault is permanently bound to its constructing venue** (owner, 2026-11-05).
`new` stores the admitted venue witness's original `TypeName`. `share_with_position` checks
that exact type before attaching a position, settling residuals, or emitting `VaultCreated`.
Another admitted venue has no authority over this vault. The bound venue's position key is
permanent and cannot be added twice, so initialization commits only once. Sui permits an
already shared object to be re-shared; key-only custody and the sharing native do not establish
freshness. The stored binding and the permanent position key enforce that lifecycle locally.

**The migrators package has no pause bits.** Its version starts unpaused and it has no unpause.
Migration stops with each product's migration bit and buyback with the vault's admin bit.
Residual risk, accepted: `prepare`, fee collection and the settled fee-split update have no
emergency stop of their own; only a delayed upgrade that advances the version retires them.
Collection must never freeze, and these calls move only a vault's own fees under its stored split.

**Complete public API in the immutable packages** (owner rule, 2026-11-05). `blast_admin`,
`blast_partners` and `blast_core` give every struct its readers and, where a value can end, its
destructor, even with no caller today: an immutable package can never add one later, while a future
package may hold these types in ways this stack does not. `blast_admin`'s delayed map is kept for
that reason, although it has no consumer and was first slated for deletion. `OwnerProof` is unchanged.

**The vault is upgradeable now and made immutable after audit** (#195). It publishes
compatible-upgradeable so an audit finding can still be fixed, and schedules `make_immutable` after
the audit and a quiet period, executed through its own wrapper. Until then a vault upgrade forces a migrators relink in the same release window: a compatible
`blast_migrators` upgrade that rebinds the vault address and bumps `constants::version`, since
every `commit_upgrade_and_advance` advances the stored version. The venues call version-gated
vault functions, so migration and fee collection abort until the relink lands.

`blast_sui` and boosts are outside this stack and adopt the generic administration separately
(#191, #205).

### Consequences

- The publish order respects the dependency edges: partners needs admin; core needs admin and
  partners; the vault and both products need core; migrators needs the vault; the launch-ticket
  template needs `blast_fun`; the vendor needs core only. The chosen sequence is admin, partners,
  core, then the vault and the two products in any order, then migrators, the template and the
  vendor. Admission happens while every package
  is paused: the vault lists the two product witnesses and the two venue witnesses at notice zero,
  each product admits its venues, every zero notice is raised, and only then do the vault and the
  products unpause. `deployments/README.md` owns the runbook.
- Forced relinks: admin, partners and core force nothing; a vault upgrade forces a migrators relink;
  a migrators, product or vendor release forces nothing.
- The SDK, indexer and admin console read `PackageVersion<OTW>` and `PackageAdmin<OTW>`
  object types, `blast_admin_events::Paused<OTW>` for every pause, migrators events under
  `blast_migrators::events`, and a two-call migration PTB.
- Implementation steps 5 and 6 above are replaced by this amendment: there is no `blast_venues`
  package, no standalone vault creation, and the vendor redeems the hand-off as a venue.

## 2026-11-06: Reject unseedable launch allocations before finalization

The launchpad applies the same shared seedable-price preflight as the presale to its final LP
Meme and Quote allocation, before consuming the creation ticket and fixing the currency supply. A creator-selected
extreme configuration must fail during construction rather than receive buyer funds and become
stuck `MigrationReady`. This does not introduce cancellation after graduation or promise venue
operator availability; those lifecycle decisions remain unchanged. The regression admits a
10-decimal coin and proves that a nonzero one-atom LP Quote allocation at an unseedable price is
refused at finalization.
