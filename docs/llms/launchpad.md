## Launchpad

### What it is

The Blast launchpad (package `blast_fun`) launches a new coin on a bonding curve. A creator
publishes a small generated coin package, which mints exactly one billion whole tokens into a
`launch_ticket::LaunchTicket` and hands the creator the coin's `TreasuryCap` beside it. In one
transaction the creator prepares the coin on a venue (Cetus or Bluefin), which returns a sealed
ticket for that venue, and turns the ticket and the cap into a `launch::Launch<Meme, Quote>`. The
creator chooses the curve's starting price, the Quote amount at which the curve closes (the
graduation target), how the supply and the final Quote are split at migration, and how the future
pool's LP fees are split. Anyone then buys and sells `Meme` against `Quote` on a constant-product
curve. When the curve's real Quote reserve reaches the target, trading stops and the launch becomes
`MigrationReady`; the launch's venue then moves the pool's share of Meme and Quote into a new pool
and a locked LP vault. `Meme` is the generated coin type and `Quote` is the coin it trades against
(for example SUI). Blast takes a share of every trade fee, a SUI creation fee, an optional one-time
share of the supply and of the final Quote, and a share of the pool's LP fees; a Blast partner named
at creation earns a cut of Blast's fees.

This guide covers everything up to and including `MigrationReady`, and what the launchpad itself
does at migration. The venue calls (preparing a coin, migrating, collecting LP fees) are in the
venues guide; the vault that holds the liquidity (`blast_vault::vault::Vault`) is in the vault
guide; the shared values a launch passes between calls (`blast_core::bps::Bps`,
`blast_core::fee_split::FeeSplit`, `blast_core::migration::VenueTicket`,
`blast_core::migration::Migration`, `blast_core::owner_proof::OwnerProof`) are in the shared core
guide.

### Objects and authority

#### Shared objects

| Object | Created | Holds | Who writes it |
| --- | --- | --- | --- |
| `package_version::PackageVersion<BLAST_FUN>` | `blast_admin::package_admin::wrap` | the active version and the Create, Trading, and Migrate pause bits | upgrade, pause, and unpause admins |
| `launch_config::LaunchConfig` | package publish | policy new launches use: admitted Meme decimals, admitted Quote types, trade fees, admitted venues, Blast's one-time migration allocation, Blast's LP-fee share, the creation fee, accepted partners | Blast admins |
| `runtime_config::RuntimeConfig` | package publish | settings read live: the account-claim signer keys and Blast's share of every trade fee | Blast admins |
| `blast_core::blast_treasury::Treasury` | `blast_core` publish | the one address every Blast fee is paid to, for every product and vault | treasury admin |
| `launch::Launch<Meme, Quote>` | `launch::finalize`, shared by `launch::share` | one launch: lifecycle, curve reserves, settings, venue, Blast's fee ledger and the creator's fee balances, opening-round pot, migration allocations | trades, claims, migration |
| `blast_admin::package_admin::PackageAdmin<BLAST_FUN>` | `blast_admin::package_admin::wrap` | the package's `Publisher` and `UpgradeCap` | upgrade admin only |
| `Currency<Meme>` | `0x2::coin_registry::finalize_registration` | the coin's name, symbol, decimals, description, icon URL, and supply state (Sui Coin Registry) | the launch, through its internal `MetadataCap<Meme>` |

`BLAST_FUN` is `blast_fun::blast_fun::BLAST_FUN`, the package's one-time witness. Publication
hands the publisher a `package_version::Publication<BLAST_FUN>`, which the publication PTB passes
with the fresh `UpgradeCap` to `blast_admin::package_admin::wrap`. Every mutating launchpad call
takes the shared `PackageVersion<BLAST_FUN>` and aborts when it is not the current version (see
Aborts).

#### Owned objects and capabilities

- `launch_ticket::LaunchTicket<Meme>` (`key, store`): created when the generated coin package is
  published and sent to the publisher. It holds the whole supply as a `Balance<Meme>`, the
  `MetadataCap<Meme>`, the creator recipient, the decimals, the supply mode (`burnable`), and the
  sell-burn rate. No call releases its contents except `launch::finalize`.
- `TreasuryCap<Meme>` (`key, store`): created by the same publish and sent to the publisher beside
  the ticket. The launcher passes it by reference to the venue's prepare call (Cetus mints the coin's
  pool-creation capability from it) and by value to `launch::new`. `launch::finalize` hands it to
  the Coin Registry, which makes the supply burn-only or fixed, so no one can mint Meme afterwards.
  The ticket and the cap can be transferred before launch; whoever launches needs both.
- `creator_authority::CurveFeeCap<Meme>` (`key, store`): authority over the launch's creator trade
  fees, and over the launch's LP vault through `launch::prove_owner`. The launch honors only the cap
  ID it records in `curve_fee_cap_id`.
- `creator_authority::CreatorMetadataCap<Meme>` (`key, store`): authority to change the coin's name,
  description, and icon URL through the launch. The launch honors only the cap ID in
  `creator_metadata_cap_id`.
- Both caps are issued once by `launch::claim_creator_caps` to the creator recipient, or reissued
  by a Blast creator admin. A holder may delete a cap with
  `creator_authority::destroy_curve_fee_cap` or `creator_authority::destroy_creator_metadata_cap`;
  deleting the live cap leaves fees unclaimable (or metadata frozen) until an admin reassigns it.

The native `MetadataCap<Meme>` never leaves the launch.

#### Creator recipient

`creator_authority::CreatorRecipient` names who may claim the creator caps. It is fixed in the
generated package and carried by the ticket into the launch. It may differ from the launcher (the
wallet that publishes and launches).

- `Address(address)`: built by `creator_authority::new_address` (non-zero). That wallet claims by
  sending the claim transaction itself.
- `Account(vector<u8>)`: built by `creator_authority::new_account` from a 32-byte opaque Blast
  account commitment. Any wallet claims by presenting an expiring signature from the Blast backend
  that binds the commitment to that wallet (see Flows).

#### Values built inside a PTB

These have `copy, drop, store` and cannot be passed as pure arguments; build them with their
constructors in the same PTB:

- `blast_core::bps::Bps`: a rate from 0 to 10,000 basis points, built by `blast_core::bps::new`
  (aborts above 10,000).
- `allocation::RecipientShare` (`allocation::recipient_share`, wrapping a `blast_core::payout::Recipient`
  from `blast_core::payout::recipient`, paid outright or under `blast_core::payout::VestingTerms`)
  and `allocation::AllocationPlan` (`allocation::plan`): the migration split of the supply and the
  final Quote.
- `blast_core::fee_split::FeeSplit` (`blast_core::fee_split::new`), from
  `blast_core::fee_split::Route` values (`blast_core::fee_split::route`), each naming a
  `blast_core::fee_split::Destination` (see Flow 3, step 6).

These have no abilities, so the PTB that creates one must consume it:

- `blast_core::migration::VenueTicket<Meme, Quote>`: returned by the venue's prepare call,
  consumed by `launch::new`.
- `launch::LaunchInitializer<Meme, Quote>`: returned by `launch::new`, consumed by
  `launch::finalize`.
- `blast_core::migration::Migration<Meme, Quote>`: returned by `launch::migrate`, consumed by the
  launch's venue inside its migrate call.
- `blast_core::owner_proof::OwnerProof`: returned by `launch::prove_owner`, consumed by a vault
  owner call.

`launch::Launch` has only `key`: the PTB that finalizes it must share it with `launch::share`.

#### Admin roles

Blast administration uses the shared ACL from `blast_admin`. A Blast admin holds a
`blast_acl::AdminCap` granted roles; in a PTB it calls `blast_acl::sign_in` with the shared
`blast_acl::ACL` to get a `blast_acl::AdminWitness` for one role, which the setter takes by
reference. A role authorizes only the functions that name it. The package roles are
`blast_admin`'s generic roles typed by `BLAST_FUN`; the product roles are the shared ones in
`blast_core::blast_domain`, which the presale, the vault, and the venues use too:

| Role | Launchpad functions it authorizes |
| --- | --- |
| `blast_admin::package_admin::PauseAdmin<BLAST_FUN>` | `blast_admin::package_admin::pause` |
| `blast_admin::package_admin::UnpauseAdmin<BLAST_FUN>` | `launch_config::unpause` |
| `blast_admin::package_admin::UpgradeAdmin<BLAST_FUN>` | `blast_admin::package_admin::schedule_upgrade`, `blast_admin::package_admin::schedule_make_immutable`, `blast_admin::package_admin::schedule_upgrade_delay`, `blast_admin::package_admin::authorize_upgrade`, `blast_admin::package_admin::commit_upgrade_and_advance`, `blast_admin::package_admin::make_immutable` |
| `blast_admin::package_admin::CancelAdmin<BLAST_FUN>` | `blast_admin::package_admin::cancel_upgrade_action` |
| `blast_core::blast_domain::CancelAdmin` | each launchpad `cancel_*` call below |
| `blast_core::blast_domain::CreatorAdmin` | `launch::schedule_curve_fee_cap_reassignment`, `launch::schedule_creator_metadata_cap_reassignment`, `launch::schedule_curve_fee_cap_delay`, `launch::schedule_creator_metadata_cap_delay` |
| `blast_core::blast_domain::TreasuryAdmin` | `launch_config::schedule_protocol_allocation`; the treasury address itself with `blast_core::blast_treasury::schedule_destination` |
| `blast_core::blast_domain::FeeAdmin` | `launch_config::schedule_trade_fees`, `launch_config::schedule_creation_fee`, `launch_config::schedule_protocol_lp_fees`, `launch_config::add_partner`, `launch_config::remove_partner`, `runtime_config::schedule_protocol_fee_share` |
| `blast_core::blast_domain::ListingAdmin` | `launch_config::set_meme_decimals_allowed`, `launch_config::set_quote_allowed` |
| `blast_core::blast_domain::VenueAdmin` | `launch_config::schedule_venue`, `launch_config::remove_venue`, `launch_config::schedule_venue_delay` |
| `blast_core::blast_domain::ClaimSignerAdmin` | `runtime_config::schedule_creator_claim_signer`, `runtime_config::revoke_creator_claim_signer`, `runtime_config::schedule_creator_claim_signer_delay` |

Integrators cannot call admin functions. What each setter changes is under "Admin operations".

### Lifecycle

`launch::Lifecycle` has four states:

```text
[OpeningRound ->] Live -> MigrationReady -> Migrated
```

| State | Entered by | Allows |
| --- | --- | --- |
| `OpeningRound` | `launch::finalize` with a non-zero opening round | `launch::join_opening_round` until the round ends (the creator also before share); `launch::settle_opening_round` once it has ended |
| `Live` | `launch::finalize` without an opening round, or `launch::settle_opening_round` | `launch::buy` (also before share, so the creator can buy first); `launch::sell` only after share |
| `MigrationReady` | a buy, or the opening-round settlement, that leaves the real Quote reserve at or above the graduation target | migration through the launch's venue; no trading |
| `Migrated` | `launch::migrate`, called inside the venue's migrate | nothing on the curve |

Separately, `public_start_ms` is set once by `launch::share`. In every state:
`launch::claim_creator_caps` (after share), `launch::claim_creator_fees`, `launch::prove_owner`,
metadata updates, `launch::claim_protocol_fees` and `launch::claim_protocol_fees_with_partner`, and
admin reassignments. `launch::deliver_opening_round` works in every state after `OpeningRound`,
including `Migrated`. A launch that never reaches its target stays `Live` forever: there is no
cancel, expiry, or refund path.

The package is published with every pause bit set. `launch_config::unpause` clears bits only once
every policy notice is guarded (see Emergency pause).

### Flows

Creating a launch takes three transactions, because each step needs an object the previous one
creates. `Clock` is the shared object at `0x6`.

#### Flow 1: publish the generated coin package (anyone; the publisher receives the ticket and the cap)

The coin is a one-module package built from the `launch_ticket_template` template. Its only code is
an initializer that runs at publish: it builds the creator recipient, calls `launch_ticket::new`
with the package's one-time witness, and transfers both the ticket and the `TreasuryCap<Meme>` to
the publisher. It exposes no public functions. Patch these constants in the compiled template:

| Constant | Meaning | Checked |
| --- | --- | --- |
| `SYMBOL` | coin symbol | ASCII printable (Coin Registry) |
| `NAME`, `DESCRIPTION`, `ICON_URL` | coin metadata | valid UTF-8; changeable later with the metadata cap |
| `DECIMALS` | coin decimals | must be admitted in `LaunchConfig` when the launch starts; default admitted set is 6 and 9 |
| `BURNABLE` | `true`: supply becomes burn-only; `false`: supply becomes fixed | none |
| `SELL_BURN_BPS` | share of each sale's post-fee Meme set aside to burn | at most 5,000 (50%), at publish and again at finalization |
| `CREATOR_RECIPIENT_BYTES`, `CREATOR_IS_ACCOUNT` | 32 bytes: an account commitment, or an address when `CREATOR_IS_ACCOUNT` is `false` | address must be non-zero |

In the template the coin type is `<new package>::meme::MEME`. Blast's own launch tooling renames the
module and witness after the symbol, so take a coin's exact type from its publish effects or from
`blast_fun::events::LaunchTicketCreated` rather than assuming `meme::MEME`. Patch the dependency
address to the launchpad's original package ID and publish with every transitive dependency: `0x1`,
`0x2`, and the current package IDs of the launchpad, `blast_admin`, `blast_core`, `blast_partners`,
and `blast_fun_vesting` (Sui rejects a publish whose dependency list misses one of the launchpad's
own dependencies). Handle the `UpgradeCap` that the Publish command returns (transfer it or make the
package immutable); it grants no authority over the coin.

Publishing:

1. Creates the currency through the Coin Registry one-time-witness path and mints
   `1_000_000_000 * 10^decimals` atomic units into the ticket (aborts on `u64` overflow, so decimals
   above 10 fail).
2. Sends `LaunchTicket<Meme>` and `TreasuryCap<Meme>` to the publisher and the unregistered
   `Currency<Meme>` to the Coin Registry address `0xc`.
3. Emits `blast_fun::events::LaunchTicketCreated`.

Do not mint or burn with the `TreasuryCap`: `launch::finalize` checks that the cap's total supply
and the ticket's balance are both exactly the minted supply.

#### Flow 2: register the currency (anyone)

Call `0x2::coin_registry::finalize_registration<Meme>` with the shared `CoinRegistry` at `0xc`
and the pending `Currency<Meme>` as a `Receiving` argument. It re-creates the currency as a shared
object at a derived address. Use that shared `Currency<Meme>` in every later step.

#### Flow 3: prepare, create, configure, and share the launch (holder of the ticket and the cap, one PTB)

Type arguments are `<Meme, Quote>` on every call below. Each initializer setter, `launch::finalize`,
and `launch::share` takes the launchpad `PackageVersion` (shared, immutable) right after the
initializer or launch. The ticket and the `TreasuryCap` are owned objects; the venue ticket, the
initializer, and the launch are values returned by earlier commands of the same PTB.

1. Prepare the coin on the chosen venue (holder of the `TreasuryCap`). Both calls return a
   `blast_core::migration::VenueTicket<Meme, Quote>` sealed by the venue's witness, for exactly this
   Meme and Quote:
   - Cetus: `blast_migrators::cetus::prepare` with the migrators'
     `PackageVersion<BLAST_MIGRATORS>` (shared), the migrators'
     `blast_migrators::venue_config::VenueConfig` (shared, mutable), Cetus's `GlobalConfig`
     (shared) and `Pools` (shared, mutable), the `TreasuryCap<Meme>` (owned, by mutable reference),
     and `tick_spacing: u32`. It mints the Meme type's single Cetus `PoolCreationCap` from the
     treasury cap, registers the pair at that tick spacing, keeps the cap and the tick spacing in
     `VenueConfig`, and emits `blast_migrators::events::CetusPoolReserved`. It aborts when
     Cetus does not register the spacing or refuses the pair at it.
   - Bluefin: `blast_migrators::bluefin::prepare` with the migrators' `PackageVersion`,
     `VenueConfig` (mutable), the `TreasuryCap<Meme>` (owned, by immutable reference), the
     `Currency<Meme>`, `tick_spacing: u32` (1 to 400), and `fee_rate: u64` (1 to 20,000, Bluefin's
     units). It records the tier in `VenueConfig`; out-of-range values abort with
     `blast_migrators::errors::EInvalidTier`, and a Meme symbol over 32 bytes with
     `blast_migrators::errors::ESymbolTooLong`.

   The venue keeps the pool tier; it can never change afterwards.
2. `launch::new` with the `LaunchTicket<Meme>` (owned, by value), the same `TreasuryCap<Meme>` (owned,
   now by value), `PackageVersion`, `LaunchConfig` (shared, immutable), and the `VenueTicket` from
   step 1. It checks that Create is not paused and that Meme and Quote differ, redeems the venue
   ticket, checks that `LaunchConfig` admits the Quote, the venue, and the Meme decimals, snapshots
   the trade fees, and returns a `LaunchInitializer<Meme, Quote>`. The launch stores the venue: only
   that venue can migrate it.
3. `launch::set_virtual_quote` with the initializer (mutable) and a `u64`: the virtual Quote reserve,
   in Quote atomic units. Required, non-zero. It sets the opening price.
4. `launch::set_graduation_target` with the initializer and a `u64`: the real Quote reserve at which
   trading closes. Required.
