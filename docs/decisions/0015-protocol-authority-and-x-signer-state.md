# 0015: Protocol authority and minimal X signer state

- Status: accepted
- Date: 2026-08-22
- Amends: [0013](0013-creator-fee-authority-and-x-claims.md), [0014](0014-typed-creator-cap-and-diagnostic-modules.md)
- Amended by: [0017](0017-coin-type-domain-for-x-creator-claims.md), [0018](0018-authority-module-separation.md), [0020](0020-admin-cap-self-destruction.md)
- Settles: the protocol-authority and X-signer portions of [0007](0007-acl-pause-and-versioning.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |
| `interest-acl@91e2f4f` | `91e2f4f83626c1cb924bac246932574501c21bf8` | interest-protocol/interest-mvr |
| `openzeppelin@cab1993` | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | OpenZeppelin/openzeppelin-contracts v5.7.0 |

## Context

The first X-claim slice treated its `AdminCap` as authority over one
`XClaimConfig`, so the cap stored that config's object id. Production instead
has one protocol-wide administration domain. Per-config binding adds state and
suggests that multiple independent Blast administrations can exist when the
package one-time witness creates only one authority root.

The first config also persisted `package_id`, a manually supplied `chain_id`, a
signer key id, and an active flag beside the signer public key. The package's
original id is derivable on Sui. A manually entered network string can drift
from the deployment. The active flag duplicates whether a key exists. The key
id is useful only when retired public keys may later be reused.

Memez separates one `SuperAdmin<T>` from revocable `Admin<T>` capabilities. Its
singleton `ACL<T>` registers admin object ids, while each `Admin<T>` contains
only a UID (`interest-acl@91e2f4f:access-control/contracts/sources/access_control.move:15-31,50-92`).
Memez config setters consequently take protocol admin authority without storing
a config id (`memez@00596fd:fun/sources/config.move:28-92`). Memez delays root
transfer, but the current holder completes it unilaterally
(`interest-acl@91e2f4f:access-control/contracts/sources/access_control.move:109-141`).

OpenZeppelin's `Ownable2Step` requires the proposed owner to accept
(`openzeppelin@cab1993:contracts/access/Ownable2Step.sol:13-20,58-66`). Its
stronger default-admin rules combine a singleton root, a two-step transfer,
delay, and cancellation
(`openzeppelin@cab1993:contracts/access/extensions/AccessControlDefaultAdminRules.sol:13-28`).
Blast needs those behaviors expressed through Sui capabilities rather than an
EVM owner-address check.

## Decision

### One protocol authority root

The package initializes exactly one shared `ProtocolAuthority`, one owned
`SuperAdminCap`, and one shared `XClaimConfig`. ADR 0018 assigns those initialization paths to
`acl` and `x_claim_config` independently; the objects do not share storage or a combined creation event.

`ProtocolAuthority` records:

- the currently recognized `SuperAdminCap` object id;
- at most `constants::max_admins!() = 16` active `AdminCap` object ids; and
- at most one pending super-admin transfer.

`SuperAdminCap` and `AdminCap` each contain only a UID. Neither contains a
configuration id. Supplying a capability is not enough by itself: every root
operation checks its object id against the singleton registry. A routine admin
first calls `acl::sign_in`, which checks its `AdminCap` id against that same live
registry and returns an unforgeable `AdminWitness` with `drop` as its only
ability. Feature configuration receives only that witness, not the authority
object and cap again. Revoked admin caps cannot produce a witness in a later
transaction.

The super admin is a cold root. It may add or revoke routine admins and manage
its own transfer. An active `AdminCap` performs routine protocol configuration,
beginning with X signer management. No separate per-config admin exists.

Admin membership is bounded. Adding a seventeenth active admin aborts. Admin
creation deliberately delivers the new capability to the named nonzero
recipient and emits its capability id and recipient. Revocation removes its id
from the registry and does not require possession of the revoked object. A cap
holder may instead destroy its own cap at any time. That transition removes live
membership when present and always deletes the owned object, including after a
prior root revocation, as specified by ADR 0020.

### Delayed, cancellable, recipient-accepted root transfer

Super-admin transfer uses the fixed `constants::super_admin_transfer_delay_ms!()` seven-day delay. The current registered root
cap proposes a nonzero recipient and may cancel or replace the proposal with a
different recipient. Re-proposing the already pending recipient aborts instead
of silently resetting its delay and emitting a false cancel/restart pair. The
proposal stores the recipient and `execute_after_ms` in shared authority state.

After the delay, only that recipient may accept. Acceptance creates and delivers
a new `SuperAdminCap`, updates the recognized root id, clears the proposal, and
thereby invalidates the previous cap atomically. The old cap may be deleted by
its holder only after it is no longer active. Root renunciation is not exposed in
the first release because it can permanently disable recovery and admin
management.

### Minimal X signer state

`XClaimConfig` stores only its UID and `signer_public_key: vector<u8>`.

- An empty key means X claims are disabled.
- A configured key is exactly 32 bytes.
- Setting a key requires an `AdminWitness` freshly obtainable from an active
  protocol `AdminCap` and a value different from the current key.
- Revocation clears the key.
- Every backend signer key is dedicated to one Blast deployment.
- A retired signer key must never be reused.
- Attestations remain short-lived and usable only for a launch's one-time
  `CreatorCap` claim.

There is no `signer_active` field and no signer key id/generation in the first
release. If key reuse, overlapping valid keys, or one key shared by deployments
is later required, that change must first add an explicit signed generation or
domain and its replay tests.

The signed Sui message contains only the canonical original `Meme` type name, X
identity commitment, claimant, and expiry. The key is dedicated to this one
message type and transition, so the payload has no schema version or action tag.
It also has no chain id, Blast package id, or runtime launch id. The EVM mapping
may use its idiomatic EIP-712 chain-id and verifying-contract domain without
forcing those fields into Sui storage. See
[ADR 0017](0017-coin-type-domain-for-x-creator-claims.md).

## Alternatives considered

**Keep `AdminCap.config_id`.** Rejected: target ids are for capabilities that
can manage several same-typed instances. Blast has one package authority root.

**Treat possession of any historical `AdminCap` as sufficient.** Rejected:
without registry membership, revocation is impossible.

**Pass `ProtocolAuthority` and `AdminCap` to every feature setter.** Rejected:
it couples feature modules to ACL storage and cap identity. The drop-only
transaction witness keeps the live membership check in `acl` and the feature
setter's privileged ABI narrow.

**Copy Memez root transfer exactly.** Rejected: its delay is useful, but the
recipient does not accept and the current holder completes the transfer.

**Use only an EVM-style owner address.** Rejected: Sui capability objects are
composable and make delegated authority explicit. The shared registry stores
only what is necessary for revocation and safe root replacement.

**Keep `signer_active`.** Rejected: a key plus a false flag permits contradictory
states. Empty-or-32-bytes represents the same state once.

**Keep the signer key id.** Rejected for the dedicated, never-reused key policy.
The current public key already rejects signatures from a rotated key. A signed
generation becomes necessary only if retired keys can be restored.

**Add a separate Blast package domain.** Rejected by ADR 0017: the signer key is
dedicated to this deployment, while the unique original meme type is the
economic domain shared by the cap and downstream integrations.

## Consequences

- There is one administration domain for the entire protocol, not one per
  config object.
- A routine admin may voluntarily renounce membership, and a previously revoked
  holder may delete the inert cap for its storage rebate.
- A stolen routine admin can change routine configuration but cannot create or
  revive admins or rotate the root.
- A stolen root can schedule a takeover and alter admins, but the public delay
  gives operators time to cancel while the current root remains available.
- The accepted recipient must actively complete root transfer.
- X signer storage has one source of truth and no manually entered network
  value.
- Reusing a retired signer key is forbidden operationally; supporting reuse
  requires a future ABI change.

## Verification

- Initialization creates one shared authority registry, one shared disabled X
  config, and one root cap; it does not create an implicit routine admin.
- The root can add an admin; that admin can sign in and use the resulting
  drop-only witness to set and revoke the X signer.
- A revoked admin fails when it next attempts to sign in.
- Active admin destruction removes registry membership and emits
  `AdminDestroyed.was_active = true`; destruction after root revocation remains
  available and emits `was_active = false`.
- An admin cap registered in another test registry cannot produce a witness.
- The seventeenth admin is rejected.
- Root transfer rejects zero/self recipients, wrong recipients, and acceptance
  before seven days; the current root can cancel or replace with a different
  recipient, while an unchanged recipient is rejected before timestamp work.
- Root-transfer time arithmetic rejects `std::u64::max_value!()` with the stable
  overflow code rather than redeclaring a primitive maximum.
- Successful acceptance invalidates the old root and activates the new one.
- A revoked signer is represented by an empty key and rejects claims.
- Rotation rejects the current key and signatures from the previous key.
- The canonical BCS fixture covers the original meme type and contains no chain
  id, Blast package id, runtime launch id, active flag, or signer generation.
- Build, strict lint, all tests, coverage, and structural diagnostic checks pass
  with the pinned toolchain.
