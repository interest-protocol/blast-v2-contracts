## Cetus and Bluefin venues

### What it is

Package `blast_migrators` holds the two venues a Blast sale can migrate to: Cetus
(`blast_migrators::cetus`) and Bluefin (`blast_migrators::bluefin`). Both products use them:
launchpad launches and presales. A venue takes part in a sale twice. At creation its `prepare` call
records the coin's pool tier and returns a sealed `blast_core::migration::VenueTicket` that the
product's `new` (for a launch, `launch::new`) redeems, so the sale can migrate only to that venue.
When the sale is ready, one PTB calls the product's own `migrate` (for a launch, `launch::migrate`),
which returns the sealed `blast_core::migration::Migration`, and then the venue's `migrate`, which
redeems it, creates a new full-range pool seeded with the sale's Meme and Quote, and locks the
position in a new shared `blast_vault::vault::Vault`, which has no removal path. Afterwards anyone
collects the position's trading fees through the venue; the vault pays Blast its share and splits
the rest by the vault's fee split. The vault itself (fee split, owner claims, partner payouts,
holder rewards) is described in the vault guide; this guide covers what the venues do and what each
call needs. The package imports no product and no product imports it.

### Objects and authority

#### Shared objects

| Object | How many | What it does |
| --- | --- | --- |
| `blast_migrators::venue_config::VenueConfig` | singleton | Venue-owned records, written once per coin and never removed: each Cetus coin's `PoolCreationCap` and tick spacing, and each Bluefin coin's tier. |
| `blast_admin::package_version::PackageVersion` | singleton, typed `PackageVersion<BLAST_MIGRATORS>` by `blast_migrators::blast_migrators::BLAST_MIGRATORS` | This package's version; every venue call checks it first. It defines no pause bits. |
| `blast_admin::package_admin::PackageAdmin` | singleton, typed `PackageAdmin<BLAST_MIGRATORS>` | Sealed custody of this package's `Publisher` and `UpgradeCap`, in Blast's generic package administration. |
| `blast_vault::vault::Vault<Meme, Quote>` | one per migrated sale | Created and shared by `migrate`; holds the venue position and the fee balances (vault guide). |

Calls also take objects from other packages:

- The product: at creation the creator passes its owned `TreasuryCap<Meme>` to `prepare`; at
  migration the venue takes the `blast_core::migration::Migration<Meme, Quote>` value the product's
  `migrate` returned earlier in the PTB, and no product object.
- Vault: `blast_vault_package::VaultRegistry` (migrate only), the vault package's
  `blast_admin::package_version::PackageVersion` (typed by `blast_vault_package::BLAST_VAULT_PACKAGE`),
  and the shared `blast_core::blast_treasury::Treasury` that Blast's LP fees go to.
- Sui: the Meme's Coin Registry `Currency<Meme>` (shared; mutable for collections and buybacks,
  which burn Meme; read-only in Bluefin `prepare` and `migrate`), the Quote's `Currency<Quote>`
  (Bluefin migration only), and `Clock` at `0x6`.
- Cetus: `GlobalConfig`, `Pools`, the pair's `Pool<CoinA, CoinB>`, and Cetus LP Burn's
  `BurnManager`, all shared.
- Bluefin: its `GlobalConfig` and the pair's `Pool<Meme, Quote>`, both shared.

#### Venue witnesses

`blast_migrators::cetus::Venue` and `blast_migrators::bluefin::Venue` are the venues'
sealed witnesses; only their own module constructs them. A venue's witness issues its tickets,
redeems its sales' migrations, keys its position inside the vault, and authorizes its fee
collections. Blast admits each witness type in each product's venue list (the launchpad's
`LaunchConfig`, so launches may start on it) and in the vault's `VaultRegistry` (so it may create
vaults), which must also list each product's package witness, for launches
`blast_fun::blast_fun::PackageWitness`, as the package witness that seals its sales' vault terms.

#### Who may call what

