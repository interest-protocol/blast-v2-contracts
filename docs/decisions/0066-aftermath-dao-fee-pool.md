# 0066: Aftermath DAO-fee wrapper and claimable launch revenue

- Status: **accepted**
- Date: 2026-09-02
- Amends: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md),
  [0059](0059-production-launchpad-abi-and-sdk-parity.md), and
  [0063](0063-aftermath-weighted-pool-migrator.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `amm@9431920` | `9431920dd04ca3125e8a351a377a4399aa9193ce` | `AftermathFinance/move-amm-public` |
| `sdk@449f8e6` | `449f8e6e52a7829fd8b2fe3c9d3145beef5316f5` | `AftermathFinance/aftermath-ts-sdk` |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | `MystenLabs/sui` |

The DAO-fee package reviewed on mainnet has current package id
`0x5ad6890968efcf3d20899e0cec735214f1067b96e77e77d86408989998468bb2`,
original package id
`0x6f60a091637054e23915b8745c0c0d47b1d49618ee3435b5f68eccf6a44fb53d`,
and production `Version` object
`0xb4bfb0f917f12ad2a772bea9b4f22431f6f5f9653162c3ae6fae5b99b21392b7`
with initial shared version `293243902`.

## Context

ADR 0063 permanently locked the fungible LP coin because an Aftermath base
pool compounds its trading fees into reserves. Burning part of that LP coin
cannot identify which withdrawn units are fees and which are principal. The
decision protected principal, but it also made Aftermath launch revenue
unclaimable.

Aftermath supplies a separate DAO-fee package. Its SDK builds `pool::new` with
an existing base `Pool`, a shared DAO version, a `u16` basis-point fee, and a
recipient address, and identifies the two returned objects as `DaoFeePool` and
`OwnerCap` (`sdk@449f8e6:src/packages/pools/api/poolsApi.ts:752`). The same SDK
requires that owner cap for later rate and recipient changes
(`sdk@449f8e6:src/packages/pools/api/poolsApi.ts:791`). DAO-aware deposit and
withdraw builders route through the wrapper instead of the base pool
(`sdk@449f8e6:src/packages/pools/api/poolsApi.ts:930` and
`sdk@449f8e6:src/packages/pools/api/poolsApi.ts:974`).

The wrapper recipient must be protocol-controlled without introducing a
separate payout address or allowing the migration caller to capture fees. It
must also preserve the existing creator/protocol live split and permanent LP
principal invariant.

## Decision

Every new Aftermath migration must wrap the newly created base pool with
Aftermath's DAO-fee pool in the same transaction. The per-launch `LpVault`
object address is the immutable fee recipient. The DAO `OwnerCap` and the
complete liquid `Balance<Lp>` are stored together in one sealed
`AftermathPosition`; neither has a public removal or by-value borrow path. The
returned `Coin<Lp>` is converted before storage, which deletes only its wrapper
UID and preserves every LP unit. The shared object exposed to traders is the
DAO-fee pool, not the inner base pool.

Vault creation is split into package-only `prepare` and `finish` operations.
`prepare` creates the key-only, unshared vault with a sentinel pool ID and
exposes its future object ID so the DAO wrapper can bind that address before it
returns the owner cap. `finish` accepts that value only while the sentinel is
present, installs the outer pool ID, attaches the complete venue position,
shares the vault, and emits `VaultCreated`. No incomplete vault is ever shared
or externally storable.

The future-migration policy gains `dao_fee_bps: u16`. The compiled defaults
are:

- 200 basis points, or 2%, for the DAO fee; and
- `0.01%` for the base pool swap-in fee, Aftermath's supported minimum.

This moves the previous default 2% revenue from inseparable LP appreciation to
separate fee coins. The remaining minimum base fee still compounds into locked
principal. Aftermath defines `0.01%` as its base-pool minimum and rejects any
swap-in fee outside `[0.01%, 10%]`
(`amm@9431920:packages/amm/sources/pool.move:46` and
`amm@9431920:packages/amm/sources/pool.move:1129`). The adapter therefore fixes
the base fee at exactly `0.01%`; it is not policy-configurable. Because the
wrapper charges independently, the exact default swap charge is `2% + 0.01%`
on the post-DAO-fee input, or 2.0098% of the original input. The DAO rate must
be in `[0, 10_000]` basis points. A live `AdminWitness` can pin the weights and
DAO rate for future migrations; permissionless migration callers choose
neither. A separate live-admin operation can increase or decrease an existing
pool's DAO rate within the same bounds. It proves that the supplied outer pool
matches the vault, borrows the retained owner cap by reference, calls
`update_fee_bps`, verifies both the resulting rate and unchanged vault
recipient, and emits complete old and new values. No operation exposes the cap
by value or calls `update_fee_recipient`.

Aftermath sends DAO fees as separate `Coin<T>` objects to the vault address.
The reviewed revision-2 bytecode splits a fee coin and calls
`transfer::public_transfer` for the configured recipient, so repeated
fee-producing operations can accumulate many child coin objects. The exact
fee formula remains an integration premise below.

One permissionless collection function receives separate vectors of
object-owned `Coin<Meme>` and `Coin<Quote>` through the vault UID. Either vector
can be empty, but together they must contain 1 through 100 receiving objects.
It converts every coin into a balance, merges both asset balances, and performs
one common `FeeLedger` accrual and one aggregate event. The live
`RuntimeConfig.protocol_fee_share_bps` applies to that aggregate; protocol
share rounds up and creator share receives the remainder under ADR 0054. The
locked LP amount is read before and after collection, and the transition aborts
unless it is unchanged. The event records only the verified final amount. A
caller can donate matching coins to the vault, but can neither withdraw them
nor redirect their allocation.

`AftermathMigrationCompleted` records both the inner base-pool ID and outer
DAO-fee-pool ID, the DAO fee, and the residual base swap-in fee. The vault's
`pool_id` is the outer, user-facing DAO-fee-pool ID. Policy mutation events
record complete old and new values.

### Mainnet premises

The DAO-fee implementation source is not published in the reviewed repository,
so these implementation claims are premises rather than cited source facts:

- **AFTERMATH-DAO-CREATION:** `pool::new` consumes the base pool, accepts the
  production version, fee and recipient, and returns a wrapper plus an owner
  cap bound to it. Falsification test: the release gate compares the normalized
  mainnet signature, type origins, package lineage, module hashes, and package
  digest before publication, then a dev-inspect constructs the wrapper and
  reads back the exact fee and vault recipient.
- **AFTERMATH-DAO-SEPARATION:** swaps, deposits, and withdrawals through the
  wrapper split `floor(amount * fee_bps / 10_000)` into a distinct coin and
  transfer it to the configured recipient. Falsification test: a mainnet-fork
  integration executes each operation at boundary amounts, receives the
  object-owned coins into the vault, and reconciles wrapper outputs, base-pool
  deltas, fee-coin balances, and rounding.
- **AFTERMATH-DAO-CAPABILITY:** fee or recipient mutation requires the matching
  `OwnerCap`. Falsification test: mainnet dev-inspect proves mutation succeeds
  with the returned cap and fails with an unrelated or absent cap.

The framework permits a package to share an external object with `key + store`
and receive an external object with `key + store` through a parent UID
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/transfer.move:123`
and
`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/transfer.move:142`).
Its executable object-receive test transfers a child to the parent's address
and receives it through that parent's UID
(`sui@06734f6:crates/sui-framework/packages/sui-framework/tests/test_scenario_tests.move:445`).

## Alternatives considered

**Burn LP tokens and classify the output as fees.** Rejected because a
fungible LP balance has no principal/fee lots. The operation can remove
principal after reserve and price changes.

**Send DAO fees directly to a protocol wallet.** Rejected because it bypasses
the launch's creator/protocol allocation ledger, weakens on-chain
reconstructability, and adds mutable payout-address operations.

**Transfer the DAO owner cap to an administrator.** Rejected because direct cap
custody would allow unmediated recipient changes and make loss or transfer of
the capability an operational risk. The cap stays locked; the contract exposes
only its bounded, admin-authorized fee-rate operation and never recipient
mutation.

**Keep the 2% base fee and add another 2% DAO fee.** Rejected because it nearly
doubles the default swap charge instead of replacing the unclaimable revenue
path.

**Set the base LP fee to zero.** Rejected by the live Aftermath constructor,
which enforces the `0.01%` minimum. The adapter fixes that unavoidable fee at
the minimum so no administrator can increase the permanently locked portion.

## Consequences

- Aftermath launch revenue becomes separately claimable without removing any
  LP principal.
- DAO fees on swaps, deposits, and withdrawals are allocated through the same
  live creator/protocol split as other venue fees.
- One accrual can delete and merge up to 100 accumulated DAO fee coin objects
  while committing only one fee-ledger mutation and event.
- Admins can adjust the DAO fee of future and existing pools from 0% through
  100%, while the vault recipient and base LP fee remain fixed.
- Each migration needs the production DAO `Version` shared object in addition
  to the base registry and creation cap.
- The SDK and indexer must treat the outer DAO-fee-pool ID as the launch's
  active pool and retain the inner pool ID as a canonical relationship fact.
- The dependency gate expands to one more exact mainnet package lineage and
  two pinned normalized modules.

## Verification

Move tests cover policy defaults and bounds, complete mutation events, pending
vault construction, maximum-size coin receipt and merging, and unchanged LP
principal during fee accrual. Source gates require DAO creation, vault-address
recipient binding, owner-cap custody, outer-pool sharing, the combined bounded
typed receive path, and prohibit exposing cap or LP removal. SDK tests cover
BCS, the batch builder and bounds, events, and reducer projections. The
mainnet ABI gate checks the exact package lineage, digest, module hashes,
origins, structs, and consumed function signatures. Publication remains
blocked until the three named premises pass their dev-inspect or mainnet-fork
tests.
