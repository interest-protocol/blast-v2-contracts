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

The version-gated, compatible-upgradeable `blast_presale` package is a separate product boundary: it owns
presale escrow, eligibility, and proportional settlement, without importing or
mutating launchpad state, and it contains no venue. Its public `new` redeems the
ticket of any venue whose witness the `CreationPolicy` admits, and its `migrate`
seals the hand-off for that venue, so the shared venues in `blast_migrators` and
one-off partner venues under `sui/vendors` serve it without importing it. See
[ADR 0099](decisions/0099-standalone-overflow-presale.md),
[ADR 0104](decisions/0104-external-presale-migrators-and-vendor-packages.md), and
[ADR 0106](decisions/0106-presale-partners.md).

What both sale products share sits below them
([ADR 0137](decisions/0137-shared-launch-stack-core-vault-and-venues.md)):
`blast_core` holds the money vocabulary (basis points, payouts, the fee
split, the protocol-fee ledger, the treasury, Merkle proofs) and the sealed
values that carry a sale to its venue and prove ownership to its vault, and the
upgradeable `blast_vault` holds every migrated sale's LP custody, fee split,
Blast share, partner hold, and holder rewards. The upgradeable `blast_migrators`
holds the Cetus and Bluefin venues for both products. Each product keeps its own
venue allowlist, Quote allowlist, and partner list. The seven-package posture
recorded by ADR 0137 is
`blast_admin`, `blast_partners` and `blast_core` immutable; `blast_fun`,
`blast_presale`, `blast_vault` and `blast_migrators` upgradeable (ADR 0137,
amended 2026-11-05).

The canonical November deployment defers those terminal actions until final
audit. Its raw admin, partners and core UpgradeCaps remain at the multisig;
the four other caps are wrapped. See the [deployment record](../deployments/README.md)
for current authority, the post-audit vault immutability plan and paused release
gates.

The package boundaries keep external dependencies and independently governed
custody outside core.

### Independent upgrade custody

A standalone framework-only manager accepts any native UpgradeCap and enforces
a fixed 48-hour notice for either an exact native upgrade digest or terminal
target immutability ([ADR 0140](decisions/0140-upgrade-cap-manager.md)). It imports
no Blast administration or business package. The controller requests or cancels;
execution is permissionless after maturity. The raw cap is never withdrawn or
lent. Upgrades use native tickets and matching receipts; terminal execution
destroys only the selected cap and its pending request. Each manager holds up to
256 native caps with independent pending actions and deadlines; its controller
authorizes enrollment, requests and cancellation across all of them. The manager
publication's own cap must be destroyed
and independently verified before valuable enrollment; enrollment has no on-chain
proof gate. This source records no change to live deployment custody; see the
[package procedure](../sui/upgrade_cap_manager/README.md).

### Dependency direction

**No product imports a venue or the vault, and the vault imports no product.**
`blast_core` defines the sealed values that cross those boundaries: the venue
ticket a venue issues when it prepares a coin, the `Migration` a product returns
at migration, and the owner proof a product issues to its creator authority.
Venues depend inward on `blast_core` and `blast_vault` and import no product; the
vault depends on neither a product nor a venue. Composition happens **in the programmable
transaction block, not in product code**: a transaction threads these values
from a venue call into the product and back to the venue or the vault, so venue
preparation is possible without the product naming any venue. Migration is two
calls: the product's `migrate` returns the `Migration`, and the next command
passes it to the stored venue's `migrate`.

The vault fixes its venue witness type at construction. Position attachment checks that exact
type before any mutation, and its permanent position key prevents a second initialization. Sui
permits re-sharing an already shared object, so sharing alone provides no lifecycle guard.

The values crossing that boundary are non-droppable, so the transaction cannot end
until the call that must consume each one has run.

## Logical components

