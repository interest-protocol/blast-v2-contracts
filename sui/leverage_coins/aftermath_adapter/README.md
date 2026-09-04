# Blast Series1 Aftermath adapter

`blast_leverage_aftermath` owns the shared objects and currencies that connect
Series1 rules to Aftermath.

The current slice owns:

- adapter package versioning and package-capability custody;
- adapter operations authorized by ephemeral Series1 `AdminWitness` values;
- `Vault<Product>`, which wraps `series_one::state::State<Product>`;
- the selected risk-module type; and
- `Coin<Vault<Product>>`, its TreasuryCap, and its MetadataCap.

The selected risk-module witness may raise or lower the live
`max_order_notional` within the immutable bounds chosen at issuance. This
value limits the absolute atomic-USDC notional of one Aftermath order. It does
not limit a user's deposit or the Vault's total open position. Updates have no
cooldown, remain available in every lifecycle state, and cannot change the
target leverage or live position by themselves.

A Series1 `RISK_ADMIN` witness may move an active Vault to `ReduceOnly`. The
adapter version is checked first. The adapter checks the role, and Series1
checks the lifecycle transition. The adapter then emits the event containing
its Vault id.

## Product witnesses

Issuance consumes a runtime `Product` witness. The witness must be a
non-primitive type from this adapter's original package. The complete currency
type is `Vault<Product>`.

One Aftermath package can therefore issue several products:

```text
Sui2x witness ──> Vault<Sui2x> ──> Coin<Vault<Sui2x>>
Sui5x witness ──> Vault<Sui5x> ──> Coin<Vault<Sui5x>>
```

Coin Registry rejects a second issuance of the same concrete product type.
There is no `AdapterRoot`, adapter-specific AdminCap, or generic venue handoff.
Series1 ACL management calls go directly to the Series1 package; this adapter
does not proxy them or accept the shared authority and AdminCaps. A caller signs
in through Series1 and passes the resulting witness to an adapter operation.

The Vault does not contain a generic extension `Bag`. Venue state will be added
as explicit typed fields only when a consensus-critical transition requires it.

The package is not ready to custody user value. Actual Aftermath account
binding and activation, mint, redemption, rebalance, and shutdown operations
remain deferred.

## Verification

Run `bash scripts/verify.sh all` from this directory.
