# 0020: Admin-cap self-destruction and voluntary renunciation

- Status: accepted
- Date: 2026-08-23
- Amends: [0001](0001-sui-package-and-module-layout.md), [0007](0007-acl-pause-and-versioning.md), [0011](0011-event-schema-and-replay.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0018](0018-authority-module-separation.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |
| `interest-acl@91e2f4f` | `91e2f4f83626c1cb924bac246932574501c21bf8` | interest-protocol/interest-mvr |

## Context

An `AdminCap` has `key, store`, so its holder owns a storage-bearing object independently of whether
the singleton `ProtocolAuthority` still recognizes its id. Root revocation must remain immediate and
must not require the root to possess that object. Consequently, root revocation can leave an inert cap
in its holder's account.

The holder also needs a direct way to renounce an active role. Requiring the cold root to revoke every
voluntary departure adds coordination and prevents a revoked holder from deleting the residual object
for its storage rebate.

## Decision

`acl::destroy_admin_cap` is a public holder-driven lifecycle transition. It receives the shared
`&mut ProtocolAuthority` and an owned `AdminCap`:

1. derive the cap id and check its current registry membership once;
2. remove the id when it is still active;
3. delete the cap UID in both the active and already-revoked branches; and
4. emit `AdminDestroyed { authority_id, admin_cap_id, was_active }` through the generic event wrapper.

The transition does not require `SuperAdminCap` and does not abort merely because membership was
already removed. Possession of the owned cap is the authorization to destroy that object. The
`was_active` event field distinguishes voluntary renunciation, which also changes registry state, from
storage cleanup after a prior `AdminRevoked` fact. The final state in both branches is an absent registry
entry and a deleted cap object.

Root `revoke_admin` continues to emit only `AdminRevoked`, because that transition removes membership
without possessing or deleting the cap. Active self-destruction emits only `AdminDestroyed`; emitting a
second `AdminRevoked` fact would represent one membership removal twice.

An `AdminWitness` produced before destruction in the same programmable transaction remains valid for
that atomic transaction. Destruction prevents every future sign-in, matching the existing witness
semantics for root revocation.

## Alternatives considered

**Require the root to delete an admin cap.** Rejected: the root generally does not own the cap, and root
revocation must not depend on cooperation from its holder.

**Abort when the cap is already revoked.** Rejected: it permanently blocks storage cleanup in exactly
the case where an inert cap remains after root revocation.

**Delete the cap without an event.** Rejected: indexers could not distinguish an active holder's
voluntary renunciation from an admin that merely stopped transacting.

**Emit both `AdminRevoked` and `AdminDestroyed` for active self-destruction.** Rejected: one operation
would produce two completed facts for the same membership removal and complicate replay reducers.

## Consequences

- An admin holder can irreversibly renounce routine authority without root coordination.
- An already-revoked holder can always delete the inert object and receive its storage rebate.
- The active-admin bound is released immediately on active self-destruction.
- Indexers can reduce root revocation and holder destruction as distinct lifecycle facts.
- No new error code or persistent field is required.

## Verification

- An active cap can be destroyed, emits `was_active = true`, and its id can no longer be revoked because
  it is absent from the registry.
- An already-revoked cap can still be destroyed and emits `was_active = false`.
- The test-only cap-deletion bypass is removed; test cleanup exercises the production transition.
- Structural checks require the public dot-syntax path and reject reintroduction of the bypass.
- Build, strict lint, all tests, coverage, and structural checks pass with the pinned toolchain.
