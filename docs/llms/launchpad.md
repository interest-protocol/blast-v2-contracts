## Launchpad

### What it is

The Blast launchpad (package `blast_fun`) launches a new coin on a bonding curve. A creator
publishes a small generated coin package, which mints exactly one billion whole tokens into a
`launch_ticket::LaunchTicket`. The creator turns the ticket into a `launch::Launch<Meme, Quote>`
through a migration adapter (Cetus or Bluefin), choosing the curve's starting price, the Quote
amount at which the curve closes (the graduation target), how the supply and the final Quote are
split at migration, and how the future pool's LP fees are split. Anyone then buys and sells `Meme`
against `Quote` on a constant-product curve. When the curve's real Quote reserve reaches the
target, trading stops and the launch becomes `MigrationReady`; the adapter then moves the pool's
share of Meme and Quote into a new Cetus or Bluefin pool. `Meme` is the generated coin type and
`Quote` is the coin it trades against (for example SUI). Blast takes a share of every trade fee, a
SUI creation fee, and an optional one-time share of the supply and of the final Quote; a Blast partner named at
creation earns a cut of Blast's fees.

This guide covers everything up to and including `MigrationReady`, and what the launchpad itself
does when an adapter migrates. The pool, the `blast_fun_migrators::vault::LpVault`, LP-fee
collection, auto-LP, buyback, and holder rewards are in the migrators guide.

### Objects and authority

#### Shared objects

| Object | Created | Holds | Who writes it |
| --- | --- | --- | --- |
| `blast_fun::blast_fun::PackageVersion` | `blast_fun::package_admin::wrap` | the active package generation | upgrade admin only |
| `launch_config::LaunchConfig` | package publish | policy that new launches snapshot: admitted Meme decimals, admitted Quote types, trade fees, admitted adapters, Blast's migration allocation, the creation fee, accepted partners | Blast admins |
| `runtime_config::RuntimeConfig` | package publish | settings read live: the account-claim signer key, Blast's share of every trade fee, the treasury address | Blast admins |
| `launch::Launch<Meme, Quote>` | `launch::finalize`, shared by `launch::share` | one launch: lifecycle, curve reserves, settings, fee ledger, opening-round pot, migration allocations | trades, claims, migration |
| `blast_fun::package_admin::PackageAdmin` | `blast_fun::package_admin::wrap` | the package's `Publisher` and `UpgradeCap` | upgrade admin only |
| `Currency<Meme>` | `0x2::coin_registry::finalize_registration` | the coin's name, symbol, decimals, description, icon URL, and supply state (Sui Coin Registry) | the launch, through its internal `MetadataCap<Meme>` |

`launch::new` and configuration setters require the shared `PackageVersion`. It does not exist
until `blast_fun::package_admin::wrap` consumes the publication bootstrap and the matching,
never-upgraded native UpgradeCap. That transaction seals both native capabilities in
`PackageAdmin` and creates `PackageVersion` atomically. A rejected wrap leaves the bootstrap
intact and the launchpad inactive. After activation, version-guarded calls abort when the caller
links old bytecode after an upgrade (see Aborts).

#### Owned objects and capabilities

- `blast_fun::blast_fun::Bootstrap` (`key` only): created once at package publication and sent
  to the deployer. It holds the canonical Publisher and initial operational generation. Its
  only production consumer is `blast_fun::package_admin::wrap`; it cannot be transferred by
  another package, shared, or used in place of `PackageVersion`.
- `launch_ticket::LaunchTicket<Meme>` (`key, store`): created when the generated coin package is
  published and sent to the publisher. It holds the whole supply as a `Balance<Meme>`, the
  `TreasuryCap<Meme>`, the `MetadataCap<Meme>`, the creator recipient, the decimals, the supply
  mode (`burnable`), and the sell-burn rate. The holder starts a launch with it; the ticket can be
  transferred first. No call releases its contents except launch finalization.
- `creator_authority::CurveFeeCap<Meme>` (`key, store`): authority over the launch's creator trade
  fees, and after migration over the creator's LP-fee share and the LP-fee split in the
  migrators' vault. The launch honors only the cap ID it records in `curve_fee_cap_id`.
- `creator_authority::BlastMetadataCap<Meme>` (`key, store`): authority to change the coin's name,
  description, and icon URL through the launch. The launch honors only the cap ID in
  `blast_metadata_cap_id`.
- Both caps are issued once by `launch::claim_creator_caps` to the creator recipient, or reissued
  by a Blast creator admin. A holder may delete a cap with
  `creator_authority::destroy_curve_fee_cap` or `creator_authority::destroy_metadata_cap`;
  deleting the live cap leaves fees unclaimable (or metadata frozen) until an admin reassigns it.

The native `MetadataCap<Meme>` never leaves the launch, and finalization consumes the
`TreasuryCap<Meme>` into the Coin Registry, so no one can ever mint more Meme.

#### Creator recipient

`creator_authority::CreatorRecipient` names who may claim the creator caps. It is fixed in the
generated package and carried by the ticket into the launch. It may differ from the launcher (the
wallet that publishes and launches).

- `Address(address)`: built by `creator_authority::new_address` (non-zero). That wallet claims by
  sending the claim transaction itself.
- `Account(vector<u8>)`: built by `creator_authority::new_account` from a 32-byte opaque Blast
  account commitment. Any wallet claims by presenting an expiring signature from the Blast
  backend that binds the commitment to that wallet (see Flows).

#### Values built inside a PTB

These have `copy, drop, store` and cannot be passed as pure arguments; build them with their
constructors in the same PTB:

- `blast_fun::bps::Bps`: a rate from 0 to 10,000 basis points, built by `blast_fun::bps::new`
  (aborts above 10,000).
- `allocation::Recipient` (`allocation::recipient`), `allocation::AllocationPlan`
  (`allocation::plan`), `allocation::Route` (`allocation::route`), `allocation::FeeSplit`
  (`allocation::fee_split`).

`launch::LaunchInitializer<Meme, Quote>` has no abilities: it must be consumed by `launch::finalize`
in the PTB that created it. `launch::Launch` has only `key`: it must be shared with `launch::share`
in that same PTB.

#### Admin roles

Blast administration uses the shared ACL from `blast_admin`. A Blast admin holds a
`blast_acl::AdminCap` granted roles; in a PTB it calls `blast_acl::sign_in<Role>` with the shared
`blast_acl::ACL` to get a `blast_acl::AdminWitness<Role>`, which the setter takes by reference. A
role authorizes only the functions that name it. The roles are types in `blast_fun_domain`:

