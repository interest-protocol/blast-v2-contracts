# 0032: Package administration custody and admin-authorized upgrades

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

Sui returns address-owned `Publisher` and `UpgradeCap` objects when Blast is
published. Leaving either capability under a deployment key creates avoidable
offchain custody: the Publisher may later be required by package-provenance
features, while the raw UpgradeCap would let that key bypass Blast's live,
revocable administration model.

The pinned framework keeps the capabilities independent. A `Publisher` records
the original package and module that claimed it, while an `UpgradeCap` records
the current package version ID, version number, and irreversible policy ceiling
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:79-99`).
The framework's public UpgradeCap functions are callable with receiver syntax,
including its `version` reader
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:7-36,189-199`).

Upgrade authorization temporarily clears the cap's package field and returns a
hot `UpgradeTicket` bound to the cap, package, policy, and digest. The native
upgrade command returns a hot `UpgradeReceipt`; committing the matching receipt
restores the new package ID and increments the cap version
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:273-308`).
The framework permits policy movement only from compatible to additive and then
to dependency-only; it exposes no operation that loosens policy
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:243-266`).

Walrus validates that an incoming raw `UpgradeCap` belongs to its own package
before wrapping it (`walrus@3c1cacc:contracts/walrus/sources/init.move:42-59`).
It stores the cap in a shared manager and separates authorization from receipt
commit (`walrus@3c1cacc:contracts/walrus/sources/upgrade.move:61-94,134-188`).
Walrus also retains its Publisher in shared protocol custody, although its
display concern—not its upgrade manager—owns that object
(`walrus@3c1cacc:contracts/walrus/sources/init.move:19-64`,
`walrus@3c1cacc:contracts/walrus/sources/display.move:22-40`). Blast does not yet
have a display concern, but it should still remove both package capabilities
from deployment-key custody without inventing an unrelated feature owner.

## Decision

### One package-administration object

Add `blast_fun::package_admin` with one shared, non-storable `PackageAdmin`.
It stores:

- the Publisher claimed by `blast::init`;
- the package's framework `UpgradeCap`; and
- `admin_authorization_enabled`, initialized to `true`.

Public `package_admin::wrap` consumes both capabilities in one deployment-time
call. Before creating or sharing any state it requires the Publisher to have
been claimed by `blast::BLAST`'s original module and requires the UpgradeCap's
current package ID to equal `type_name::original_id<blast::BLAST>()`. The latter
also intentionally rejects a cap already used for a direct upgrade before
wrapping. Neither capability has a release, transfer, burn, or public borrow
path after intake. A future package feature may add a narrowly reviewed
package-only Publisher use, but no speculative getter is exposed now.

This boundary is named for package administration rather than only upgrades
because it deliberately retains both framework capabilities. The small
`blast` module remains the OTW and initial Publisher-claim bootstrap; package
administration owns durable custody after the publisher calls `wrap`.

Production code uses receiver syntax for capability operations, including the
framework's additive/dependency-only restriction functions and the public
`version` reader.

### Interim admin authorization and policy restriction

`authorize_upgrade` accepts `&mut PackageAdmin`, a borrowed `AdminWitness`, and
the exact 32-byte package digest. It first requires that routine-admin package
administration remains enabled, validates the digest, and authorizes under the
wrapped cap's current policy. A caller cannot request a different policy.

`restrict_to_additive` and `restrict_to_dependency_only` accept the manager and
an `AdminWitness`. Both require the routine-admin path to remain enabled and
require the requested policy to be strictly more restrictive than the current
one before invoking Sui's irreversible restriction. Equal or looser requests
abort with a stable Blast error before mutation, and each successful transition
emits its previous and new policy. There is intentionally no generic policy
setter and no operation that restores a more permissive policy.

This means **any currently active routine Blast admin can authorize arbitrary
replacement code allowed by the current policy and can permanently narrow that
policy**. This is materially stronger than configuration authority and must be
reflected in operational custody of every `AdminCap`.

`commit_upgrade` accepts only the manager and framework `UpgradeReceipt`. It
does not redundantly require `AdminWitness`: the non-droppable receipt is bound
to the exact cap and can exist only after authorization earlier in the same
programmable transaction.

The complete upgrade transaction is:

1. `acl::sign_in` produces `AdminWitness` from the live registry and admin cap;
2. `package_admin::authorize_upgrade` returns a ticket for the exact digest;
3. the native Sui upgrade command consumes the ticket and returns a receipt;
4. `package_admin::commit_upgrade` consumes the receipt and restores the cap.

### Irreversible governance cutover

`package_admin::disable_admin_authorization` is package-visible, not public. It
exists so an approved governance module added in a later package version can
atomically install its replacement authority and then retire the original
routine-admin path. The operation changes `admin_authorization_enabled` from
`true` to `false`, emits a typed completion fact, and rejects repetition.

There is no inverse operation. Once false, the version-one admin authorization
function and both version-one admin policy-restriction functions permanently
abort, including when called through old published bytecode. The flag does not
itself authorize governance upgrades; the later governance design must add its
own ticket-authorization path before performing the cutover. Adding governance
without calling this operation would leave the original admin path active.

### Events and release boundary

Creation emits one complete `PackageAdminCreated` fact containing the manager,
Publisher, and UpgradeCap IDs plus package ID, version, policy, and enabled
state. Upgrade authorization and commit retain their exact-digest and version
facts. Policy restriction emits old/new values, and governance cutover emits
`PackageAdminAuthorizationDisabled` as the irreversible completed fact.

Before public deployment, every mutable shared protocol object must have the
version/package gate required by ADR 0007, and the upgrade/migration flow must
advance those gates so old entrypoints cannot bypass a fix.

## Alternatives considered

**Leave either capability address-owned.** Rejected: it preserves unnecessary
deployment-key authority or custody after protocol initialization.

**Keep Publisher in an unrelated placeholder feature.** Rejected: no such
feature exists. The package-administration object truthfully owns both package
capabilities until a concrete Publisher use is designed.

**Store the capabilities in ProtocolAuthority.** Rejected: ACL membership and
package capabilities have distinct lifecycles. Combining them would enlarge the
root/admin state and entangle access review with framework hot-potato handling.

**Expose a mutable policy setter.** Rejected: Sui policy restriction is
irreversible. Explicit additive and dependency-only transitions make the
available state changes and their authority reviewable.

**Let an AdminWitness disable its own path.** Rejected: routine administration
should not be able to accidentally or maliciously brick its only upgrade route.
Only package code can perform the cutover, allowing a later governance module
to establish replacement authority in the same reviewed transition.

**Require AdminWitness again at commit.** Rejected: it adds no authority; the
matching hot receipt already proves that this exact cap authorized the upgrade.

**Copy Walrus quorum and emergency governance now.** Rejected for this slice:
Blast has no accepted validator committee, DAO, delay, or recovery design. The
shared custody and authorize/commit split are reusable, while governance needs
its own ADR.

## Consequences

- Both package capabilities leave deployment-key custody after one validated
  wrap and cannot be extracted through the public ABI.
- An active routine admin is package code authority under the current policy
  and may irreversibly narrow that policy while its path is enabled.
- Policy can never be loosened; dependency-only effectively prevents future
  Blast bytecode changes while still allowing dependency updates.
- Governance cutover is one-way. Setting the flag false without first adding a
  replacement authorization path would permanently remove Blast's ability to
  issue new upgrade tickets from the wrapped cap.
- A package upgrade is not a rollback: earlier bytecode remains published, so
  shared-state version gates remain mandatory.

## Verification

- Intake accepts the Publisher and UpgradeCap for Blast, emits their complete
  custody fact, and rejects a Publisher from another module or cap for another
  package before state creation.
- No public or test-only escape hatch releases either wrapped capability.
- A live admin authorizes an exact 32-byte digest; malformed digests, revoked
  admins, and a retired admin path abort with stable errors.
- Additive and dependency-only restrictions succeed in order, emit old/new
  policy, and equal, looser, or post-cutover admin requests abort before mutation.
- A framework test upgrade increments the wrapped cap version, while a receipt
  produced for another cap fails the framework binding check.
- Package-only cutover succeeds once, emits its completion fact, cannot be
  reversed, and prevents the original authorization and policy paths.
- Structural checks require the Publisher-plus-cap-plus-flag layout, provenance
  checks, receiver syntax, one-way cutover, and absence of capability release or
  admin re-enable operations.
- Build, warnings-as-errors lint, and the full Move suite pass against the pinned
  toolchain.