| Call | Who |
| --- | --- |
| `blast_migrators::cetus::prepare`, `blast_migrators::bluefin::prepare` | holder of the coin's `TreasuryCap<Meme>` (the creator), in the sale's creation PTB |
| `blast_migrators::cetus::migrate`, `blast_migrators::bluefin::migrate` | anyone, with the `Migration` the product's `migrate` returned in the same PTB |
| `blast_migrators::cetus::collect_fees`, `blast_migrators::bluefin::collect_fees` | anyone |
| `blast_migrators::cetus::settle_and_apply_fee_split`, `blast_migrators::bluefin::settle_and_apply_fee_split` | anyone, once the vault's proposed split is ready |
| `blast_migrators::cetus::compound_auto_lp`, `blast_migrators::bluefin::compound_auto_lp` | anyone |
| `blast_migrators::cetus::buyback_and_burn`, `blast_migrators::bluefin::buyback_and_burn` | Blast admin: `blast_core::blast_domain::BuybackAdmin` |
| `blast_admin::package_admin::schedule_upgrade`, `blast_admin::package_admin::authorize_upgrade`, `blast_admin::package_admin::commit_upgrade_and_advance`, `blast_admin::package_admin::schedule_make_immutable`, `blast_admin::package_admin::make_immutable`, `blast_admin::package_admin::schedule_upgrade_delay`, typed `<BLAST_MIGRATORS>` | Blast admin: `blast_admin::package_admin::UpgradeAdmin<BLAST_MIGRATORS>` |
| `blast_admin::package_admin::cancel_upgrade_action<BLAST_MIGRATORS>` | Blast admin: `blast_admin::package_admin::CancelAdmin<BLAST_MIGRATORS>` |
| `blast_admin::package_admin::wrap<BLAST_MIGRATORS>` | holder of the package's `blast_admin::package_version::Publication` and native `UpgradeCap` (once, at deployment) |

The vault's own calls (owner claims, fee-split proposals, partner payouts, holder rewards) are listed
in the vault guide; the owner acts there with an owner proof from the sale's product (for a launch,
`launch::prove_owner`). A Blast
admin signs in with `blast_acl::sign_in` on the shared `blast_acl::ACL` to get the role's
`blast_acl::AdminWitness`. Integrators cannot call admin functions.

#### Trust assumptions

- **Upgradeable package.** `UpgradeAdmin` can authorize compatible upgrades of this package after
  the upgrade notice (48 hours at publication). Positions are held by the vault package, under the
  venue's key: the Cetus migration liquidity is also burned through Cetus LP Burn, whose
  `CetusLPBurnProof` can only collect fees.
- **Venue operators.** Cetus's pool-manager role can create a reserved pair's pool without the
  coin's `PoolCreationCap`. If it does so first, Cetus migration aborts, and only a migrators
  upgrade could recover the sale. If Cetus stops registering the sale's tick spacing, migration
  aborts and the sale stays ready to migrate.
- **Auto-LP price-move skim.** Auto-LP adds at the pool's current price. A caller can move the price
  in the same transaction, compound, and move it back, skimming part of that call's auto-LP amount.
  Frequent compounding keeps each slice small. Buybacks are admin-only with a minimum output for
  the same reason.
- **Buyback timing.** The burn route's Quote waits until a `BuybackAdmin` acts; nothing forces a
  buyback.

### Lifecycle

1. **Prepare** (creation PTB): the venue records the coin's tier in `VenueConfig` and returns a
   `VenueTicket<Meme, Quote>`; the product's `new` redeems it and stores the venue. A coin is
   prepared once: its records are write-once.
2. **Sale**: the launch trades until `MigrationReady`, or the presale fills (product guides).
3. **Migrate**: in one PTB the product's `migrate` returns the sale's `Migration`, and the venue's
   `migrate` redeems it, creates the pool, and creates and shares the vault. A `Migration` cannot be
   dropped or stored, so a PTB that does not redeem it aborts, and a failed venue migration aborts the
   whole transaction, product step included: the sale stays ready to migrate.
4. **Collect**: any number of fee collections, fee-split changes, and buybacks through the venue.
   The vault never closes and its positions are never removed.

### Flows

Every venue call takes the migrators `PackageVersion<BLAST_MIGRATORS>` (shared) and checks it
before anything else. Calls that also mutate the vault take the vault package's version too, because
each package checks only its own version.

#### Prepare a coin on Cetus (creator, inside the sale's creation PTB)

