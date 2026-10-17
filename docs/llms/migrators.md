## Migration and LP vaults

### What it is

A Blast launch trades on a bonding curve until the curve fills and the launch becomes
`MigrationReady`. The `blast_fun_migrators` package then moves the launch's pool allocation into a
new full-range position on a DEX: Cetus or Bluefin, whichever the creator picked when the launch
started. The position goes into a per-launch shared vault, `blast_fun_migrators::vault::LpVault`,
and no function can take it out again. From then on anyone can collect the position's trading fees.
Each collection pays Blast its LP-fee share, then splits the rest by the vault's `FeeSplit` (the
launch's until the creator changes it) into five parts: creator, auto-LP (added back to the pool),
holder rewards, burn, and fixed recipients. This guide covers how a launch starts on a venue, the
migration itself, and everything the vault does afterwards.

### Objects and authority

#### Shared objects

| Object | How many | What it does |
| --- | --- | --- |
| `blast_fun_migrators::vault::LpVault` (`LpVault<Meme, Quote>`) | one per migrated launch | Holds the venue position, Blast's migration residuals, and every balance a collection feeds. |
| `lp_fee_policy::LpFeePolicy` | singleton | Blast's LP-fee share (a default pair and optional per-coin pairs) and the address Blast's share is paid to. |
| `blast_holder_rewards::Round` (`Round<Meme, Quote>`) | one per published round | A funded Merkle allocation of holder rewards and its claim bitmap. |
| `blast_fun_migrators::venue_config::VenueConfig` | singleton | Keeps each Cetus launch's `PoolCreationCap` forever, under `blast_fun_migrators::cetus::CreationCapKey` (typed by the Meme). |
| `blast_fun_migrators::blast_fun_migrators::PackageVersion` | singleton | This package's operational generation. Every public call except `wrap` checks it first. |
| `blast_fun_migrators::package_admin::PackageAdmin` | singleton | Sealed custody of this package's `Publisher` and `UpgradeCap`. |

Calls also take objects from other packages:

- Launchpad: the shared `launch::Launch` (`Launch<Meme, Quote>`), the launchpad's own
  `blast_fun::blast_fun::PackageVersion`, and `launch_config::LaunchConfig` (start only).
- Sui: the Meme's Coin Registry `Currency<Meme>` (shared; taken mutably because collections burn
  Meme), the Quote's `Currency<Quote>` (Bluefin migration only), and `Clock` at `0x6`.
- Cetus: `GlobalConfig`, `Pools`, the pair's `Pool<CoinA, CoinB>`, and Cetus LP Burn's
  `BurnManager`, all shared.
- Bluefin: its `GlobalConfig` and the pair's `Pool<Meme, Quote>`, both shared.
- Partners: the launch's shared `blast_partners::blast_partners::Partner`, when the launch named
  one.

#### Capabilities and roles

- `creator_authority::CurveFeeCap` (`CurveFeeCap<Meme>`, owned, transferable). The launch records
  the ID of the one live cap. Its holder claims the creator's LP fees and changes the fee split. The
  creator gets it from `launch::claim_creator_caps`. A Blast admin with
  `blast_fun_domain::CreatorAdmin` can retire it and issue a new one with
  `launch::reassign_curve_fee_cap`; the new cap then controls the vault too.
- Blast admin roles. An admin calls `blast_acl::sign_in` (type argument `Role`) with the shared
  `blast_acl::ACL` and its own `blast_acl::AdminCap`, which yields a droppable
  `blast_acl::AdminWitness` (`AdminWitness<Role>`). Each admin call takes the witness for exactly
  one role:
  - `blast_fun_domain::BuybackAdmin`: buyback and burn.
  - `blast_fun_domain::RewardsAdmin`: publish holder-reward rounds.
  - `blast_fun_domain::TreasuryAdmin`: claim migration residuals; set the LP-fee destination.
  - `blast_fun_domain::FeeAdmin`: set Blast's default and per-coin LP-fee shares.
  - `blast_fun_domain::UpgradeAdmin`: authorize and commit package upgrades.

  These role types belong to the launchpad; this package declares no roles of its own. Integrators
  cannot call admin functions.

#### Who may call what

