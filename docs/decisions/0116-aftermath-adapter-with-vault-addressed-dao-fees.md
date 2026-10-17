# 0116: Aftermath adapter with vault-addressed DAO fees

- Status: proposed
- Date: 2026-10-17
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md), whose
  release matrix was Cetus and Bluefin only, and
  [0099](0099-standalone-overflow-presale.md), whose presale adapters were Cetus
  and Bluefin only
- Reuses: [0066](0066-aftermath-dao-fee-pool.md), the historical DAO-fee design
  whose adapter [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
  removed, and [0104](0104-external-presale-migrators-and-vendor-packages.md),
  whose vendor package fixes the pool terms

## Sources

| Ref | Where | What |
| --- | --- | --- |
| `evidence@2026-09-05` | `docs/research/sui-auto-lp-venue-evidence.json` | Normalized ABI and `sui move disassemble` output of the mainnet DAO-fee package `0x5ad68909…` (revision 2) and AMM package `0xf948935b…` (revision 3), read from the official GraphQL endpoint |
| `evidence@2026-10-17` | `docs/research/sui-auto-lp-venue-evidence.json`, `supplements[0]` | The same DAO-fee `pool` module (hash `029b3e6e…`): disassembly of `new`, `assert_fee_is_at_most_one_hundred_percent`, `update_fee_bps`, and `update_fee_recipient`; the `withdraw` and `swap` modules' fee collection on each Meme or Quote coin, never on the LP coin |
| `deposit@2026-10-17` | `docs/research/sui-auto-lp-venue-evidence.json`, `supplements[1]` | The AMM `deposit` module (hash `a9b023fe…`): disassembly of `deposit_2_coins_direct`, which rejects a zero coin, takes Aftermath's protocol fee through `protocol_fees::collect_fees_2_coins`, computes the LP out with `math::calc_deposit_exact_in_direct`, aborts with code 24 below `min_lp`, joins both remaining coins whole, and mints the LP; the protocol-fee vault `vault` module (hash `ba9bcf56…`): `total_protocol_fee` reads `fee_percentages.total_protocol_fee`, and `collect_fees` splits `mul_by_fraction(amount, total_protocol_fee)` of a coin among the treasury, insurance fund, and dev wallet by the vault's percentages (50%, 30%, 20% at observation), less a referee discount; the AMM `pool` module's constants, with the 1,000-unit minimum LP supply and the fee bounds |
| `amm-source@9431920` | `AftermathFinance/move-amm-public` at commit `9431920`, `packages/amm/sources/pool.move` and `pool_registry.move` | `MIN_FEE` 0.01%, `MAX_FEE` 10% on `fee_swap_in`; `fee_swap_out`, `fee_deposit`, and `fee_withdraw` asserted zero (`EInvalidFee` 4); `register_pool` hashes the sorted coin types, weights, flatness, and the four fee vectors, not the pool name or LP type, and aborts with `EDuplicatePool` (61) on a registered hash |
| `vendor-gate@2026-09-02` | `sui/vendors/aftermath_dao_presale/scripts/check_mainnet_abi.mjs` | Package lineage, module hashes, and the normalized signatures of `pool_factory::create_pool_2_coins_v2`, `pool::balance_of`, `dao_fee_amm::pool::new`, `fee_bps`, and `fee_recipient` |
| `sui@06734f6` | `crates/sui-framework/packages/sui-framework/sources/transfer.move` | `public_receive<T: key + store>(&mut UID, Receiving<T>): T` |

## Context

The `blast_aftermath_dao_presale` vendor package (ADR 0104) migrates a partner's
sales into a 50/50 Aftermath weighted pool wrapped in Aftermath's DAO-fee pool,
with the 2% DAO fee paid to a compiled treasury and the LP coin sent to `0x0`.
Blast wants the same venue for its own presales and launches, charging Blast's
LP-fee share and splitting the rest like every other venue. Two facts shape the
design:

- Aftermath pays the DAO fee as coins. The reviewed revision-2 bytecode of
  `dao_fee_amm::pool::collect_dao_fee` computes
  `floor(amount × fee_bps / 10_000)`, splits that from the offered coin, and calls
  `transfer::public_transfer` to the pool's `fee_recipient`
  (`evidence@2026-09-05`, `bytecode_excerpts["aftermath_dao_fee-pool::collect_dao_fee"]`).
  A zero fee sends nothing. Nothing is credited to a position the vault could
  collect from.
- The fee recipient is fixed when the DAO-fee pool is created
  (`dao_fee_amm::pool::new(Pool<Lp>, &Version, u16, address, &mut TxContext)`),
  and only the returned `OwnerCap` can change it afterwards (ADR 0066's
  AFTERMATH-DAO-CAPABILITY premise). `new` accepts any `fee_bps` of at most
  10,000 and aborts with code 0 above it (`evidence@2026-10-17`,
  `assert_fee_is_at_most_one_hundred_percent`); it has no lower bound.
  `update_fee_bps` and `update_fee_recipient` check only the package version:
  neither bounds the new fee nor compares the `OwnerCap` to the pool it
  mutates. One `Pool<Lp>` exists per LP coin and `new` consumes it, so one
  `OwnerCap<Lp>` exists per pool, and sealing it is what fixes the fee and the
  recipient.
- The base pool's own fees are Aftermath's, not the creator's: `fee_swap_in`
  must be in [0.01%, 10%] and the swap-out, deposit, and withdraw fees must be
  zero (`amm-source@9431920`), so the adapters pass the minimum swap-in fee and
  zeros, as the vendor does.
- Aftermath's registry rejects a second pool with the same coins, weights,
  flatness, and fees (`amm-source@9431920`). Launch buyers hold Meme while the
  curve is live, so a pool created only at migration could be created first by
  anyone, for dust, and every later `migrate` would abort: the launch would
  stay `MigrationReady` with its Quote locked, which ADR 0088 forbids an
  adapter to allow. No sale token circulates before a presale migrates, so the
  presale is not exposed and creates its pool at migration.
- Aftermath's exact-in deposit (`deposit@2026-10-17`) joins both coins whole
  at whatever ratio the pool prices them, after taking Aftermath's protocol
  fee from each, at most `amount × total_protocol_fee / 1e18`, and asks only
  that the LP minted reach the caller's minimum. An unshared pool's price
  cannot move between its creation and that deposit.

## Decision

**One adapter module per package.** `blast_presale::aftermath` and
`blast_fun_migrators::aftermath` map the vendor's flow onto the presale's
`Vault` and the launchpad's `LpVault`:

- `new` takes the DAO fee the pool charges, `dao_fee_bps` in 1..=10,000
  (`EInvalidDaoFee`): the creator's tier, as Cetus and Bluefin tiers are. The
  launchpad records it as `(0, dao_fee_bps)`, no tick spacing; the presale
  records it in `VenueConfig` under the sale token's type, as ADR 0111 does for
  the other venues. The other pool terms are compiled: 50/50 weights, flatness
  zero, Aftermath's minimum 0.01% base swap-in fee.
- `finalize` takes the `CreatePoolCapV2` of a fresh LP coin `Lp` the creator
  published, aborts unless this module's `new` started the initializer
  (`EWrongMigrator`, read through the core's `migration_witness` getter), and
  finalizes the sale or launch through the core. The presale's returns, with
  the new sale, a key-only `PoolCreation<Lp, Meme, Quote>` holding the
  capability and the sale's ID. The launchpad's returns, with the new launch,
  a `PendingPool<Lp, Meme, Quote>` hot potato holding the capability and the
  launch's ID, and rejects a fee split with an auto-LP or burn part
  (`EUnsupportedFeeSplit`), since neither has a route out of an Aftermath
  vault. The new object's ID exists only then, and binding by ID, not by type,
  is what keeps one reservation from ever serving another pool.
- **Pre-created launch pool.** The launchpad's `create_pool` consumes the
  pending pool in the creation PTB: it creates the pool with the fixed terms
  in Aftermath's coin order from a seed the creator buys from the still-owned
  launch with `launch::buy` and some Quote, sends the seed's LP coin to `0x0`,
  announces the reservation, and returns the key-only
  `PoolCreation<Lp, Meme, Quote>` holding the unshared pool, bound to the
  launch's ID. The pool's registry slot is taken before any buyer holds Meme,
  so nobody can register it first; the pool is unshared, so nothing can trade
  on it or move its price before the migration, and a dust seed leaves the
  opening price where the curve ends. The pending pool has no abilities, so a
  PTB that finalizes here cannot end without creating the pool, and a
  capability of another coin, or an LP coin with other than 9 decimals, fails
  that PTB inside Aftermath instead of stranding a launch. Because the seed
  buy needs the launch `Live` before `launch::share`, an Aftermath launch
  cannot set an opening round; the launchpad is unchanged, so the creation PTB
  fails at the buy rather than at a dedicated check. The reservation is
  returned unshared so the creating PTB can fill the curve and migrate in the
  same transaction; `share` shares it for a later migration, and nothing else
  can share, store, or drop it. A creator who finalizes through the core
  instead has no reservation: the launch can never migrate.
- The presale creates its pool at migration from the hand-off, as before: no
  sale token circulates earlier, so no pool can be registered first, and a
  capability of another coin, or an LP coin with other than 9 decimals, makes
  every migration abort inside Aftermath, so the sale refunds at its
  liquidity deadline and the UI must verify the capability before listing.
- `migrate` checks the package generation (launchpad), then that the
  reservation names this sale or launch (`EWrongPresale`, `EWrongLaunch`),
  consumes it, reads the fee back, and takes the hand-off. The presale
  creates the pool in Aftermath's coin order from exactly those balances and
  checks the pool holds every unit (`EPoolMismatch`). The launchpad deposits
  them into the reserved pool through `deposit_2_coins_direct` in Aftermath's
  coin order with a zero minimum, passing Aftermath's `ProtocolFeeVault`,
  `Treasury`, `InsuranceFund`, and `ReferralVault`, and checks each balance
  grew by at least the hand-off less Aftermath's protocol fee at the vault's
  reported total rate, rounded up (`EPoolMismatch`): the bound is exact when
  Aftermath takes its fee and tight otherwise, and it fails only if Aftermath
  takes more than it reports. Both then build the vault with no position yet,
  create the DAO-fee pool with the vault's ID as the recipient at that fee and
  check both values back (`EDaoFeePoolMismatch`), share the vault with the
  returned `OwnerCap` as its position and the minted LP coin's amount as its
  liquidity, share the DAO-fee pool as the object traders use, and send the
  `Coin<Lp>` to `0x0`. The vault's `pool_id` is the base pool;
  `DaoFeePoolCreated` (presale) and `AftermathPoolCreated` (migrators) record
  the DAO-fee pool, owner cap, and LP coin IDs, and `VaultCreated.liquidity`
  is the LP amount the vault does not hold.
- `collect_fees` takes `vector<Receiving<Coin<Meme>>>` and
  `vector<Receiving<Coin<Quote>>>`, aborts unless the vault's position sits
  under `aftermath::Venue` (`EWrongVault`, through the vaults' new package-only
  `has_position`), receives each listed coin through the vault's UID with the
  new package-only `receive_fee`, joins them, and hands the totals to the
  vault's existing split. A coin the vault does not own aborts in the
  framework. Without the venue check, the launchpad route would commit a split
  change on a Cetus or Bluefin vault without settling that position's accrued
  fees.
- **No split update on Aftermath.** The vault promises that a split changes
  only after the fees accrued under it are settled. Aftermath's fees are coins
  the package cannot enumerate, so no call can settle every accrued fee before
  a change: the launchpad adapter has no `settle_and_update_fee_split`, and an
  Aftermath vault's split is the one its launch was finalized with. With no
  auto-LP or burn part admitted, nothing accumulates in the vault without a
  route out.

**Vault seams.** Both vaults split creation into two package-only steps: `new`
builds the unshared vault with its pool binding and no position, and
`share_with_position` attaches the position once under the venue's sealed key,
emits `VaultCreated`, and shares the vault in one consuming call. The DAO-fee
pool must name the vault's address before the owner cap, its position, exists,
and Sui's fresh-ID rule forbids building an object around a `UID` minted
elsewhere, so the vault is born first and takes its position as it is shared.
`create` runs both for Cetus and Bluefin. The vault has only `key`, so an
adapter holding an unfinished vault can do nothing but share it with a
position. `has_position` tells an adapter the vault is its own, and
`receive_fee` is the vault's only receipt. The migrators source gate pins every
seam and that only `aftermath` takes the unshared path.

**Custody.** The LP coin, the pool's whole liquidity, goes to `0x0` as the
vendor's does: unrecoverable by any code, this package's upgrades included. The
owner cap is the vault's position under the ordinary sealed `PositionKey<Venue>`,
so no one can reprice or redirect the pool; the package exposes no function
that uses it, and `VaultCreated.position_id` names it.

**Not in scope.** After migration the migrators adapter adds no liquidity to and
swaps nothing in an Aftermath pool, so an Aftermath launch admits no auto-LP and
no burn part in its split. The migration deposit pins the AMM `deposit` module
and the four fee packages it takes (`ProtocolFeeVault`, `Treasury`,
`InsuranceFund`, `ReferralVault`) as link stubs, calling only
`total_protocol_fee` on them. The package stays upgradeable, so a later
generation can add the routes and a two-step split update. The presale has
neither share.

**Explorer naming.** `aftermath::PoolCreation`, and in the presale its two
events, read on explorers as Aftermath types, as the venue modules' `Venue` and
`Witness` types already do; ADR 0085's naming table records them as accepted
residuals of the per-venue module layout. `PendingPool` never exists on chain.

## Alternatives considered

- **Keep the vendor's treasury recipient and have Blast claim from it.** Rejected:
  it bypasses the vault split and Blast's LP-fee policy, which is the point of
  charging a fee like every other venue.
- **Create the DAO-fee pool first and update the recipient to the vault.**
  Rejected: it needs `update_fee_recipient`, an extra pinned ABI entry, and a
  window in which the pool pays someone else.
- **Keep the LP coin as the vault's position.** Rejected (owner, 2026-10-17):
  a position the vault seals is locked only as long as the package's code keeps
  it so; a coin at `0x0` is locked by the framework.
- **Attach the owner cap under a separate `PoolAuthorityKey`.** Rejected: with
  the LP coin gone the owner cap is the vault's only venue object, and the
  existing position key already seals it with no borrow or removal path.
- **Reserve the pool's registry slot as Cetus reserves a pair.** Not possible:
  Aftermath has no permissioned pair registration, and its pool creation needs
  liquidity. Creating the whole pool from a seed at creation, and keeping it
  unshared until migration, is the equivalent.
- **Salt each coin's swap-in fee with the transaction digest** so the registry
  hash differs per migration and nobody can register the pool ahead of it.
  Rejected (owner, 2026-10-17) for the pre-created pool: a front-run
  migration still failed once, every launch pool carried a different fee, and
  a creator's wrong capability still stranded a launch. The pre-created pool
  fails the creation PTB instead, and every launch pool has the same terms.
- **Change the launchpad** to expose the lifecycle or an opening-round getter,
  or to reserve the seed for the adapter. Rejected (owner, 2026-10-17): the
  launchpad is unchanged; the creation PTB's own failure at the seed buy is
  the opening-round check.
- **A liveness exit for a launch that cannot migrate.** Deferred: with the
  pool created in the creation PTB, no Aftermath launch can be stranded by a
  wrong capability or a registered pool; a refund path would be a launchpad
  change.
- **Keep `settle_and_update_fee_split` on Aftermath with caller-listed coins.**
  Rejected: the cap holder could commit a new split while listing none of the
  coins already at the vault's address, so fees would not follow the split they
  accrued under.
- **Return the capability from `new` in a hot potato.** Rejected (owner,
  2026-10-17): `finalize` already needs the initializer, which only the launch's
  or sale's creator holds, so the capability goes straight to `finalize` and
  the `EWrongMigrator` check replaces the potato's forcing.
- **Bind the reservation by type only.** Rejected (owner, 2026-10-17): the
  treasury cap and the launch ticket are unique per Meme, so a type binding is
  sound, but a reservation must name the exact sale or launch it serves.
- **The vendor's compiled 2% DAO fee.** Rejected (owner, 2026-10-17): the fee is
  the creator's tier, like a Cetus tick spacing or a Bluefin fee rate, within
  Aftermath's own range, which `new` enforces at most 10,000; the adapters add
  only the lower bound of one, since a zero fee pays the vault nothing.

## Consequences

- Six more pinned mainnet lineages (Aftermath AMM revision 3, DAO-fee revision
  2, Protocol Fee Vault revision 2, Treasury, Insurance Fund, and Referral
  Vault revision 1) in the migrators' dependency gate and lock; the presale
  reuses the first two.
- The presale gains a third adapter under the same `CreationPolicy` admission;
  the launchpad's `LaunchConfig` admits `aftermath::Witness` like the others.
- An Aftermath launch's split is fixed at finalization and has no auto-LP or
  burn part; its creator can still claim creator fees and fund holder rounds.
- A creator can finalize, create the pool, fill the curve, and migrate in one
  PTB, since the reservation and the launch are both still owned then; every
  Aftermath launch costs its creator a seed buy and some Quote, locked in the
  pool, and cannot set an opening round.
- Indexers find an Aftermath vault's pending fees as the coins its address owns,
  not as a position's accrued fees; `AftermathPoolReserved` and
  `PoolCreationReserved` link the LP coin to the pair, and the launch's
  `AftermathPoolReserved` names the pool before the launch is shared.
- The migrators source gate now allows exactly one receiving path.

## Verification

- Move tests in both packages: `new` records the witness and the fee tier,
  accepts both bounds and rejects beyond them, and needs the policy's
  admission; `finalize` returns one reservation bound to the new sale or
  launch (the presale announces it), rejects another adapter's initializer,
  and (launchpad) rejects a split with an auto-LP or burn part; the launchpad's
  `create_pool` reaches Aftermath's factory with the seed and its protocol-fee
  ceiling rounds up; `share` shares the reservation; `migrate` rejects another
  sale's or launch's reservation before touching anything; an owner cap is a
  vault position sealed under its venue and
  invisible to another; a vault built before its position announces nothing
  until it is shared with one, and cannot be shared with an empty one;
  collection rejects another venue's vault, receives the vault's own coins and
  splits them exactly, an empty collection moves nothing, a coin owned by
  someone else aborts in `sui::transfer`, and a stale migrators generation
  aborts first.
- `sui/migrators/scripts/check_source_boundaries.sh` pins the module, its
  bodies, errors, and parameter order, that the pending pool has no abilities,
  the vault seams, the single receiving path, and that the two LP coins are
  the package's only transfers to `0x0`; `python3 scripts/check_move_style.py`
  holds.
- Release: `node scripts/check_mainnet_abi.mjs` in `sui/migrators` (all six
  Aftermath lineages, hashes, and ABI; passed against mainnet on 2026-10-17)
  and the Aftermath rows of the dev-inspect matrix in
  `sui/migrators/DEPENDENCIES.md`, including the live protocol-fee take,
  before either package is published. The local stubs prove types, not
  behavior.