5. Build the allocation plan: one `blast_core::bps::new` per share; per project recipient, one
   `blast_core::payout::recipient` (a non-zero address and `Option<VestingTerms>`: `None` pays
   outright, `Some` from `blast_core::payout::vesting_terms` locks the allocation in a linear
   schedule starting at migration) and one `allocation::recipient_share` (that recipient, Meme share,
   Quote share); a `MakeMoveVec` of type
   `allocation::RecipientShare` (may be empty); then `allocation::plan` with the curve Meme share, pool
   Meme share, pool Quote share, and the vector. Pass it to `launch::set_allocation_plan`. Required.
6. Build the LP-fee split. For each route, build a destination with
   `blast_core::fee_split::address_destination` (an address),
   `blast_core::fee_split::owner_destination` (the curve-fee cap holder),
   `blast_core::fee_split::auto_lp_destination`, `blast_core::fee_split::holder_rewards_destination`,
   or `blast_core::fee_split::burn_destination`, then `blast_core::fee_split::route` with the
   destination and a `Bps`. Collect the routes with a `MakeMoveVec` of type
   `blast_core::fee_split::Route` and call `blast_core::fee_split::new`. Pass the `FeeSplit` to
   `launch::set_lp_fee_split`. Required.
7. Optional: `launch::set_opening_round` with a length in ms: 0 (default, no round) or 60,000 to
   300,000.
8. Optional: `launch::set_partner` with `LaunchConfig`, a `blast_partners::blast_partners::Partner`
   (shared, immutable), and `Clock`. The partner must be one `LaunchConfig` accepts now. This is the
   only time a launch can name a partner.
9. Pay the creation fee: `SplitCoins` from the gas coin for exactly the applied
   `LaunchConfig.creation_fee` in MIST (use `0x2::coin::zero<0x2::sui::SUI>` when it is zero).
10. `launch::finalize` consumes the initializer and takes `PackageVersion`, the shared
    `launch::LaunchRegistry` (mutable), the shared `Currency<Meme>` (mutable), `LaunchConfig`, and
    the fee coin. It returns the `Launch<Meme,
    Quote>` value. It checks every setting (see Aborts), adds Blast's current one-time allocation to
    the plan and requires each asset to sum to 10,000, fixes the supply as burn-only or fixed in the
    Coin Registry (consuming the `TreasuryCap`), keeps the curve's Meme as `meme_reserve` and the
    rest as `allocated_meme`, stores the creation fee in the fee ledger, and emits
    `blast_fun::events::LaunchCreated`. The lifecycle is `OpeningRound` when an opening round was
    set, else `Live`.
11. Optional creator purchase before anyone else can trade:
    - without an opening round: `launch::buy` on the launch value (see Buy); transfer both returned
      coins. A buy here may even reach the target.
    - with an opening round: `launch::join_opening_round` on the launch value (see Opening round);
      the creator's bid joins the same pot at the same price as everyone's.
12. `launch::share` consumes the launch value and takes `PackageVersion` and `Clock`: it records
    `public_start_ms` (now), shares the launch, and emits `blast_fun::events::LaunchShared`. The
    opening round, if any, ends `opening_round_ms` later. This must be the launch's last use in the
    PTB.

The creator caps cannot be claimed in this PTB; claim them in a later transaction. Any abort reverts
the whole PTB, including the venue's preparation.

#### Opening round (anyone)

1. Join: `launch::join_opening_round` with the shared launch, `PackageVersion`, a `Coin<Quote>`
   (non-zero), and `Clock`. It adds the coin to one pot and to the sender's bid, kept as a dynamic
   field `launch::OpeningRoundBidKey(sender)` on the launch. Repeated joins add up. Emits
   `blast_fun::events::OpeningRoundJoined`. Allowed until `public_start_ms + opening_round_ms`.
2. Settle: from that time on, anyone calls `launch::settle_opening_round` with the launch,
   `PackageVersion`, `RuntimeConfig`, and `Clock`. The lifecycle becomes `Live`, and the whole pot
   buys from the curve once, with the usual fees, the graduation cap, and no minimum output. The Meme
   bought and any Quote refunded stay in the launch for delivery. A pot too small to buy one Meme
   atom is held whole for refund unless its net Quote reaches the target. Emits
   `blast_fun::events::Bought` (when Quote enters the reserve) and
   `blast_fun::events::OpeningRoundSettled`. If the pot reached the target, the launch is
   `MigrationReady` at once.
3. Deliver: anyone calls `launch::deliver_opening_round` with the launch, `PackageVersion`, and the
   bidder's address. The bidder (not the caller) receives its pro-rata Meme and Quote as coins, and
   its bid record is removed. Emits `blast_fun::events::OpeningRoundDelivered`. One call per bidder;
   it works in any later state.

#### Buy (anyone)

Split the exact input from your Quote coins (from the gas coin when Quote is SUI). `launch::buy`
takes the shared launch, `PackageVersion`, `RuntimeConfig`, that `Coin<Quote>`, and
`min_meme_out: u64`. It returns `(Coin<Meme>, Coin<Quote>)`: the Meme bought (after the Meme fee) and
the Quote refunded past the graduation target. The refund coin is usually zero-valued; it has no
`drop`, so transfer it or destroy it with `0x2::coin::destroy_zero`. Emits
`blast_fun::events::Bought`. The buy that reaches the target makes the launch `MigrationReady`. That
final buy may return zero Meme because of rounding or Meme fees, but only with `min_meme_out = 0`; a
positive minimum still aborts, and non-final zero-output buys abort too.

#### Sell (anyone, after share)

Merge your Meme coins and split the amount to sell. `launch::sell` takes the shared launch,
`PackageVersion`, `RuntimeConfig`, that `Coin<Meme>`, and `min_quote_out: u64`, and returns the Quote
after fees as a `Coin<Quote>`. The Meme fee and the sell-burn share are taken from the input first;
the sell-burn Meme waits in `pending_burn` until migration. Emits `blast_fun::events::Sold`. Trades
take no deadline and no `Clock`: the minimum output is the only price protection.

#### Claim the creator caps (creator recipient, after share)

`launch::claim_creator_caps` takes the shared launch, `PackageVersion`, `RuntimeConfig`, an
`Option<vector<u8>>` attestation, and `Clock`. It returns a `CurveFeeCap<Meme>` and a
`CreatorMetadataCap<Meme>`; transfer both to the sender. It works once, in any state after share.
Emits `blast_fun::events::CreatorCapsClaimed`.

- Address recipient: the sender must be that address; pass `None`.
- Account recipient: pass `Some(attestation)`, obtained from the Blast backend for the sending
  wallet. The attestation is the BCS encoding of `(expiry_ms: u64, signature: vector<u8>)`, 73 bytes
  for a 64-byte signature, with nothing after it. The call checks `Clock` time `<= expiry_ms` and
  verifies the Ed25519 signature against every admitted key in `RuntimeConfig.creator_claim_signers`
  (any one may have signed; with none admitted, every account claim fails) over the 28 ASCII bytes
  of the domain tag `b"blast_fun::creator_claim::v1"` followed by the BCS bytes of
  `creator_authority::CreatorClaimMessage`, whose fields in order are `meme`, `account_commitment`,
  `claimant`, and `expiry_ms`. Here `meme` is the Meme `TypeName` with original package IDs (64 hex
  characters, no `0x`, then `::module::NAME`) and `claimant` is the sender. The signed bytes are:
  the tag (no length prefix), the type-name string's ULEB128 length and ASCII bytes, `0x20` and the
  32-byte commitment, the 32-byte claimant address, then `expiry_ms` as 8 little-endian bytes. There
  is no Sui intent prefix or extra hash.

#### Claim creator trade fees (cap holder: `CurveFeeCap<Meme>`)

`launch::claim_creator_fees` takes the shared launch, `PackageVersion`, and `&CurveFeeCap<Meme>`, and
returns `(Coin<Meme>, Coin<Quote>)` holding all creator fees accrued so far (one may be zero). Works
in any state, including after migration. Emits `blast_fun::events::CreatorFeesClaimed`.

#### Act as the vault's owner (cap holder: `CurveFeeCap<Meme>`)

After migration the launch's vault serves its owner through an owner proof:

1. `launch::prove_owner` with the shared launch (immutable), `PackageVersion`, and the live
   `&CurveFeeCap<Meme>`. It returns a `blast_core::owner_proof::OwnerProof` naming this launch and
   the launchpad's `blast_fun::blast_fun::PackageWitness`.
2. In the same PTB, pass the proof by value to one vault owner call:
   `blast_vault::vault::claim_owner_balances` (returns the owner route's LP fees as two coins; consume
   both), `blast_vault::vault::schedule_fee_split`, or `blast_vault::vault::cancel_fee_split`.

One proof authorizes one call; build a new one for each. A proof for another launch aborts in the
vault. See the vault guide for the vault side.

