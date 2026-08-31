# Consume–Replace–Retire

Use this emergency pattern when already-published bytecode has a dangerous
mutator for live shared state and no version, pause, or revocable required-
capability seam is observed by every old path. A code-only upgrade cannot retire
immutable old package versions.

## Recovery invariant

The dangerous old input must cease to exist, and the surviving live state must
move behind a distinct type that old bytecode cannot accept:

```text
authorize exact old state
then consume and unpack it once
then move all surviving contents into a fresh replacement type
then update canonical authority and discovery references
then share the fresh replacement and retire the old UID
```

If old calls remain harmless, changing the latest implementation can be
sufficient. If an existing gate can disable every dangerous old path, use that
gate instead. This migration is the last generic recovery boundary, not routine
upgrade machinery.

## Safe sequence

1. Inventory every old function that can reach the shared object across all
   callable package versions.
2. Prove that no existing version, pause, or capability seam can disable every
   dangerous path.
3. Add a distinct replacement type such as `StateV2`. Preserve the original
   datatype layout and every existing public signature.
4. Authorize migration with an existing authority bound to the exact state or
   package lineage, such as the accepted admin or governance capability.
5. Take the old shared state by value, validate its identity, unpack it once,
   move every surviving value, and delete its UID in the same successful
   transaction.
6. Create the replacement with a fresh UID, add an operational version gate,
   update canonical authority references, and share it only after the complete
   replacement is valid.
7. Emit an old-ID-to-new-ID migration fact and cut dependent packages, clients,
   indexers, caches, and operators over to the new package generation, type, and
   object ID.

Creating another object of the original type is insufficient: old functions
could accept it. A replacement shared object also needs a fresh UID because
Sui requires an object to be newly created in the transaction that shares it
([pinned `transfer.move`](https://github.com/MystenLabs/sui/blob/60f0e8a6abb0523d5c9c7f5edc006f40d8dead03/crates/sui-framework/packages/sui-framework/sources/transfer.move#L97-L108)).

## State and compatibility audit

- Inventory every balance, supply fact, capability, child object, collection,
  and direct dynamic field.
- Direct dynamic fields attached to the old UID do not follow the fresh UID;
  remove, migrate, or deliberately retire them.
- Add new functions or a new module for the replacement type when existing
  public signatures cannot change. Old non-public entry signatures may be
  changed by a compatible upgrade, but old package versions remain callable
  until the original state is consumed.
- Reconcile all assets and accounting exactly. Do not delete the old state
  before the transaction has extracted every value required for recovery.

## Operational boundary

Package upgrade and replacement-state setup are separate transactions. Until
migration consumes the original object, old bytecode can still reach it. Use
any pre-existing pause seam, minimize and monitor the exposure window, and
record the residual race when no seam can close it.

If migration cannot be authorized, cannot reach all required state, or cannot
retire the old input before further harm, the old-version risk remains
unresolved. Do not describe publication of the new code as remediation.

## Verification obligations

Test:

- authorized migration and rejection of wrong authority or state identity;
- repeated migration and concurrent or stale operational attempts;
- full rollback when any extraction, move, update, event, or share step fails;
- exact asset, supply, liability, reward, and accounting reconciliation;
- child-object, collection, and direct dynamic-field handling;
- deletion of the old state and old-function rejection of the new type;
- canonical reference, capability, client, indexer, and dependency cutover;
- liveness of every required user exit after migration.

The central principle is: when old immutable code cannot be gated, retire its
input type and move the protocol to a fresh type boundary.