| Component | Responsibility | Must not own |
| --- | --- | --- |
| Package bootstrap | canonical OTW and the package witness, which `blast_admin::package_version::new_publication` pins in an owned `Publication` beside the claimed `Publisher` | protocol administration, feature state, or upgrade authority |
| Package administration (`blast_admin`) | the generic `PackageVersion<OTW>` and `PackageAdmin<OTW>`: sealed `Publisher` and `UpgradeCap` custody, pause bits, exact-digest upgrades under the compatible policy with the version advanced in the same commit, and deliberate `make_immutable` | ACL membership storage, feature configuration, or state migration |
| Protocol ACL | root rotation and revocable routine-admin membership | feature configuration, backend keys, creator recipients, or fees |
| Runtime config | the creator-claim backend keys and the live bonding-curve trade protocol fee share | admin delegation, creator recipient or issuance, cold launch policy, accrued balances, total trade-fee rates, the treasury (`blast_core`), or claim authority |
| Launch config | a table of admitted Quote types (the creator picks each launch's virtual Quote reserve), mutable generated-Meme decimal admission, Quote/Meme trade-fee rates, a delayed future-launch migration-fee allocation, Blast's delayed LP-fee share each new vault takes at migration, and the delayed venue allowlist that gates which venue's ticket may start a launch | live launch repricing, per-launch project allocation choices, quote currency-registry objects, DEX costs or dependencies, user balances, derived valuations, or hot trade configuration |
| Registry/config | global limits, other fee ceilings, emergency state | user balances or curve math |
| Launch ticket | one-time-witness currency creation, exact supply mint, and pre-launch supply and metadata custody; the `TreasuryCap` travels beside it under the launchpad's seal (`blast_core::sealed_treasury_cap`) | venue binding, decimal policy, trades, metadata updates, or migration |
| Launch initializer | no-ability construction by `launch::new` from the ticket, the sealed `TreasuryCap` it alone opens, and a redeemed venue ticket; creator setters for target, plan, LP-fee split, and opening round; `finalize` checks every invariant | persistence beyond its transaction or any post-migration behavior |
| Launch | key-only top-level shared asset identity, lifecycle, reserves, the partner-aware protocol fee ledger, transition guards, and the creator's immutable post-migration settings (venue, LP-fee split) | owned transfer, nesting, venue-specific migration code, or any post-migration update |
| Basis-points unit (`blast_core`) | universal 0–10,000 rate validation, explicit up/down application, and exact apportionment | domain ceilings, combined-rate policy, authority, storage ownership, or events |
| Curve math | pure quote and reserve transition formulas | authority, storage, transfers |
| Allocation math | the migration allocation plan and its exact apportionment | lifecycle state, custody, claims, venue costs, transfers, or DEX dependencies |
| Off-chain SDK | deterministic curve-release and native-Quote valuation previews from immutable launch facts | contract authority, balance mutation, migration permission, or a second source of truth |
| Fees | creator/protocol curve-fee splitting and the launch's accrued accounting for creation, curve, and one-time migration fees; the embedding launch checks its live curve-fee capability or bound custodian | recurring LP fees, venue residuals, arbitrary recipient execution, or referral attribution |
| LP vault (`blast_vault`) | position custody with no exposed withdrawal path for both products under the venue's key, the sale's sealed terms, and the fee split; every permissionless collection pays Blast's per-vault share to the core treasury, or holds it when the sale named a partner until a permissionless payout gives the partner its cut and the treasury the rest, pays the address routes, and credits the owner, auto-LP, holder-reward, and burn balances; migration residuals settled once by the sale's terms; owner claims and delayed split schedule/cancel under the product's owner proof; the admitted-venue registry | sale pricing, pre-migration settings, or venue code |
| Holder rewards (`blast_vault`) | Merkle rounds funded from a vault's holder-reward balance, an optional Quote gas reserve reimbursed once to the treasury within its cap, proof claims before a deadline and permissionless deadline recovery | holder accounting, which stays off-chain |
| Migration hand-off (`blast_core`) | the venue ticket for one Meme and Quote pair, the one-time `Migration` only the stored venue redeems, the vault terms, and the owner proof | DEX-specific object/storage details or custody |
| Venue | prepare a coin at a venue-valid tier, redeem a migration, create the pool and the vault, collect the position's fees into the vault, compound auto-LP under a live `AutoLpAdmin` capability and trusted price bounds (consuming and re-sharing the pool), and buy back | changing product economics |
| Standalone presale | create the sale token's currency from its one-time witness with the `TreasuryCap` sealed under the presale (`sale_token`), and require that zero-supply seal at `new`; derive and escrow BPS allocations; lock Quote commitments; settle one proportional fill; permissionlessly hand the configured venue a sealed migration; prove the cap holder's ownership to its vault; pay the Blast partner named at creation its cut of Blast's raise fee | launchpad curves or state, LP custody or fee splits, fixed-supply policy, giving a partner a cut of Blast's token fee, or post-creation sale-economics changes |

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
previews.

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

## Asset pair

A launch pairs its generated meme coin with a quote `Coin<Quote>`. Stored rates
and public fee-rate configuration inputs use the validated `Bps` unit; replay
events use raw `u64` primitive values. Core admits
new pairs through the Table-backed quote portion of `LaunchConfig`, keyed by the
quote's original `TypeName`; an entry only admits its Quote. The creator picks
each launch's virtual Quote reserve and graduation target, and intake rejects a
zero reserve and a target whose pool Quote share rounds to zero. Launch state
stores the creator's reserve and target, snapshots both administratively
configured trade-fee rates, and records the original `TypeName` of the witness of
the venue whose ticket started it. Both registries are
admission decisions; the snapshot does not add a quote `Currency` shared-object
dependency or a DEX package dependency. See
[ADR 0041](decisions/0041-launch-config-owned-trade-fees.md) and
[ADR 0092](decisions/0092-creator-picks-the-virtual-quote.md); the creator, not
`LaunchConfig`, picks the virtual reserve. The one unit and rounding boundary is
`blast_core::bps::Bps` (ADR 0137).

## One-time allocation and payouts

An `AllocationPlan` holds the curve's Meme share, the pool's Meme and Quote
shares (all positive), Blast's explicit Meme and Quote shares, and at most
sixteen project recipients, each an address with a Meme and a Quote share. The
creator's plan initially leaves Blast's fields at zero: `LaunchConfig` holds
Blast's allocation, set once by an administrator (Meme at most 9,998 BPS and
Quote at most 9,999 BPS so the curve and pool stay positive), and finalization
copies it into those fields. Each asset must then sum to exactly 10,000 BPS.