`blast_migrators::cetus::prepare` (type arguments `<Meme, Quote>`) takes, in order: the migrators
`PackageVersion`, `VenueConfig` (mutable), Cetus `GlobalConfig`, Cetus `Pools` (mutable), the
`TreasuryCap<Meme>` (owned, by mutable reference), and `tick_spacing: u32`. It:

1. Checks that Cetus registers a fee rate for `tick_spacing` (Cetus aborts otherwise).
2. Mints the Meme type's single Cetus `PoolCreationCap` from the treasury cap and registers the pair
   at `tick_spacing`. Cetus aborts if it refuses the pair there.
3. Stores the cap under `blast_migrators::cetus::CreationCapKey` and the tick spacing under
   `blast_migrators::cetus::PoolTierKey` in `VenueConfig`, with no path to remove either, and
   emits `blast_migrators::events::CetusPoolReserved`.
4. Returns a `blast_core::migration::VenueTicket<Meme, Quote>` sealed by
   `blast_migrators::cetus::Venue`.

After this, only that cap (or Cetus's pool-manager role) can create the pair's Cetus pool at that
tick spacing, so no buyer can pre-create the migration pool at a price of their choosing. The fee
rate is whatever Cetus registers for the tick spacing.

#### Prepare a coin on Bluefin (creator, inside the sale's creation PTB)

`blast_migrators::bluefin::prepare` (type arguments `<Meme, Quote>`) takes, in order: the migrators
`PackageVersion`, `VenueConfig` (mutable), the `TreasuryCap<Meme>` (owned, by immutable reference,
proving the caller controls the coin), the Meme's `Currency<Meme>` (read-only), `tick_spacing: u32`,
and `fee_rate: u64`. It aborts with `blast_migrators::errors::EInvalidTier` unless `tick_spacing` is
in 1..=400 and `fee_rate` in 1..=20,000 (Bluefin's own pool-creation bounds, checked here because
Bluefin checks them only at pool creation), then with `blast_migrators::errors::ESymbolTooLong`
when the Meme symbol is longer than 32 bytes (the pool and its position store it). It stores a
`blast_migrators::bluefin::PoolTier` under `blast_migrators::bluefin::PoolTierKey` in `VenueConfig`,
emits `blast_migrators::events::BluefinPoolTierRecorded`, and returns a `VenueTicket<Meme, Quote>`
sealed by `blast_migrators::bluefin::Venue`. It needs no Bluefin objects.

Either way, pass the ticket to the product's `new` in the same PTB (for a launch, `launch::new`,
with the same `TreasuryCap` by value; launchpad guide, Flow 3). The ticket cannot be stored or
dropped.

#### Migrate to Cetus (anyone)

Nothing requires a separate transaction, so the PTB that completes a sale can migrate too.

1. Work out Cetus's coin order. Cetus orders a pool's coins `CoinA` and `CoinB` by type name, and
   the venue checks the order with Cetus's own `is_right_order<CoinA, CoinB>` (in Cetus's `factory`
   module). Dev-inspect it, or dry-run `migrate` with either order: the wrong one aborts with
   `blast_migrators::errors::EInvalidCoinOrder`.
2. Call the product's `migrate` (for a launch, `launch::migrate`; launchpad guide). It returns the
   sale's `Migration<Meme, Quote>`.
3. Call `blast_migrators::cetus::migrate` with type arguments `<Meme, Quote, CoinA, CoinB>` and, in
   order: the `Migration` result of step 2 (by value), the migrators `PackageVersion`,
   `VenueConfig`, Cetus `GlobalConfig`, Cetus `Pools` (mutable), LP Burn `BurnManager` (mutable),
   `VaultRegistry` (mutable), the vault `PackageVersion`, `Treasury`, and `Clock`. It returns
   nothing; the caller receives no object.

Inside the venue call, in order:

1. Checks the coin order (`blast_migrators::errors::EInvalidCoinOrder`) and that `{CoinA, CoinB}`
   is exactly `{Meme, Quote}` (`blast_migrators::errors::EWrongCoinPair`).
2. Redeems the `Migration` with its witness, receiving the pool's Meme and Quote and the vault's
   terms; a hand-off sealed for any other venue aborts.
