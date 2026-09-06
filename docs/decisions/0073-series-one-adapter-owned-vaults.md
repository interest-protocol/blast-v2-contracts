# 0073: Series1 core with adapter-owned product Vaults

- Status: **accepted**
- Date: 2026-09-04
- Active-contract amendment: 2026-09-06 (pre-publication source contract)
- Supersedes the package-boundary, versioning, issuance, and adapter-handoff
  portions of [0064](0064-aftermath-backed-leverage-coins.md),
  [0070](0070-series-one-versioning-and-role-administration.md),
  [0071](0071-series-one-vault-issuance.md), and
  [0072](0072-series-one-package-capability-custody.md)

## Context

Series1 rules must remain stable when a venue integration changes. The same
Series1 administrators must also control every Series1 adapter. At the same
time, one venue package must be able to issue several leverage products, such
as 2x and 5x, without publishing another adapter package.

A generic handoff between a Series-owned shared Vault and an adapter added
types and sequencing without protecting anything useful. The stronger boundary
is ordinary object custody: the adapter owns the outer shared object and keeps
the embedded Series1 state private.

## Decision

### Series1 package

Series1 owns one shared, non-generic `ProtocolAuthority`. It issues non-generic
`AdminCap` objects whose role bitmap is valid for every adapter that depends on
this exact Series1 package. There is no Aftermath-specific or Bluefin-specific
admin cap.

Series1 also owns policy, lifecycle, accounting math, bounded values, and
`state::State<Product>`. `State<Product>` has `store` only. Its fields are
private, so adapters can store it but cannot directly modify its policy,
notional bound, reserve, or lifecycle.

Each product has one immutable public maintenance band, target, and hard
threshold. There is no privileged inner band. Fee and admin-allocation ceilings
are immutable; authorized future settings remain within those ceilings. The
adapter retains native TreasuryCap supply, separate native admin collateral,
and the immutable locked-share amount and nonzero seed funder. Core State does
not duplicate these native balances.

Only State construction accepts an `AdminWitness`. After construction, the
custodial adapter authenticates each operation before it calls a Series1 state
mutation. Series1 state mutations enforce core policy and lifecycle invariants
without repeating adapter-level authorization.

Series1 does not own a currency, venue account, venue-specific state, adapter
witness, package version, Publisher, UpgradeCap, or handoff transport. A future
Series2 is a new package and coin family, not a Series1 upgrade.

### Adapter package

Each adapter owns its package version and upgrade custody. It defines the
outer key-only `Vault<phantom Product>`, stores `State<Product>` inside it, and
owns all venue-specific fields and capabilities. External callers cannot
borrow the private Series state from the outer Vault. Adapter functions perform
venue work and then call the appropriate Series1 mutation function.

Adapter operations accept an ephemeral `AdminWitness` issued by the shared
Series1 authority. A caller signs in through Series1 with the same `AdminCap`
used for every adapter, then passes the witness to an adapter operation. ACL
management calls go directly to Series1; adapters do not accept ACL state or
caps and do not proxy administrator creation, revocation, role changes, or
super-admin transfer. No adapter-domain type or adapter-specific
administrative capability exists.

### Product identity and issuance

Adapter issuance takes a runtime product witness:

```move
public fun issue<Product: drop, RiskModule: drop>(
    protocol: &Protocol,
    admin_witness: &AdminWitness,
    product_witness: Product,
    risk_module: RiskModule,
    package_admin: &PackageAdmin,
    registry: &mut CoinRegistry,
    // immutable policy, bounds, metadata, and context
): Vault<Product>
```

The adapter accepts only a non-primitive `Product` whose original package id is
the adapter's original package id. A product module therefore defines a sealed
witness such as `Sui2x` or `Sui5x`, while the shared Series1 issuer role
authorizes the call.

The currency is `Coin<Vault<Product>>`. The same Aftermath package can issue
`Vault<Sui2x>` and `Vault<Sui5x>` because they are different types. Coin
Registry rejects another issuance of `Vault<Sui2x>`.

Issuance returns the owned Vault. A separate adapter `share` function publishes
it. The adapter retains its TreasuryCap and MetadataCap as dynamic object
children and starts the embedded Series state uninitialized with zero reserve.
Issuance also requires the adapter's `PackageAdmin` object and revalidates that
it contains this adapter's Publisher and UpgradeCap. A Vault therefore cannot
be issued while either raw package capability remains outside permanent
package custody. `PackageAdmin::new` authenticates the cap's original package
once; later issuance requires a nonzero live cap package ID rather than the
original ID because every successful native upgrade commits a new package ID
into that same retained cap.

### Risk module and versioning

The outer adapter Vault stores the selected risk-module `TypeName`. The global
Series1 `RISK_ADMIN` can replace it in any lifecycle state, including shutdown.
Rotation changes no immutable Series policy or product currency type.