| Role | Launchpad functions it authorizes |
| --- | --- |
| `blast_fun_domain::UpgradeAdmin` | `blast_fun::package_admin::authorize_upgrade`, `blast_fun::package_admin::commit_upgrade_and_advance`, `blast_fun::package_admin::make_immutable` |
| `blast_fun_domain::CreatorAdmin` | `launch::reassign_curve_fee_cap`, `launch::reassign_metadata_cap` |
| `blast_fun_domain::TreasuryAdmin` | `launch_config::set_protocol_allocation`, `runtime_config::set_treasury` |
| `blast_fun_domain::FeeAdmin` | `launch_config::set_trade_fees`, `launch_config::set_creation_fee`, `launch_config::add_partner`, `launch_config::remove_partner`, `runtime_config::set_protocol_fee_share` |
| `blast_fun_domain::ListingAdmin` | `launch_config::set_meme_decimals_allowed`, `launch_config::set_quote_allowed` |
| `blast_fun_domain::AdapterAdmin` | `launch_config::set_migration_witness_allowed` |
| `blast_fun_domain::ClaimSignerAdmin` | `runtime_config::set_creator_claim_signer` |
| `blast_fun_domain::BuybackAdmin`, `blast_fun_domain::RewardsAdmin` | migrators only (buyback, holder-reward rounds) |

Integrators cannot call these. What each setter changes is under "Admin operations".

### Lifecycle

`launch::Lifecycle` has four states:

```text
[OpeningRound ->] Live -> MigrationReady -> Migrated
```

| State | Entered by | Allows |
| --- | --- | --- |
| `OpeningRound` | `launch::finalize` with a non-zero opening round | `launch::join_opening_round` until the round ends (the creator also before share); `launch::settle_opening_round` once it has ended |
| `Live` | `launch::finalize` without an opening round, or `launch::settle_opening_round` | `launch::buy` (also before share, so the creator can buy first); `launch::sell` only after share |
| `MigrationReady` | a buy, or the opening-round settlement, that leaves the real Quote reserve at or above the graduation target | migration by the launch's own adapter; no trading |
| `Migrated` | `launch::migrate` (called by the adapter) | nothing on the curve |

Separately, `public_start_ms` is set once by `launch::share`. In every state:
`launch::claim_creator_caps` (after share), `launch::claim_creator_fees`, metadata updates,
`launch::claim_protocol_fees` and `launch::claim_protocol_fees_with_partner`, and admin
reassignments. `launch::deliver_opening_round` works in every state after `OpeningRound`, including
`Migrated`. A launch that never reaches its target stays `Live` forever: there is no cancel,
expiry, or refund path.

### Flows

Creating a launch takes three transactions, because each step needs an object the previous one
creates.

#### Flow 1: publish the generated coin package (anyone; the publisher receives the ticket)

The coin is a one-module package built from the `launch_ticket_template` template. Its only code is an
initializer that runs at publish: it builds the creator recipient and calls `launch_ticket::new`
with the package's one-time witness, then transfers the ticket to the publisher. It exposes no
public functions. Patch these constants in the compiled template:

| Constant | Meaning | Checked |
| --- | --- | --- |
| `SYMBOL` | coin symbol | ASCII printable (Coin Registry); at most 32 bytes at finalization |
| `NAME`, `DESCRIPTION`, `ICON_URL` | coin metadata | valid UTF-8; changeable later with the metadata cap |
| `DECIMALS` | coin decimals | must be admitted in `LaunchConfig` when the launch starts; default admitted set is 6 and 9 |
| `BURNABLE` | `true`: supply becomes burn-only; `false`: supply becomes fixed | none |
| `SELL_BURN_BPS` | share of each sale's post-fee Meme set aside to burn | at most 5,000 (50%), at publish and again at finalization |
| `CREATOR_RECIPIENT_BYTES`, `CREATOR_IS_ACCOUNT` | 32 bytes: an account commitment, or an address when `CREATOR_IS_ACCOUNT` is `false` | address must be non-zero |

