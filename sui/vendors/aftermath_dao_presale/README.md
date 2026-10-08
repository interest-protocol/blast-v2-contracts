# Aftermath DAO-pool presale migrator

`blast_aftermath_dao_presale` is a one-off partner package. A `blast_presale` sale
started through its `new` and finalized through its `finalize` migrates into a fresh Aftermath weighted pool wrapped in
Aftermath's DAO-fee pool, and the DAO fee reaches the partner treasury. The design
is recorded in
[ADR 0104](../../../docs/decisions/0104-external-presale-migrators-and-vendor-packages.md).

## Pool terms

Every pool gets the same compiled terms; neither the creator nor the migration
caller chooses them.

- 50/50 weights and flatness zero, Aftermath's uncorrelated weighted-product curve.
- A 2% DAO fee on every swap, deposit, and withdrawal, paid as separate coins
  straight to the `TREASURY` compiled into the module.
- Aftermath's minimum 0.01% base swap-in fee, which it requires and which
  compounds into the locked LP, and no swap-out, deposit, or withdrawal fee.

## Authority and fees

Publication sends the package's only `AdminCap` to the publisher, and
`scripts/publish_immutable.sh` makes the package immutable in the same
transaction, so no one can change how a funded sale migrates. The `AdminCap`'s one power is creating sales: `new` takes it and returns the
sale's `PresaleInitializer`, whose terms are set as for any presale; `finalize`
takes it again, names the treasury as the sale's only LP-fee recipient, which is
where its fees go, binds the sale's `PoolCreation`, and sends the treasury the
sale's `PresaleCap`. It refuses an initializer another migrator started. A sale
`new` started but finalized directly in
`blast_presale` has no `PoolCreation`, so it cannot migrate and refunds after its
LP deadline. The `PresaleCap` can only destroy
itself after a cancellation, since these sales have no `presale_vault::Vault` residuals
to claim.

Every migration sends the treasury that pool's DAO-fee `OwnerCap`. With it the
treasury can change its pool's DAO fee, anywhere Aftermath allows from 0% to
100%, or the fee recipient, directly through Aftermath. No `presale_vault::Vault` exists
for these pools, so Blast's LP-fee rates and holder-reward rounds do not apply;
Blast still takes its raise and token shares when `blast_presale::migrate` runs.
The `AdminCap` holder may name a Blast partner on the initializer `new` returns,
with `blast_presale::set_partner` before `finalize`; the partner then earns its cut of
Blast's raise fee as on any presale
([ADR 0106](../../../docs/decisions/0106-presale-partners.md)). The presale
`AdminCap` may also replace this one sale's Blast raise and token rates with
`blast_presale::set_protocol_fees`, as on any presale: in the creation
transaction before `blast_presale::share`, which needs both caps in one
transaction, or afterward until the `start_ms` the share fixed.

## Migration and custody

Aftermath creates a pool only from a `CreatePoolCapV2` minted by a freshly
published LP coin. The treasury publishes one per sale (Aftermath's
`publish-lp-coin` transaction) and passes its cap to `new`, which shares a
`PoolCreation<Lp>` binding it to the new presale and emits
`PoolCreationReserved`. Migration then stays permissionless without letting the
caller choose the LP coin. `migrate` takes the sale and its `PoolCreation`, and:

1. checks the `PoolCreation` is bound to this sale, then consumes it;
2. takes the sale's LP tokens and Quote from `blast_presale::migrate` with this
   package's `Witness`;
3. creates the pool in Aftermath's coin order and checks it holds every unit;
4. wraps it in a DAO-fee pool paying the treasury 2% and checks both values;
5. shares the DAO-fee pool, the object traders use; and
6. sends the treasury the pool's `OwnerCap`, and sends the LP coin Aftermath
   returned, the complete LP balance, to `0x0`.

No one can sign for `0x0`, so no transaction can use that LP coin: the
liquidity is locked in the pool forever. The package is immutable, so neither
the treasury nor Blast can redirect a funded sale's raise or LP tokens. If
Aftermath retires the AMM or DAO-fee version this package links to, its
migrations abort, its sales refund at their LP deadline, and new sales need a new
vendor package. A `CreatePoolCapV2` for a different LP coin than `Lp` would
make Aftermath abort the migration, so the treasury must bind the cap its `Lp`
coin minted; a sale that cannot migrate becomes refundable at its LP deadline.

## Deployment order

1. Publish the `blast_presale` generation whose `new` and `migrate` are public,
   following its [runbook](../../presale/DEPLOYING.md), which retires the live
   dependency-only generation's `Published.toml` entry first. The new entry then
   names the address this package links to.
2. Run `scripts/verify.sh` and `node scripts/check_mainnet_abi.mjs`. The ABI
   gate fails on any newer Aftermath revision until it is reviewed.
3. Run `scripts/publish_immutable.sh --preview`, then `--execute`.
4. With the presale `AdminCap`, call `creation_policy::set_migration_witness_allowed`
   for `<package>::blast_aftermath_dao_presale::Witness`, and allow the sale's
   Quote type.
5. Before the first sale migrates, prove a mainnet dev-inspect of `migrate` with a
   fresh LP coin for both coin orders: the local stubs prove types, not behavior.

`migrate` takes Aftermath's shared `PoolRegistry`
(`0xfcc774493db2c45c79f688f88d28023a3e7d98e4ee9f48bbf5c7990f651577ae`) and the
DAO-fee `Version`
(`0xb4bfb0f917f12ad2a772bea9b4f22431f6f5f9653162c3ae6fae5b99b21392b7`), both as
recorded on 2026-09-02.