3. Reads the coin's tick spacing from `VenueConfig` and Cetus's full-range ticks for it.
4. Computes the opening price from those atomic amounts with
   `blast_core::migration::sqrt_price_x64` (see Economics), creates the pool with the reserved
   `PoolCreationCap` at the recorded tick spacing, and seeds full-range liquidity with exactly the
   handed-off balances. It never adopts an existing pool.
5. Burns the position through Cetus LP Burn; Cetus records the liquidity as permanently locked.
6. Creates the vault from the terms with `blast_vault::vault::new` (aborts unless the registry
   admits `blast_migrators::cetus::Venue` and the terms' package witness), attaches the `CetusLPBurnProof`
   and Cetus's leftover coins with `blast_vault::vault::share_with_position`, and shares the vault.
   The leftovers are migration residuals, settled by the terms.

#### Migrate to Bluefin (anyone)

Bluefin pools always have Meme as coin A: `Pool<Meme, Quote>`.

1. Split a `Coin<SUI>` worth exactly the SUI pool-creation fee Bluefin currently configures. Bluefin
   aborts on any other amount, and the whole coin is paid.
2. Call the product's `migrate`; it returns the sale's `Migration<Meme, Quote>`.
3. Call `blast_migrators::bluefin::migrate` with type arguments `<Meme, Quote>` and, in order: the
   `Migration` result (by value), the migrators `PackageVersion`, `VenueConfig`, `Currency<Meme>`,
   `Currency<Quote>`, Bluefin `GlobalConfig` (mutable), `VaultRegistry` (mutable), the vault
   `PackageVersion`, `Treasury`, the `Coin<SUI>` fee (by value), and `Clock`.

Inside the call: it redeems the `Migration` as above; reads the coin's tier from `VenueConfig`;
creates `Pool<Meme, Quote>` at the tier, named `MEME-QUOTE` from the two Coin Registry symbols, with
no Meme icon and the Quote's icon; opens a position across the widest tick range Bluefin's
configured bounds allow at that spacing; seeds it with the handed-off balances; creates the vault
with the position and Bluefin's leftovers (residuals, settled by the terms) and shares it; and
shares the pool. The caller receives no object, but Bluefin records the caller as the new pool's
manager, a Bluefin role limited to the pool's reward emissions and to handing the role on.

#### Collect LP fees (anyone)

Anyone may collect, as often as they like. A collection that finds no fees is valid.

- Cetus: `blast_migrators::cetus::collect_fees`, type arguments `<Meme, Quote, CoinA, CoinB>`,
  with the `Vault<Meme, Quote>` (mutable), migrators `PackageVersion`, vault `PackageVersion`,
  `Treasury`, `Currency<Meme>` (mutable), Cetus `GlobalConfig`, LP Burn `BurnManager`, and the
  vault's Cetus `Pool<CoinA, CoinB>` (mutable). It takes no `Clock`.
- Bluefin: `blast_migrators::bluefin::collect_fees`, type arguments `<Meme, Quote>`, with the
  `Vault<Meme, Quote>` (mutable), migrators `PackageVersion`, vault `PackageVersion`, `Treasury`,
  `Currency<Meme>` (mutable), Bluefin `GlobalConfig`, the vault's `Pool<Meme, Quote>` (mutable), and
  `Clock`.

Order of operations:

1. On Cetus, prove the coin pair (`blast_migrators::errors::EWrongCoinPair`). Check the pool is
   the vault's own (`blast_migrators::errors::EPositionPoolMismatch`).
2. Collect fees. Cetus: from the burned position through LP Burn, plus the auto-LP position's fees
   once it exists. Bluefin: from the migration position.
3. Split through `blast_vault::vault::split_fees`: Blast's share of each asset (rounded up) is paid to
   the `Treasury` at once, or held for the partner when the sale named one; the rest is apportioned
   over the vault's fee split. Address routes are paid as coins; the owner, auto-LP, and
   holder-reward routes accrue in the vault; the burn route's Meme is burned and its Quote kept for
   buybacks. A zero collection moves and emits nothing.

Collection never adds liquidity: the auto-LP share waits in the vault for `compound_auto_lp`
below, so a venue refusing an add can never block collecting fees.

#### Compound auto-LP (anyone)

Anyone may compound, as often as they like, in the same PTB as a collection or apart from it. A
call that finds nothing the pool takes is valid and adds nothing.

- Cetus: `blast_migrators::cetus::compound_auto_lp`, type arguments `<Meme, Quote, CoinA, CoinB>`,
  with the `Vault<Meme, Quote>` (mutable), migrators `PackageVersion`, vault `PackageVersion`,
  Cetus `GlobalConfig`, the vault's Cetus `Pool<CoinA, CoinB>` (mutable), and `Clock`.
- Bluefin: `blast_migrators::bluefin::compound_auto_lp`, type arguments `<Meme, Quote>`, with the
  `Vault<Meme, Quote>` (mutable), migrators `PackageVersion`, vault `PackageVersion`, Bluefin
  `GlobalConfig`, the vault's `Pool<Meme, Quote>` (mutable), and `Clock`.

It checks the pool is the vault's own (`blast_migrators::errors::EPositionPoolMismatch`), takes every
waiting auto-LP Meme and Quote (every collection's part plus anything left from earlier calls), adds
what the pool takes at its current price, and keeps the rest in the vault
(`blast_vault_events::AutoLiquidityAdded`).

Auto-LP per venue:

- Cetus burned the migration position, so it cannot take liquidity. The first time both auto-LP
  balances are nonzero, the vault opens a second full-range position in the same pool (emitting
  `blast_vault_events::AutoLpPositionOpened`) and keeps it with no removal path. Each add fixes all
  of coin A if Cetus's liquidity math says the coin B balance covers it, else all of coin B if the
  coin A balance covers that, else adds nothing.
- Bluefin adds to the migration position. The venue picks the fixed side from the pool price and the
  position's bound prices, keeping a 2-atom margin on the other side (see Economics).
- Both add nothing while either side is empty, so a one-sided auto-LP balance waits until the other
  asset arrives.

#### Settle and apply a new fee split (anyone)

The owner proposes a split on the vault with an owner proof from the sale's product (for a launch,
`launch::prove_owner`), then `blast_vault::vault::schedule_fee_split` (product and vault guides). It
is ready after a fixed 48-hour notice. Once ready, anyone calls
`blast_migrators::cetus::settle_and_apply_fee_split` (`<Meme, Quote, CoinA, CoinB>`) or
`blast_migrators::bluefin::settle_and_apply_fee_split` (`<Meme, Quote>`) with the same arguments
as `collect_fees`, plus the `Clock` on Cetus. It checks the proposal is ready
(`blast_vault::vault::assert_fee_split_ready`), collects and splits every position's fees under the
current split, and then applies the new split (`blast_vault::vault::apply_fee_split`), so each fee
follows the split it accrued under. The call takes no split of its own: it applies only the stored
proposal.

#### Buyback and burn (Blast admin: `blast_core::blast_domain::BuybackAdmin`)

A `BuybackAdmin` calls `blast_migrators::cetus::buyback_and_burn` (`<Meme, Quote, CoinA, CoinB>`)
or `blast_migrators::bluefin::buyback_and_burn` (`<Meme, Quote>`) with the vault, the migrators
`PackageVersion`, the vault `PackageVersion`, the `AdminWitness` for `BuybackAdmin`,
`Currency<Meme>`, the venue's `GlobalConfig`, the vault's pool, `quote_in` (atomic Quote),
`min_meme_out` (atomic Meme), and `Clock`. It checks the pool is the vault's
(`blast_migrators::errors::EPositionPoolMismatch`), takes exactly `quote_in` of the vault's burn
Quote, swaps it for Meme in the vault's pool up to the widest price limit, burns the Meme bought (or
sends it to `@0x0` when the supply is fixed), keeps any Quote the pool did not take for the next
buyback, and emits `blast_vault_events::BuybackBurned`. The admin sets `min_meme_out` from an
off-chain price, because anyone can move the pool price inside a transaction.