For each asset, allocation widens `total * bps` to `u128`. Blast's share takes
its ceiling; every other part takes its floor, and the remaining atomic units go
one each by descending fractional remainder, earlier parts first on ties. The
amounts sum exactly to the input. Blast's terminal Meme and Quote allocation
enters the launch's protocol fee ledger.

Initial Meme is physically split at construction: the curve's share becomes the
curve reserve and the rest is pooled in the launch. When migration begins, the
terminal real-Quote reserve is apportioned by the same plan, every project
recipient is paid its Meme and Quote as coins, Blast's Meme and Quote migration
fee joins the launch's protocol fee ledger, and only the pool's share is handed
to the venue in the sealed `Migration`.
Only a regulated Quote whose deny list names a destination can make that
transfer fail, which strands the launch; the founder accepted that risk.
`LaunchCreated` carries the complete plan, the pool tier, the LP-fee split,
and the opening-round length, one `MigrationAllocationPaid` records each
payout, `ProtocolFeesAccrued` records Blast's one-time migration fee, the
vault's `VaultCreated` records the vault, pool, and position identities with
the sealed terms, the residuals, and the position's liquidity, and `Migrated`
records the handoff and disposal amounts. Each LP-fee collection's `FeesCollected`
records Blast's share and every part of the split, `AutoLiquidityAdded`
what went back into the pool, and `BuybackBurned` each buyback. See
[ADR 0088](decisions/0088-reusable-launch-accounting-and-atomic-migration.md),
[ADR 0091](decisions/0091-fee-split-buyback-and-burn.md), and
[ADR 0137](decisions/0137-shared-launch-stack-core-vault-and-venues.md).

One property remains invariant regardless of the admitted quote set:

- **Pair and venue immutability.** The selected `(Meme, Quote)` pair and
  venue witness type are fixed at launch and never change through bonding,
  migration, recovery, or settlement.
See [ADR 0023](decisions/0023-generated-coin-supply-and-metadata-custody.md).

## Coin creation