#### Update coin metadata (cap holder: `CreatorMetadataCap<Meme>`)

`launch::set_name`, `launch::set_description`, and `launch::set_icon_url` each take the launch (by
immutable reference), `PackageVersion`, `&CreatorMetadataCap<Meme>`, the shared `Currency<Meme>`
(mutable), and the new `String`. The value must differ from the current one. Works in any state.
Each emits `blast_fun::events::MemeMetadataUpdated` with all three current values. Symbol and
decimals never change.

#### Claim Blast's launch fees (anyone)

Blast's fees on a launch (its trade-fee share, the creation fee, and the one-time migration
allocation) wait in the launch's `blast_core::protocol_fees::Ledger`, created at finalization under
the launch's `blast_fun::blast_fun::PackageWitness` and bound to its partner, until anyone pays them out:

- Launch without a partner: `launch::claim_protocol_fees` with the launch, `PackageVersion`, and the
  shared `blast_core::blast_treasury::Treasury`. Sends every Blast balance (Meme, Quote, SUI) to
  the treasury's destination.
- Launch with a partner: `launch::claim_protocol_fees_with_partner` with the launch,
  `PackageVersion`, `Treasury`, and the launch's `Partner` (shared); no `Clock`. Each balance first
  pays the partner its applied share through `blast_partners::blast_partners::pay`, then the rest
  goes to the treasury.

Both pay through `blast_core::protocol_fees::pay` or `blast_core::protocol_fees::pay_with_partner`
and emit `blast_core::blast_core_events::ProtocolFeesPaid<Meme, Quote>`, whose `origin` is the
launch ID; an empty ledger sends and emits nothing. Calling the wrong one aborts with
`blast_core::errors::EPartnerMismatch` (`blast_core::protocol_fees`). Blast's LP fees after
migration are paid by the vault, not here.

#### Migration, launchpad side (anyone, through the launch's venue)

Anyone migrates a `MigrationReady` launch with two calls in one PTB: `launch::migrate` with the
launch, `PackageVersion`, `LaunchConfig`, and `Currency<Meme>`, which returns the launch's
`Migration`, then its venue's migrate, `blast_migrators::cetus::migrate` or
`blast_migrators::bluefin::migrate`, with that `Migration` first (arguments in the venues guide),
which redeems it with its own witness and builds the pool and the vault. The `Migration` has no
abilities and only the stored venue's witness can redeem it, so a PTB that does not pass it to that
venue fails. `launch::migrate`:

1. Checks the current version, that Migrate is not paused, and that the launch is
   `MigrationReady`.
2. Apportions the Meme supply and the final real Quote reserve by the allocation plan (see
   Economics).
3. Pays every project recipient its Meme and Quote through `blast_core::payout::pay_or_vest`: as
   coins, or into one shared `blast_fun_vesting::blast_fun_linear_vesting::Vesting` per asset
   starting now for a vesting recipient (zero amounts are skipped). It emits
   `blast_fun::events::MigrationAllocationPaid` for each recipient, naming the Meme and Quote
   schedule IDs when the recipient vests. The venue's migrate passes the `Clock`.
4. Moves Blast's one-time Meme and Quote allocation into the launch's fee ledger and, when either is
   non-zero, emits `blast_fun::events::ProtocolFeesAccrued`.
5. Disposes of the curve's unsold Meme plus `pending_burn`: burned through the Coin Registry when
   the supply is burn-only, otherwise sent to `@0x0`.
6. Sets `Migrated` and emits `blast_fun::events::Migrated`.
7. Seals the vault's terms (`blast_core::migration::vault_terms`) under `blast_fun::blast_fun::PackageWitness`:
   this launch's ID, its LP-fee split, Blast's LP-fee share applied in `LaunchConfig` now, the
   launch's partner, and migration residuals to Blast. It returns a `Migration` holding the pool's
   Meme and Quote and those terms, redeemable only by the launch's venue.

Any failure aborts the whole transaction and leaves the launch `MigrationReady` with every balance in
place. The opening-round balances awaiting delivery are untouched.

#### Admin operations (Blast admin)

Each setter takes the object it changes, `PackageVersion`, and the role's `AdminWitness`. Delayed
schedules abort with code 16 from the Blast admin delayed module of their type (`delayed` for a
setting, `delayed_set` for a venue or signer admission) when nothing would change; "Delayed
administration" lists their events. The allow/remove toggles for Quotes and decimals instead abort
inside `sui::vec_set` when the entry already has the requested state.

- `launch_config::set_quote_allowed` (ListingAdmin, type argument `Quote`), with `allowed: bool`:
  admits or removes a Quote for new launches; existing launches keep trading. Emits
  `blast_fun::events::QuoteAllowed`.
- `launch_config::set_meme_decimals_allowed` (ListingAdmin), with `decimals: u8` and `allowed`.
  Emits `blast_fun::events::MemeDecimalsAllowed`.
- `launch_config::schedule_venue` (VenueAdmin, type argument the venue's witness, for example
  `blast_migrators::cetus::Venue`), with `Clock`: schedules admission after the applied venue
  notice; rejects primitive types and types defined at `0x1` or `0x2`. Anyone applies it with
  `launch_config::apply_venue` once ready; CancelAdmin discards it with
  `launch_config::cancel_venue`, even when ready. `launch_config::remove_venue` (VenueAdmin)
  removes a venue for new launches at once and cancels its pending admission. Existing launches
  keep their venue. A venue must also be admitted in the vault's registry to migrate (see the vault
  guide).
- `launch_config::schedule_trade_fees` (FeeAdmin), with Quote and Meme fee `Bps`, each at most 1,000;
  only launches started afterward use them.
- `launch_config::schedule_creation_fee` (FeeAdmin), with an amount in MIST, at most 10,000,000,000
  (10 SUI).
- `launch_config::schedule_protocol_allocation` (TreasuryAdmin), with Meme and Quote `Bps`: Blast's
  one-time share for launches finalized afterward; each asset at most 1,000 (10%).
- `launch_config::schedule_protocol_lp_fees` (FeeAdmin), with Meme and Quote `Bps`: Blast's share of
  each asset in the LP fees of vaults created afterward, each at most 3,000 (30%). Vaults already
  created keep the share they started with.
- `launch_config::add_partner` (FeeAdmin), with a `Partner`: new launches may name it at once;
  cancels a pending removal. The config's `blast_partners::partner_list::PartnerList` emits
  `blast_partners::partner_list::PartnerAdded` with the config as `owner`.
- `launch_config::remove_partner` (FeeAdmin), with a `Partner` and `Clock`: new launches may still
  name it for `blast_partners::blast_partners::delay_ms` (seven days); launches that already name it
  keep paying it. Emits `blast_partners::partner_list::PartnerRemoved`.
- `runtime_config::schedule_protocol_fee_share` (FeeAdmin), with a `Bps`: Blast's share of every trade
  fee on every launch, from the next trade; at most 7,000 (70%), so the creator keeps at least 30%.
- The treasury address is `blast_core::blast_treasury::Treasury`'s, shared by every product and
  vault; a TreasuryAdmin changes it with `blast_core::blast_treasury::schedule_destination`.
- `runtime_config::schedule_creator_claim_signer` (ClaimSignerAdmin), with a 32-byte Ed25519 public
  key and `Clock`: proposes admitting a key that may sign account claims, ready after the applied
  signer notice. Live and pending keys together are capped at four; rescheduling a pending key
  replaces its admission and restarts its notice. `runtime_config::apply_creator_claim_signer`
  (anyone, after the notice) admits it; `runtime_config::cancel_creator_claim_signer` (CancelAdmin)
  discards it, even when ready.
- `runtime_config::revoke_creator_claim_signer` (ClaimSignerAdmin), with the key: removes a live key,
  or discards a pending one, at once. Attestations that key signed stop verifying, including ones
  signed before the revocation.
- Cap reassignment (CreatorAdmin schedules, anyone applies): see "Creator cap reassignment".
- Upgrades (`UpgradeAdmin<BLAST_FUN>`): `blast_admin::package_admin::authorize_upgrade` returns an
  `UpgradeTicket` for an exact, scheduled digest; after the Upgrade command,
  `blast_admin::package_admin::commit_upgrade_and_advance` commits the receipt and advances
  `PackageVersion` in the same transaction. Ending upgrades needs a launchpad wrapper around
  `blast_admin::package_admin::make_immutable`, which takes the launchpad's package witness; the
  launchpad has none yet, so only a later upgrade can add it. The admin guide documents these calls.

Each `schedule_*` setting has an `apply_*` that anyone calls once ready and a `cancel_*` for
CancelAdmin, named after it (for example `launch_config::apply_protocol_lp_fees` and
`launch_config::cancel_protocol_lp_fees`).

### Delayed administration