Issuance and rotation also consume a runtime value of the selected witness
type. A generic type argument alone is not authority because a caller can name
any public type. An admitted risk witness must be non-primitive and originate
outside the adapter's original package, which prevents the adapter's publicly
constructible `Product<Tag>` wrapper from becoming risk authority. Production
risk packages must expose only their intended sealed witness constructor and
must be published immutably. The adapter cannot prove constructor visibility or
upgrade posture from `TypeName`; reviewed production risk-package source and
immutable publication evidence are therefore a release prerequisite, not an
invariant inferred from the foreign-package check. The Vault continues to store
only `TypeName`, so `RISK_ADMIN` retains the immediate witness-replacement
model.

The selected risk module can raise or lower the current
`max_order_notional` within the immutable minimum and maximum selected at
issuance. This value limits the absolute atomic-USDC notional of one adapter
order. It does not limit a user's deposit or the Vault's total open position.
There is no cooldown. The update changes no target leverage, lifecycle, or
live position and remains available during shutdown. Series1 owns the bounded
value mutation; the adapter authenticates the runtime risk-module witness and
emits the Vault-identified update event.

The current four-state lifecycle is `Uninitialized → Active → Unwinding →
Settled`. Only a live Series1 shutdown-role witness (role bit `8`) can call
`vault::begin_shutdown` from Active. Risk administration alone cannot retire a
product. The adapter checks its version and shutdown role; Series1 owns the
irreversible lifecycle transition. The call requires no oracle or venue data.
Its Emergency or ObservedVenueChange reason records an administrator's decision,
not an on-chain liquidation verdict. Off-chain observers can report liquidation
or ADL candidates but cannot automatically trigger retirement. Permissionless
health synchronization preserves lifecycle and the accepted economic checkpoint
on unresolved changes. There is no ReduceOnly or reactivation surface.

Unwinding permits only bounded close-only venue recovery, not minting or ordinary
redemption. Normal closes require fresh authenticated prices; a frozen-market
close uses only the pinned direct settlement operation. Permissionless
finalization requires exact flat exposure, no orders, current funding snapshots,
no liability, and recovery of every whole collateral atom. The only admitted
venue remainder is the exact nonnegative allocated-collateral remainder below
one collateral atom, derived from the full-precision checkpoint, never a caller
tolerance or write-off. ADR 0074 specifies its units and event ABI.

The adapter retains terminal holder cash in a private typed native `Balance`,
separate from admin cash. Finalization removes the reserve book entry and seals
Settled once. Native TreasuryCap supply minus immutable locked seed determines
eligible supply; no parallel mutable claim ledger exists. If eligibility is
zero at finalization, all recovered holder cash transfers once to the nonzero
seed funder recorded at activation. Otherwise claims burn native shares and pay
the floor-rounded fraction of remaining local cash without fees or venue/oracle
access; the last eligible claimant receives dust. Retirement neither freezes
coin transfers nor controls external Quote markets.

Only the adapter is versioned. Its public operational and administrative routes
check the adapter version. The stable Series1 state and ACL do not carry an
adapter version.

Series1 publication is one atomic PTB: publish the package, bind the returned
`UpgradeCap`, and consume it with `0x2::package::make_immutable`. No transaction
may expose or transfer that capability between publication and destruction.
The transaction digest, package ID, chain identifier, reviewed source commit
and tree, bytecode verification, and absence of a created `UpgradeCap` are
release evidence required before any adapter publication or Vault issuance.
The executable runbook is `sui/leverage_coins/series_one/DEPLOYING.md`.

## Consequences

- One Series1 AdminCap works across Aftermath, Bluefin, and later Series1
  adapters.
- One adapter package can issue any number of distinct sealed product types.
- The product witness, not an adapter root, determines the currency type.
- The adapter owns the shared-object and capability boundary; no generic
  request/receipt handoff is needed.
- Replacing or upgrading an adapter does not add venue state to Series1.
- Series1 remains venue neutral and a future Series2 can use a new core package.

## Verification

- Prove one adapter issues both `Vault<Sui2x>` and `Vault<Sui5x>`.
- Prove Coin Registry rejects a second issuance for the same product witness.
- Reject primitive and foreign-package product witnesses.
- Reject primitive and same-adapter-package risk witnesses, including
  `Product<Tag>`, and require actual witness values at issuance and rotation.
- Prove issuance and risk rotation accept witnesses issued by the global
  Series1 authority and cap.
- Prove an issued Vault wraps one uninitialized Series state, retains both coin
  capabilities, and has zero supply and reserve.
- Pin the one-way Series1-to-adapter dependency and custody split in source
  boundary gates.
- Preview the atomic Series1 publication PTB and verify the executed digest
  proves same-transaction `make_immutable` with no surviving `UpgradeCap`.