#### Package upgrades (Blast admin: `UpgradeAdmin<BLAST_MIGRATORS>`)

The package uses Blast's generic package administration, typed by
`blast_migrators::blast_migrators::BLAST_MIGRATORS`. `blast_admin::package_admin::schedule_upgrade`
announces an exact 32-byte digest. After the notice, `blast_admin::package_admin::authorize_upgrade`
returns its upgrade ticket, and `blast_admin::package_admin::commit_upgrade_and_advance` commits the
receipt and moves `PackageVersion<BLAST_MIGRATORS>` to the next version in the same transaction.
From then on every call to the old package's code aborts the version check, so integrators must
call the current package address; type names keep the original address. Upgrading this package
leaves the products and the vault on their own versions; an upgrade of the vault requires a
relink of this package. `blast_admin::package_admin::schedule_make_immutable` schedules the end of upgrades, which
`blast_admin::package_admin::make_immutable` executes only from this package's own code (a later
upgrade must add that wrapper);
`blast_admin::package_admin::schedule_upgrade_delay` changes the notice. The package defines no
pause bits: migration stops with the product's migration pause bit, and buybacks with the vault's
admin pause bit.

### Economics

All amounts are atomic units. BPS are out of 10,000.

#### Migration seed and residuals

The opening sqrt price is `blast_core::migration::sqrt_price_x64`,
`floor(sqrt(coin_b / coin_a) × 2^64)` from the handed-off atomic amounts: Quote/Meme when Meme is
coin A, Meme/Quote otherwise. Display decimals never enter it. The seed fixes
the side with more atoms (Meme on a tie), unless the venue's math says that would overdraw the other
side by rounding, in which case it fixes the other side. Whatever the venue does not take is the
migration residual, settled by the sale's terms: residuals to Blast are paid to the `Treasury` at
once, or held for the partner when the sale named one; residuals to the owner wait in the vault.
Position principal plus residuals equals the hand-off.

