# Delayed UpgradeCap manager

A standalone, framework-only manager holds several native UpgradeCaps. Each cap
has one independent pending action: upgrade an exact native digest, or make its
target immutable. Both wait 48 hours from that cap's request transaction. Several
upgrades and immutability requests can wait together, including requests queued
in the same PTB. Every action selects the original UpgradeCap ID, which remains
stable when its target's package ID changes.

## Authority and custody

The shared, key-only manager owns an ObjectTable of native caps, preserving their
original object IDs and discoverability. Its transferable ManagerCap authorizes
additional enrollment, requests and cancellation for every cap in that manager.
Mature actions are executable by anyone. A manager supports at most 256 active
caps, with at most one pending request per cap. Operations use individual lookups
and never iterate over the collection. Burning a cap frees an enrollment slot.
Independent requests still share Sui transaction ordering on the same manager.

The raw caps are never lent or withdrawn. Upgrade execution returns the native
linear UpgradeTicket; its native Upgrade command and matching receipt commit
must finish in the same PTB. The native VM checks the actual module/dependency
bytes against the stored digest. Commit derives the cap ID from the native
receipt. Several tickets may be outstanding in the same PTB and committed in
any order. Incomplete tickets, missing commits and failed commands roll back
all effects. Each cap's native policy restrictions are preserved.

Making one target immutable removes and destroys only its native cap, custody
field and pending request. Other caps and requests, the manager, object table and
controller survive. The manager can accept caps even after its last cap is burned.
Native immutability permanently ends target upgrades; it does not freeze
application objects or migrate them. Check required exits and dependency routes
before requesting it.

Keep the controller address-owned by its intended custodian; sharing or freezing
it exposes its borrowed authority. Transfer preserves all pending requests. Its
holder may destroy it to renounce enrollment, request and cancellation authority
for every managed cap. Pending actions remain executable after maturity. Idle
caps become inaccessible if the sole controller is lost or destroyed; this does
not perform native cap destruction.

## Manager package immutability

Enrollment does not prove or enforce immutability of the manager package itself.
Before enrolling valuable caps, destroy the manager package's own original
UpgradeCap with Sui's native make_immutable operation. Publish its transaction
digest and verify the actual effects against the expected original cap and package,
exact reviewed bytecode and single-generation history. A digest alone is not
verification. No proof object or custom sealing function is needed. Enrolling
the manager's own cap into itself is not a substitute for destroying it.

## Prepared flow

This procedure records no publication, transaction or live-cap selection.

1. Review the exact manager package, publish it, and destroy its own native cap.
   Verify and publish the immutable publication's identities and deletion evidence.
2. Call new with the first raw target cap, share the returned manager, and transfer
   its controller to the intended custodian. That controller can add more caps
   through add_upgrade_cap. Verify original cap IDs and custody below the embedded
   ObjectTable UID. No Blast Publication is needed.
3. Request an exact native 32-byte upgrade digest for a chosen cap ID, or request
   that cap's target immutability. Each emits its own request timestamp and deadline.
   Publish reproducible upgrade artifacts for observers; a Git hash is not the
   native upgrade digest. Repeat for other caps without waiting for earlier requests.
4. At or after a cap's deadline, authorize its upgrade, consume the ticket in the
   native Upgrade command, and commit its receipt to this manager. Alternatively,
   execute that cap's mature immutability request. Verify the selected native cap
   and fields are deleted while the manager and other caps remain available.

Cancel a particular cap's request explicitly before replacement; only its delay
restarts. Cancellation is permitted after maturity until execution wins native
ordering and has no execution priority. Requests have no expiry. A cap with an
outstanding native ticket cannot be enrolled or receive a new request. Other caps
remain usable; a new request for that cap can begin after its receipt commits,
including in the same PTB. There is no delay setter, emergency bypass, raw-cap
return or policy setter. Business-version activation, dependency relinking and
state migrations remain target-specific obligations.

Local verification uses the scoped Move suite and the upgrade_cap_manager Rust
target in sui/launchpad/ptb_tests under workspace resource guards. The fixture
under fixtures/upgrade_target is a local test input only. See
[ADR 0140](../../docs/decisions/0140-upgrade-cap-manager.md) and the generated
[integrator reference](../../llms/upgrade-cap-manager.txt).
