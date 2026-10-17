# 0116: Aftermath adapter with vault-addressed DAO fees

- Status: accepted
- Date: 2026-10-17
- Amends: [0099](0099-standalone-overflow-presale.md), whose presale adapters
  were Cetus and Bluefin only
- Reuses: [0066](0066-aftermath-dao-fee-pool.md), the historical DAO-fee design
  whose adapter [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
  removed, and [0104](0104-external-presale-migrators-and-vendor-packages.md),
  whose vendor package fixes the pool terms

## Sources

| Ref | Where | What |
| --- | --- | --- |
| `evidence@2026-09-05` | `docs/research/sui-auto-lp-venue-evidence.json` | Normalized ABI and `sui move disassemble` output of the mainnet DAO-fee package `0x5ad68909…` (revision 2) and AMM package `0xf948935b…` (revision 3), read from the official GraphQL endpoint |
| `evidence@2026-10-17` | `docs/research/sui-auto-lp-venue-evidence.json`, `supplements[0]` | The same DAO-fee `pool` module (hash `029b3e6e…`): disassembly of `new`, `assert_fee_is_at_most_one_hundred_percent`, `update_fee_bps`, and `update_fee_recipient`; the `withdraw` and `swap` modules' fee collection on each Meme or Quote coin, never on the LP coin |
| `deposit@2026-10-17` | `docs/research/sui-auto-lp-venue-evidence.json`, `supplements[1]` | The AMM `deposit` module (hash `a9b023fe…`) and the protocol-fee vault's `vault` module (hash `ba9bcf56…`): disassembly of `deposit_2_coins_direct`, `total_protocol_fee`, and `collect_fees`, read for the withdrawn launchpad design |
| `deposit-sim@2026-10-17` | `docs/research/sui-auto-lp-venue-evidence.json`, `supplements[2]` | Read-only simulations of the AMM's exact-in deposit math for the withdrawn launchpad design: a deposit succeeds only when the two coins' balance growth ratios are within 100× of each other and the pool holds more than a few atomic units of each coin |
| `amm-source@9431920` | `AftermathFinance/move-amm-public` at commit `9431920`, `packages/amm/sources/pool.move` and `pool_registry.move` | `MIN_FEE` 0.01%, `MAX_FEE` 10% on `fee_swap_in`; `fee_swap_out`, `fee_deposit`, and `fee_withdraw` asserted zero (`EInvalidFee` 4); `register_pool` hashes the sorted coin types, weights, flatness, and the four fee vectors, not the pool name or LP type, and aborts with `EDuplicatePool` (61) on a registered hash |
| `vendor-gate@2026-09-02` | `sui/vendors/aftermath_dao_presale/scripts/check_mainnet_abi.mjs` | Package lineage, module hashes, and the normalized signatures of `pool_factory::create_pool_2_coins_v2`, `pool::balance_of`, `dao_fee_amm::pool::new`, `fee_bps`, and `fee_recipient` |
| `sui@06734f6` | `crates/sui-framework/packages/sui-framework/sources/transfer.move` | `public_receive<T: key + store>(&mut UID, Receiving<T>): T` |

## Context

The `blast_aftermath_dao_presale` vendor package (ADR 0104) migrates a partner's
sales into a 50/50 Aftermath weighted pool wrapped in Aftermath's DAO-fee pool,
with the 2% DAO fee paid to a compiled treasury and the LP coin sent to `0x0`.
Blast wants the same venue for its own presales, charging Blast's LP-fee share
and splitting the rest like every other venue. Three facts shape the design:

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
  zero (`amm-source@9431920`), so the adapter passes the minimum swap-in fee and
  zeros, as the vendor does.
- Aftermath's registry rejects a second pool with the same coins, weights,
  flatness, and fees (`amm-source@9431920`), and the hash ignores the LP coin
  and the pool name, so a `CreatePoolCapV2` reserves nothing: anyone holding
  both coins can register a pool with the adapter's terms. No sale token
  circulates before a presale migrates, so nobody can register a sale's pool
  first. A bonding-curve launch is different: buyers hold Meme while the curve
  is live, so a launch pool created only at migration could be registered
  first and the launch stranded, and a pool created at launch creation needs a
  seed of Meme that the launchpad does not mint for the creator; the launchpad
  therefore has no Aftermath adapter (see Alternatives).

## Decision

**One adapter module, `blast_presale::aftermath`,** maps the vendor's flow onto
the presale's `Vault`:

- `new` takes the DAO fee the pool charges, `dao_fee_bps` in 1..=10,000
  (`EInvalidDaoFee`): the creator's tier, as Cetus and Bluefin tiers are. It is
  recorded in `VenueConfig` under the sale token's type with tick spacing 0, as
  ADR 0111 does for the other venues. The other pool terms are compiled: 50/50
  weights, flatness zero, Aftermath's minimum 0.01% swap-in fee.
- `finalize` takes the `CreatePoolCapV2` of a fresh LP coin `Lp` the creator
  published, aborts unless this module's `new` started the initializer
  (`EWrongMigrator`, read through the core's `migration_witness` getter),
  finalizes the sale through the core, and returns, with the new sale and its
  cap, a key-only `PoolCreation<Lp, Meme, Quote>` holding the capability and
  the sale's ID. The sale's ID exists only then, and binding by ID, not by
  type, is what keeps one reservation from ever serving another pool. `share`
  shares it; nothing else can share, store, or drop it. A creator who
  finalizes through the core instead has no reservation: the sale can never
  migrate and refunds at its liquidity deadline. `finalize` cannot check the
  capability against `Lp`, so a capability of another coin, or an LP coin with
  other than 9 decimals, leaves a reservation whose every migration aborts
  inside Aftermath; the sale then refunds like one finalized through the core,
  and the UI must verify the capability before listing.
- `migrate` checks that the reservation names this sale (`EWrongPresale`),
  consumes it, reads the fee back from `VenueConfig`, takes the hand-off,
  creates the pool in Aftermath's coin order from exactly those balances and
  checks the pool holds every unit (`EPoolMismatch`), builds the vault with no
  position yet, creates the DAO-fee pool with the vault's ID as the recipient
  at that fee and checks both values back (`EDaoFeePoolMismatch`), shares the
  vault with the returned `OwnerCap` as its position and the LP coin's amount
  as its liquidity, shares the DAO-fee pool as the object traders use, and
  sends the `Coin<Lp>` to `0x0`. The vault's `pool_id` is the base pool;
  `DaoFeePoolCreated` records the DAO-fee pool, owner cap, and LP coin IDs,
  and `VaultCreated.liquidity` is the LP amount the vault does not hold.
- `collect_fees` takes `vector<Receiving<Coin<Meme>>>` and
  `vector<Receiving<Coin<Quote>>>`, aborts unless the vault's position sits
  under `aftermath::Venue` (`EWrongVault`, through the vault's package-only
  `has_position`), receives each listed coin through the vault's UID with the
  package-only `receive_fee`, joins them, and hands the totals to the vault's
  existing split. A coin the vault does not own aborts in the framework.

**Vault seams.** The presale vault splits creation into two package-only steps:
`new` builds the unshared vault with its pool binding and no position, and
`share_with_position` attaches the position once under the venue's sealed key,
emits `VaultCreated`, and shares the vault in one consuming call. The DAO-fee
pool must name the vault's address before the owner cap, its position, exists,
and Sui's fresh-ID rule forbids building an object around a `UID` minted
elsewhere, so the vault is born first and takes its position as it is shared.
`create_without_presale` runs both for Cetus and Bluefin. The vault has only
`key`, so an adapter holding an unfinished vault can do nothing but share it
with a position. `has_position` tells an adapter the vault is its own, and
`receive_fee` is the vault's only receipt. The presale source gate pins the
seams and that only `aftermath` takes the unshared path.

**Custody.** The LP coin, the pool's whole liquidity, goes to `0x0` as the
vendor's does: unrecoverable by any code. The owner cap is the vault's position
under the ordinary sealed `PositionKey<Venue>`, so no one can reprice or
redirect the pool; the package exposes no function that uses it, and
`VaultCreated.position_id` names it.

**Explorer naming.** `aftermath::PoolCreation` and the adapter's two events read
on explorers as Aftermath types, as the venue modules' `Venue` and `Witness`
types already do; ADR 0085's naming table records them as accepted residuals of
the per-venue module layout.

**Link stubs.** The presale keeps its own normalized Aftermath interfaces under
`sui/presale/interfaces` (AMM revision 3 and DAO-fee revision 2); the vendor
package overrides them with its own copies, so both build side by side.

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
- **Return the capability from `new` in a hot potato.** Rejected (owner,
  2026-10-17): the sale's ID, which the reservation must name, exists only at
  `finalize`, which already needs the initializer only the creator holds, so
  the capability goes straight to `finalize`.
- **Bind the reservation by type only.** Rejected (owner, 2026-10-17): the
  treasury cap is unique per sale token, so a type binding is sound, but a
  reservation must name the exact sale it serves.
- **The vendor's compiled 2% DAO fee.** Rejected (owner, 2026-10-17): the fee is
  the creator's tier, like a Cetus tick spacing or a Bluefin fee rate, within
  Aftermath's own range, which `new` enforces at most 10,000; the adapter adds
  only the lower bound of one, since a zero fee pays the vault nothing.
- **An Aftermath adapter in the launchpad migrators as well.** Withdrawn
  (owner, 2026-10-17) after two designs: a pool created at migration with the
  fixed terms could be registered first by any Meme holder and strand the
  launch; a pool created in the launch-creation PTB closed that, but needed a
  seed the creator cannot supply, since the launchpad does not mint Meme for
  the creator, and its migration deposit depended on Aftermath's exact-in
  deposit math, which the simulations (`deposit-sim@2026-10-17`) show fails
  outside a narrow band of balance growth and pool size, so the migration had
  to deposit in slices behind a seed floor and a protocol-fee cap. The launchpad
  keeps Cetus and Bluefin, whose pair registration (Cetus) or creator-only
  pool creation (Bluefin) needs no seed. The deposit and simulation evidence
  stays on record for any future venue whose pool must exist before its
  liquidity does.
- **Keep `settle_and_update_fee_split` on Aftermath with caller-listed coins.**
  Not applicable: the presale has no split update; its fees are coins the
  package cannot enumerate, so the split a sale is created with is final.

## Consequences

- Two pinned mainnet lineages (Aftermath AMM revision 3 and DAO-fee revision 2)
  as presale link stubs, verified by the vendor's gate and the presale's
  dev-inspect rows before publication.
- The presale gains a third adapter under the same `CreationPolicy` admission;
  the migrators package and the launchpad are unchanged.
- Indexers find an Aftermath vault's pending fees as the coins its address owns,
  not as a position's accrued fees; `PoolCreationReserved` links the LP coin
  to the sale.
- The presale source gate allows exactly one receiving path.

## Verification

- Move tests in `blast_presale`: `new` records the witness and the fee tier,
  accepts both bounds and rejects beyond them, and needs the policy's
  admission; `finalize` returns one reservation bound to the new sale,
  announces it, and rejects another adapter's initializer; `share` shares the
  reservation; `migrate` rejects another sale's reservation before touching
  anything; an owner cap is a vault position sealed under its venue and
  invisible to another; a vault built before its position announces nothing
  until it is shared with one, and cannot be shared with an empty one;
  collection rejects another venue's vault, receives the vault's own coins and
  splits them exactly, an empty collection moves nothing, and a coin owned by
  someone else aborts in `sui::transfer`.
- `sui/presale/scripts/check_source_boundaries.sh` pins the module, the vault
  seams, the single receiving path, and that the LP coin is the package's one
  transfer to `0x0`; `python3 scripts/check_move_style.py` holds.
- Release: the vendor's `node scripts/check_mainnet_abi.mjs` (both Aftermath
  lineages, hashes, and ABI; passed against mainnet on 2026-10-17) and
  dev-inspect of the presale's Aftermath routes against the published packages
  before the package is published. The local stubs prove types, not behavior.
