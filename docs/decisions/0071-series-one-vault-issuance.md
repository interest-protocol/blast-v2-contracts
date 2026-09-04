# 0071: Series1 Vault and dynamic share-currency issuance

- Status: **superseded** by
  [0073](0073-series-one-adapter-owned-vaults.md)
- Date: 2026-09-03
- Amends: [0064](0064-aftermath-backed-leverage-coins.md) and
  [0070](0070-series-one-versioning-and-role-administration.md)

## Sources

> Historical decision. ADR 0073 moves the outer Vault, Coin Registry call,
> currency capabilities, and runtime product witness into the adapter package.
> Series1 now returns only `State<Product>`.

| Short ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

## Context

Series1 has pure accounting, immutable policy values, a closed lifecycle, one
package-version cutover, and role administration. It does not yet have the
shared object that defines a leverage-share currency and owns its mint
authority.

The currency type must stay stable when its venue adapter changes. The
permanent type identity is therefore `Vault<AdapterRoot>`, while the active
adapter and risk module are stored as original `TypeName` values. Issuance must
be one-time for each `AdapterRoot`, must not require a currency OTW, and must
leave no externally usable metadata or mint capability.

The pinned Coin Registry permits the module that defines a `key` type to create
its currency dynamically, rejects an existing type, and records the created
`TreasuryCap` id
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:170-201`).
Its `finalize` path shares the dynamic `Currency`, returns the unique
`MetadataCap`, and records that cap's id in canonical Currency state
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:319-330`).

## Decision

Add `vault.move` as the owner of `Vault<phantom AdapterRoot>`. The type has
`key` only. `issue` returns the owned Vault, and a separate consuming `share`
function publishes it as shared state in the same transaction. Its initial
state contains:

- one immutable `TierPolicy`;
- one positive `BoundedValue` for the absolute atomic-USDC notional limit on
  one adapter order;
- `Lifecycle::Uninitialized`;
- the original type names of the initial adapter and risk-module witnesses;
- zero maintenance-reserve accounting;
- one empty protected adapter `Bag`;
- the share `TreasuryCap` as a discoverable dynamic object child; and
- the share `MetadataCap` as a discoverable dynamic object child.

Issuance is the only transition in this slice. It takes the singleton
`PackageVersion`, a borrowed `AdminWitness`, and the framework `CoinRegistry`.
The authorized issuer selects the adapter-root and risk-module identities as
type arguments; issuance does not require runtime values of either type. It
checks the package version first, requires `VAULT_ISSUER`, rejects primitive or
vector identities, requires both type arguments to have `drop`, and requires a
positive maximum-order-notional minimum before any registry or object mutation. The
issuer role is the authority for both initial type selections. The later
operation path must still authenticate the active module before accepting an
adapter or risk-module action.

A private `new<AdapterRoot, RiskModule>` validates and returns the unshared
Vault. The public `issue` transition separately registers the currency,
finalizes metadata, attaches both returned capabilities, emits the issuance
event, and returns the completed Vault. The public `share` function is its only
publication sink. Because the Vault has `key` but not `store`, a successful
creation transaction must consume it through `share`; future initialization can
compose between `issue` and `share` without changing issuance.

The immutable policy constructors become public pure functions. They create no
authority or state and let an issuer compose one validated `TierPolicy` before
calling `vault::issue`. Their existing field accessors and operational gates
remain package-only.

`vault::issue` registers `Coin<Vault<AdapterRoot>>` with nine decimals. The
issuer supplies the symbol, name, description, and icon URL. The function
stores both the unique `TreasuryCap<Vault<AdapterRoot>>` and
`MetadataCap<Vault<AdapterRoot>>` as type-keyed dynamic object children of the
Vault and exposes no release path. This slice exposes no metadata mutation
path. Dynamic object fields preserve each child capability as a separately
discoverable live object
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/dynamic_object_field.move:4-7,24-40`).
Coin Registry remains the one-per-type replay guard.

Issuance creates a zero-supply, zero-reserve, uninitialized Vault, which the
creation transaction publishes through `share`. No operation can mint, accept
funds, or change exposure in this state. A later risk-module
initialization must atomically bind the venue, fund and open the seed position,
mint and lock seed shares, and activate the lifecycle. This resolves the
uninitialized-state liveness requirement by forbidding value before activation,
instead of making issuance depend on the unfinished venue adapter.

After final local mutation, `VaultIssued<AdapterRoot>` records the Vault,
TreasuryCap, and MetadataCap ids, both selected witness types, the immutable
policy, the maximum-order-notional bounds, and the zero initial reserve. Coin Registry
state remains the authority for currency metadata and both capability bindings.

## Alternatives considered

**Use a currency OTW.** Rejected because the framework registry already enforces
one currency for each `Vault<AdapterRoot>` type, and the issuer role controls
the only core call to the non-OTW constructor.

**Store the TreasuryCap inline or in the adapter Bag.** Rejected because either
form wraps the object and prevents standard tooling from resolving the live cap
id recorded by Coin Registry.

**Delete or return the MetadataCap.** Rejected because Series1 retains metadata
authority under the same Vault that owns the currency. Deletion would remove
that authority permanently, while returning it would expose it outside protocol
custody.

**Create and activate the position in the issuance call.** Deferred because the
required Aftermath bindings, normalized checkpoint, oracle carrier, and
post-execution proofs remain open. The uninitialized lifecycle exists to keep
the zero-value shell inert until those proofs are available.

**Add witness rotation and financial transitions now.** Deferred from this
issuance slice. ADR 0073 subsequently adds the no-op-rejecting,
package-origin-aware witness rotations. Financial transitions still require
their lifecycle, event, and adapter-handoff rules.

## Consequences

- One authorized issuer can permanently claim each `AdapterRoot` currency type.
- The share-currency type does not change when the active adapter later rotates.
- Vault construction remains composable before the dedicated publication step.
- The Vault exclusively controls mint and metadata authority while standard Sui
  tooling can still discover both child capabilities and their canonical
  registry bindings.
- Currency metadata has no mutation route in this slice, but its capability is
  retained for a later explicitly authorized Vault transition.
- The shared Vault is inert and holds no user or protocol value before the
  later initialization transition succeeds.
- ADR 0072 subsequently adds package-upgrade custody. The package remains
  non-publishable until the complete activation, exit, and adapter paths are
  implemented and audited.

## Verification

- Test successful issuance, exact stored state, claimed metadata authority,
  zero supply, both dynamic capability identities, and the complete event
  payload.
- Prove two different `AdapterRoot` types can each issue once and a repeated
  type fails through Coin Registry uniqueness.
- Pin package-version and issuer-role precedence before witness, bound, and
  framework validation.
- Reject primitive adapter and risk-module types, a zero notional minimum, and
  malformed `BoundedValue` order with exact errors and locations.
- Pin the public policy-construction and Vault-issuance surfaces in the source
  boundary gate.
- Run both environment builds, warning-as-error lint, all Move tests, source
  boundaries, and `git diff --check` with the pinned toolchain.