Generated coins use Coin Registry's one-time-witness path. The generated
package's initializer passes its witness to the sole launchpad constructor,
which computes exactly one billion whole tokens in `u64` arithmetic that aborts
on overflow, creates the currency at the requested decimals, mints that supply,
and finalizes metadata; the initializer transfers the persistable launch ticket
and the coin's `TreasuryCap`, sealed under the launchpad's package witness in a
`blast_core::sealed_treasury_cap::SealedTreasuryCap`, to the publisher. The ticket holds the complete
`Balance<Meme>`, `MetadataCap<Meme>`, the decimals, the owner-selected `Fixed`
or `BurnOnly` mode, and the creator-selected fixed sell-burn rate capped at 50%.
In one PTB the launcher takes the launchpad's admission of the venue from
`LaunchConfig` and prepares the coin on that venue, whose `prepare` validates
the creator's pool tier, borrows the sealed `TreasuryCap` with the admission
before any Meme can leave the ticket (the Cetus venue reserves pool creation
with it), and returns a sealed venue ticket. Only the launchpad's witness opens
the seal, so no one mints Meme before the launch
([ADR 0138](decisions/0138-sealed-treasury-caps-and-venue-admissions.md)).
`launch::new` redeems the venue ticket, takes the launch ticket and the sealed
`TreasuryCap` by value and opens it, returning a `LaunchInitializer` with no abilities. The
creator sets the graduation target, allocation plan, LP-fee split, and optional
opening round, and `finalize` checks them all. Because a generated package's
initializer cannot read launch policy, starting checks the decimals, the Quote,
and the venue against the current policy, and finalization checks the Meme symbol against its
32-byte bound and, since a ticket may come from an older launchpad version, the
sell-burn rate and the whole minted supply again, then consumes the treasury cap into the
selected mode, so no mint authority survives finalization. The native `Currency` is delivered to the Coin Registry
address, and completing its registration is permissionless; intake needs it.
The creator recipient may be a wallet address or an opaque Blast account
commitment and may differ from the launcher. The native metadata cap never
leaves `Launch`. The creator claim issues a `CurveFeeCap<Meme>` for curve fees
and a `CreatorMetadataCap<Meme>` for metadata updates through the launch; a
creator administrator can reassign each independently
([ADR 0082](decisions/0082-revocable-creator-and-lp-fee-capabilities.md)). The
creator always keeps the curve-fee cap: after migration its holder proves
ownership to the launch's vault with `launch::prove_owner`, to claim the owner's
balances and change the split
([ADR 0137](decisions/0137-shared-launch-stack-core-vault-and-venues.md)).
See [ADR 0047](decisions/0047-coin-registry-authoritative-supply-mode.md) and
[ADR 0080](decisions/0080-provider-independent-creator-recipient.md), as amended
by [ADR 0088](decisions/0088-reusable-launch-accounting-and-atomic-migration.md).
The ticket records its decimals and sell-burn policy; launch intake recomputes
the canonical supply. Terminal migration reads the authoritative supply mode
from Coin Registry.

A sale token comes from the `presale_coin_template` package, whose initializer
passes its witness to `blast_presale::sale_token::new`: the presale creates the
currency and seals the `TreasuryCap` under its own witness, so the creator
holds it only sealed until `blast_presale::new` opens it, after the same
admission-gated venue preparation
([ADR 0138](decisions/0138-sealed-treasury-caps-and-venue-admissions.md)).
A coin that will not launch or sell on Blast comes from the separate
`coin_template` package, which has no Blast dependency: its initializer delivers
the creator-chosen supply, `TreasuryCap` or supply mode, and `MetadataCap`
straight to the creator's recipients, and it can never produce a `LaunchTicket`
or a sealed cap ([ADR 0108](decisions/0108-standalone-coin-template.md)).

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
  venue whose witness the launch stored can redeem its migration.
- `Migrated`: set by the one `migrate` call, which also completes terminal
  disposal.

Every transition is single-use and evented.

## Migration boundary

The historical contracts correctly treated migration as a typed, one-time
handoff. V2 retains that property but narrows it:

1. An exact-target buy returns excess Quote and closes trading.
2. Anyone calls `launch::migrate`. The launch pays every recipient, burns the
   curve's unsold Meme and the pending sell-burn (or sends them to `@0x0` under
   a fixed supply), marks the launch `Migrated`, and returns a sealed
   `Migration` holding only the pool's Meme and Quote and the vault's terms.
   Only the stored venue's witness can redeem it.
3. The next PTB command passes the `Migration` to the stored venue's `migrate`,
   which seeds the pool and installs the position, which must hold
   liquidity, in a new `blast_vault` vault with the launch's sealed terms; the
   residuals go to Blast at once, or are held for the launch's partner. Any
   failure rolls back the whole transaction. From then on the vault holds the
   position and its fees.

Incomplete venues never ship as aborting production functions. An unavailable
venue stays outside the release. A venue whose dependency cannot yet be pinned to an
immutable commit is a **release gate on that venue, not a reason to omit its
design**.

Every venue creates a fresh pool. Where anyone holding Meme could create the
pool first (Cetus), the venue reserves creation when it prepares the coin,
before the curve opens. No venue adopts a pool someone else created. A
mismatch is an atomic abort that leaves the launch `MigrationReady` with every
balance in place. The initial price is derived from the terminal atomic
reserves and is never a configured constant (`blast_core::migration`, ADR 0137).

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

- Launchpad: the canonical `Publisher` and raw `UpgradeCap` enter one shared
  `PackageAdmin<BLAST_FUN>` after module/package provenance checks. An
  `AdminWitness<UpgradeAdmin<BLAST_FUN>>` signed in on the singleton Blast ACL
  (ADR 0097) schedules an exact digest and, after the upgrade notice, authorizes
  it under the cap's compatible policy, which no path narrows (ADR 0137); the
  native receipt then commits against the same cap and
  advances the version, and `make_immutable` is the deliberate end of
  upgrades. No pre-planted governance cutover flag exists.
  The launchpad's OTW retains its Publisher and initial version in an owned
  `Publication`. Only validated capability wrapping consumes it and creates the
  shared `PackageVersion` required by launch creation and routine configuration setters
  (ADR 0137).
  The only upgrade finalizer commits the native receipt and advances the
  package version to the exact next compiled version in the same call;
  there is no separate activation step.
