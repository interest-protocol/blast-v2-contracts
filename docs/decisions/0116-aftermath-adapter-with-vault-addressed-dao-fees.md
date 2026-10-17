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
  AFTERMATH-DAO-CAPABILITY premise).

## Decision

**One adapter module per package.** `blast_presale::aftermath` and
`blast_fun_migrators::aftermath` map the vendor's flow onto the presale's
`Vault` and the launchpad's `LpVault`:

- `new` takes the `CreatePoolCapV2` of a fresh LP coin `Lp` the creator published
  and the DAO fee the pool charges, `dao_fee_bps` in 1..=10,000
  (`EInvalidDaoFee`): the creator's tier, as Cetus and Bluefin tiers are. The
  launchpad records it as `(0, dao_fee_bps)`, no tick spacing; the presale
  records it in `VenueConfig` under the sale token's type, as ADR 0111 does for
  the other venues. The other pool terms are compiled: 50/50 weights, flatness
  zero, Aftermath's minimum 0.01% base swap-in fee. `new` returns the capability
  in an ability-free `PendingPoolCreation<Lp, Meme, Quote>`, so the creation PTB
  cannot drop it.
- `finalize` finalizes the sale or launch through the core, then shares a
  key-only `PoolCreation<Lp, Meme, Quote>` holding the capability and the new
  object's ID. The sale's ID exists only then, and binding by ID, not by type,
  is what keeps one reservation from ever serving another pool.
- `migrate` first checks the reservation names this sale or launch
  (`EWrongPresale`, `EWrongLaunch`), consumes it, reads the fee back, takes the
  hand-off, creates the pool in Aftermath's coin order from exactly those
  balances and checks the pool holds every unit (`EPoolMismatch`), builds the
  vault with the returned `Coin<Lp>` as its position and the LP amount as its
  liquidity, creates the DAO-fee pool with the vault's own ID as the recipient
  at that fee and checks both values back (`EDaoFeePoolMismatch`), attaches the
  `OwnerCap` under the vault's new sealed `PoolAuthorityKey<Venue>`, shares the
  vault, and shares the DAO-fee pool as the object traders use. The vault's `pool_id` is the base pool; `DaoFeePoolCreated`
  (presale) and `AftermathPoolCreated` (migrators) record the DAO-fee pool and
  owner cap IDs.
- `collect_fees` takes `vector<Receiving<Coin<Meme>>>` and
  `vector<Receiving<Coin<Quote>>>`, receives each listed coin through the
  vault's UID with the new package-only `receive_fee`, joins them, and hands the
  totals to the vault's existing split. A coin the vault does not own aborts in
  the framework. The launchpad adds `settle_and_update_fee_split` on the same
  inputs.

**Vault seams.** Both vaults split creation into a package-only `new` that
returns the unshared vault and `share`, because the DAO-fee pool must name the
vault's address before the owner cap exists; `create` keeps sharing in one call
for Cetus and Bluefin. `attach_pool_authority` writes the owner cap once with no
borrow or removal path, and `receive_fee` is the vault's only receipt. The
migrators source gate pins all four and that only `aftermath` reaches them.

**Custody.** The LP coin is the vault's position: as locked as a coin at `0x0`,
but discoverable under the vault and announced by `VaultCreated`. The owner cap
stays in the vault so no one can reprice or redirect the pool; the package
exposes no function that uses it.

**Not in scope.** The migrators adapter adds no liquidity to and swaps nothing in
an Aftermath pool: Aftermath's deposit and swap routes take four further shared
objects (`ProtocolFeeVault`, `Treasury`, `InsuranceFund`, `ReferralVault`) whose
ABI is not pinned here. An Aftermath launch vault's auto-LP and burn-Quote shares
therefore wait in the vault, and creators who pick Aftermath should set those
parts to zero. The package stays upgradeable, so a later generation can add the
routes. The presale has neither share, so nothing waits there.

## Alternatives considered

- **Keep the vendor's treasury recipient and have Blast claim from it.** Rejected:
  it bypasses the vault split and Blast's LP-fee policy, which is the point of
  charging a fee like every other venue.
- **Create the DAO-fee pool first and update the recipient to the vault.**
  Rejected: it needs `update_fee_recipient`, an extra pinned ABI entry, and a
  window in which the pool pays someone else.
- **Send the LP coin to `0x0` as the vendor does.** Rejected: the vault already
  seals its position, and `VaultCreated.position_id` then names the locked
  liquidity.
- **Bind the reservation by type only.** Rejected (owner, 2026-10-17): the
  treasury cap and the launch ticket are unique per Meme, so a type binding is
  sound, but a reservation must name the exact sale or launch it serves; the
  hot potato makes the ID binding unavoidable at creation.
- **The vendor's compiled 2% DAO fee.** Rejected (owner, 2026-10-17): the fee is
  the creator's tier, like a Cetus tick spacing or a Bluefin fee rate, within
  Aftermath's own range.

## Consequences

- Two more pinned mainnet lineages (Aftermath AMM revision 3 and DAO-fee revision
  2) in the migrators' dependency gate and lock, reused by the presale.
- The presale gains a third adapter under the same `CreationPolicy` admission;
  the launchpad's `LaunchConfig` admits `aftermath::Witness` like the others.
- Indexers find an Aftermath vault's pending fees as the coins its address owns,
  not as a position's accrued fees; `AftermathPoolReserved` and
  `PoolCreationReserved` link the LP coin to the pair.
- The migrators source gate now allows exactly one receiving path.

## Verification

- Move tests in both packages: `new` records the witness and the fee tier,
  bounds the fee, and needs the policy's admission; `finalize` shares one
  reservation bound to the new sale or launch and announces it; `migrate`
  rejects another sale's or launch's reservation before touching anything; the owner cap attaches once under its venue and never
  under another; collection receives the vault's own coins and splits them
  exactly, an empty collection moves nothing, a coin owned by someone else aborts
  in `sui::transfer`, a stale migrators generation aborts first, and a settled
  update splits under the old split then commits.
- `sui/migrators/scripts/check_source_boundaries.sh` pins the module, its
  bodies, errors, and parameter order, the vault seams, and the single
  receiving path; `python3 scripts/check_move_style.py` holds.
- Release: `node scripts/check_mainnet_abi.mjs` in `sui/migrators` (both
  Aftermath lineages, hashes, and ABI) and a mainnet dev-inspect of each
  `migrate` with a fresh LP coin in both coin orders, then one DAO-fee swap whose
  fee coin a dev-inspect `collect_fees` receives, before either package is
  published. The local stubs prove types, not behavior.