#### Blast's LP-fee share and the split

Each collection takes Blast's share of each asset, `ceil(gross × bps / 10,000)`, with the vault's
per-asset share. A sale's vault starts with the share its product sealed into the `Migration`
(for a launch, the `LaunchConfig.protocol_lp_fees` value applied at migration), at most 3,000 BPS; Blast can change one vault's share only after a
fixed 48-hour notice. The rest of each asset is apportioned over the fee split's routes by largest
remainder, so the routes always sum to what is left. This is separate from Blast's one-time
fees a product takes at migration. The vault guide has the details,
including partner payouts.

#### Auto-LP math

Auto-LP never swaps. It fixes all of one side and pays what the venue asks of the other at the
current price; the rest of the other side waits. Bluefin's side choice, with `P`, `L`, `U` the
current, lower, and upper sqrt prices (Q64.64), `a` the Meme balance, `b` the Quote balance, and a
2-atom margin: fix Meme when `liquidity = a × (P × U / 2^64) / (U − P)` is positive and below 2^128
and `ceil(liquidity × (P − L) / 2^64) + 2 ≤ b`; otherwise fix Quote when
`liquidity = b × 2^64 / (P − L)` is positive and `ceil(liquidity × 2^64 / P) − floor(liquidity ×
2^64 / U) + 2 ≤ a`; otherwise wait. A price at or outside the range adds nothing. Cetus uses Cetus's
own liquidity math with no margin.

#### Buybacks

A buyback spends exactly `quote_in` of the burn Quote; Quote the pool does not take returns to the
burn Quote. Every Meme bought is burned, or sent to `@0x0` under a fixed supply.

### Time rules

- Preparation happens only in the sale's creation PTB; the tier never changes afterwards.
- The venue adds no migration deadline: the product decides when its `migrate` may return a
  `Migration`, and its migration pause bit stops it.
- A proposed fee split waits a fixed 48 hours; once ready it stays ready until someone settles and
  applies it, or the owner cancels it. Until then collections use the current split.
- Collections have no deadline or cooldown.

### Reading state

- Which venue a sale uses: the sale's stored venue, the type name of
  `blast_migrators::cetus::Venue` or `blast_migrators::bluefin::Venue`.
- A Cetus coin's tier: the `u32` tick spacing in the `VenueConfig` dynamic field keyed by
  `blast_migrators::cetus::PoolTierKey` (typed by the Meme); its `PoolCreationCap` is the dynamic
  object field keyed by `blast_migrators::cetus::CreationCapKey`, whose ID matches
  `CetusPoolReserved`.