- `blast_migrators` keeps its `UpgradeCap` in its generic
  `PackageAdmin<BLAST_MIGRATORS>` and stays upgradeable: Cetus and Bluefin gate
  callers by package version, so each of their bumps forces a migrators relink.
  A vault upgrade forces one too, in the same release window, because the venues
  call version-gated vault functions. A product upgrade forces none, since the
  venues take the `Migration` from the PTB. Every migrators upgrade uses the
  compatible policy and bumps its compiled version constant; no path narrows
  cap policy.
- `blast_vault` publishes upgradeable and is made immutable after its audit and
  a quiet period (ADR 0137, #195).

- Boosts Aftermath separates native receipt commit from successor activation
  ([ADR 0123](decisions/0123-successor-activated-boosts-upgrades.md)). The successor
  proves its own compiled version is exactly next before changing the shared
  `Protocol`; failed activation leaves existing operations usable. Authorization
  and receipt commit remain version-independent for repair. Compatible policy
  cannot be narrowed; `make_immutable` still requires the current version.
  These historical authorization paths remain callable with the live ACL's
  UpgradeAdmin role: a future governance replacement must revoke that role or
  explicitly account for it. Version cutover alone does not retire this authority.

Replacement governance and recovery require approval before the first public
deployment of the fresh stack.

Presale uses the same custody-before-activation (ADR 0137): an owned
Publication precedes the shared PackageVersion. Its separate provenance module
`blast_presale_package` avoids policy/economics module cycles. SDK callers pass
the same version to each operational mutation; upgrade commit advances it
atomically and makes prior-version bytecode unusable.

Launchpad, presale, migrators and the vault retain the canonical Publisher and
version in a unique owned Publication until validated custody wrap consumes
it; all four use `blast_admin`'s generic publication and package
administration (ADR 0137). It has no policy authority. Wrap shares the canonical
PackageVersion; launchpad, presale and the vault start fully paused. Ordinary ACL operations configure policy after wrap.
Each protected operation owns its applied notice, initially zero for publication-owned
policy. A proposal binds its value, next notice and a deadline derived from the old
applied notice. Application commits both fields; cancellation preserves both applied
fields. Delay-only changes follow the same timelock, with no immediate setter or
bypass. The PackageAdmin persists its own notice independently of other policy.
`blast_admin::delayed` stores settings as `Delayed`, one-shot actions as
`DelayedAction` and venue allowlists as `DelayedSet`, each keyed by a
module-defined type and parent object ID. The primitives emit every lifecycle event;
embedding modules emit only their own side effects.
Settle or cancel all setup proposals, configure and verify every operation's intended
notice, then unpause. New creator-cap operations begin at 48 hours; a vault's
fee-split and Blast-share changes always wait a fixed 48 hours. The vault's venue
admissions start at zero notice, so Blast admits its venues and raises that
notice before unpausing the vault. Pausing, cancellation and
upgrading never reset an applied notice. The backend creator-claim signer remains
a separate runtime setting: admission waits the configured signer notice,
and revocation is immediate (ADR 0134).

Boosts margin recovery separates the ability to open risk from the ability to
reduce it ([ADR 0124](decisions/0124-margin-recovery-and-initial-headroom.md)).
The adapter authenticates venue facts; core seals the rebalance direction and
owns policy admission. Only increasing plans require opening margin, both
before execution and after fills. Donations become allocated position cash.
Initial-margin settings must satisfy the live venue floor and core's conditional
conservative cushion; later recovery is never gated by that issuance budget.

Partner share and cap terms are keyed `blast_admin::delayed` values with a fixed
seven-day notice. PartnerAdmin schedules or cancels; anyone applies a ready
proposal. Payments and recipient checks read applied values, so product payout
calls take no Clock for the partner. See ADR 0095.

## Utility source ownership

OTC and vesting remain independently published immutable packages,
maintained in this repository with their SDK and release records. Internal
consumers use local package dependencies. Repository consolidation changes no
on-chain ownership or ABI; [ADR 0135](decisions/0135-utility-contracts-consolidation.md)
records the history and license boundary.

Vault custody is subject to both vault and venue upgrade authority while those packages remain
upgradeable. Making the vault immutable alone does not freeze venue code that can borrow its
position. Cetus separately burns the migration position through its LP-burn mechanism; its
unburned auto-LP position remains within this upgrade trust boundary.
