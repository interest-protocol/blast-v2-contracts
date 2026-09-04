# Blast leverage Series1

`blast_leverage_series_one` is the venue-neutral, stable core used by every
Series1 adapter.

It owns:

- one shared `ProtocolAuthority` and the Series1-wide `AdminCap` role bitmap;
- immutable tier and valuation policy values;
- the closed lifecycle;
- reserve-aware accounting and exposure math;
- reusable bounded values; and
- `state::State<Product>`, the non-object state value stored by an adapter.

It does not own a leverage currency, venue account, adapter witness, package
version, Publisher, UpgradeCap, or generic cross-package handoff. Those belong
to each adapter package.

## Shared administration

Series1 publishes one shared `acl::ProtocolAuthority` and delivers one
`acl::SuperAdminCap`. A registered `acl::AdminCap` is not generic over an
adapter. The same live cap and role bitmap therefore authorize Aftermath,
Bluefin, and any later adapter that depends on this exact Series1 package.

| Bit | Role | Authority |
| ---: | --- | --- |
| 1 | `VAULT_ISSUER` | Creates a product's Series1 state and adapter currency. |
| 2 | `RISK_ADMIN` | Selects the risk module used by an adapter Vault. |
| 8 | `SHUTDOWN_ADMIN` | Controls future Series1 shutdown transitions. |
| 16 | `PACKAGE_ADMIN` | Controls versioned adapter package administration. |

One cap can hold any nonzero subset of those bits. Bit 4 is intentionally not
assigned.

## Adapter custody boundary

`state::State<Product>` has `store` but not `key`, `copy`, or `drop`. An
adapter places it inside its own key-only `Vault<Product>`. Because Series1
keeps every State field private and the adapter keeps the outer Vault field
private, callers cannot obtain arbitrary mutable access to core state.

The State owns the frozen minimum and maximum around its live
`max_order_notional`. This value limits the absolute atomic-USDC notional of
one adapter order. It does not limit a user's deposit or the Vault's total open
position. Its setter permits either direction inside the bounds, rejects a
no-op, and does not change lifecycle or live exposure. The custodial adapter
authenticates its selected risk module before calling it.

The Series1-wide `RISK_ADMIN` may also move an `Active` State to `ReduceOnly`.
The adapter validates that role before it calls the State transition. Series1
then validates only the one-way lifecycle change. The transition cannot
activate, resume, or begin shutdown. The adapter emits the Vault-identified
event after the Series transition succeeds.

The adapter calls Series1 mutation functions after it validates venue inputs,
its package version, and the shared Series1 admin role. The adapter also owns
the Coin Registry call, TreasuryCap, MetadataCap, explicit venue state, and
risk-module selection.

## Operation observations

`observation::PriceObservation`, `PositionObservation`, and
`FundingSettlement` are linear, operation-scoped normalized data carriers.
They authenticate neither a caller nor a venue or oracle source; each adapter
must establish source identity before it constructs them. The package alone can
consume their fields, ensuring an observation cannot be duplicated, retained,
or unpacked by an adapter after it passes into Series1.

| Code | Macro | Raised by | Meaning |
| ---: | --- | --- | --- |
| 75 | `invalid_observation_price` | `observation` | A normalized price or mark is zero. |
| 76 | `invalid_observation_lot_size` | `observation` | A normalized position has zero lot size. |
| 77 | `invalid_position_observation` | `observation` | Base and notional do not describe a flat or lot-aligned non-flat position. |

## Current state

This package is not ready to custody user value. It provides the immutable
policy, lifecycle, ACL, and accounting foundation. Activation, mint,
redemption, rebalance, shutdown settlement, and venue verification remain
deferred to operation-specific Series1 functions and adapters.

## Verification

Run:

```bash
bash scripts/verify.sh all
```

The gate checks source boundaries, testnet and mainnet builds, warning-as-error
lint, and all Move tests with the pinned toolchain.