In the template the coin type is `<new package>::meme::MEME`. Blast's own launch tooling renames
the module and witness after the symbol, so take a coin's exact type from its publish effects or
from `blast_fun::events::LaunchTicketCreated` rather than assuming `meme::MEME`. Patch the dependency address to the launchpad's original
package ID and publish with every transitive dependency: `0x1`, `0x2`, and the current package IDs
of the launchpad, `blast_admin`, `blast_partners`, and `blast_fun_timelock` (Sui rejects a publish
whose dependency list misses one of the launchpad's own dependencies). Handle the `UpgradeCap` that the Publish command
returns (transfer it or make the package immutable); it grants no authority over the coin.

Publishing:

1. Creates the currency through the Coin Registry one-time-witness path and mints
   `1_000_000_000 * 10^decimals` atomic units (aborts on `u64` overflow, so decimals above 10
   fail).
2. Sends `LaunchTicket<Meme>` to the publisher and the unregistered `Currency<Meme>` to the Coin
   Registry address `0xc`.
3. Emits `blast_fun::events::LaunchTicketCreated`.

#### Flow 2: register the currency (anyone)

Call `0x2::coin_registry::finalize_registration<Meme>` with the shared `CoinRegistry` at `0xc`
and the pending `Currency<Meme>` as a `Receiving` argument. It re-creates the currency as a shared
object at a derived address. Use that shared `Currency<Meme>` in every later step.

#### Flow 3: create, configure, and share the launch (ticket holder, one PTB)

Type arguments are `<Meme, Quote>` on every adapter and `launch` call below. `Clock` is the shared
object at `0x6`. Every initializer setter below, `launch::finalize`, and `launch::share`
takes the launchpad `PackageVersion` as a shared, immutable argument immediately after the
initializer or launch. Each checks the current generation before validation or mutation.
`launch::new` needs the adapter's witness, which only the adapter module can construct, so a
launch always starts through an adapter's `new`; only that adapter can borrow the ticket's treasury
cap during the PTB (`launch::treasury_cap_mut`).

1. Start the launch through an admitted adapter. Both return a `LaunchInitializer<Meme, Quote>`:
   - Cetus: `blast_fun_migrators::cetus::new` takes the owned ticket, the migrators'
     `blast_fun_migrators::blast_fun_migrators::PackageVersion` (shared), the launchpad
     `PackageVersion` (shared), `LaunchConfig` (shared), the migrators'
     `blast_fun_migrators::venue_config::VenueConfig` (shared, mutable), Cetus's `GlobalConfig`
     (shared) and `Pools` (shared, mutable), and `tick_spacing: u32`. The fee rate is the one
     Cetus registers for that tick spacing; the call aborts when Cetus does not register the
     spacing or refuses the pair at it. It mints the Meme type's single Cetus `PoolCreationCap`
     from the ticket's treasury cap, registers the pair at the tick spacing, keeps the cap in
     `VenueConfig`, and emits `blast_fun_migrators::blast_events::CetusPoolReserved`. From then on
     only that cap or Cetus's own pool-manager role can create the pair's pool at that spacing, so
     no buyer can create the migration pool first.
   - Bluefin: `blast_fun_migrators::bluefin::new` takes the owned ticket, the migrators'
     `PackageVersion`, the launchpad `PackageVersion`, `LaunchConfig`, `tick_spacing: u32` (1 to
     400), and `fee_rate: u64` (1 to 20,000, Bluefin's units); otherwise it aborts with
     `blast_fun_migrators::bluefin::EInvalidTier`.

   Inside, `launch::new` checks that Meme and Quote differ, that `Quote`, the adapter's witness,
   and the decimals are admitted in `LaunchConfig`, and snapshots the trade fees. The pool tier
   (tick spacing, fee rate) is fixed from here on.
2. `launch::set_virtual_quote` with the initializer (mutable) and a `u64`: the virtual Quote
   reserve, in Quote atomic units. Required, non-zero. It sets the opening price.
3. `launch::set_graduation_target` with the initializer and a `u64`: the real Quote reserve at
   which trading closes. Required.
4. Build the allocation plan: one `blast_fun::bps::new` per share; one `allocation::recipient` per
   project recipient (address, Meme share, Quote share); a `MakeMoveVec` of type
   `allocation::Recipient` (may be empty); then `allocation::plan` with the curve Meme share, pool
   Meme share, pool Quote share, and the vector. Pass it to `launch::set_allocation_plan`.
   Required.
5. Build the LP-fee split: one `allocation::route` per extra recipient (address, share); a
   `MakeMoveVec` of type `allocation::Route`; then `allocation::fee_split` with the creator,
   auto-LP, rewards, and burn shares and the vector. Pass it to `launch::set_lp_fee_split`.
   Required.
6. Optional: `launch::set_opening_round` with a length in ms: 0 (default, no round) or 60,000 to
   300,000.
7. Optional: `launch::set_partner` with `LaunchConfig`, a `blast_partners::blast_partners::Partner`
   (shared, immutable), and `Clock`. The partner must be one `LaunchConfig` accepts now. This is the
   only time a launch can name a partner.
8. Pay the creation fee: `SplitCoins` from the gas coin for exactly `LaunchConfig.creation_fee`
   MIST (use `0x2::coin::zero<0x2::sui::SUI>` when it is zero).
9. `launch::finalize` consumes the initializer and takes `PackageVersion`, the shared `Currency<Meme>` (mutable),
   `LaunchConfig`, and the fee coin. It returns the `Launch<Meme, Quote>` value. It checks every
   setting (see Aborts), copies Blast's current allocation into the plan and requires each asset to
   sum to 10,000, fixes the supply as burn-only or fixed in the Coin Registry (consuming the
   treasury cap), keeps the curve's Meme as `meme_reserve` and the rest as `allocated_meme`, stores
   the creation fee in the fee ledger, and emits `blast_fun::events::LaunchCreated`. The lifecycle
   is `OpeningRound` when an opening round was set, else `Live`.
10. Optional creator purchase before anyone else can trade:
    - without an opening round: `launch::buy` on the launch value (see Buy); transfer both returned
      coins. A buy here may even reach the target.
    - with an opening round: `launch::join_opening_round` on the launch value (see Opening round);
      the creator's bid joins the same pot at the same price as everyone's.
11. `launch::share` consumes the launch value and takes `PackageVersion` and `Clock`: it records `public_start_ms`
    (now), shares the launch, and emits `blast_fun::events::LaunchShared`. The opening round, if
    any, ends `opening_round_ms` later. This must be the launch's last use in the PTB.

The creator caps cannot be claimed in this PTB; claim them in a later transaction.

#### Opening round (anyone)

1. Join: `launch::join_opening_round` with the shared launch, `PackageVersion`, a `Coin<Quote>`
   (non-zero), and `Clock`. It adds the coin to one pot and to the sender's bid, kept as a dynamic
   field `launch::OpeningRoundBidKey(sender)` on the launch. Repeated joins add up. Emits
   `blast_fun::events::OpeningRoundJoined`. Allowed until `public_start_ms + opening_round_ms`.
2. Settle: from that time on, anyone calls `launch::settle_opening_round` with the launch,
   `PackageVersion`, `RuntimeConfig`, and `Clock`. The lifecycle becomes `Live`, and the whole pot
   buys from the curve once, with the usual fees, the graduation cap, and no minimum output. The
   Meme bought and any Quote refunded stay in the launch for delivery. A zero-output pot is
   refunded whole unless its net Quote reaches the target. A target-reaching pot is charged even
   when it returns zero Meme. Emits `blast_fun::events::Bought` (when Quote enters the reserve) and `blast_fun::events::OpeningRoundSettled`. If the pot reached the target, the
   launch is `MigrationReady` at once.
3. Deliver: anyone calls `launch::deliver_opening_round` with the launch, `PackageVersion`, and the
   bidder's address. The bidder (not the caller) receives its pro-rata Meme and Quote as coins, and
   its bid record is removed. Emits `blast_fun::events::OpeningRoundDelivered`. One call per
   bidder; it works in any later state.

#### Buy (anyone)

Split the exact input from your Quote coins (from the gas coin when Quote is SUI). `launch::buy`
takes the shared launch, `PackageVersion`, `RuntimeConfig`, that `Coin<Quote>`, and
`min_meme_out: u64`. It returns `(Coin<Meme>, Coin<Quote>)`: the Meme bought (after the Meme fee)
and the Quote refunded past the graduation target. The refund coin is usually zero-valued; it has
no `drop`, so transfer it or destroy it with `0x2::coin::destroy_zero`. Emits
`blast_fun::events::Bought`. The buy that reaches the target makes the launch `MigrationReady`.
That final buy may return zero Meme because of rounding or Meme fees, but only with
`min_meme_out = 0`. A positive minimum still aborts; nonterminal zero-output buys abort too.
The target cap and fees still apply, and excess Quote is refunded.

#### Sell (anyone, after share)

Merge your Meme coins and split the amount to sell. `launch::sell` takes the shared launch,
`PackageVersion`, `RuntimeConfig`, that `Coin<Meme>`, and `min_quote_out: u64`, and returns the
Quote after fees as a `Coin<Quote>`. The Meme fee and the sell-burn share are taken from the input
first; the sell-burn Meme waits in `pending_burn` until migration. Emits
`blast_fun::events::Sold`. Trades take no deadline and no `Clock`: the minimum output is the only
price protection.

#### Claim the creator caps (creator recipient, after share)

`launch::claim_creator_caps` takes the shared launch, `PackageVersion`, `RuntimeConfig`, an
`Option<vector<u8>>` attestation, and `Clock`. It returns a `CurveFeeCap<Meme>` and a
`BlastMetadataCap<Meme>`; transfer both to the sender. It works once, in any state after share.
Emits `blast_fun::events::CreatorCapsClaimed`.

- Address recipient: the sender must be that address; pass `None`.
- Account recipient: pass `Some(attestation)`, obtained from the Blast backend for the sending
  wallet. The attestation is the BCS encoding of `(expiry_ms: u64, signature: vector<u8>)`, 73 bytes
  for a 64-byte signature, with nothing after it. The call checks `Clock` time `<= expiry_ms` and
  verifies the Ed25519 signature with `RuntimeConfig.creator_claim_signer_public_key` over the raw
  BCS bytes of `creator_authority::CreatorClaimMessage`, whose fields in order are `meme`,
  `account_commitment`, `claimant`, and `expiry_ms`. Here `meme` is the Meme `TypeName` with
  original package IDs (64 hex characters, no `0x`, then `::module::NAME`) and `claimant` is the
  sender. The signed bytes are: the type-name string's ULEB128 length and ASCII bytes, `0x20` and
  the 32-byte commitment, the 32-byte claimant address, then `expiry_ms` as 8 little-endian bytes.
  There is no intent prefix or extra hash.

#### Claim creator trade fees (CurveFeeCap holder)

`launch::claim_creator_fees` takes the shared launch, `PackageVersion`, and `&CurveFeeCap<Meme>`,
and returns `(Coin<Meme>, Coin<Quote>)` holding all creator fees accrued so far (one may be zero).
Works in any state, including after migration. Emits `blast_fun::events::CreatorFeesClaimed`.
Post-migration LP fees are claimed from the migrators' vault with the same cap.

#### Update coin metadata (BlastMetadataCap holder)

`launch::set_name`, `launch::set_description`, and `launch::set_icon_url` each take the launch (by
immutable reference), `PackageVersion`, `&BlastMetadataCap<Meme>`, the shared `Currency<Meme>`
(mutable), and the new `String`. The value must differ from the current one. Works in any state.
Each emits `blast_fun::events::MemeMetadataUpdated` with all three current values. Symbol and
decimals never change.

#### Claim Blast's fees (anyone)

Blast's fees on a launch (its trade-fee share, the creation fee, and the one-time migration
allocation) wait in the launch's fee ledger until anyone pays them out:

- Launch without a partner: `launch::claim_protocol_fees` with the launch, `PackageVersion`, and
  `RuntimeConfig`. Sends every Blast balance (Meme, Quote, SUI) to `RuntimeConfig.treasury`.
- Launch with a partner: `launch::claim_protocol_fees_with_partner` with the launch,
  `PackageVersion`, `RuntimeConfig`, the launch's `Partner` (shared), and `Clock`. Each balance
  first pays the partner its share through `blast_partners::blast_partners::pay`, then the rest goes
  to the treasury.

Both emit `blast_fun::events::ProtocolFeesClaimed`. Calling the wrong one aborts with
`EPartnerMismatch`. Zero balances send nothing.

#### Migration, launchpad side (anyone, through the adapter)

Anyone triggers migration of a `MigrationReady` launch through its adapter
(`blast_fun_migrators::cetus::migrate` or `blast_fun_migrators::bluefin::migrate`; arguments in the
migrators guide). The adapter calls `launch::migrate` with its witness, which checks the lifecycle
and that the witness is the one the launch stored, then:

1. Apportions the Meme supply and the final real Quote reserve by the allocation plan (see
   Economics).
2. Pays every project recipient its Meme and Quote as coins (zero amounts are skipped) and emits
   `blast_fun::events::MigrationAllocationPaid` for each recipient.
3. Moves Blast's Meme and Quote allocation into the launch's protocol fee ledger and, when either is
   non-zero, emits `blast_fun::events::ProtocolFeesAccrued`.
4. Disposes of the curve's unsold Meme plus `pending_burn`: burned through the Coin Registry when
   the supply is burn-only, otherwise sent to `@0x0`.
5. Sets `Migrated`, emits `blast_fun::events::Migrated`, and returns the pool's Meme and Quote
   balances to the adapter, which creates the pool and the vault in the same transaction.

Any failure aborts the whole transaction and leaves the launch `MigrationReady` with every balance
in place. The opening-round balances awaiting delivery are untouched.

#### Admin operations (Blast admin)

Each setter takes the object it changes, `PackageVersion`, and the role's `AdminWitness`, and
emits an event. Value setters abort with `blast_fun::errors::EUnchanged` when nothing would change. The
allow/remove toggles for Quotes, decimals, and adapters instead abort inside the Sui collection
(`sui::dynamic_field` or `sui::vec_set`) when the entry already has the requested state.

- `launch_config::set_quote_allowed<Quote>` (ListingAdmin), with `allowed: bool`: admits or removes
  a Quote for new launches; existing launches keep trading. Emits `blast_fun::events::QuoteSet`.
- `launch_config::set_meme_decimals_allowed` (ListingAdmin), with `decimals: u8` and `allowed`.
  Emits `blast_fun::events::MemeDecimalsSet`.
- `launch_config::set_migration_witness_allowed<Witness>` (AdapterAdmin), with `allowed`: admits or
  removes an adapter; rejects types defined at `0x1` or `0x2`. Existing launches keep their adapter.
  Emits `blast_fun::events::MigrationWitnessSet`.
- `launch_config::set_trade_fees` (FeeAdmin), with Quote and Meme fee `Bps`, each at most 1,000;
  only launches started afterward use them. Emits `blast_fun::events::LaunchTradeFeesChanged`.
- `launch_config::set_creation_fee` (FeeAdmin), with an amount in MIST. Emits
  `blast_fun::events::CreationFeeChanged`.
- `launch_config::set_protocol_allocation` (TreasuryAdmin), with Meme and Quote `Bps`: Blast's
  one-time share for launches finalized afterward; Meme at most 9,998 and Quote at most 9,999.
  Emits `blast_fun::events::ProtocolAllocationSet`.
- `launch_config::add_partner` (FeeAdmin), with a `Partner`: new launches may name it at once;
  cancels a pending removal. Emits `blast_fun::events::PartnerAdded`.
- `launch_config::remove_partner` (FeeAdmin), with a `Partner` and `Clock`: new launches may still
  name it for `blast_partners::blast_partners::delay_ms` (seven days); launches that already name it
  keep paying it. Aborts with `EPartnerNotAccepted` when it is not accepted now. Emits
  `blast_fun::events::PartnerRemoved`.
- `runtime_config::set_protocol_fee_share` (FeeAdmin), with a `Bps`: Blast's share of every trade
  fee on every launch, from the next trade. Emits `blast_fun::events::ProtocolFeeShareChanged`.
- `runtime_config::set_treasury` (TreasuryAdmin), with a non-zero address: every later Blast fee
  claim on every launch pays it. Emits `blast_fun::events::TreasuryChanged`.
- `runtime_config::set_creator_claim_signer` (ClaimSignerAdmin), with a 32-byte Ed25519 public key,
  or empty bytes to stop all account claims. Emits `blast_fun::events::CreatorClaimSignerSet`.
- `launch::reassign_curve_fee_cap` and `launch::reassign_metadata_cap` (CreatorAdmin), with a
  non-zero recipient: mint a fresh cap, record it as the live one, send it to the recipient, and
  cancel any unclaimed creator claim. The old cap stops working; unclaimed curve fees follow the
  new cap. Emit `blast_fun::events::CurveFeeCapReassigned` or
  `blast_fun::events::MetadataCapReassigned`.
- Upgrades (UpgradeAdmin): `blast_fun::package_admin::authorize_upgrade` returns an
  `UpgradeTicket` for an exact digest; after the Upgrade command,
  `blast_fun::package_admin::commit_upgrade_and_advance` commits the receipt and advances
  `PackageVersion` in the same transaction; `blast_fun::package_admin::make_immutable` ends
  upgrades for good.

### Economics

All amounts are atomic units. Rates are BPS out of 10,000. `ceil` rounds up, `floor` rounds down.

#### Supply

Every generated coin has exactly `1_000_000_000 * 10^decimals` atoms, minted once. Finalization
re-checks the ticket's balance and the treasury cap's supply against this amount and fixes the
supply in the Coin Registry. After that no one can mint. Under a burn-only supply anyone can burn
Meme through the Coin Registry; a fixed supply cannot be burned, so the launch sends its
disposals to `@0x0` instead.

#### Allocation plan

An `AllocationPlan` splits two totals at migration:

- Meme supply: `curve_meme_bps` (sold on the curve) + `lp_meme_bps` (seeds the pool) + Blast's
  `protocol_meme_bps` + each recipient's `meme_bps` = 10,000. Curve and pool Meme shares must be
  positive.
- Final real Quote reserve: `lp_quote_bps` (seeds the pool) + Blast's `protocol_quote_bps` + each
  recipient's `quote_bps` = 10,000.

The creator's plan leaves Blast's fields at zero; `launch::finalize` copies
`LaunchConfig.protocol_allocation` into them and then checks both sums. So the creator's shares
must sum to 10,000 minus Blast's current share for each asset. At most 16 recipients; each
destination is non-zero (`allocation::plan` does not reject repeated addresses). The plan is fixed
for the launch's life. Finalization also requires the pool's Quote share of the graduation target
to be at least one atom.

Apportionment (used for the Meme supply at finalization and migration, and for the Quote at
migration): each part's exact share is `total * bps / 10,000` in `u128`. Blast's part takes the
ceiling; every other part takes the floor; the leftover atoms go one each to the parts with the
largest remainders, earlier parts first on ties. Part order is curve, pool, Blast, recipients in
plan order for Meme, and pool, Blast, recipients for Quote. The parts sum exactly to the total.

At finalization the curve's part becomes `meme_reserve`; the pool, Blast, and recipient parts wait
in `allocated_meme`. At migration recipients are paid, Blast's parts enter the fee ledger, and the
pool's parts go to the adapter. Unsold curve Meme is disposed of, never paid to anyone.

#### Curve math

Let `M = meme_reserve`, `V = virtual_quote`, `Q = real_quote_reserve`, `T = graduation_target`,
`fq = quote_fee_bps`, `fm = meme_fee_bps`, `s = sell_burn_bps`. The curve is constant product over
`(V + Q) * M`; the virtual reserve never leaves the launch. Spot price in Quote atoms per Meme atom
is `(V + Q) / M`.

Buy with `q` Quote supplied:

1. Cap: `R = T - Q`. If `q - ceil(q * fq / 10,000) <= R`, the gross input is `q` and the refund 0.
   Otherwise gross `g = ceil(R * 10,000 / (10,000 - fq))` and refund `q - g`.
2. `quote_fee = ceil(g * fq / 10,000)`; `net = g - quote_fee`.
3. `meme_out_gross = floor(M * net / (V + Q + net))`.
4. `meme_fee = ceil(meme_out_gross * fm / 10,000)`; `meme_out_net = meme_out_gross - meme_fee`.
5. If `meme_out_net` is 0, `launch::buy` aborts with `EZeroTradeOutput` (settlement instead keeps
   the pot for refund). If it is below `min_meme_out`, abort `ESlippageExceeded`.
6. `Q += net`, `M -= meme_out_gross`. If `Q >= T`, the launch becomes `MigrationReady`. Because of
   rounding the final `Q` can sit a few atoms above `T`.

Sell with `m` Meme:

1. `meme_fee = ceil(m * fm / 10,000)`.
2. `burn = ceil((m - meme_fee) * s / 10,000)`, added to `pending_burn`.
3. `x = m - meme_fee - burn` reaches the curve: `quote_out_gross = floor((V + Q) * x / (M + x))`.
4. `quote_fee = ceil(quote_out_gross * fq / 10,000)`;
   `quote_out_net = quote_out_gross - quote_fee`. Abort `EZeroTradeOutput` when it is 0, and
   `ESlippageExceeded` when below `min_quote_out`.
5. `M += x`, `Q -= quote_out_gross`.

Every rounding favors the curve and the fee ledger over the trader.

#### Trade fees and Blast's share

`quote_fee_bps` and `meme_fee_bps` are copied from `LaunchConfig` when the launch starts and never
change (each at most 1,000). On every trade (and the settlement purchase) each fee splits as
`protocol = ceil(fee * p / 10,000)` and `creator = fee - protocol`, where `p` is
`RuntimeConfig.protocol_fee_share_bps` read live at that trade. Both parts stay in the launch's fee
ledger: the creator part until `launch::claim_creator_fees`, Blast's part until a permissionless
Blast fee claim.

#### Creation fee

Exactly `LaunchConfig.creation_fee` MIST of SUI, whatever the Quote, paid at finalization into the
ledger's `protocol_sui` balance. It is Blast's and is claimed with the other Blast fees.

#### Partner payouts

A partner named at creation is the launch's partner for good (`partner_id`), and its LP vault
inherits it after migration. When Blast's fees are claimed, each balance (Meme, Quote, SUI) pays the
partner `floor(balance * share_bps / 10,000)`, with `share_bps` the partner's share in force at the
claim (set by Blast, at most 8,000); Blast's treasury gets the rest. The partner's cut covers trade
fees, the creation fee, and the one-time migration allocation.

#### LP-fee split

The `FeeSplit` set at launch divides every future LP-fee collection, after Blast's LP-fee share,
into `creator_bps`, `auto_lp_bps`, `rewards_bps`, `burn_bps`, and up to 16 extra routes (non-zero,
distinct destinations), summing to exactly 10,000 and applied to both assets. The burn part's Meme
is burned at collection and its Quote buys Meme back to burn. The launch stores it unchanged and the
vault copies it at migration; after that the curve-fee cap holder changes it in the vault (migrators
guide).

#### Worked example

SUI Quote (9 decimals), Meme with 9 decimals (supply `10^18` atoms), plan 8,000 curve / 2,000 pool
Meme and 10,000 pool Quote, Blast allocation 0, `V = T = 8,000 SUI`. Ignoring fees and sells:

- The curve holds 800M tokens; opening price `8,000 / 800M = 0.00001` SUI per token (10,000 SUI for
  the whole supply).
- At the target the curve holds about `800M * 8,000 / 16,000 = 400M` tokens: 400M sold for
  8,000 SUI; closing price `16,000 / 400M = 0.00004` SUI per token.
- Migration seeds the pool with 200M tokens and 8,000 SUI (also 0.00004), and disposes of 400M
  unsold tokens; a burn-only supply ends at 600M tokens.

With a 1% Quote fee and no Meme fee, a first buy of 100 SUI pays a 1 SUI fee and receives
`floor(8 * 10^17 * 99 * 10^9 / (8 * 10^12 + 99 * 10^9)) = 9,778,985,059,883,936` atoms (about 9.78M
tokens). With `Q = 7,990 SUI` and the same fee, supplying 20 SUI uses `g = 10.101010102` SUI and
refunds 9.898989898 SUI; the net 10 SUI lands `Q` exactly on 8,000.

### Time rules

All times are `Clock` milliseconds.

- `public_start_ms` is the time of `launch::share`. Sells and creator-cap claims need it set;
  buys do not (only the creator's own PTB can reach the unshared launch).
- Opening round: joins are accepted while `now < public_start_ms + opening_round_ms` (and before
  share); settlement is accepted when `now >= public_start_ms + opening_round_ms`. At exactly the
  end, a join aborts and settlement succeeds. Settlement is never possible before share. Length is
  0 or 60,000 to 300,000 ms.
- Account claims: accepted while `now <= expiry_ms`.
- Partner acceptance: `set_partner` needs `now < accepted_until_ms`; removal sets
  `accepted_until_ms = now + 7 days`, and `add_partner` restores `u64::MAX`.
- Trades, claims, deliveries, and migration have no deadline. Settings snapshot at `new` and
  `finalize`; config changes made later never reach existing launches, except
  `protocol_fee_share_bps`, `treasury`, and the claim signer, which are read live.

### Reading state

The launchpad exposes few getters; read object fields through Sui RPC (object content, dynamic
fields), or dev-inspect a call.

Getters: `launch::pool_tier` returns `(tick_spacing, fee_rate)` in the adapter's venue units;
`launch::lp_fee_split` returns the `FeeSplit`; `launch::partner_id` returns `Option<ID>`;
`launch::assert_curve_fee_cap` aborts unless a cap is the live curve-fee cap; on a `FeeSplit`,
`allocation::recipients`, `allocation::destination` (of a `Route`), and
`allocation::apportion_fee_split(total)` returning `(creator, auto_lp, rewards, burn, per-route)`;
`blast_fun::bps::value` and `blast_fun::bps::apply_up` on a `Bps`.

`Launch<Meme, Quote>` fields: `lifecycle`; `public_start_ms`; `opening_round_ms`;
`opening_round_bids` (undelivered bids' total); `opening_round_quote` (the pot, then the refund
awaiting delivery); `opening_round_meme`; `sell_burn_bps`; `virtual_quote`; `graduation_target`;
`quote_fee_bps`; `meme_fee_bps`; `migration_witness` (adapter type); `pool_tick_spacing`;
`pool_fee_rate`; `lp_fee_split`; `atomic_supply`; `meme_reserve`; `real_quote_reserve`;
`pending_burn`; `allocation_plan`; `allocated_meme`; `fee_ledger` (`protocol_meme`, `creator_meme`,
`protocol_quote`, `creator_quote`, `protocol_sui`); `creator` (`Some` until claimed or reassigned);
`curve_fee_cap_id`; `blast_metadata_cap_id`; `partner_id`. The `Meme` and `Quote` types are the
object's type arguments.

| Question | Answer |
| --- | --- |
| Price | `(virtual_quote + real_quote_reserve) / meme_reserve` Quote atoms per Meme atom; scale by `10^meme_decimals / 10^quote_decimals` for whole tokens; times one billion tokens for fully diluted value |
| Progress to graduation | `real_quote_reserve / graduation_target` |
| Quote still needed | `ceil((graduation_target - real_quote_reserve) * 10,000 / (10,000 - quote_fee_bps))` gross |
| Tradeable? | buy: `lifecycle` is `Live`; sell: also `public_start_ms` is set |
| Opening round end | `public_start_ms + opening_round_ms` |
| One bidder's pending bid | dynamic field `launch::OpeningRoundBidKey(address)` on the launch (a `u64`); absent once delivered |
| Unclaimed creator / Blast fees | `fee_ledger` balances |
| Is this cap live? | its object ID equals `curve_fee_cap_id` or `blast_metadata_cap_id` |
| Coin metadata, supply mode, total supply | the shared `Currency<Meme>` |

`LaunchConfig` fields: `meme_decimals`, `quotes` (a `Table` keyed by the Quote `TypeName` with
original IDs), `quote_fee_bps`, `meme_fee_bps`, `migration_witnesses`, `protocol_allocation`
(`meme_bps`, `quote_bps`), `creation_fee` (MIST); accepted partners are dynamic fields
`launch_config::PartnerKey(ID)` holding `accepted_until_ms`. `RuntimeConfig` fields:
`creator_claim_signer_public_key`, `protocol_fee_share_bps`, `treasury`. Preview a trade exactly by
dev-inspecting `launch::buy` or `launch::sell` against the live launch.

### Events

Every launchpad event is wrapped: its on-chain type is
`<blast_fun original id>::blast_events::Event<<blast_fun original id>::events::Name>`
(`blast_fun::blast_events::Event`). Filter by that full event type, not by the called module:
`blast_fun::events::Migrated`, for example, is emitted inside an adapter's call. Events do not carry
the transaction sender; take it from the transaction.

| Event | Emitted by | Key fields and what to derive |
| --- | --- | --- |
| `blast_fun::events::LaunchTicketCreated` | coin publish | `ticket_id`, `meme` type, `decimals`, `metadata_cap_id`, `creator`, `burnable`, `sell_burn_bps` |
| `blast_fun::events::LaunchCreated` | `launch::finalize` | `launch_id`, `ticket_id` (join to the ticket for the Meme type), `quote` type, `migration_witness`, pool tier, `lp_fee_split`, `virtual_quote`, `graduation_target`, both fee rates, the full `allocation_plan` with Blast's shares, `opening_round_ms`, `creation_fee`, `partner_id` |
| `blast_fun::events::LaunchShared` | `launch::share` | `public_start_ms`; round end is this plus `opening_round_ms` |
| `blast_fun::events::OpeningRoundJoined` | join | `quote` added and `bids` (pot total); the bidder is the transaction sender |
| `blast_fun::events::OpeningRoundSettled` | settle | `bids`, `meme` bought, `quote` held for refund |
| `blast_fun::events::OpeningRoundDelivered` | deliver | `bidder`, `bid`, `meme`, `quote` paid |
| `blast_fun::events::Bought` | buy, settlement | `quote_in` (gross used), `meme_out_gross`, `meme_out_net`, `quote_refund`, the four fee parts, reserves after; graduated when `real_quote_reserve >= graduation_target`. A `Bought` before `LaunchShared` in the creation transaction is the creator's buy; the one beside `OpeningRoundSettled` is the pot's |
| `blast_fun::events::Sold` | sell | `meme_in_gross`, `pending_burn` added, `quote_out_gross`, the four fee parts, reserves after |
| `blast_fun::events::CreatorCapsClaimed` | creator claim | `meme` type and both cap IDs (no launch ID: one launch per Meme type) |
| `blast_fun::events::CurveFeeCapReassigned`, `blast_fun::events::MetadataCapReassigned` | admin | `launch_id`, new cap ID, `recipient` |
| `blast_fun::events::MemeMetadataUpdated` | metadata setters | `launch_id`, current `name`, `description`, `icon_url` |
| `blast_fun::events::CreatorFeesClaimed` | creator fee claim | `launch_id`, `meme_amount`, `quote_amount` |
| `blast_fun::events::ProtocolFeesClaimed` | Blast fee claims | `treasury` and its Meme, Quote, SUI amounts; partner amounts (0 without a partner) |
| `blast_fun::events::MigrationAllocationPaid` | migration | one per recipient: `destination`, `meme`, `quote` |
| `blast_fun::events::ProtocolFeesAccrued` | migration | Blast's one-time Meme and Quote allocation |
| `blast_fun::events::Migrated` | migration | `meme`, `quote` handed to the pool, `disposed_meme`, `total_supply_after` |

Config events: `blast_fun::events::QuoteSet`, `blast_fun::events::MemeDecimalsSet`,
`blast_fun::events::MigrationWitnessSet`, `blast_fun::events::LaunchTradeFeesChanged`,
`blast_fun::events::CreationFeeChanged`, `blast_fun::events::ProtocolAllocationSet`,
`blast_fun::events::PartnerAdded`, `blast_fun::events::PartnerRemoved`,
`blast_fun::events::ProtocolFeeShareChanged`, `blast_fun::events::TreasuryChanged`,
`blast_fun::events::CreatorClaimSignerSet`. Outside the envelope: the Cetus adapter's
`blast_fun_migrators::blast_events::CetusPoolReserved` at creation, and
`blast_partners::blast_partners::PartnerPaid` for each partner payout.

### Aborts

Launchpad aborts carry a numeric code from `blast_fun::errors`; the abort location is the module
that detected it.

| Flow | Code, constant (module) | Fix |
| --- | --- | --- |
| any | 13 in `blast_admin::operational_version` | call the launchpad's current package ID |
| publish | 9 `blast_fun::errors::EInvalidSellBurnBps` (`launch_ticket`); 25 `blast_fun::errors::EInvalidCreatorRecipient`, 26 `blast_fun::errors::EInvalidAccountCommitment` (`creator_authority`); `EInvalidSymbol` in `sui::coin_registry`; arithmetic overflow | sell-burn at most 5,000; a non-zero address or a 32-byte commitment; an ASCII-printable symbol; decimals at most 10 |
| start | 11 `blast_fun::errors::EInvalidMemeQuotePair` (`launch`) | Quote must differ from Meme |
| start | 32 `blast_fun::errors::EQuoteNotAllowed`, 3 `blast_fun::errors::EMigrationWitnessNotAllowed`, 2 `blast_fun::errors::EDecimalsNotAllowed` (`launch_config`) | use an admitted Quote, adapter, and decimals |
| building values | 0 `blast_fun::errors::EInvalidBps` (`bps`); 6 `blast_fun::errors::EInvalidDestination`, 7 `blast_fun::errors::EInvalidShares`, 8 `blast_fun::errors::ERecipientCapacityReached`, 24 `blast_fun::errors::EDuplicateDestination` (`allocation`) | rates at most 10,000; non-zero addresses; curve and pool Meme positive; split sums to 10,000; at most 16 distinct routes |
| finalize | `std::option` `EOPTION_NOT_SET` | set the virtual Quote, target, plan, and LP-fee split |
| finalize | 35 `blast_fun::errors::EInvalidCreationFee`, 33 `blast_fun::errors::EInvalidVirtualQuote`, 13 `blast_fun::errors::EInvalidOpeningRound`, 12 `blast_fun::errors::EMemeSymbolTooLong`, 14 `blast_fun::errors::EInvalidGraduationTarget` (`launch`) | exact fee coin; virtual Quote above 0; round 0 or 60,000 to 300,000; symbol at most 32 bytes; target big enough that the pool's Quote share is at least 1 |
| finalize | 7 `blast_fun::errors::EInvalidShares`, 8 (`allocation`) | plan plus Blast's allocation must sum to 10,000 per asset; at most 16 recipients |
| finalize | 10 `blast_fun::errors::EInvalidInitialMemeSupply`, 9 `blast_fun::errors::EInvalidSellBurnBps` (`launch_ticket`) | an untouched ticket with sell-burn at most 5,000 |
| set partner | 36 `blast_fun::errors::EPartnerNotAccepted` (`launch_config`) | name a partner `LaunchConfig` accepts now |
| buy, sell | 15 `blast_fun::errors::EInvalidLaunchLifecycle` (`launch`) | trade only while `Live`; sell only after share |
| buy | 17 `blast_fun::errors::EZeroTradeOutput` (`launch`), 16 `blast_fun::errors::ESlippageExceeded` | larger input; lower `min_meme_out` or re-quote |
| sell | 17 (`curve`), 16 (`launch`) | larger input; lower `min_quote_out` |
| join | 15, 18 `blast_fun::errors::EOpeningRoundEnded`, 34 `blast_fun::errors::EZeroOpeningRoundBid` (`launch`) | join during the round with a non-zero coin |
| settle | 15, 19 `blast_fun::errors::EOpeningRoundNotEnded` (`launch`) | wait for the end; settle once |
| deliver | 15 (`launch`); `sui::dynamic_field` code 1 | settle first; the address has no undelivered bid |
| creator claim | 15 (`launch`) before share; `std::option` `EOPTION_NOT_SET` when already claimed or reassigned, or when an account claim passes `None` | claim once, after share |
| creator claim | 30 `blast_fun::errors::ECreatorNotSender`, 28 `blast_fun::errors::EInvalidCreatorClaimAttestation`, 29 `blast_fun::errors::ECreatorClaimExpired`, 31 `blast_fun::errors::EInvalidCreatorClaimSignature` (`creator_authority`); a truncated attestation aborts in `sui::bcs` | send from the recipient address with `None`, or a fresh, well-formed attestation for this sender |
| creator fees, metadata | 22 `blast_fun::errors::ECreatorCapNotLive` (`launch`); 20 `blast_fun::errors::ENothingAccrued` (`fees`); 23 `blast_fun::errors::EUnchanged` (`launch`) | use the live cap; wait for fees; pass a new value |
| Blast fee claim | 37 `blast_fun::errors::EPartnerMismatch` (`launch`); 20 (`fees`) | use the call that matches `partner_id`, with that partner |
| migration | 15, 21 `blast_fun::errors::EInvalidMigrationWitness` (`launch`) | migrate only `MigrationReady` launches, through their own adapter |

Admin setters also abort with 1 `blast_fun::errors::EInvalidTradeFeeBps`, 4
`blast_fun::errors::EInvalidMigrationWitnessType`, 5
`blast_fun::errors::EInvalidProtocolAllocation`, 6 (zero treasury), 25
`blast_fun::errors::EInvalidCreatorRecipient`, 27
`blast_fun::errors::EInvalidCreatorClaimPublicKey`, 36, or 23; and in `blast_acl::sign_in` when
the cap is not a live admin cap or lacks the role.

### Pitfalls

- Building the plan to sum to 10,000 on its own. Blast's allocation is added at finalization, so
  read `LaunchConfig.protocol_allocation` and leave exactly that room in each asset.
- Passing the pre-registration `Currency<Meme>`. Finalization needs the shared one that
  `0x2::coin_registry::finalize_registration` creates, in a separate earlier transaction.
- Trying to claim the creator caps, or to use the launch, after `launch::share` in the creation
  PTB. The launch is consumed by `share`; claim in a later transaction.
- Paying a creation fee that is close but not exact, or forgetting the coin when the fee is zero.
- Expecting to add a partner later. Only `launch::set_partner` before `finalize` names one.
- Calling `launch::claim_protocol_fees` on a launch with a partner (or the reverse); it aborts.
- Dropping returned coins. `launch::buy` and `launch::claim_creator_fees` return two coins, either
  possibly zero; transfer or destroy both.
- Setting `min_meme_out` or `min_quote_out` to 0 in production: there is no other price protection.
- Forgetting the sell burn in sell previews: only `x` of the input reaches the curve.
- Indexing opening-round bidders from events alone: `blast_fun::events::OpeningRoundJoined` has no
  bidder field; use the transaction sender, or the launch's `launch::OpeningRoundBidKey` dynamic
  fields, to know whom to deliver to.
- Reassigning only one creator cap for an unclaimed launch. Either reassignment cancels the pending
  claim for both caps, so the other cap stays unissued until it is reassigned too.
- Deleting a live cap: curve fees or metadata stay locked until a creator admin reassigns it.
- Calling an old package ID after an upgrade: every protected call aborts. Call the current package
  ID; types and events keep the original ID.
- Choosing a Cetus tick spacing that Cetus does not register, or a Bluefin tier outside its bounds:
  the start aborts, and the tier can never change after creation.
- Filtering events by emitting module instead of by the full `blast_fun::blast_events::Event` type.

### Q&A

**How do I show a launch's current price and market cap?** Read `virtual_quote`,
`real_quote_reserve`, and `meme_reserve` from the launch (or the reserves from the latest
`blast_fun::events::Bought` or `blast_fun::events::Sold`). Price is
`(virtual_quote + real_quote_reserve) / meme_reserve` Quote atoms per Meme atom; adjust for both
decimals and multiply by one billion tokens for fully diluted value.

**How do I quote a buy or sell exactly?** Apply the formulas under Curve math with the launch's
snapshotted fee rates and sell-burn rate, or dev-inspect `launch::buy` / `launch::sell` with real
coins. Both round against the trader.

**What happens when a buy overshoots the graduation target?** The launch uses only the gross Quote
needed to bring the real reserve to the target and returns the rest as the second coin of
`launch::buy`. The launch becomes `MigrationReady` and all buys and sells stop.

**Who migrates the launch, and when?** Anyone, as soon as it is `MigrationReady`, through the
adapter it started with (`blast_fun_migrators::cetus::migrate` or
`blast_fun_migrators::bluefin::migrate`). Only that adapter's witness passes `launch::migrate`.

**What happens to unsold tokens and the sell burn?** Both are disposed of at migration: burned when
the supply is burn-only, or sent to `@0x0` when it is fixed. `blast_fun::events::Migrated` reports
`disposed_meme` and `total_supply_after`.

**Can the creator change the target, plan, fees, tier, or LP-fee split after launch?** No. They are
fixed at creation. Only the metadata (name, description, icon) changes, with the metadata cap;
after migration the curve-fee cap holder can change the LP-fee split in the migrators' vault.

**How does the creator get paid?** The creator recipient claims a `CurveFeeCap<Meme>` once with
`launch::claim_creator_caps`, then calls `launch::claim_creator_fees` at any time for its share of
every trade fee. After migration the same cap claims the creator's LP-fee share from the vault.

**How does the opening round treat early buyers?** Every bid, including the creator's before share,
joins one pot that buys once at settlement, so all bidders pay the same average price. Each bidder
receives Meme and refunded Quote in proportion to its bid, rounded down, with the last delivery
taking the remainder.

**Does a partner earn on a launch?** Only if named at creation with `launch::set_partner`. When
anyone claims Blast's fees with `launch::claim_protocol_fees_with_partner`, the partner receives its
share of Blast's trade fees, the creation fee, and the one-time migration allocation; the vault
inherits the partner for LP fees.

**Can a launch fail or be refunded?** No. There is no cancellation, expiry, or refund: a launch that
never reaches its target stays `Live`, and holders exit by selling to the curve.
