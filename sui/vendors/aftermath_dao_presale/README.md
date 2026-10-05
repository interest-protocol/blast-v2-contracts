# Aftermath DAO-pool presale migrator

`blast_aftermath_dao_presale` is a one-off partner package. A `blast_presale` sale
created through its `new` migrates into a fresh Aftermath weighted pool wrapped in
Aftermath's DAO-fee pool, and the DAO fee reaches the partner treasury. The design
is recorded in
[ADR 0104](../../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md).

## Pool terms

Every pool gets the same compiled terms; neither the creator nor the migration
caller chooses them.

- 50/50 weights and flatness zero, Aftermath's uncorrelated weighted-product curve.
- A 2% DAO fee on every swap, deposit, and withdrawal, paid as separate coins to
  the shared `Config` object's address.
- Aftermath's minimum 0.01% base swap-in fee, which it requires and which
  compounds into the locked liquidity, and no swap-out, deposit, or withdrawal fee.

## Authority and fees

Publication shares one `Config` holding the treasury, initially the `TREASURY`
constant, and sends the package's only `AdminCap` to that address.
`scripts/publish.sh` sends the `UpgradeCap` there in the publish transaction.

- `claim_fees<CoinType>` is open to anyone: it receives the fee coins waiting at
  `Config` and pays them to the current treasury as one coin.
- `set_treasury` takes the `AdminCap` and moves where every later claim goes,
  including fees already waiting.

A sale created here names `Config` as its only LP-fee recipient, which is where
its fees go. No `PresaleVault` exists for these pools, so Blast's LP-fee rates and
holder-reward rounds do not apply; Blast still takes its raise and token shares
when `blast_presale::migrate` runs.

## Migration and custody

Migration is permissionless, like every presale venue. Aftermath creates a pool
only from a `CreatePoolCapV2` minted by a freshly published LP coin, so the caller
first publishes one (Aftermath's `publish-lp-coin` transaction) and passes its
type as `Lp`. `migrate` then:

1. takes the sale's LP tokens and Quote from `blast_presale::migrate` with this
   package's `Witness`;
2. creates the pool in Aftermath's coin order and checks it holds every unit;
3. wraps it in a DAO-fee pool paying `Config` at 2% and checks both values;
4. shares the DAO-fee pool, the object traders use; and
5. freezes the complete LP balance and the DAO pool's `OwnerCap` in a
   `LockedLiquidity`, so the liquidity can never be withdrawn.

The `UpgradeCap` holder can upgrade this package. An upgrade cannot move frozen
LP, but it could read the frozen `OwnerCap` by reference to change a pool's DAO
fee or recipient, and it changes how sales not yet migrated reach Aftermath.

## Deployment order

1. Publish the `blast_presale` generation whose `new` and `migrate` are public;
   the live dependency-only generation cannot gain them. Its `Published.toml`
   then names the address this package links to.
2. Confirm `TREASURY` in `sources/blast_aftermath_dao_presale.move`.
3. Run `scripts/verify.sh` and `node scripts/check_mainnet_abi.mjs`. The ABI
   gate fails on any newer Aftermath revision until it is reviewed.
4. Run `scripts/publish.sh --preview`, then `--execute`.
5. With the presale `AdminCap`, call `creation_policy::set_migration_witness_allowed`
   for `<package>::blast_aftermath_dao_presale::Witness`, and allow the sale's
   Quote type.
6. Before the first sale migrates, prove a mainnet dev-inspect of `migrate` with a
   fresh LP coin for both coin orders: the local stubs prove types, not behavior.

`migrate` takes Aftermath's shared `PoolRegistry`
(`0xfcc774493db2c45c79f688f88d28023a3e7d98e4ee9f48bbf5c7990f651577ae`) and the
DAO-fee `Version`
(`0xb4bfb0f917f12ad2a772bea9b4f22431f6f5f9653162c3ae6fae5b99b21392b7`), both as
recorded on 2026-09-02.