Each policy owns its applied notice. A value schedule takes the proposed value and the **next**
`delay_ms`, but it is ready at `now + applied delay_ms`: passing zero cannot shorten the current
wait. Application, by anyone with `Clock`, makes the value and the next notice active together.
Rescheduling replaces the proposal and restarts the full applied notice. `CancelAdmin` can cancel
even a ready proposal. A proposal that changes neither value nor notice aborts with code 16
(`EUnchanged`) from Blast admin. Every notice is at most `blast_admin::delayed::max_delay_ms` (30
days). The admin guide documents these delayed primitives in full.

The delayed modules emit every schedule, cancel, and apply event; the launchpad emits none of its
own for them. They are generic in the
operation's key and value type and carry `owner` (the ID of the object that stores the field) and
`key`: `delayed::DelayedScheduled`, `delayed::DelayedCancelled`, and `delayed::DelayedApplied` for a
setting; `delayed_action::ActionScheduled`, `delayed_action::ActionCancelled`, and
`delayed_action::ActionApplied` for upgrades and cap reassignments; `delayed_set::SetScheduled`,
`delayed_set::SetCancelled`, `delayed_set::SetApplied`, and `delayed_set::MemberRemoved` for venue
and signer admissions.

| Operation | Object and field | Key | Value or action type |
| --- | --- | --- | --- |
| Trade fees | `LaunchConfig.trade_fees` | `launch_config::TradeFeesKey` | `launch_config::TradeFees` |
| Migration allocation | `LaunchConfig.protocol_allocation` | `launch_config::ProtocolAllocationKey` | `allocation::ProtocolAllocation` |
| Blast's LP-fee share | `LaunchConfig.protocol_lp_fees` | `launch_config::ProtocolLpFeesKey` | `launch_config::ProtocolLpFees` |
| Creation fee | `LaunchConfig.creation_fee` | `launch_config::CreationFeeKey` | `u64` |
| Venue admissions | `LaunchConfig.venues` | `launch_config::VenueKey` | `TypeName` |
| Account-claim signer keys | `RuntimeConfig.creator_claim_signers` | `runtime_config::ClaimSignerKey` | `vector<u8>` (a 32-byte Ed25519 public key) |
| Blast's trade-fee share | `RuntimeConfig.protocol_fee_share_bps` | `runtime_config::ProtocolFeeShareKey` | `blast_core::bps::Bps` |
| Upgrades and immutability | `PackageAdmin<BLAST_FUN>.upgrade` | `blast_admin::package_admin::UpgradeKey<BLAST_FUN>` | `blast_admin::package_admin::UpgradeAction` |
| Curve-fee cap reassignment | `Launch.curve_fee_cap_reassignment` | `launch::CurveFeeCapReassignment` | `address` (the recipient) |
| Metadata cap reassignment | `Launch.creator_metadata_cap_reassignment` | `launch::CreatorMetadataCapReassignment` | `address` (the recipient) |

Venue admissions share one applied notice across venue types, changed by
`launch_config::schedule_venue_delay` (VenueAdmin), `launch_config::apply_venue_delay` (anyone),
and `launch_config::cancel_venue_delay` (CancelAdmin); pending admissions keep their deadlines.
Account-claim signer keys form one set with its own notice, changed the same way by
`runtime_config::schedule_creator_claim_signer_delay`,
`runtime_config::apply_creator_claim_signer_delay`, and
`runtime_config::cancel_creator_claim_signer_delay`. Admitting a key waits that notice; revocation
is immediate, so a rotation admits the new key before revoking the old one.

The PackageAdmin is `blast_admin`'s generic administration and starts with a 48-hour notice.
`blast_admin::package_admin::schedule_upgrade` takes an exact 32-byte digest;
`blast_admin::package_admin::authorize_upgrade` consumes only that ready digest.
`blast_admin::package_admin::schedule_make_immutable` schedules the end of upgrades, which
`blast_admin::package_admin::make_immutable` executes only from the launchpad's own code (a later
upgrade must add that wrapper). `blast_admin::package_admin::schedule_upgrade_delay` proposes only the notice,
replacing any pending action; anyone applies it with `blast_admin::package_admin::apply_upgrade_delay`.
`blast_admin::package_admin::cancel_upgrade_action` (`CancelAdmin<BLAST_FUN>`) cancels any of these.

#### Creator cap reassignment

Each launch starts both cap notices at 48 hours. CreatorAdmin schedules a replacement recipient with
`launch::schedule_curve_fee_cap_reassignment` or `launch::schedule_creator_metadata_cap_reassignment`, or
only a new notice with `launch::schedule_curve_fee_cap_delay` or
`launch::schedule_creator_metadata_cap_delay`; each operation holds one pending proposal, so either kind
replaces the other. After the notice anyone applies a reassignment with
`launch::apply_curve_fee_cap_reassignment` or `launch::apply_creator_metadata_cap_reassignment`, and a
notice change with `launch::apply_curve_fee_cap_delay` or `launch::apply_creator_metadata_cap_delay`;
calling the other kind's apply aborts with code 18 from `delayed_action`. CancelAdmin cancels with
`launch::cancel_curve_fee_cap_reassignment` or `launch::cancel_creator_metadata_cap_reassignment`.

A reassignment mints a fresh cap, records it as the live one, sends it to the non-zero recipient, and
cancels any unclaimed creator claim for both caps. The old cap stops working: unclaimed curve fees
and the vault's owner proofs follow the new curve-fee cap. Applying emits
`delayed_action::ActionApplied`, then `blast_fun::events::CurveFeeCapReassigned` or
`blast_fun::events::CreatorMetadataCapReassigned`.

### Emergency pause

A `PauseAdmin<BLAST_FUN>` calls `blast_admin::package_admin::pause` to set bits on `PackageVersion`
at once; it emits `blast_admin::blast_admin_events::Paused<BLAST_FUN>`. Only
`UnpauseAdmin<BLAST_FUN>` clears bits, with `launch_config::unpause`, which takes `LaunchConfig`,
`PackageVersion` (mutable), the witness, `PackageAdmin<BLAST_FUN>`, `RuntimeConfig`, and the core
`blast_core::blast_treasury::Treasury`. It checks the current version, then aborts with
`blast_fun::errors::EUnguardedDelay` unless every launchpad notice and the treasury's notice are
guarded: the claim-signer set, the trade-fee share, trade fees, the venue set, the migration
allocation, the LP-fee share, the creation fee, and the treasury destination each have a nonzero
applied notice, no pending proposal would set one to zero, and no venue or signer admission is
pending. The generic administration then requires the upgrade notice to be guarded too and emits
`blast_admin::blast_admin_events::Unpaused<BLAST_FUN>`.

Create is 1, Trading is 2, Migrate is 4; all together are 7. Create stops `launch::new`,
`launch::finalize`, and `launch::share`. Trading stops buys, sells, and opening-round joins and
settlement. Migrate stops `launch::migrate`. Pauses never expire. Claims, metadata updates, owner
proofs, and opening-round delivery stay open.

### Economics

