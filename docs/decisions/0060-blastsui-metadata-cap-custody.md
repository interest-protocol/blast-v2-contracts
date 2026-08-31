# 0060 — Retain currency and receipt update capabilities in package-admin custody

- Status: **accepted**
- Date: 2026-08-31
- Amends: [0053](0053-single-validator-funsui-and-blastsui.md)
- Amended by: [0061](0061-blastsui-routine-admin-and-composable-package-custody.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

## Context

ADR 0053 made both protocol currencies permanently immutable by calling
`CurrencyInitializer::finalize_and_delete_metadata_cap` during package
initialization. The pinned framework deletes the unique capability in that
path. Its separate `finalize` function instead returns the claimed
`MetadataCap<T>` after it transfers the OTW-created `Currency<T>` to the Coin
Registry address
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:319-345`).

Both currency metadata authorities must survive publication without remaining
in deployment-key custody. The receipt Display creator also transferred its unique
`DisplayCap<BlastSuiDepositReceipt>` to `@0x0`. That did not delete the object,
but it made the update authority permanently inaccessible. The pinned framework
defines `DisplayCap<T>` as a key-and-store capability and requires it to change
a Display field
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/display_registry.move:47-81`).

Because all three capabilities have their own `UID`, the pinned framework's
dynamic object fields keep them separately discoverable by ID while attached to
their parent
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/dynamic_object_field.move:4-37`).

The package already has one shared, non-storable `PackageAdmin` that permanently
wraps its package capabilities. The repository contains no blastSUI deployment
record, so this decision changes its owned dynamic-object-field set and
bootstrap ABI before the recorded first publication.

## Decision

Both currency initializers call `CurrencyInitializer::finalize`, then send the
empty treasury cap and unique metadata cap to the publishing sender. Neither
currency metadata authority is deleted during publication.

`deposit_receipt::create_display` returns the canonical
`DisplayCap<BlastSuiDepositReceipt>` after it configures and shares the Display.
The deployment PTB passes that result, `MetadataCap<FUN_SUI>`, and
`MetadataCap<BLAST_SUI>` to the composable package-custody lifecycle accepted
in ADR 0061. `package_admin::new`
first validates the canonical `Publisher` and raw `UpgradeCap`; each
admin-authorized `package_admin::add_capability` then moves one child under an
exact type-derived dynamic-object-field key; terminal `package_admin::share`
requires all three launch-time capabilities before it publishes the parent. The
generic key supports future capability types without adding fields to the
declared struct layout. The object exposes no capability release, transfer,
borrow, or metadata-mutation function. Retention therefore preserves all three
update authorities without adding a public mutation surface.

Each `PackageCapabilityAdded` event identifies its parent, child object ID, and
fully qualified capability type. `PackageAdminCreated` records only the fixed
parent capability IDs and native upgrade state. The framework defines
`MetadataCap<T>` as a key-and-store capability bound to its coin type
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:86-89`).

## Alternatives considered

**Leave a capability with the publishing sender.** Rejected: the key could
change currency or receipt metadata outside protocol custody.

**Delete the capability during initialization.** Rejected: deletion is
irreversible and removes the requested metadata authority.

**Add a metadata setter now.** Rejected: no current operation, authorization
policy, or accepted metadata update is required. Custody does not require a
public mutation surface.

**Keep locking the display capability at `@0x0`.** Rejected: the object remains
on chain, but no transaction can recover or use it to update the receipt
Display.

**Keep deleting the funSUI metadata capability.** Rejected: it is another
package update authority of the same class. Deletion creates an unnecessary
asymmetry and permanently prevents an authorized metadata correction.

## Consequences

- The publisher temporarily receives both currency metadata capabilities
  between publication and package custody; the deployment runbook makes
  attachment and sharing part of the Display-creation PTB.
- `PackageAdmin` retains its fixed struct fields and owns three typed dynamic
  object fields. All child capabilities stay discoverable by object ID. The
  parent remains key-only, shared, and non-releasable.
- `package_admin::add_capability` accepts each update authority as a generic
  child object, and `PackageCapabilityAdded` records its exact type and ID.
- A future metadata or Display update still requires a separate ADR, a
  version-gated and routine-admin-authorized operation, exact tests, and an
  emitted completed fact.
- Existing source or deployment tooling must supply and record all three
  update-cap object IDs when it constructs package administration.

## Verification

- The currency initializer test takes both typed metadata caps from the
  publishing sender and confirms both treasury caps still have zero supply.
- The package-admin custody test creates the canonical Display, attaches all
  three required capabilities, rejects missing or duplicate child types, and asserts
  that each input object ID equals its dynamic-object-field child and
  `PackageCapabilityAdded` fact.
- The SDK's frozen blastSUI ABI, event decoder, and reducer project the new
  typed capability facts and reject a contract/artifact mismatch.
- Both build environments, warning-as-error lint, the complete Move suite,
  source boundaries, coverage, and `git diff --check` must pass under Sui CLI
  `1.77.2-51d177ad7d65`.