- A Bluefin coin's tier: the `blast_migrators::bluefin::PoolTier` (`tick_spacing`, `fee_rate`)
  in the `VenueConfig` dynamic field keyed by `blast_migrators::bluefin::PoolTierKey`.
- A vault's pool: `blast_vault::vault::pool_id`, or the `pool_id` in its `VaultCreated` event. The
  vault's type arguments name the Meme and Quote; the `VaultCreated` event's third type argument
  names the venue.
- The positions: dynamic object fields of the vault keyed by `blast_vault::vault::PositionKey` (the
  Cetus `CetusLPBurnProof` or the Bluefin `Position`) and, on Cetus, `blast_vault::vault::AutoLpPositionKey`
  (the auto-LP `Position`), each typed by the venue witness.
- Pending LP fees: dev-inspect `collect_fees` against the live vault and pool.

### Events

| Event | Emitted by | What to derive |
| --- | --- | --- |
| `blast_migrators::events::CetusPoolReserved` | `blast_migrators::cetus::prepare` | type arguments `<Meme, Quote>`, `pool_creation_cap_id`, `tick_spacing`: the Cetus pair is reserved |
| `blast_migrators::events::BluefinPoolTierRecorded` | `blast_migrators::bluefin::prepare` | type arguments `<Meme, Quote>`, `tick_spacing`, `fee_rate`: the Bluefin tier |
| the product's migration events | the product's `migrate`, earlier in the same PTB | recipients paid, Blast's one-time fees, pool amounts (product guides) |
| `blast_vault_events::VaultCreated` | `migrate` | `vault_id`, `pool_id`, `position_id`, `liquidity`, the sealed `terms`, residual amounts; type arguments `<Meme, Quote, Venue>` |
| `blast_vault_events::FeesCollected` | `collect_fees`, `settle_and_apply_fee_split` | gross amounts, Blast's cut, each route's amounts in route order |
| `blast_vault_events::AutoLpPositionOpened`, `blast_vault_events::AutoLiquidityAdded` | `compound_auto_lp` | Cetus's auto-LP position; liquidity added and what still waits |
| `blast_vault_events::BuybackBurned` | `buyback_and_burn` | `quote_spent`, `meme_burned`, burn Quote still waiting |
| `blast_core::blast_core_events::ProtocolFeesPaid` | migration and collections on a vault without a partner | Blast's residuals and LP-fee cut paid to the treasury |
| `delayed::DelayedApplied` | `settle_and_apply_fee_split` | keyed by `blast_vault::vault::FeeSplitKey` with the vault ID as `owner`: the previous and new split |

The migrators, vault, and core events are plain Sui events (not wrapped in an envelope), typed by
the pair's `Meme` and `Quote`. Cetus and Bluefin emit their own pool, position, and swap events in
the same transactions.

### Aborts

| Flow | Abort | Fix |
| --- | --- | --- |
| any | code 9 in `blast_admin::package_version` | call the current package ID of the migrators, product, or vault package |
| Cetus prepare | Cetus aborts in its own modules | choose a tick spacing Cetus registers, for a pair it accepts |
| Bluefin prepare | 3 `blast_migrators::errors::EInvalidTier`, then 4 `blast_migrators::errors::ESymbolTooLong` | tick spacing 1..=400, fee rate 1..=20,000; a Meme symbol of at most 32 bytes |
| Cetus migrate, collect, buyback | 0 `blast_migrators::errors::EInvalidCoinOrder` (migrate), 2 `blast_migrators::errors::EWrongCoinPair` | pass the pool's coin order; `CoinA` and `CoinB` must be the sale's Meme and Quote |
| migrate | `sui::dynamic_field` code 1 reading the tier; 8 `blast_core::errors::EWrongVenue` in `blast_core::migration` | call the migrate of the venue the sale stores, with that sale's `Migration` |
| migrate | the product's own lifecycle or pause abort in its `migrate` (product guides) | wait until the sale is ready to migrate and its migration is unpaused |
| migrate | 1 `blast_vault::errors::EUnadmittedVenue`, 33 `blast_vault::errors::EUnadmittedPackageWitness`, 4 `blast_vault::errors::EZeroLiquidity` (vault) | the venue and the product's package witness must be listed in `VaultRegistry`; the seed must give positive liquidity |
| migrate | Cetus aborts when the pair's pool already exists or the tick spacing is no longer registered; Bluefin aborts on a wrong creation fee | the sale stays ready to migrate; pass the exact Bluefin fee |
| collect, settle, buyback | 1 `blast_migrators::errors::EPositionPoolMismatch` in the venue's module | pass the vault's own pool |
| settle and apply | 14 `ENoPending` or 13 `ENotReady` from Blast admin's `delayed` module | wait until the scheduled split is ready |
| buyback | 7 `blast_vault::errors::EBuybackQuoteOutOfRange`, 8 `blast_vault::errors::EBuybackBelowMinimum`; Blast admin `EPaused` when the vault's admin bit is set | spend a positive amount up to the burn Quote; re-quote `min_meme_out` |