Publication defaults follow the [Blast visual map](https://map.blast.fun/#fees): the curve charges
150 BPS of Quote and 0 BPS of Meme, and Blast receives 5,000 BPS of each collected trade fee (50/50
with the creator). The migration allocation defaults to 250 BPS of the Meme supply and 150 BPS of
the final real Quote reserve. Blast's LP-fee share defaults to 1,500 BPS of each asset. The creation
fee defaults to zero. Administrators can change these within compiled maximums (trade fees 1,000 BPS
each, Blast's trade-fee share 7,000 BPS, migration allocation 1,000 BPS per asset, LP-fee share
3,000 BPS per asset, creation fee 10 SUI); read the live objects before constructing a launch.

All amounts are atomic units. Rates are BPS out of 10,000. `ceil` rounds up, `floor` rounds down.

#### Supply

Every generated coin has exactly `1_000_000_000 * 10^decimals` atoms, minted once. Finalization
re-checks the ticket's balance and the treasury cap's supply against this amount and fixes the supply
in the Coin Registry. After that no one can mint. Under a burn-only supply anyone can burn Meme
through the Coin Registry; a fixed supply cannot be burned, so the launch sends its disposals to
`@0x0` instead.

#### Allocation plan

An `AllocationPlan` splits two totals at migration:

- Meme supply: `curve_meme_bps` (sold on the curve) + `lp_meme_bps` (seeds the pool) + Blast's
  `protocol_meme_bps` + each recipient's `meme_bps` = 10,000. Curve and pool Meme shares must be
  positive.
- Final real Quote reserve: `lp_quote_bps` (seeds the pool) + Blast's `protocol_quote_bps` + each
  recipient's `quote_bps` = 10,000. The pool's Quote share must be positive.

The creator's plan leaves Blast's fields at zero; `launch::finalize` copies the applied
`LaunchConfig.protocol_allocation` into them and then checks both sums. So the creator's shares must
sum to 10,000 minus Blast's current share for each asset. At most 16 recipients; each destination is
non-zero (repeated addresses are allowed). The plan is fixed for the launch's life. Finalization
also requires the pool's Quote share of the graduation target to be at least one atom.

Apportionment uses `blast_core::bps::apportion`: each part takes the floor of its exact share,
Blast's part takes the ceiling, and the leftover atoms go one each to the parts with the largest
remainders, earlier parts first on ties. Part order is curve, pool, Blast, recipients in plan order
for Meme, and pool, Blast, recipients for Quote. The parts sum exactly to the total.

At finalization the curve's part becomes `meme_reserve`; the pool, Blast, and recipient parts wait in
`allocated_meme`. At migration recipients are paid, Blast's parts enter the fee ledger, and the
pool's parts go to the venue. Unsold curve Meme is disposed of, never paid to anyone.

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
5. If `meme_out_net` is 0 and `net` does not reach the target, nothing is bought: `launch::buy`
   aborts with `blast_fun::errors::EZeroTradeOutput` (settlement instead keeps the pot for refund).
   If it is below `min_meme_out`, abort `blast_fun::errors::ESlippageExceeded`.
6. `Q += net`, `M -= meme_out_gross`. If `Q >= T`, the launch becomes `MigrationReady`.

Sell with `m` Meme:

1. `meme_fee = ceil(m * fm / 10,000)`.
2. `burn = ceil((m - meme_fee) * s / 10,000)`, added to `pending_burn`.
3. `x = m - meme_fee - burn` reaches the curve: `quote_out_gross = floor((V + Q) * x / (M + x))`.
4. `quote_fee = ceil(quote_out_gross * fq / 10,000)`; `quote_out_net = quote_out_gross - quote_fee`.
   Abort `blast_fun::errors::EZeroTradeOutput` when it is 0, and
   `blast_fun::errors::ESlippageExceeded` when below `min_quote_out`.
5. `M += x`, `Q -= quote_out_gross`.

Every rounding favors the curve and the fee ledger over the trader.

#### Trade fees and Blast's share

`quote_fee_bps` and `meme_fee_bps` are copied from `LaunchConfig` when the launch starts and never
change. On every trade (and the settlement purchase) each fee splits as
`protocol = ceil(fee * p / 10,000)` and `creator = fee - protocol`, where `p` is
`RuntimeConfig.protocol_fee_share_bps` read live at that trade. Both parts stay in the launch's fee
ledger: the creator part until `launch::claim_creator_fees`, Blast's part until a permissionless
Blast fee claim.

#### Creation fee

Exactly `LaunchConfig.creation_fee` MIST of SUI, whatever the Quote, paid at finalization into the
launch's Blast fee ledger. It is Blast's and is claimed with the other Blast launch fees.

#### Partner payouts

A partner named at creation is the launch's partner for good (`partner_id`), and its vault's terms
carry it after migration. When Blast's launch fees are claimed, each balance (Meme, Quote, SUI) pays
the partner `floor(balance * share_bps / 10,000)`, with `share_bps` the partner's applied share at the
claim (set by Blast, at most 8,000); the treasury gets the rest. The partner's cut covers trade fees,
the creation fee, and the one-time migration allocation; the vault pays its cut of Blast's LP fees.

#### LP fees after migration

The `FeeSplit` set at launch becomes the vault's starting split; the launch stores it unchanged. A
split has 1 to 20 routes with positive shares summing to 10,000, no address twice, and at most one
each of owner, auto-LP, holder rewards, and burn. Each LP-fee collection first pays Blast its share
of each asset, rounded up: the `LaunchConfig.protocol_lp_fees` value applied when the launch
migrates, not when it starts. The rest is apportioned over the routes. The owner route accrues for
the curve-fee cap holder, who claims it and proposes split changes through `launch::prove_owner`.
Migration residuals (what the pool does not take when seeded) go to Blast. The vault guide has the
full LP-fee economics.

#### Worked example

SUI Quote (9 decimals), Meme with 9 decimals (supply `10^18` atoms), plan 8,000 curve / 2,000 pool
Meme and 10,000 pool Quote, Blast allocation 0, `V = T = 8,000 SUI`. Ignoring fees and sells:

- The curve holds 800M tokens; opening price `8,000 / 800M = 0.00001` SUI per token (10,000 SUI for
  the whole supply).
- At the target the curve holds about `800M * 8,000 / 16,000 = 400M` tokens: 400M sold for 8,000
  SUI; closing price `16,000 / 400M = 0.00004` SUI per token.
- Migration seeds the pool with 200M tokens and 8,000 SUI (also 0.00004), and disposes of 400M
  unsold tokens; a burn-only supply ends at 600M tokens.

With a 1% Quote fee and no Meme fee, a first buy of 100 SUI pays a 1 SUI fee and receives
`floor(8 * 10^17 * 99 * 10^9 / (8 * 10^12 + 99 * 10^9)) = 9,778,985,059,883,936` atoms (about 9.78M
tokens). With `Q = 7,990 SUI` and the same fee, supplying 20 SUI uses `g = 10.101010102` SUI and
refunds 9.898989898 SUI; the net 10 SUI lands `Q` exactly on 8,000.

### Time rules

All times are `Clock` milliseconds.

- `public_start_ms` is the time of `launch::share`. Sells and creator-cap claims need it set; buys do
  not (only the creator's own PTB can reach the unshared launch).
- Opening round: joins are accepted while `now < public_start_ms + opening_round_ms` (and before
  share); settlement is accepted when `now >= public_start_ms + opening_round_ms`. At exactly the
  end, a join aborts and settlement succeeds. Settlement is never possible before share. Length is 0
  or 60,000 to 300,000 ms.
- Account claims: accepted while `now <= expiry_ms`.
- Partner acceptance: `launch::set_partner` needs the partner list to accept it now; removal keeps
  it accepted until `now + 7 days` (exclusive), and `launch_config::add_partner` accepts it again.
- Trades, claims, deliveries, and migration have no deadline.
- Snapshots: the trade fees at `launch::new`; the migration allocation and the creation fee at
  `launch::finalize`; Blast's LP-fee share at migration. `protocol_fee_share_bps`, the core treasury
  destination, and the claim signer keys are read live. Later config changes never reach a launch past its snapshot.

### Reading state

- Find a coin's launch without an indexer: its object ID is derived from the shared
  `launch::LaunchRegistry` and the key `launch::LaunchKey<Meme>`, a field-less struct whose BCS is
  the single byte `0x00` (Move gives it a `dummy_field: bool`):
  `0x2::dynamic_field::hash_type_and_key(registry_id,
  0x2::derived_object::DerivedObjectKey<blast_fun::launch::LaunchKey<Meme>>, [0])`, with types named
  by original package IDs. A coin has at most one launch; a second `launch::finalize` for the same
  Meme aborts in `sui::derived_object`.

The launchpad has no getters; read object fields through Sui RPC (object content, dynamic fields),
or dev-inspect a call.

`Launch<Meme, Quote>` fields: `lifecycle`; `public_start_ms`; `opening_round_ms`;
`opening_round_bids` (undelivered bids' total); `opening_round_quote` (the pot, then the refund
awaiting delivery); `opening_round_meme`; `sell_burn_bps`; `virtual_quote`; `graduation_target`;
`quote_fee_bps`; `meme_fee_bps`; `venue` (the venue witness type with original IDs); `lp_fee_split`;
`atomic_supply`; `meme_reserve`; `real_quote_reserve`; `pending_burn`; `allocation_plan`;
`allocated_meme`; `protocol_fees` (a `blast_core::protocol_fees::Ledger` holding Blast's Meme,
Quote, and SUI; `blast_core::protocol_fees::balances` reads them); `creator_meme_fees` and
`creator_quote_fees`; `creator` (`Some` until claimed or reassigned); `curve_fee_cap_reassignment`;
`creator_metadata_cap_reassignment`; `curve_fee_cap_id`; `creator_metadata_cap_id`; `partner_id`. The `Meme`
and `Quote` types are the object's type arguments. The pool tier is not on the launch: the venue
keeps it in `VenueConfig` (see the venues guide).

| Question | Answer |
| --- | --- |
| Price | `(virtual_quote + real_quote_reserve) / meme_reserve` Quote atoms per Meme atom; scale by `10^meme_decimals / 10^quote_decimals` for whole tokens; times one billion tokens for fully diluted value |
| Progress to graduation | `real_quote_reserve / graduation_target` |
| Quote still needed | `ceil((graduation_target - real_quote_reserve) * 10,000 / (10,000 - quote_fee_bps))` gross |
| Tradeable? | buy: `lifecycle` is `Live`; sell: also `public_start_ms` is set |
| Which venue migrates it? | `venue`: `blast_migrators::cetus::Venue` or `blast_migrators::bluefin::Venue` |
| Opening round end | `public_start_ms + opening_round_ms` |
| One bidder's pending bid | dynamic field `launch::OpeningRoundBidKey(address)` on the launch (a `u64`); absent once delivered |
| Unclaimed creator / Blast launch fees | `fee_ledger` balances |
| Is this cap live? | its object ID equals `curve_fee_cap_id` or `creator_metadata_cap_id` |
| Coin metadata, supply mode, total supply | the shared `Currency<Meme>` |

A `delayed::Delayed` stores `owner`, `key`, the applied `value`, the applied `delay_ms`, and an
optional `pending` proposal with the proposed `value`, next `delay_ms`, and `ready_at_ms`. Read the
applied `value` for live economics. `LaunchConfig` holds `meme_decimals`, `quotes` (a `VecSet` of the
Quote `TypeName`s with original IDs), `venues`, and the delayed `trade_fees`,
`protocol_allocation`, `protocol_lp_fees` (`meme_bps`, `quote_bps`), and `creation_fee` (MIST).
`venues` is a `delayed_set::DelayedSet`: `members` holds the admitted venue type names, `delay_ms`
the applied admission notice, and `admissions` each pending type's `delay_ms` and `ready_at_ms`.
Accepted partners are the config's `partners` field, a `blast_partners::partner_list::PartnerList`
(see the partners guide).
`RuntimeConfig` holds `creator_claim_signers` (a `DelayedSet` of keys) and
`protocol_fee_share_bps`; `blast_core::blast_treasury::destination` reads the treasury address.
A `Bps` is a positional struct wrapping one `u64`. Preview a trade exactly by dev-inspecting `launch::buy` or `launch::sell` against the live launch.

### Events

Launchpad events are emitted directly, with no envelope: the on-chain type is
`<blast_fun original id>::events::Name<...>`. Every launch event is generic in the launch's coin
types, `Name<Meme, Quote>` (`LaunchTicketCreated<Meme>` and `QuoteAllowed<Quote>` carry the one type
they concern), so the type arguments name the coin and Quote. Filter by event type, not by the called
module: `blast_fun::events::Migrated`, for example, is emitted inside a venue's call. Events do not
carry the transaction sender; take it from the transaction.

| Event | Emitted by | Key fields and what to derive |
| --- | --- | --- |
| `blast_fun::events::LaunchTicketCreated` | coin publish | `ticket_id`, `decimals`, `metadata_cap_id`, `creator`, `burnable`, `sell_burn_bps` |
| `blast_fun::events::LaunchCreated` | `launch::finalize` | `launch_id`, `ticket_id`, `venue`, `lp_fee_split`, `virtual_quote`, `graduation_target`, both fee rates, the full `allocation_plan` with Blast's shares, `opening_round_ms`, `creation_fee`, `partner_id` |
| `blast_fun::events::LaunchShared` | `launch::share` | `public_start_ms`; round end is this plus `opening_round_ms` |
| `blast_fun::events::OpeningRoundJoined` | join | `quote_amount` added and `bids` (pot total); the bidder is the transaction sender |
| `blast_fun::events::OpeningRoundSettled` | settle | `bids`, `meme_amount` bought, `quote_amount` held for refund |
| `blast_fun::events::OpeningRoundDelivered` | deliver | `bidder`, `bid`, `meme_amount`, `quote_amount` paid |
| `blast_fun::events::Bought` | buy, settlement | `quote_in` (gross used), `meme_out_gross`, `meme_out_net`, `quote_refund`, the four fee parts, reserves after; graduated when `real_quote_reserve >= graduation_target`. A `Bought` before `LaunchShared` in the creation transaction is the creator's buy; the one beside `OpeningRoundSettled` is the pot's |
| `blast_fun::events::Sold` | sell | `meme_in_gross`, `pending_burn` added, `quote_out_gross`, the four fee parts, reserves after |
| `blast_fun::events::CreatorCapsClaimed` | creator claim | both cap IDs (no launch ID: one launch per Meme type) |
| `blast_fun::events::CurveFeeCapReassigned`, `blast_fun::events::CreatorMetadataCapReassigned` | anyone applying a ready reassignment | `launch_id`, new cap ID, `recipient` |
| `blast_fun::events::MemeMetadataUpdated` | metadata setters | `launch_id`, current `name`, `description`, `icon_url` |
| `blast_fun::events::CreatorFeesClaimed` | creator fee claim | `launch_id`, `meme_amount`, `quote_amount` |
| `blast_core::blast_core_events::ProtocolFeesPaid` | Blast launch-fee claims | `package_witness` (`blast_fun::blast_fun::PackageWitness`), `origin` (the launch ID), `treasury` and its Meme, Quote, SUI amounts; `partner_id` and its amounts (0 without a partner) |
| `blast_fun::events::MigrationAllocationPaid` | migration | one per recipient: `destination`, `meme_amount`, `quote_amount`, and `meme_vesting_id`, `quote_vesting_id` (the shared `Vesting` IDs when the recipient vests, else none) |
| `blast_fun::events::ProtocolFeesAccrued` | migration | Blast's one-time Meme and Quote allocation |
| `blast_fun::events::Migrated` | migration | `meme_amount`, `quote_amount` handed to the venue for the pool, `disposed_meme`, `total_supply_after` |

Config events: `blast_fun::events::QuoteAllowed`, `blast_fun::events::MemeDecimalsAllowed`,
and the partner list's `blast_partners::partner_list::PartnerAdded` and
`blast_partners::partner_list::PartnerRemoved`. From other packages: the
pause and version events of `blast_admin::blast_admin_events`, the delayed modules' events (see "Delayed administration"), the Cetus venue's
`blast_migrators::events::CetusPoolReserved` at creation, the vault's
`blast_vault_events::VaultCreated` at migration, and `blast_partners::blast_partners::PartnerPaid`
for each partner payout.

### Aborts

Launchpad aborts carry a numeric code from `blast_fun::errors`; the abort location is the module
that detected it. Pause, version, and upgrade aborts come from `blast_admin`, recipient and
fee-payout aborts from `blast_core`, and partner-list aborts from `blast_partners`.

| Flow | Code, constant (module) | Fix |
| --- | --- | --- |
| any | 9 in `blast_admin::package_version` | call the launchpad's current package ID |
| pause, unpause | 19 `EInvalidPauseBits`, 20 `EPauseUnchanged` from `blast_admin::package_version` | select nonzero supported bits that change the active mask |
| create, buy, sell, join, settle, migrate | 21 `blast_admin::errors::EPaused` (`package_version`) | wait for an `UnpauseAdmin<BLAST_FUN>` to clear the operation's bit |
| unpause | 32 `blast_fun::errors::EUnguardedDelay` (`launch_config`); 23 `EUnguardedUpgradeDelay` from `blast_admin::package_admin` | make every launchpad notice and the core treasury's nonzero, cancel proposals that would zero one, settle pending admissions |
| package administration | 22 `EWrongUpgradeAction`, 11 `EInvalidPackageDigest` from `blast_admin::package_admin` | execute the exact scheduled action; use a 32-byte digest |
| delayed administration | 13 `ENotReady`, 14 `ENoPending`, 15 `EInvalidDelay`, 16 `EUnchanged`, 18 `EWrongChange` from Blast admin's delayed modules | wait for `ready_at_ms`; schedule before applying or cancelling; choose a notice of at most 30 days; change the value or notice; apply with the call matching the pending change |
| publish | 7 `blast_fun::errors::EInvalidSellBurnBps` (`launch_ticket`); 20 `blast_fun::errors::EInvalidCreatorRecipient`, 21 `blast_fun::errors::EInvalidAccountCommitment` (`creator_authority`); `EInvalidSymbol` in `sui::coin_registry`; arithmetic overflow | sell-burn at most 5,000; a non-zero address or a 32-byte commitment; an ASCII-printable symbol; decimals at most 10 |
| prepare | `blast_migrators::errors::EInvalidTier`, `blast_migrators::errors::ESymbolTooLong`; Cetus aborts in its own modules | a tier within Bluefin's bounds and a Meme symbol of at most 32 bytes; a tick spacing Cetus registers and a pair it accepts |
| start | 9 `blast_fun::errors::EInvalidMemeQuotePair` (`launch`) | Quote must differ from Meme |
| start | 27 `blast_fun::errors::EQuoteNotAllowed`, 2 `blast_fun::errors::EVenueNotAllowed`, 1 `blast_fun::errors::EDecimalsNotAllowed` (`launch_config`) | use an admitted Quote, venue, and decimals |
| building values | 0 `blast_core::errors::EInvalidBps` (`blast_core::bps`); 3 `blast_core::errors::EInvalidRoute`, 4 `blast_core::errors::EInvalidFeeSplit` (`blast_core::fee_split`); 12 `blast_core::errors::EInvalidRecipient` (`blast_core::payout`); 2 `blast_core::errors::EInvalidVestingTerms` (`blast_core::payout`); 5 `blast_fun::errors::EInvalidShares` (`allocation`) | rates at most 10,000; positive route shares and non-zero addresses; at most 20 distinct routes summing to 10,000; positive vesting periods; curve Meme and pool Meme/Quote positive |
| finalize | `std::option` `EOPTION_NOT_SET` | set the virtual Quote, target, plan, and LP-fee split |
| finalize | 30 `blast_fun::errors::EInvalidCreationFee`, 28 `blast_fun::errors::EInvalidVirtualQuote`, 10 `blast_fun::errors::EInvalidOpeningRound`, 11 `blast_fun::errors::EInvalidGraduationTarget` (`launch`) | exact fee coin; virtual Quote above 0; round 0 or 60,000 to 300,000; target big enough that the pool's Quote share is at least 1 |
| finalize | 5 `blast_fun::errors::EInvalidShares`, 6 `blast_fun::errors::ERecipientCapacityReached` (`allocation`) | plan plus Blast's allocation must sum to 10,000 per asset; at most 16 recipients |
| finalize | 8 `blast_fun::errors::EInvalidInitialMemeSupply`, 7 (`launch_ticket`) | an untouched supply (nothing minted or burned with the `TreasuryCap`); sell-burn at most 5,000 |
| set partner | 4 `blast_partners::errors::EPartnerNotAccepted` (`blast_partners::partner_list`) | name a partner `LaunchConfig` accepts now |
| buy, sell | 12 `blast_fun::errors::EInvalidLaunchLifecycle` (`launch`) | trade only while `Live`; sell only after share |
| buy | 14 `blast_fun::errors::EZeroTradeOutput`, 13 `blast_fun::errors::ESlippageExceeded` (`launch`) | larger input; lower `min_meme_out` or re-quote |
| sell | 14 (`curve`), 13 (`launch`) | larger input; lower `min_quote_out` |
| join | 12, 15 `blast_fun::errors::EOpeningRoundEnded`, 29 `blast_fun::errors::EZeroOpeningRoundBid` (`launch`) | join during the round with a non-zero coin |
| settle | 12, 16 `blast_fun::errors::EOpeningRoundNotEnded` (`launch`) | wait for the end; settle once |
| deliver | 12 (`launch`); `sui::dynamic_field` code 1 | settle first; the address has no undelivered bid |
| creator claim | 12 (`launch`) before share; `std::option` `EOPTION_NOT_SET` when already claimed or reassigned, or when an account claim passes `None` | claim once, after share |
| creator claim | 25 `blast_fun::errors::ECreatorNotSender`, 23 `blast_fun::errors::EInvalidCreatorClaimAttestation`, 24 `blast_fun::errors::ECreatorClaimExpired`, 26 `blast_fun::errors::EInvalidCreatorClaimSignature` (`creator_authority`); a truncated attestation aborts in `sui::bcs` | send from the recipient address with `None`, or a fresh, well-formed attestation for this sender |
| creator fees, owner proof, metadata | 18 `blast_fun::errors::ECreatorCapNotLive` (`launch`); 17 `blast_fun::errors::ENothingAccrued` (`launch`); 19 `blast_fun::errors::EUnchanged` (`launch`) | use the live cap; wait for fees; pass a new value |
| Blast launch-fee claim | 7 `blast_core::errors::EPartnerMismatch` (`blast_core::protocol_fees`) | use the call that matches `partner_id`, with that partner |
| migrate | 12 (`launch`) | migrate only a `MigrationReady` launch |
| migrate | 8 `blast_core::errors::EWrongVenue` (`blast_core::migration`), or a missing tier in `sui::dynamic_field` | call the migrate of the venue the launch stores |

Admin setters also abort with 0 `blast_fun::errors::EInvalidTradeFeeBps`, 3
`blast_fun::errors::EInvalidVenue`, 4 `blast_fun::errors::EInvalidProtocolAllocation`, 34
`blast_fun::errors::EInvalidLpFeeBps`, 33 `blast_fun::errors::EInvalidProtocolFeeShare`, 30
(creation fee above 10 SUI), 20 (zero reassignment recipient), 22
`blast_fun::errors::EInvalidCreatorClaimPublicKey`, 31 `blast_fun::errors::ETooManyClaimSigners`;
with `blast_partners::errors::EPartnerNotAccepted` (removing a partner not accepted now) or
`blast_partners::errors::EUnchanged` (adding an accepted partner, or removing one already being
removed) from `blast_partners::partner_list`; and in `blast_acl::sign_in` when the cap is not a
live admin cap or lacks the role.

### Pitfalls

- Preparing the venue in a separate transaction. The `VenueTicket` cannot be stored or dropped, so
  the venue's prepare, `launch::new`, `launch::finalize`, and `launch::share` all run in one PTB.
- Passing the `TreasuryCap` by value to the venue. Cetus takes it by mutable reference and Bluefin by
  immutable reference; only `launch::new` takes it by value, afterwards.
- Minting or burning with the `TreasuryCap` before launch: finalization aborts.
- Building the plan to sum to 10,000 on its own. Blast's allocation is added at finalization, so read
  `LaunchConfig.protocol_allocation` and leave exactly that room in each asset.
- Passing the pre-registration `Currency<Meme>`. Finalization needs the shared one that
  `0x2::coin_registry::finalize_registration` creates, in a separate earlier transaction.
- Trying to claim the creator caps, or to use the launch, after `launch::share` in the creation PTB.
  The launch is consumed by `share`; claim in a later transaction.
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
- Deleting a live cap: curve fees, vault owner calls, or metadata stay locked until a creator admin
  reassigns it.
- Reusing an `OwnerProof`: each one is consumed by one vault call.
- Assuming Blast's LP-fee share is fixed at creation. It is read from `LaunchConfig` at migration.
- Calling an old package ID after an upgrade: every protected call aborts. Call the current package
  ID; types and events keep the original ID.
- Filtering events by emitting module instead of by event type.

### Q&A

**How do I show a launch's current price and market cap?** Read `virtual_quote`,
`real_quote_reserve`, and `meme_reserve` from the launch (or the reserves from the latest
`blast_fun::events::Bought` or `blast_fun::events::Sold`). Price is
`(virtual_quote + real_quote_reserve) / meme_reserve` Quote atoms per Meme atom; adjust for both
decimals and multiply by one billion tokens for fully diluted value.

**What is the call order to create a launch?** Publish the coin package (ticket and `TreasuryCap`
arrive), register the currency, then one PTB: the venue's prepare (returns the `VenueTicket`),
`launch::new` with the ticket, the cap, and the venue ticket, the setters, `launch::finalize`, an
optional creator buy or bid, and `launch::share`.

**What happens when a buy overshoots the graduation target?** The launch uses only the gross Quote
needed to bring the real reserve to the target and returns the rest as the second coin of
`launch::buy`. The launch becomes `MigrationReady` and all buys and sells stop.

**Who migrates the launch, and when?** Anyone, as soon as it is `MigrationReady`, through the venue
the launch stores: `launch::migrate`, then `blast_migrators::cetus::migrate` or
`blast_migrators::bluefin::migrate` with the returned `Migration` in the same PTB, which only that
venue can redeem.

**What happens to unsold tokens and the sell burn?** Both are disposed of at migration: burned when
the supply is burn-only, or sent to `@0x0` when it is fixed. `blast_fun::events::Migrated` reports
`disposed_meme` and `total_supply_after`.

**Can the creator change the target, plan, fees, venue, tier, or LP-fee split after launch?** No; the
launch fixes them. Only the metadata (name, description, icon) changes, with the metadata cap. After
migration the curve-fee cap holder can propose a new split to the vault with an owner proof, after a
48-hour notice.

**How does the creator get paid?** The creator recipient claims a `CurveFeeCap<Meme>` once with
`launch::claim_creator_caps`, then calls `launch::claim_creator_fees` at any time for its share of
every trade fee. After migration it calls `launch::prove_owner` and
`blast_vault::vault::claim_owner_balances` in one PTB for the owner route's LP fees.

**How much of the LP fees does Blast take?** The `LaunchConfig.protocol_lp_fees` share applied at
migration, 1,500 BPS of each asset by default and at most 3,000, taken before the split. Migration
residuals also go to Blast.

**How does the opening round treat early buyers?** Every bid, including the creator's before share,
joins one pot that buys once at settlement, so all bidders pay the same average price. Each bidder
receives Meme and refunded Quote in proportion to its bid, rounded down, with the last delivery
taking the remainder.

**Can a launch fail or be refunded?** No. There is no cancellation, expiry, or refund: a launch that
never reaches its target stays `Live`, and holders exit by selling to the curve.
