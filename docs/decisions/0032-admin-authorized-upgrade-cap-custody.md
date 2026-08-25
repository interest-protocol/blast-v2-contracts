# 0032: Admin-authorized UpgradeCap custody

- Status: accepted
- Date: 2026-08-25
- Amends: [0001](0001-sui-package-and-module-layout.md), [0007](0007-acl-pause-and-versioning.md), [0011](0011-event-schema-and-replay.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0031](0031-package-witness-and-publisher-custody.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `walrus@3c1cacc` | `3c1cacc11c9292ed498f01f798cf790f02ea5062` | MystenLabs/walrus |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

The focused primary-source comparison is recorded in
[`../research/walrus-upgrade-cap-custody.md`](../research/walrus-upgrade-cap-custody.md).

## Context

Sui returns an address-owned `UpgradeCap` when Blast is first published. Leaving
that raw capability under a deployment key would make package upgrades depend
only on that key and would bypass Blast's live, revocable administration model.
The capability should instead enter protocol-defined custody before the first
upgrade.

The pinned framework keeps `Publisher` and `UpgradeCap` independent. A
`Publisher` records its originating package and module, while `UpgradeCap`
records the current package version ID, version number, and irreversible policy
ceiling (`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:79-99`).
Authorization temporarily clears the cap's package field and returns a hot
`UpgradeTicket` bound to the cap, package, policy, and digest. The native upgrade
command returns a hot `UpgradeReceipt`; committing the matching receipt restores
the new package ID and increments the cap version
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:273-308`).

Walrus validates that an incoming raw `UpgradeCap` belongs to its own package
before wrapping it
(`walrus@3c1cacc:contracts/walrus/sources/init.move:42-59`). It then stores the
cap in a shared `UpgradeManager`; normal quorum authorization and a separate
manager-bound emergency capability issue tickets through that one wrapped cap
(`walrus@3c1cacc:contracts/walrus/sources/upgrade.move:61-94,134-171`). Its
commit path records the new package ID in versioned shared state and commits the
receipt into the cap
(`walrus@3c1cacc:contracts/walrus/sources/upgrade.move:173-188`).

Walrus also retains its claimed `Publisher`, but does so in its display concern,
not in the upgrade manager
(`walrus@3c1cacc:contracts/walrus/sources/init.move:19-64`,
`walrus@3c1cacc:contracts/walrus/sources/display.move:22-40`). Blast currently
has no feature that consumes a Publisher, so ADR 0031's separate address-owned
custody remains the smaller boundary.

## Decision

### Dedicated UpgradeCap custody

Add `blast_fun::upgrade` with one shared `UpgradeManager`. It stores:

- the package's framework `UpgradeCap`; and
- `admin_authorization_enabled`, initialized to `true` and checked by the
  version-one admin authorization path.

Public `upgrade::wrap` consumes a raw `UpgradeCap`, checks that its current
package ID equals `type_name::original_id<blast::BLAST>()`, moves it into the
manager, and shares the manager. Intake of a cap for any other package aborts
before object creation or sharing. The initial deployment must wrap the cap
before any upgrade; a cap already used directly points at a later package
version and is intentionally rejected by this version-one intake check.

The raw cap has no release or transfer path after wrapping. `UpgradeManager`
has `key` but not `store`, so external code cannot place the manager inside
another owned object or extract its capability.

### Interim admin authorization

`authorize_upgrade` accepts `&mut UpgradeManager`, a borrowed `AdminWitness`,
and the 32-byte package digest. It first requires that the durable admin path is
enabled, validates the digest length, reads the wrapped cap's current policy,
and calls the framework authorization function with exactly that policy and
digest. The caller cannot request a more permissive policy.

This deliberately means **any currently active routine Blast admin can
authorize arbitrary replacement code allowed by the wrapped cap's policy**.
That is materially stronger than the existing configuration authority. It is
accepted as the first operational policy requested here, not treated as
equivalent risk to changing a fee or signer key. Root revocation prevents a
revoked admin from producing a witness in a later transaction; a witness
already produced in the same atomic transaction retains the existing ACL
semantics.

`commit_upgrade` accepts only the manager and framework `UpgradeReceipt`. It
does not redundantly require `AdminWitness`: the non-droppable receipt is bound
to the exact cap and can exist only after that manager authorized a ticket
earlier in the same programmable transaction. The framework validates the cap
binding before installing the new package ID.

The complete programmable transaction is:

1. `acl::sign_in` produces `AdminWitness` from the live registry and admin cap;
2. `upgrade::authorize_upgrade` returns `UpgradeTicket` for the exact digest;
3. the native Sui upgrade command consumes the ticket and returns
   `UpgradeReceipt`; and
4. `upgrade::commit_upgrade` consumes the receipt and restores the wrapped cap
   with its incremented version.

### Durable governance seam and release boundary

Version one exposes no quorum, timelock, policy-narrowing, or immutability
operation. The stored `admin_authorization_enabled` flag is nevertheless part of
the initial layout and the original authorization function checks it. A later
approved governance path can irreversibly set it to `false`; doing so will also
disable the old version-one admin authorization bytecode. Adding a governance
path without disabling this original path would not reduce admin upgrade power.

This manager is the package-upgrade custody and authorization primitive, not the
complete shared-state migration design. Before the first public deployment,
every mutable shared protocol object must have the version/package gate required
by ADR 0007, and the upgrade/migration flow must advance those gates so old
package entrypoints cannot bypass a fix.

### Publisher remains separate

`Publisher` is not stored in `UpgradeManager` and is not used as a repeating
equality proxy for the cap. `blast::init` continues to deliver it to the
publishing sender. The existing test proves it belongs to `blast_fun`; any
future feature that accepts an arbitrary Publisher must call
`publisher.from_package<blast::BLAST>()` at that feature boundary.

## Alternatives considered

**Leave UpgradeCap address-owned.** Rejected: it bypasses revocable onchain
administration and makes a deployment key the complete code authority.

**Store UpgradeCap in ProtocolAuthority.** Rejected: package upgrades are a
distinct authority and lifecycle concern. Embedding the cap would enlarge ACL
state and make root/admin review inseparable from framework hot-potato handling.

**Require AdminWitness again at commit.** Rejected: it does not add authority.
Only the matching hot receipt can satisfy commit, and that receipt exists only
after the gated authorization earlier in the same transaction.

**Store Publisher beside UpgradeCap.** Rejected: Walrus keeps Publisher for its
display concern, not upgrade authorization. Blast has no current publisher-gated
feature, and the original package ID provides the one required intake check.

**Copy Walrus quorum and emergency governance now.** Rejected for this slice:
Blast has no validator committee or accepted governance design. The shared cap
custody and authorize/commit split are the reusable mechanics; authority remains
Blast's requested `AdminWitness` until a later ADR replaces it.

**Omit the durable admin-path flag and add governance later.** Rejected: old Sui
bytecode remains callable. A later quorum path would be cosmetic if version-one
admin authorization could still issue tickets from the same manager.

## Consequences

- The raw Blast `UpgradeCap` becomes inaccessible after one validated wrap.
- An active routine admin becomes package code authority under the cap's current
  policy; operational custody must treat every `AdminCap` accordingly.
- The manager adds one shared object and no persistent proposal collection.
- Publisher, upgrade, ACL, and future governance custody stay separate.
- A later irreversible admin-path retirement is layout-compatible, but its
  replacement authority, delay, and recovery policy still require a new ADR.
- An upgrade is not a rollback: previous package versions remain published, and
  shared-state gates remain mandatory before release.

## Verification

- Intake accepts a test cap for Blast's original package and emits the manager,
  cap, package, policy, version, and enabled-state creation fact.
- Intake rejects a cap for another package with the stable Blast error before
  sharing a manager.
- A real `AdminWitness` authorizes an exact 32-byte digest; malformed digest
  lengths and a disabled admin path abort with stable Blast errors.
- The framework test upgrade converts the ticket to a receipt, commit increments
  the cap version, and wrapped events record authorization and completion.
- A receipt produced for another manager aborts on the framework cap-binding
  check and changes no state.
- Structural checks require package-ID validation, the UID-plus-two-state-field manager layout,
  `AdminWitness` only on authorization, no raw-cap release function, and no
  Publisher coupling.
- Publisher provenance remains covered independently by `blast_tests.move`.
- Build, warnings-as-errors lint, and the full Move suite pass against the
  pinned toolchain.
