# 0063: Aftermath weighted-pool migration with permanently locked LP tokens

- Status: **accepted**
- Date: 2026-08-31
- Amends: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md) and
  [0057](0057-admin-pinned-venue-tiers.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `amm@9431920` | `9431920dd04ca3125e8a351a377a4399aa9193ce` | `AftermathFinance/move-amm-public` |
| `interfaces@f62e74a` | `f62e74aa862ef65b8950a70d83aac8cb71c19837` | `AftermathFinance/move-interfaces` |
| `sdk@449f8e6` | `449f8e6e52a7829fd8b2fe3c9d3145beef5316f5` | `AftermathFinance/aftermath-ts-sdk` |

The adapter links to the current mainnet AMM package revision 3 at
`0xf948935b111990c2b604900c9b2eeb8f24dcf9868a45d1ea1653a5f282c10e29`,
whose original package id is
`0xefe170ec0be4d762196bedecd7a065816576198a6527c99282a2551aaa7da38c`.
The production `PoolRegistry` is
`0xfcc774493db2c45c79f688f88d28023a3e7d98e4ee9f48bbf5c7990f651577ae`.

## Context

Aftermath creates constant-function pools from complete input coins and returns
a fungible LP coin. It does not charge a separate pool-opening asset, but its
V2 API consumes a `CreatePoolCapV2` made from a fresh, zero-supply LP currency.
The cap must therefore be prepared before the atomic launch migration.

Aftermath trading fees compound into pool reserves. They are not separable
from LP principal without burning LP tokens. Treating any later LP withdrawal
as a fee collection could remove principal after price movement and would
break ADR 0054's permanent-liquidity invariant.

## Decision

Add Aftermath as a sixth module in the aggregate migrators package. It uses
`pool_factory::create_pool_2_coins_v2` to create a fresh two-coin pool only.
The caller supplies the LP type's `CreatePoolCapV2`, but supplies no pool
weight, curve, fee, price, name, or liquidity parameter.

The compiled default pool policy is:

- 50% Meme and 50% Quote weights, summing exactly to Aftermath's `1e18` unit;
- flatness zero, selecting the uncorrelated weighted-product curve;
- a 2% swap-in fee by default, in Aftermath's `1e18` fee unit;
- the same swap-in fee for both assets; and
- zero swap-out, deposit, and withdrawal fees.

The role-based weights and swap-in fee remain correctable after package
immutability. The Aftermath module owns `AftermathPolicy`, containing Meme
weight, Quote weight, and swap-in fee, and stores it in `VenueConfig` under its
sealed `PolicyKey`. Each weight must be at least 1%, the pair must sum exactly
to Aftermath's `1e18` fixed one, and the fee must remain in Aftermath's
supported `[0.01%, 10%]` range. The one public setter requires a live core
`AdminWitness`, rejects an unchanged effective policy, emits complete old and
new policy values, and affects only later migrations. Migration callers cannot
select any policy input.

`VenueConfig` exposes only package-level generic dynamic-field operations. A
venue can access a policy entry only by constructing its concern-owned key.
This lets future adapters add typed policy shapes without changing the frozen
`VenueConfig` layout or extending one cross-venue enum. The five CLMM adapters
retain the shared `(tick_spacing, fee_rate)` `Tier` shape.

Aftermath requires underlying type names in lexicographic order. Two public
routes cover Meme in the first or second slot. Each route compares
`type_name::with_defining_ids` values, checks that the LP type is not already
registered, and validates the effective policy before calling core migration.
The routes map the role-based Meme and Quote weights into canonical coin order.
A wrong route, reused LP type, or invalid policy therefore fails before the
witness-bound payload is redeemed.

The adapter passes both complete source coins to Aftermath and then reconciles
the returned state before sharing the pool. Success requires:

- exactly two assets;
- exact source Meme and Quote balances in the pool;
- exact weights, flatness, and all four fee vectors;
- nine LP decimals;
- a nonzero returned LP coin; and
- total LP supply equal to the returned liquid LP plus Aftermath's exact
  `1_000` minimum permanently illiquid LP amount.

Any mismatch aborts the whole Sui transaction. The adapter then attaches the
entire returned `Coin<Lp>` to the launch's `LpVault` as the sealed Aftermath
position and stores zero migration residuals. No function can remove, burn,
split, transfer, or borrow that coin by value. The pool is shared only after
the vault is constructed.

Aftermath gets dedicated `AftermathPolicyUpdated` and
`AftermathMigrationCompleted` events. The policy event records complete old and
new weights and fee. The migration event records the launch, vault, pool, LP
type, source amounts, locked LP amount, applied role weights, fixed flatness,
and applied swap-in fee. The CLMM-specific square-root price and tick fields in
`MigrationCompleted` do not apply.

ADR 0054's fee-collection and creator/protocol LP-fee claims do not apply to
Aftermath. Its compounded trading fees stay inseparable from the permanently
locked LP principal. The common vault's fee ledger remains empty and no
Aftermath collection route exists. This exception preserves the stronger
principal invariant instead of manufacturing an unsafe fee/principal split.

The dependency is a minimal normalized interface with aborting local link
stubs. The release verifier separately pins `CreatePoolCapV2` to revision 3,
where that capability type originated, while other consumed AMM types retain
their original-package origins. Publication remains blocked until the release
gate verifies the exact mainnet lineage and normalized function signatures, and
a mainnet dev-inspect proves pool creation and every postcondition. The
aggregate package must still be made immutable before its LP lock is described
as permanent.

## Alternatives considered

**Let the migration caller choose weights or fees.** Rejected: permissionless
migration would let the first caller irreversibly choose the economics of the
locked pool. Only the effective admin-pinned policy can replace compiled
defaults.

**Store every venue policy in one enum.** Rejected: each new DEX shape would
change a published enum layout, centralize venue-specific validation, and add a
wrong-variant failure path. Sealed typed dynamic fields preserve the singleton
layout while letting each adapter own its policy invariants.

**Withdraw LP tokens later and call the gain fees.** Rejected: a fungible LP
token represents both principal and compounded fees, and reserve movements do
not provide a safe on-chain principal boundary.

**Create the LP currency during migration.** Rejected: Aftermath's V2 flow
creates `CreatePoolCapV2` in the LP type's defining package, so preparation is
a separate transaction and package publication step.

**Use the deprecated revision-2 pool-creation ABI.** Rejected: mainnet's
current package revision exposes the V2 capability API and accepts the live
registry's protocol version.

## Consequences

- Every source asset and every liquid LP token is reconciled and permanently
  custodied in one atomic transaction.
- Admins can change Aftermath's role weights and swap-in fee for future
  migrations without exposing those choices to permissionless migration
  callers.
- Aftermath trading fees increase the value of locked liquidity but are never
  separately claimable by creators or the protocol.
- Operators must publish a fresh nine-decimal LP type and prepare its
  `CreatePoolCapV2` before migrating a launch.
- A deployment needs one more exact mainnet dependency and dev-inspect fixture
  before the aggregate package can pass its release gate.

## Verification

From `sui/migrators/`, `sui move test --lint` covers policy defaults, sealed
overrides, weight normalization and minimums, fee bounds, unchanged-policy
rejection, and source-level invariants. The source-boundary gate requires both
canonical routes, role-to-canonical weight mapping, all external
postconditions, whole-LP vault custody, absence of an Aftermath fee-collection
path, and pool sharing after vault construction. The mainnet ABI gate pins the
current package lineage and all consumed signatures. A production dev-inspect
must exercise both type orientations and the live registry before publication.
