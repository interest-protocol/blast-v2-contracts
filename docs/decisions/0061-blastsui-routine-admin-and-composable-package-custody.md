# 0061 — Routine administration and composable package custody for blastSUI

- Status: **accepted**
- Date: 2026-08-31
- Amends: [0053](0053-single-validator-funsui-and-blastsui.md), [0060](0060-blastsui-metadata-cap-custody.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

## Context

ADR 0053 gave the singleton `SuperAdminCap` direct authority over routine fee
and package operations. That makes the cold root part of every operational
transaction. The root's durable purpose is narrower: manage revocable routine
administrators and rotate itself. Fee policy, upgrade authorization, upgrade
policy restriction, and activation are routine operations.

ADR 0060 also described package custody as one `wrap` call that simultaneously
validated fixed package identity, accepted a fixed set of child capabilities,
and irreversibly shared the parent. The receipt `DisplayCap` is produced by a
separate call in the same programmable transaction. Future package-owned
capabilities should be attachable without adding fixed parent fields or another
one-shot constructor signature.

The pinned framework's `VecSet` provides bounded ID membership, while dynamic
object fields attach a child object to its parent and preserve the child's
object identity
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/vec_set.move`,
`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/dynamic_object_field.move:4-37`).

## Decision

### Separate root administration from routine administration

`ProtocolAuthority` stores the active `SuperAdminCap` ID and a `VecSet<ID>` of
at most 16 active routine `AdminCap` IDs.

The active `SuperAdminCap` can grant and revoke routine admins and manage its
own delayed transfer. It does not authorize routine package or vault changes.
Grant rejects the zero address and a full registry. Revocation removes the ID
immediately without requiring possession of the cap. A cap owner can destroy
an active or already revoked `AdminCap`; destruction emits whether it also
removed live membership.

`acl::sign_in` checks the shared package version and active registry membership,
then returns a drop-only `AdminWitness`. The witness authorizes:

- package-capability attachment;
- exact-digest native upgrade authorization;
- irreversible restriction to additive upgrades;
- operational package-version activation; and
- redemption-fee changes.

Native upgrade commit remains authorized by the matching non-forgeable
`UpgradeReceipt`, not by either admin capability.

### Construct, attach, then finalize

Package custody uses a staged, single-purpose lifecycle in one programmable
transaction:

```move
let witness = authority.sign_in(package_version, admin_cap);
let mut package_admin = package_admin::new(publisher, upgrade_cap, ctx);
package_admin.add_capability(package_version, &witness, fun_metadata_cap);
package_admin.add_capability(package_version, &witness, blast_metadata_cap);
package_admin.add_capability(package_version, &witness, display_cap);
package_admin.share();
```

`new` validates and stores only the fixed Publisher and UpgradeCap identity.
It returns a `key`-only object, so incomplete custody cannot be transferred,
stored, or dropped. Each generic `add_capability<Capability: key + store>` call
performs exactly one authorized attachment under
`CapabilityKey<Capability>`. It uses `dynamic_object_field`, rejects a second
child of the same exact type, and emits `PackageCapabilityAdded` with the
parent ID, child ID, and original fully qualified type.

`share` is the terminal irreversible step. It first requires
`MetadataCap<FUN_SUI>`, `MetadataCap<BLAST_SUI>`, and
`DisplayCap<BlastSuiDepositReceipt>`, then shares the parent and emits its fixed
creation state. New capability types can be attached before `share` without
changing `PackageAdmin`'s declared fields. The same admin-authorized primitive
can attach a new exact capability type to the shared parent after publication.
No function releases or borrows an attached capability.

This is the **construct–attach–finalize** pattern: keep each function
single-purpose, keep irreversible publication terminal, and let one PTB compose
resources returned by independent calls.

## Alternatives considered

**Use `SuperAdminCap` for every privileged call.** Rejected: it turns a cold
membership root into a hot operational key and makes routine revocation less
useful.

**Let every `AdminCap` authorize itself without registry sign-in.** Rejected:
the root could not revoke a lost or compromised cap without possessing it.

**Keep one `wrap` function with every required capability parameter.**
Rejected: it couples validation, attachment, and sharing; every future child
type changes the constructor ABI; and independently returned children are less
composable.

**Store child capabilities in ordinary dynamic fields.** Rejected: these are
objects with `UID`s. `dynamic_object_field` preserves child-object ownership
and discoverability by object ID.

**Allow sharing incomplete custody.** Rejected: the missing launch capability
could no longer be added through the intended pre-publication lifecycle.

## Consequences

- The root can stay cold after it provisions routine operators.
- An operator uses one sign-in witness across several routine calls in the same
  transaction.
- Revocation affects the next sign-in immediately. An already-created witness
  cannot escape its transaction because it lacks `store`.
- `PackageAdmin` retains a stable fixed layout while its owned capability set
  can grow by exact type during bootstrap or after publication.
- Deployment tooling must use `new`, one `add_capability` call per child, and
  `share` in order. The transaction aborts atomically if any stage fails.
- `PackageCapabilityAdded` is the replay source for dynamic child identity;
  `PackageAdminCreated` remains the replay source for fixed parent state.

## Verification

- ACL tests cover delivery, bounded capacity, live sign-in, immediate
  revocation, active-cap destruction, and revoked-cap destruction.
- Package-admin tests cover canonical provenance, staged construction, required
  child checks, exact-type duplicate rejection, future capability attachment,
  admin-witness authorization, and native receipt-authorized commit.
- Vault tests use `AdminWitness` for fee changes and reject a witness from a
  foreign authority registry.
- The SDK's frozen ABI, decoders, and reducer project routine-admin membership
  and exact typed package-capability attachments.
- Both build environments, warning-as-error lint, the complete Move suite,
  source boundaries, coverage, and `git diff --check` must pass under Sui CLI
  `1.77.2-51d177ad7d65`.