| Call | Who |
| --- | --- |
| `blast_fun_migrators::cetus::new`, `blast_fun_migrators::bluefin::new` | anyone holding the `launch_ticket::LaunchTicket` (the creator) |
| `blast_fun_migrators::cetus::migrate`, `blast_fun_migrators::bluefin::migrate` | anyone |
| `blast_fun_migrators::cetus::collect_fees`, `blast_fun_migrators::bluefin::collect_fees` | anyone |
| `blast_fun_migrators::vault::claim_protocol_lp_fees_with_partner` | anyone |
| `blast_holder_rewards::claim` | anyone (pays only the leaf's beneficiary) |
| `blast_fun_migrators::vault::claim_creator_fees` | cap holder: the live `CurveFeeCap<Meme>` |
| `blast_fun_migrators::cetus::settle_and_update_fee_split`, `blast_fun_migrators::bluefin::settle_and_update_fee_split` | cap holder: the live `CurveFeeCap<Meme>` |
| `blast_fun_migrators::cetus::buyback_and_burn`, `blast_fun_migrators::bluefin::buyback_and_burn` | Blast admin: `BuybackAdmin` |
| `blast_holder_rewards::publish_round` | Blast admin: `RewardsAdmin` |
| `blast_fun_migrators::vault::claim_protocol_fees` | Blast admin: `TreasuryAdmin` |
| `lp_fee_policy::set_protocol_destination` | Blast admin: `TreasuryAdmin` |
| `lp_fee_policy::set_default_shares`, `lp_fee_policy::set_coin_shares`, `lp_fee_policy::clear_coin_shares` | Blast admin: `FeeAdmin` |
| `blast_fun_migrators::package_admin::authorize_upgrade`, `blast_fun_migrators::package_admin::commit_upgrade_and_advance` | Blast admin: `UpgradeAdmin` |
| `blast_fun_migrators::package_admin::wrap` | cap holder: the package's `Publisher` and `UpgradeCap` (done once at deployment) |

#### What an `LpVault` holds

- The venue position, as a dynamic object field under `blast_fun_migrators::vault::PositionKey`
  (`PositionKey<Venue>`), where `Venue` is `blast_fun_migrators::cetus::Venue` or
  `blast_fun_migrators::bluefin::Venue`. On Cetus this is the `CetusLPBurnProof` of the burned
  migration position; on Bluefin it is the Bluefin `Position`.
- On Cetus only, from the first collection that finds both auto-LP balances nonzero: a second
  full-range Cetus `Position` under `blast_fun_migrators::vault::AutoLpPositionKey`
  (`AutoLpPositionKey<Venue>`).
- `protocol_meme_residual`, `protocol_quote_residual`: what the venue did not take when seeding the
  position at migration. Blast's; only `TreasuryAdmin` claims them.
- `unpaid_protocol_meme`, `unpaid_protocol_quote`: Blast's LP-fee share held for the partner payout
  (partnered vaults only).
- `creator_meme`, `creator_quote`: creator LP fees not yet claimed.
- `auto_lp_meme`, `auto_lp_quote`: auto-LP amounts the pool has not taken yet.
- `rewards_meme`, `rewards_quote`: holder-reward funds not yet reserved by a round.
- `burn_quote`: Quote waiting for a buyback.
- `fee_split`: the current split (the launch's at migration).
- `pool_id`, `partner_id` (copied from the launch, never changes), `next_round`, `last_checkpoint`.

No function removes or transfers a position. No function withdraws the auto-LP, rewards, or burn
balances except the flows below.

#### Trust assumptions

- **Upgradeable package.** `UpgradeAdmin` can authorize compatible upgrades of this package through
  `PackageAdmin`. An upgrade can add functions to these modules, so the vault's custody and routing
  rules hold only as long as Blast's upgrade governance keeps them. The Cetus migration liquidity is
  different: Cetus LP Burn has burned it, and its `CetusLPBurnProof` can only collect fees. The
  Bluefin position, the Cetus auto-LP position, and every vault balance depend on this package's
  code.
- **Blast sets its own share at any time.** `FeeAdmin` can set Blast's LP-fee share anywhere from 0
  to 10,000 BPS per asset, by default or per coin, with no delay. It applies from the next
  collection. `TreasuryAdmin` can redirect Blast's share at any time.
- **The admin can publish any round.** Merkle proofs enforce the published allocation, not the truth
  of Blast's off-chain holder accounting. `RewardsAdmin` can assign unreserved rewards to any
  recipient in a new round. Rounds never expire, and nothing cancels a round or sweeps its funds, so
  a wrong root or an over-sized budget cannot be recovered through the current functions.
- **Auto-LP price-move skim.** Auto-LP adds at the pool's current price. A caller can move the price
  in the same transaction, collect, and move it back, skimming part of that call's auto-LP amount.
  Frequent collection keeps each exposed slice small. Buybacks are admin-only with a minimum out for
  the same reason.
- **Venue operators.** Cetus's pool-manager role can create a reserved pair's pool without the
  `PoolCreationCap`. If it does so first, Cetus migration aborts, and only a package upgrade could
  recover the launch. If Cetus stops registering the launch's tick spacing, migration aborts and the
  launch stays `MigrationReady`.
- **Buyback timing.** Burn Quote waits until a `BuybackAdmin` acts; nothing forces a buyback.

### Lifecycle

- **Launch.** `MigrationReady` → `migrate` → `Migrated`. Only the adapter whose `Witness` the launch
  recorded at start can migrate it. A failed migration aborts the whole transaction and leaves the
  launch `MigrationReady`.
- **Vault.** Created and shared inside `migrate` with the launch's `FeeSplit`. Each
  `settle_and_update_fee_split` replaces the split. On Cetus, the auto-LP position appears the
  first time a collection finds both auto-LP balances nonzero, even if nothing is then added. The
  vault never closes.
- **Rounds.** `next_round` starts at 0 and rises by 1 per published round. Each round's checkpoint
  interval must start where the previous one ended. A round stays claimable forever.

### Flows

Every public call in this package except the one-time `wrap` takes
`blast_fun_migrators::blast_fun_migrators::PackageVersion` (shared) and checks it before anything
else. Calls whose launchpad step checks the launchpad generation (`new`, `migrate`) take the
launchpad's `blast_fun::blast_fun::PackageVersion` as well, because each package checks only its own
generation.

#### Starting a launch on a venue

The launchpad guide covers building a launch. The adapter call is its first step: it starts the
`launch::LaunchInitializer` hot potato (`LaunchInitializer<Meme, Quote>`), which the same PTB must
complete with `launch::finalize` and then `launch::share`. The adapter records its `Witness` type in
the launch, so only that venue can migrate it later.

`blast_fun_migrators::cetus::new` (type arguments `<Meme, Quote>`; anyone holding the ticket) takes,
in order: the `LaunchTicket<Meme>` by value, the migrators `PackageVersion`, the launchpad
`PackageVersion`, `LaunchConfig`, `VenueConfig` (mutable), Cetus `GlobalConfig`, Cetus `Pools`
(mutable), and `tick_spacing: u32`. It:

1. Reads the fee rate Cetus registers for `tick_spacing`. Cetus aborts if it registers none.
2. Calls `launch::new` with `blast_fun_migrators::cetus::Witness`, which checks the launchpad
   generation and that `LaunchConfig` admits the adapter, the Quote, and the Meme's decimals, and
   records the tier `(tick_spacing, fee_rate)`.
3. Mints the Meme type's single Cetus `PoolCreationCap` from the ticket's treasury capability,
   before any Meme can leave the ticket, and registers the pair at `tick_spacing`. Cetus aborts if
   it refuses the pair there.
4. Stores the cap in `VenueConfig` under `CreationCapKey<Meme>`, with no path to remove it, and
   emits `blast_fun_migrators::blast_events::CetusPoolReserved`.

After this, only that cap (or Cetus's pool-manager role) can create the pair's Cetus pool at that
tick spacing, so no buyer can pre-create the migration pool at a price of their choosing.

`blast_fun_migrators::bluefin::new` (type arguments `<Meme, Quote>`; anyone holding the ticket)
takes, in order: the ticket, the migrators `PackageVersion`, the launchpad `PackageVersion`,
`LaunchConfig`, `tick_spacing: u32`, and `fee_rate: u64`. It aborts with `EInvalidTier` unless
`tick_spacing` is in 1..=400 and `fee_rate` is in 1..=20,000 (Bluefin's own pool-creation bounds),
then calls `launch::new` with `blast_fun_migrators::bluefin::Witness`. It needs no Bluefin objects.
Tiers are in each venue's own units.

#### Migrating to Cetus

Anyone may migrate once the launch is `MigrationReady`. Nothing requires a separate transaction, so
the PTB that graduates the curve can migrate too.

1. Work out Cetus's coin order. Cetus orders a pool's coins `CoinA` and `CoinB` by type name, and
   Blast checks the order with Cetus's own `is_right_order<CoinA, CoinB>` (in Cetus's `factory`
   module), which returns `true` for the accepted order. Dev-inspect it, or dry-run `migrate` with
   either order: the wrong one aborts with `EInvalidCoinOrder`.
2. Call `blast_fun_migrators::cetus::migrate` with type arguments `<Meme, Quote, CoinA, CoinB>` and,
   in order: the `Launch<Meme, Quote>` (mutable), the migrators `PackageVersion`, the launchpad
   `PackageVersion`, the Meme's `Currency<Meme>` (mutable), `VenueConfig`, Cetus `GlobalConfig`,
   Cetus `Pools` (mutable), LP Burn `BurnManager` (mutable), and `Clock`. It returns nothing; the
   caller receives no object.

Inside the call, in order:

1. Checks the migrators generation, then `CoinA`/`CoinB` order (`EInvalidCoinOrder`), then that
   `{CoinA, CoinB}` is exactly `{Meme, Quote}` (`EWrongCoinPair`).
2. Reads the launch's tier and Cetus's full-range ticks for its tick spacing.
3. Calls `launch::migrate`, which checks the launchpad generation, `MigrationReady`, and the adapter
   witness; pays the allocation plan's recipients; accrues Blast's one-time migration fee in the
   launch; burns the unsold curve Meme and pending sell-burn (or sends them to `@0x0` under a fixed
   supply); marks the launch `Migrated`; and hands the pool's Meme and Quote to the adapter.
4. Computes the opening price from those atomic amounts (see Economics), creates the pool with the
   reserved `PoolCreationCap` at the launch's tick spacing, and seeds full-range liquidity with
   exactly the handed-off balances. It never adopts an existing pool.
5. Burns the position through Cetus LP Burn. Cetus records the liquidity as permanently locked.
6. Creates and shares the `LpVault` holding the `CetusLPBurnProof` and Cetus's leftover coins as
   protocol residuals, and emits `VaultCreated`. It aborts with `EZeroLiquidity` if the position
   holds no liquidity.

#### Migrating to Bluefin

Anyone may call `blast_fun_migrators::bluefin::migrate` once the launch is `MigrationReady`. Bluefin
pools always have Meme as coin A: `Pool<Meme, Quote>`.

1. Split a `Coin<SUI>` worth exactly the SUI pool-creation fee Bluefin currently configures. Bluefin
   aborts on any other amount, and the whole coin is paid.
2. Call `blast_fun_migrators::bluefin::migrate` with type arguments `<Meme, Quote>` and, in order:
   the `Launch` (mutable), the migrators `PackageVersion`, the launchpad `PackageVersion`,
   `Currency<Meme>` (mutable), `Currency<Quote>`, Bluefin `GlobalConfig` (mutable), the `Coin<SUI>`
   fee (by value), and `Clock`.

Inside the call: it runs `launch::migrate` as above; creates `Pool<Meme, Quote>` at the launch's
tier, named `MEME-QUOTE` from the two Coin Registry symbols, with no Meme icon and the Quote's icon;
opens a position across the widest tick range Bluefin's configured bounds allow at that spacing;
seeds it with the handed-off balances; creates and shares the `LpVault` with the position and
Bluefin's leftovers as protocol residuals (`VaultCreated`); and shares the pool. The caller receives
no object, but Bluefin records the caller as the new pool's manager, a Bluefin role limited to the
pool's reward emissions and to handing the role on.

#### Collecting LP fees

Anyone may collect, as often as they like. A collection that finds no fees is valid.

- Cetus: `blast_fun_migrators::cetus::collect_fees`, type arguments `<Meme, Quote, CoinA, CoinB>`,
  with the `LpVault` (mutable), migrators `PackageVersion`, `LpFeePolicy`, `Currency<Meme>`
  (mutable), Cetus `GlobalConfig`, LP Burn `BurnManager`, the vault's Cetus `Pool<CoinA, CoinB>`
  (mutable), and `Clock`.
- Bluefin: `blast_fun_migrators::bluefin::collect_fees`, type arguments `<Meme, Quote>`, with the
  `LpVault` (mutable), migrators `PackageVersion`, `LpFeePolicy`, `Currency<Meme>` (mutable),
  Bluefin `GlobalConfig`, the vault's `Pool<Meme, Quote>` (mutable), and `Clock`.

Exact order of operations:

1. Check the migrators generation. On Cetus, prove the coin pair (`EWrongCoinPair`).
2. Check the pool is the vault's own (`EPositionPoolMismatch`).
3. Collect fees. Cetus: from the burned position through LP Burn, plus the auto-LP position's fees
   once it exists. Bluefin: from the migration position.
4. Split (if either amount is nonzero; otherwise skip to step 5 with no event):
   1. Read Blast's live share for this Meme from `LpFeePolicy` and take `ceil(gross × bps / 10,000)`
      of each asset.
   2. Apportion the rest of each asset by the vault's `FeeSplit` (see Economics).
   3. Pay Blast's share to the policy's current destination, or, on a partnered vault, add it to
      `unpaid_protocol_meme`/`unpaid_protocol_quote`.
   4. Add the creator, auto-LP, and rewards parts to their vault balances.
   5. Burn the burn part's Meme; add the burn part's Quote to `burn_quote`.
   6. Transfer each recipient its Meme and Quote as coins, in the split's order. Zero amounts send
      nothing.
   7. Emit `FeesCollected`.
5. Auto-LP: take all of `auto_lp_meme` and `auto_lp_quote` (this call's part plus anything left from
   earlier calls) and add what the pool takes at its current price. Keep the rest in the vault. Emit
   `AutoLiquidityAdded` only if something was added.

Auto-LP per venue:

- Cetus burned the migration position, so it cannot take liquidity. The first time both auto-LP
  balances are nonzero, the vault opens a second full-range position in the same pool (emitting
  `AutoLpPositionOpened`) before deciding the add, and keeps it with no removal path. Each add
  fixes all of coin A if Cetus's liquidity math says the coin B balance covers it, else all of coin
  B if the coin A balance covers that, else adds nothing.
- Bluefin adds to the migration position. Blast's own math picks the fixed side from the pool price
  and the position's bound prices, keeping a 2-atom margin on the other side.
- Both add nothing while either side is empty, so a one-sided auto-LP balance waits until the other
  asset arrives. The unfixed side's excess always waits for a later call.

#### Paying a partnered vault's Blast LP fees

When the launch named a partner, collections hold Blast's share in the vault instead of paying it.
Anyone may pay it out with `blast_fun_migrators::vault::claim_protocol_lp_fees_with_partner`
(`<Meme, Quote>`), passing the `LpVault` (mutable), migrators `PackageVersion`, `LpFeePolicy`, the
vault's `blast_partners::blast_partners::Partner`, and `Clock`. It aborts with `EPartnerMismatch`
unless the partner is the one the vault inherited (so it also aborts on a vault without a partner).
If nothing is held it returns without moving anything or emitting an event. Otherwise it takes
everything held, pays the partner its cut of each asset through
`blast_partners::blast_partners::pay` (which emits `blast_partners::blast_partners::PartnerPaid` for
each nonzero amount and sends the funds to the partner's recipient), pays the rest to the policy's
current destination, and emits `ProtocolLpFeesClaimed`. Compose it after `collect_fees` in one PTB
to settle both at once.

#### Claiming creator LP fees

1. Optionally call `collect_fees` first in the same PTB, so the latest fees are included.
2. Call `blast_fun_migrators::vault::claim_creator_fees` (type arguments `<Meme, Quote>`) with the
   `LpVault` (mutable), migrators `PackageVersion`, the `Launch<Meme, Quote>` (read-only), and the
   live `CurveFeeCap<Meme>` (owned, by reference). It returns `(Coin<Meme>, Coin<Quote>)` holding
   all of `creator_meme` and `creator_quote`, and emits
   `blast_fun_migrators::blast_events::CreatorFeesClaimed`.
3. Transfer or use both coins; coins cannot be dropped, so the PTB must consume them, even a
   zero-value one.

It aborts in the launchpad with code 22 if the cap is not the launch's live cap, and with
`ENoCreatorFees` if both balances are zero. This is separate from `launch::claim_creator_fees`,
which pays the creator's bonding-curve trade fees.

#### Changing the fee split

The live `CurveFeeCap` holder replaces the split. Fees already in the pool settle under the old
split first, so every fee follows the split it accrued under.

1. Build the new split in the PTB: one `allocation::route` (destination, BPS) per recipient, a
   `MakeMoveVec` of those routes, then `allocation::fee_split` (creator, auto-LP, rewards, and burn
   BPS, then the routes), with each `Bps` from `blast_fun::bps::new`. The parts must sum to exactly
   10,000; at most 16 recipients; destinations nonzero and distinct.
2. Call `blast_fun_migrators::cetus::settle_and_update_fee_split` with `<Meme, Quote, CoinA, CoinB>`
   or `blast_fun_migrators::bluefin::settle_and_update_fee_split` with `<Meme, Quote>`. Arguments,
   in order: the `LpVault` (mutable), migrators `PackageVersion`, `LpFeePolicy`, the `Launch`
   (read-only), the live `CurveFeeCap<Meme>`, `Currency<Meme>` (mutable), the venue objects exactly
   as in that venue's `collect_fees` (Cetus `GlobalConfig`, `BurnManager`, pool; or Bluefin
   `GlobalConfig`, pool), the new `FeeSplit` from step 1, and `Clock`.

Order: generation check; (Cetus) pair proof; live-cap check (launchpad code 22); proposal differs
from the current split (`EFeeSplitUnchanged`); a full collection exactly as above under the old
split; then the new split commits and emits `FeeSplitChanged`. A settlement that finds no fees
still commits. Balances already in the vault (creator, auto-LP leftovers, rewards, burn Quote) stay
where they are; auto-LP leftovers keep being added on later collections even if the new split has
no auto-LP part.

#### Buyback and burn (Blast admin)

A `BuybackAdmin` calls `blast_fun_migrators::cetus::buyback_and_burn` (`<Meme, Quote, CoinA,
CoinB>`) or `blast_fun_migrators::bluefin::buyback_and_burn` (`<Meme, Quote>`) with the vault, the
migrators `PackageVersion`, `&AdminWitness<BuybackAdmin>`, `Currency<Meme>`, the venue
`GlobalConfig`, the vault's pool, `min_meme_out` (atomic Meme units), and `Clock`. It checks the
pool is the vault's (`EPositionPoolMismatch`), takes all of `burn_quote` (`ENoBuybackQuote` if
zero), swaps it for Meme in the vault's pool up to the widest price limit, aborts with
`EBuybackBelowMinimum` if the Meme bought is below `min_meme_out`, burns that Meme (or sends it to
`@0x0` when the supply is not burn-only, as collections do), returns any Quote the pool did not
take to `burn_quote`, and emits `BuybackBurned`. The admin sets `min_meme_out` from an off-chain
price, because anyone can move the pool price inside a transaction.

#### Holder-reward rounds

Blast's off-chain system turns holder balances between checkpoints into a Merkle allocation. The
contract enforces only the published allocation, not how it was computed.

Publishing (Blast admin, `RewardsAdmin`): `blast_holder_rewards::publish_round` (`<Meme, Quote>`)
with the vault (mutable), migrators `PackageVersion`, `&AdminWitness<RewardsAdmin>`, `number`,
`start_checkpoint`, `end_checkpoint`, `root`, `manifest_digest`, `leaf_count`, `meme_amount`,
`quote_amount`. Checks, in order: `number` equals the vault's `next_round` (`EWrongRound`);
`start_checkpoint < end_checkpoint` and, after the first round, `start_checkpoint` equals the
previous `end_checkpoint` (`EInvalidInterval`); `root` and `manifest_digest` are 32 bytes each
(`EInvalidCommitment`); `leaf_count` is 1..=65,536 (`EInvalidLeafCount`); at least one amount is
nonzero (`EEmptyBudget`). It moves the budget out of `rewards_meme`/`rewards_quote` (a Sui balance
abort if the vault holds less), shares a new `Round`, and emits `RoundPublished`. The contract never
checks that the leaves sum to the budget. Checkpoints are opaque u64 values to the contract.

Claiming (anyone): `blast_holder_rewards::claim` (`<Meme, Quote>`) with the `Round` (mutable),
migrators `PackageVersion`, `index`, `beneficiary`, `meme_amount`, `quote_amount`, and `proof`
(`vector<vector<u8>>`, leaf to root). Checks, in order: `index < leaf_count` (`EInvalidIndex`); the
leaf is unpaid (`EAlreadyClaimed`); `beneficiary` is not `@0x0` (`EInvalidBeneficiary`); an amount
is nonzero (`EEmptyBudget`); the proof verifies (`EInvalidProof`). It marks the leaf paid, transfers
the nonzero amounts as coins to `beneficiary` (never to the sender; a Sui balance abort if the round
holds less), and emits `RewardPaid`. Anyone can relay a claim; the beneficiary receives the same
coins either way. There is no deadline.

Leaf and proof format (Blake2b-256 throughout, BCS encoding):

- Leaf: `blake2b256(0x00 || "blast-holder-rewards-v1" || vault_id || round || index || beneficiary
  || meme_amount || quote_amount)`. `vault_id` is the `LpVault` ID (32 bytes), not the `Round` ID.
  `round`, `index`, and the amounts are u64 little-endian (8 bytes each). `beneficiary` is 32
  bytes. The tag is the ASCII string after one zero byte.
- Internal node: `blake2b256(0x01 || left || right)`.
- Tree: leaves in index order. At any level with an odd count, the last node pairs with itself.
- Proof: exactly as many 32-byte siblings as the tree has levels (`leaf_count` 1 needs none, 2 needs
  one, 3 or 4 need two, and so on). At each level, if the current index is even the node is
  `node(current, sibling)`, otherwise `node(sibling, current)`; then the index halves.
- Test vector: with the vault ID and beneficiaries written as small numbers left-padded to 32
  bytes, vault `0xd`, round 0, and leaves (index, beneficiary, Meme, Quote) `(0, 0xa, 10, 20)`,
  `(1, 0xb, 30, 40)`, `(2, 0xc, 50, 60)` give leaf 0
  `18ba1db53bc0da39eb6f1f00df49fa5be0932e85ca8f8257f4d278edea7f1aa8` and root
  `93f46ab27a1d3a5def3379afd0a3b02cc149d6fa03b7105b2697deba8c12cb2d`. Leaf 2's proof is
  `[leaf 2 itself, node(leaf 0, leaf 1)]`.

#### Claiming migration residuals (Blast admin)

A `TreasuryAdmin` calls `blast_fun_migrators::vault::claim_protocol_fees` (`<Meme, Quote>`) with the
vault, migrators `PackageVersion`, and `&AdminWitness<TreasuryAdmin>`. It returns `(Coin<Meme>,
Coin<Quote>)` holding both residuals, emits `ProtocolFeesClaimed` with the sender as `claimant`, and
aborts with `ENothingClaimable` when both are zero. Blast's one-time migration fee is not here; it
sits in the launch and is claimed through the launchpad.

#### LP-fee policy (Blast admin)

- `lp_fee_policy::set_default_shares` (`FeeAdmin`): sets the default Meme and Quote BPS for every
  coin without its own pair. Aborts with `EProtocolFeeSharesUnchanged` if unchanged.
- `lp_fee_policy::set_coin_shares` (type argument `Meme`; `FeeAdmin`): sets this Meme's own pair,
  keyed by its original type name. A pair equal to the defaults is still a real entry: later default
  changes skip that coin. Aborts if it equals the coin's current pair.
- `lp_fee_policy::clear_coin_shares` (type argument `Meme`; `FeeAdmin`): removes the coin's pair so
  the defaults apply again. Aborts in Sui's table code if the coin has no pair.
- `lp_fee_policy::set_protocol_destination` (`TreasuryAdmin`): redirects every later Blast payout.
  Aborts with `EProtocolDestinationUnchanged` for `@0x0` or the current address.

Each takes effect from the next collection or partner payout. At publication the defaults are 0 BPS
for both assets and the destination is the publishing address; read the live object for current
values.

#### Package upgrades (Blast admin)

`blast_fun_migrators::package_admin::authorize_upgrade` returns an upgrade ticket for an exact
digest; `blast_fun_migrators::package_admin::commit_upgrade_and_advance` commits the receipt and
moves `PackageVersion` to the next generation in the same call. From then on, every call to the old
package's code aborts the generation check, so integrators must call the current package address.
Type names keep the original package address. Upgrading this package leaves the launchpad on its own
generation.

### Economics

All amounts are atomic units. BPS are out of 10,000.

#### Blast's LP-fee share

For each collection, with the Meme's own pair if `FeeAdmin` set one, otherwise the defaults:

- `protocol_meme = ceil(gross_meme × meme_bps / 10,000)`
- `protocol_quote = ceil(gross_quote × quote_bps / 10,000)`

Blast's share rounds up, so it takes the rounding dust of its own part. The pair and the destination
are read live at each collection. This share is separate from Blast's one-time migration allocation,
which the launchpad takes from the supply and the final reserve at migration.

#### Partner cut

On a partnered vault, Blast's share waits in `unpaid_protocol_*`. At payout the partner receives
`floor(held × share_bps / 10,000)` of each asset, using the partner's share in force at payout time
(the partners package caps it at 8,000 BPS and delays Blast's changes to it by seven days). Blast's
destination receives the rest. The creator, recipients, auto-LP, rewards, and burn receive exactly
what they would without a partner.

#### The fee split

`net = gross − protocol`, per asset. The vault's `FeeSplit` divides each asset's `net` independently
into parts in this fixed order: creator, auto-LP, rewards, burn, then each recipient in the split's
order. Apportionment is largest-remainder and exact:

1. Each part gets `floor(net × part_bps / 10,000)`.
2. The units left over go one each to the parts with the largest remainders (`net × part_bps mod
   10,000`), ties going to the earlier part.

The parts always sum to `net`. Anyone can preview a split with the public, pure
`allocation::apportion_fee_split` in a dev-inspect.

Worked example (Blast at 1,000 BPS Meme and 2,500 BPS Quote; split creator 2,000, auto-LP 2,000,
rewards 1,000, burn 1,000, recipient B 2,500, recipient A 1,500; gross 11 Meme and 7 Quote):

| | Blast | Creator | Auto-LP | Rewards | Burn | B | A |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Meme (net 9) | 2 | 2 | 2 | 1 | 1 | 2 | 1 |
| Quote (net 5) | 2 | 1 | 1 | 1 | 0 | 1 | 1 |

#### Where each part goes

| Part | Destination |
| --- | --- |
| Blast | Policy destination at once, or held for the partner payout. |
| Creator | `creator_meme`/`creator_quote`, until the live `CurveFeeCap` claims it. |
| Auto-LP | Added back to liquidity in the same call; what the pool does not take waits in `auto_lp_*`. |
| Rewards | `rewards_meme`/`rewards_quote`, until a round reserves it. |
| Burn, Meme | Burned at once if the Meme's Coin Registry supply is burn-only; otherwise sent to `@0x0`. |
| Burn, Quote | `burn_quote`, until a buyback swaps it for Meme and disposes of that Meme as above. |
| Recipients | Coins transferred to each destination in the same call. |

#### Auto-LP math

Auto-LP never swaps. It fixes all of one side and pays what the venue asks of the other at the
current price; the rest of the other side waits. Bluefin's side choice, with `P`, `L`, `U` the
current, lower, and upper sqrt prices (Q64.64) and a 2-atom margin: fix Meme when `liquidity = a ×
(P × U / 2^64) / (U − P)` is positive and below 2^128 and `ceil(liquidity × (P − L) / 2^64) + 2 ≤
quote balance`; otherwise fix Quote when `liquidity = b × 2^64 / (P − L)` is positive and
`ceil(liquidity × 2^64 / P) − floor(liquidity × 2^64 / U) + 2 ≤ meme balance`; otherwise wait. A
price at or outside the range adds nothing. Cetus uses Cetus's own liquidity math with no margin.

#### Migration seed and residuals

The opening sqrt price is `floor(sqrt(coin_b / coin_a) × 2^64)` from the handed-off atomic amounts:
Quote/Meme when Meme is coin A, Meme/Quote otherwise. Display decimals never enter it. The seed
fixes the side with more atoms (Meme on a tie), unless the venue's math says that would overdraw the
other side by rounding, in which case it fixes the other side. Whatever the venue does not take
becomes the vault's protocol residuals. Position principal plus residuals equals the hand-off.

### Time rules

- No deadlines exist in this package. Collections, payouts, claims, and buybacks work at any time.
- Policy changes apply from the next collection; there is no delay.
- A partner payout uses the partner's share in force at payout, not at collection.
- Holder-reward rounds never expire. Their checkpoint intervals must be contiguous and nonempty.
- `migrate`, `collect_fees`, `settle_and_update_fee_split`, and `buyback_and_burn` take `Clock`
  (`0x6`) for the venue's own use (`new` takes none); the partner payout takes it for the partner's
  timelocked share.

### Reading state

This package has no public getters for its objects. Read object fields over RPC or GraphQL.

- **Vault** (`LpVault<Meme, Quote>`): the fields listed under "What an `LpVault` holds". Each
  `Balance` shows its value. `fee_split` holds `creator_bps`, `auto_lp_bps`, `rewards_bps`,
  `burn_bps` (each a `Bps` wrapping one u64) and `recipients` (each with `destination` and `bps`).
  The position is a dynamic object field of the vault: list its dynamic fields, or read the child
  object by the ID in `VaultCreated.position_id`.
- **Find a launch's vault:** scan `VaultCreated` events for its `meme` type name, or read the
  objects the migrate transaction created. Each Meme type has exactly one launch, so `LpVault<Meme,
  Quote>` is unique per Meme.
- **Blast's live share for a coin:** `LpFeePolicy.coins` is a table keyed by the standard library's
  `TypeName` holding the Meme's original type name (64 hex digits without `0x`, then the module and
  type names, each after two colons). If the coin has an entry, use its `meme_bps`/`quote_bps`;
  otherwise use `defaults`. `destination` is the current payee.
- **Round** (`Round<Meme, Quote>`): `vault`, `number`, `root`, `leaf_count`, `meme` and `quote`
  (funds left), and `claimed`, a bitmap of u256 words: leaf `i` is paid when bit `i mod 256` of word
  `i / 256` is set.
- **Cetus reservation:** `VenueConfig` has a dynamic object field `CreationCapKey<Meme>` holding the
  pair's `PoolCreationCap`.
- **Launch facts** (public launchpad getters): `launch::pool_tier` (tick spacing and fee rate),
  `launch::lp_fee_split` (the split at migration), `launch::partner_id`.
- **Generation:** `PackageVersion.generation`, an `OperationalVersion` whose own `generation` field
  holds the number.
- **Pending fees and the next split:** dry-run `collect_fees`; the emitted `FeesCollected` and
  `AutoLiquidityAdded` show exactly what a collection would do now.

### Events

This package emits its events directly, with no envelope. The launchpad wraps its own events in
`blast_fun::blast_events::Event`. All events below are in this package's `blast_events` module.

| Event | Emitted by | Fields |
| --- | --- | --- |
| `CetusPoolReserved` | Cetus `new` | `meme`, `quote` (type names), `pool_creation_cap_id`, `tick_spacing` |
| `VaultCreated` | `migrate` | `vault_id`, `pool_id`, `position_id`, `venue`, `meme`, `quote` (type names), `residual_meme`, `residual_quote`, `liquidity`, `fee_split` |
| `FeesCollected` | nonzero collection | `vault_id`, `gross_meme`, `gross_quote`, `protocol_destination` (none when held for a partner), `protocol_meme`, `protocol_quote`, `creator_*`, `auto_lp_*`, `rewards_*`, `burn_meme` (burned), `burn_quote` (waits), `recipient_meme`, `recipient_quote` (split order) |
| `AutoLpPositionOpened` | first Cetus collection with both auto-LP balances nonzero | `vault_id`, `position_id` |
| `AutoLiquidityAdded` | auto-LP added something | `vault_id`, `meme_amount`, `quote_amount`, `meme_pending`, `quote_pending` |
| `FeeSplitChanged` | split update | `vault_id`, `old_fee_split`, `new_fee_split` |
| `CreatorFeesClaimed` | creator LP-fee claim | `vault_id`, `meme_amount`, `quote_amount` |
| `BuybackBurned` | buyback | `vault_id`, `quote_spent`, `meme_burned`, `quote_pending` |
| `RoundPublished` | round publish | `vault_id`, `round_id`, `number`, `start_checkpoint`, `end_checkpoint`, `root`, `manifest_digest`, `leaf_count`, `meme_amount`, `quote_amount`, `meme_unallocated`, `quote_unallocated` |
| `RewardPaid` | reward claim | `round_id`, `index`, `beneficiary`, `meme_amount`, `quote_amount`, `meme_remaining`, `quote_remaining` |
| `ProtocolFeesClaimed` | residual claim | `vault_id`, `meme`, `quote` (type names), `claimant`, `meme_amount`, `quote_amount` |
| `ProtocolLpFeesClaimed` | partner payout | `vault_id`, `protocol_destination`, `protocol_meme`, `protocol_quote`, `partner_meme`, `partner_quote` |
| `LpFeePolicyChanged` | policy share change | `meme` (none for defaults), `old_meme_bps`, `old_quote_bps`, `new_meme_bps`, `new_quote_bps` (the old pair is none when a coin pair is created, the new pair none when it is removed) |
| `LpFeeDestinationChanged` | destination change | `old_destination`, `new_destination` |

Event order inside one call: a collection emits `FeesCollected`, then possibly
`AutoLpPositionOpened`, then possibly `AutoLiquidityAdded`; a split update adds `FeeSplitChanged`
last. Venue events from Cetus or Bluefin appear alongside. A partner payout emits
`blast_partners::blast_partners::PartnerPaid` (per nonzero asset) before `ProtocolLpFeesClaimed`. A
migrate transaction carries the launchpad's wrapped `blast_fun::events::MigrationAllocationPaid` (one
per allocation recipient), `blast_fun::events::ProtocolFeesAccrued` (only when Blast's migration fee
is nonzero), and `blast_fun::events::Migrated` before `VaultCreated`.

#### Replaying a vault from events

Start a vault at `VaultCreated`: its `fee_split`, residuals, `pool_id`, `position_id`.
`VaultCreated` has no launch ID; link it through `Migrated.launch_id` in the same transaction, or
through the `meme` type. On Cetus, `position_id` is the `CetusLPBurnProof`, not the burned Cetus
position. Position principal is `Migrated.meme − residual_meme` and `Migrated.quote −
residual_quote`. Then reduce:

- `FeesCollected`: add `creator_*`, `auto_lp_*`, `rewards_*`, and `burn_quote` to their balances;
  `burn_meme` left the supply (or went to `@0x0`); if `protocol_destination` is none, add
  `protocol_*` to the held partner balance; recipient `i` of the split in force received
  `recipient_meme[i]` and `recipient_quote[i]`.
- `AutoLiquidityAdded`: auto-LP balances become `meme_pending`/`quote_pending`; principal rises by
  the added amounts. It can appear without `FeesCollected`, when only earlier leftovers were added.
- `FeeSplitChanged`: adopt `new_fee_split`.
- `CreatorFeesClaimed`, `ProtocolFeesClaimed`, `ProtocolLpFeesClaimed`: the matching balances become
  zero (each claim takes everything). `CreatorFeesClaimed` names no recipient; the coins go wherever
  the PTB sends them.
- `BuybackBurned`: `burn_quote` becomes `quote_pending`; `meme_burned` left the supply (or went to
  `@0x0`).
- `RoundPublished`: rewards balances become `meme_unallocated`/`quote_unallocated`; `next_round`
  becomes `number + 1` and `last_checkpoint` becomes `end_checkpoint`; record the round's budget
  under `round_id`.
- `RewardPaid`: find the round by `round_id`; its funds become `meme_remaining`/`quote_remaining`;
  mark `index` paid.

A collection that finds no fees emits no `FeesCollected` and changes no balance except through
auto-LP. The replay reproduces every vault balance exactly.

### Aborts

Codes are per module. This package's errors carry their constant name and code; the launchpad and
Blast admin abort with plain numeric codes from the named module.

| Flow | Abort | Fix |
| --- | --- | --- |
| any | code 13 from Blast admin's `operational_version` module | Call the current package address with the current `PackageVersion` objects; pass the launchpad's too on `new`/`migrate`. |
| Cetus `migrate` | `EInvalidCoinOrder` (0, module `cetus`) | Swap `CoinA` and `CoinB`. |
| Cetus routes | `EWrongCoinPair` (2, module `cetus`) | `CoinA`/`CoinB` must be exactly the launch's Meme and Quote. |
| collect, settle, buyback | `EPositionPoolMismatch` (Cetus 1, Bluefin 0) | Pass the pool whose ID is the vault's `pool_id`. |
| Bluefin `new` | `EInvalidTier` (1, module `bluefin`) | Tick spacing 1..=400, fee rate 1..=20,000. |
| `migrate` | code 15 from the launchpad's `launch` module | The launch is not `MigrationReady` (not graduated, or already migrated). |
| `migrate` | code 21 from the launchpad's `launch` module | Use the venue the launch started with. |
| `migrate` | `EZeroLiquidity` (3, module `vault`) | The seed produced no liquidity; nothing to fix by retrying. |
| creator claim, split update | code 22 from the launchpad's `launch` module | Use the launch's live `CurveFeeCap`. |
| creator claim | `ENoCreatorFees` (2, module `vault`) | Collect first, or wait for fees. |
| split update | `EFeeSplitUnchanged` (1, module `vault`) | Propose a different split. |
| split construction | codes 6, 7, 8, 24 from the launchpad's `allocation` module; 0 from its `bps` module | Nonzero destination, sum exactly 10,000, at most 16 recipients, no duplicates, each BPS ≤ 10,000. |
| partner payout | `EPartnerMismatch` (6, module `vault`) | Pass the `Partner` whose ID is the vault's `partner_id`; vaults without a partner have no payout. |
| buyback | `ENoBuybackQuote` (4), `EBuybackBelowMinimum` (5), module `vault` | Wait for burn Quote; lower `min_meme_out` or retry at a better price. |
| residual claim | `ENothingClaimable` (0, module `vault`) | Nothing left to claim. |
| publish round | `EWrongRound` (0), `EInvalidInterval` (1), `EInvalidCommitment` (2), `EInvalidLeafCount` (3), `EEmptyBudget` (4) in `blast_holder_rewards` | Use `next_round`, a contiguous interval, 32-byte digests, 1..=65,536 leaves, a nonzero budget within the rewards balance. |
| reward claim | `EInvalidIndex` (5), `EAlreadyClaimed` (6), `EInvalidBeneficiary` (7), `EEmptyBudget` (4), `EInvalidProof` (8) in `blast_holder_rewards` | Pass the leaf exactly as committed with its full-depth proof; each leaf pays once. |
| policy | `EProtocolDestinationUnchanged` (0), `EProtocolFeeSharesUnchanged` (1) in `lp_fee_policy` | Change the stored value. |

Venue-side aborts (Cetus or Bluefin refusing a tier, a pair, or a fee amount) carry the venue's own
codes.

### Pitfalls

- **Cetus coin order.** Every Cetus route after `new` takes `<Meme, Quote, CoinA, CoinB>`, with
  `CoinA`/`CoinB` in Cetus's order, not launch order. On routes that take a pool, the pool's type
  already fixes the order. Bluefin routes take only `<Meme, Quote>`.
- **Two version objects.** `new` and `migrate` need both this package's `PackageVersion` and the
  launchpad's. Other calls need only this package's.
- **Two kinds of creator fees and protocol fees.** `launch::claim_creator_fees` pays bonding-curve
  fees; `blast_fun_migrators::vault::claim_creator_fees` pays LP fees. Each package has its own
  `CreatorFeesClaimed` and `ProtocolFeesClaimed` event; decode by full type.
- **Partnered vaults do not pay Blast at collection.** `FeesCollected.protocol_destination` is none
  and the share waits until someone calls the partner payout.
- **Not every call emits `FeesCollected`.** A collection that finds no fees emits none, but auto-LP
  can still add earlier leftovers with only `AutoLiquidityAdded`.
- **Auto-LP leftovers are normal.** One side always has excess after an add, and a one-sided balance
  waits for the other asset. Leftovers are not lost.
- **`claim_creator_fees` aborts on an empty balance.** Check `creator_meme`/`creator_quote` or
  collect in the same PTB first.
- **Bluefin migration costs SUI and sets a manager.** The caller supplies the exact Bluefin creation
  fee and becomes the pool's Bluefin manager.
- **Merkle details.** Leaves bind the vault ID (not the round ID) and the round number; the odd last
  node pairs with itself; proof length must equal the tree depth exactly.
- **Holder rewards are paid only to the beneficiary.** A relayer pays gas and receives nothing.
- **Upgrades.** After an upgrade, calls to the old package address abort; type names still use the
  original address, so per-coin policy keys and event filters do not change.

### Q&A

**Who triggers migration, and is there a reward?** Anyone, once the launch is `MigrationReady`, by
calling the venue's `migrate`. The caller pays gas (and on Bluefin the SUI creation fee) and
receives no object or reward. On Bluefin the caller becomes the pool's Bluefin manager.

**Can the creator or Blast withdraw the liquidity?** No function removes a position from the vault.
The Cetus migration liquidity is burned through Cetus LP Burn. The Bluefin position and the Cetus
auto-LP position have no removal path in the current code, which an upgrade of this package could
change.

**How do I find a launch's vault and pool?** Scan `VaultCreated` events for the `meme` type name;
the match gives `vault_id`, `pool_id`, and `position_id`. The vault's type is
`LpVault<Meme, Quote>`, and its `pool_id` field also names the pool.

**How does a creator get LP fees?** Call `collect_fees` (anyone can), then
`blast_fun_migrators::vault::claim_creator_fees` with the launch and the live `CurveFeeCap`, in one
PTB if you like. The call returns two coins the PTB must transfer.

**How much does Blast take?** Read `LpFeePolicy`: the coin's own pair if present, else the defaults,
applied as `ceil(gross × bps / 10,000)` per asset before the split. Blast can change it at any time,
from the next collection.

**How often should fees be collected?** Any time; it is permissionless and a zero collection is
harmless. Frequent collection keeps each auto-LP add small, which limits what a price mover can
skim.

**What happens to the burn share?** The Meme part is burned in the same collection (or sent to
`@0x0` when the supply is not burn-only). The Quote part waits in `burn_quote` until a Blast
`BuybackAdmin` swaps it for Meme with a minimum out and disposes of that Meme the same way.

**How do holders claim rewards?** Blast publishes a round with a Merkle root; a holder (or any
relayer) calls `blast_holder_rewards::claim` with the leaf's index, beneficiary, amounts, and proof.
The coins go to the beneficiary. Claims never expire, and each leaf pays once.

**Can the fee split change after migration?** Yes. The live `CurveFeeCap` holder calls the venue's
`settle_and_update_fee_split`, which first collects and splits pending fees under the old split,
then commits the new one as the next generation.

**When does a partner get its cut of LP fees?** When anyone calls
`blast_fun_migrators::vault::claim_protocol_lp_fees_with_partner` on the vault. It pays the partner
its share in force at that moment, rounded down, and Blast's destination the rest.