### Pitfalls

- Calling `prepare` outside the creation PTB. The `VenueTicket` cannot be stored, so prepare and the
  product's creation calls (for a launch, `launch::new`, `launch::finalize`, and `launch::share`)
  share one PTB.
- Passing the `TreasuryCap` by value to `prepare`. Cetus takes it by mutable reference and Bluefin
  by immutable reference; the product's `new` takes it by value afterwards.
- Choosing a Cetus tick spacing Cetus does not register, a Bluefin tier outside its bounds, or a
  Meme symbol longer than 32 bytes on Bluefin: creation aborts, and the tier can never change after
  creation.
- Passing Cetus coin types in Meme/Quote order instead of the pool's order.
- Calling the product's `migrate` without the venue's `migrate` in the same PTB. Its `Migration`
  cannot be dropped, so the transaction aborts; pass it to the stored venue's `migrate`.
- Forgetting the Bluefin pool-creation fee coin, or passing a different amount.
- Expecting the burned Cetus position to grow: auto-LP goes to the second position.
- Expecting a ready fee split to apply by itself. Someone must call `settle_and_apply_fee_split`.
- Calling an old package ID after an upgrade.

### Q&A

**Which venue does a sale migrate to?** The one whose `prepare` produced the ticket the sale
redeemed; the sale stores that venue's witness type. Only that venue's `migrate` can redeem its
`Migration`.

**What is the PTB to start a launch on Cetus?** `blast_migrators::cetus::prepare` with the
`TreasuryCap` by mutable reference (returns the `VenueTicket`), `launch::new` with the ticket and
the `TreasuryCap` by value, the launch setters, `launch::finalize`, and `launch::share`, in that
order.

**What is the PTB to migrate?** Two calls: the product's `migrate` (for a launch, `launch::migrate`),
then the venue's `migrate` with the returned `Migration` as its first argument. They succeed or abort
together.

**Can anyone withdraw the migrated liquidity?** No. The vault holds the position under the venue's
key with no removal path, and the Cetus migration position is also burned through Cetus LP Burn.

**Who can migrate a sale?** Anyone, once the product's `migrate` accepts it. The PTB that completes
the sale can migrate in the same transaction.

**Why do Cetus calls take `CoinA` and `CoinB`?** Cetus orders a pool's coins by type name, so the
pool's types may be `Pool<Quote, Meme>`. The venue proves the pair matches the sale and retypes
balances between the two orders.

**Who receives the migration residuals?** Whoever the sale's terms name: Blast, paid to the
`Treasury` or held for the partner payout, or the owner, held in the vault.

**How often should LP fees be collected?** As often as useful; collection is permissionless and
cheap to retry. Compound as often, with `compound_auto_lp`; frequent compounding keeps the auto-LP
price-move exposure small.

**How does the creator change the LP-fee split?** With an owner proof from the product (for a
launch, the curve-fee cap and `launch::prove_owner`), call `blast_vault::vault::schedule_fee_split`
in one PTB. After 48 hours anyone applies it with the venue's `settle_and_apply_fee_split`, which
first settles fees under the old split.

**Does pausing a product stop collections?** No. A product's migration pause stops new migrations
only; fee collection never pauses, and buybacks stop only with the vault's admin pause.

**Why might a Cetus migration fail?** Cetus no longer registers the tick spacing, Cetus's
pool-manager role created the pair's pool first, the vault registry does not admit the venue or the
product's witness, or the product's migration is paused. The sale stays ready to migrate in every
case.
