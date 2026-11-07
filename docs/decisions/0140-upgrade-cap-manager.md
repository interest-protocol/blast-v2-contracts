# 0140: Digest-bound delayed UpgradeCap management

- Status: accepted
- Date: 2026-11-07
- Owner decision: Jose requested a generic native UpgradeCap manager. Upgrades
  bind a digest; upgrades and terminal immutability each require 48 hours from
  their own request. The manager's own cap is destroyed directly, with verified
  transaction evidence, rather than an on-chain proof object.
- Scope: unpublished package and local verification. No publication, transaction,
  live-cap transfer or release approval is authorized.
- Amends: ADR 0137's external authority options for raw caps. Existing deployment
  custody and the terminal choice for each live target are separate decisions.

## Context

An upgrade of Blast admin can change the ACL and delay implementation used by
its dependents. Admin defines no Publication for itself. External custody must
therefore be independent of Blast's upgradeable administration boundary.

A generic delayed withdrawal is smaller, but releasing the raw cap permits
unrestricted later upgrades. Lending the raw cap against a return receipt still
allows an arbitrary digest during the loan. The selected boundary commits to the
exact native upgrade digest and never releases raw authority.

## Decision

Use one framework-only package, intended to be made immutable before valuable
enrollment by destroying its own original native cap. Verify exact publication
bytes, history, cap deletion and normalized transaction effects; publish the
digest as an evidence locator. Enrollment deliberately has no proof-object gate.
Until its own cap is destroyed, manager-package upgrades remain a trust boundary.

Each shared key-only manager owns up to 256 native caps in an ObjectTable and
issues one transferable, instance-bound controller for enrollment, requests and
cancellation across those caps. Every original cap ID stays discoverable. Any
native cap is supported; no Blast ACL, OTW, Publication or target package import
is needed.

Each original cap ID independently holds at most one pending Request as a dynamic
field on the manager UID. Several requests can coexist, including in one PTB;
there is no global pending-action slot. The cap ID is stable across upgrades.
The controller requests one of two mutually exclusive actions per cap: upgrade
an exact 32-byte native digest, or make the target natively immutable. Both store canonical
Clock plus 172,800,000 ms, reject overflow, and execute inclusively at maturity.
Cancellation removes either action, and every replacement starts a fresh wait.
An existing mature action remains executable until cancellation wins ordering.
Cancelling or executing one cap's action never resets another cap's deadline.
Independent deadlines share the manager's transaction ordering.

Upgrade authorization is permissionless after maturity. The cap's existing
native policy applies, and native ticket/receipt resources require atomic Upgrade
and matching commit. The native VM checks the module/dependency digest [S1, S2].
Enrollment and new requests reject the native zero-package sentinel, preventing
outstanding tickets from crossing custody or creating requests for that cap
mid-authorization. Other caps remain usable. Commit derives its cap ID from the
native receipt, allowing multiple outstanding tickets and reverse-order commits.

A mature immutability action removes and destroys the exact native cap, removes
its custody field and pending request. The manager, ObjectTable, controller and
other caps survive, and burning a cap frees an enrollment slot. Even an empty
manager can accept new caps. The bounded collection is never iterated; requests
are bounded by the cap count. A separate controller may be deleted
by its holder. There is no withdrawal, mutable cap borrow, raw-cap loan, delay
setter, emergency bypass or policy setter. No target business-version activation
or state migration is inferred.

## Consequences and verification

Keep controllers in intended address-owned custody. A transferred controller
retains authority over the pending action. A lost or destroyed controller blocks
enrollment, new requests and cancellation for every managed cap; pending actions
remain permissionlessly executable. Destroying the sole controller strands idle
caps without native cap burn. Terminal target immutability is irreversible and
requires checking dependent routes and application exits before requesting it.

Require exact-abort Move tests and actual native simulator PTBs for original
manager-cap burn, generic enrollment, visible custody, controller binding, every
request/action boundary, cancellation, overflow, real upgrades and digest rejection,
incomplete/swapped receipts, outstanding-authorization composition, terminal
cap/field/request deletion and rollback after a later command aborts, independent
per-cap deadlines and cancellation, simultaneous native tickets, isolated burns,
capacity boundaries and reuse after the manager becomes empty. Keep generated
references and CI wiring current. Source review and local tests do not establish
live publication or custody facts.

## Sources

| Ref | Immutable source |
| --- | --- |
| S1 | [Native cap, ticket, receipt and make_immutable](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move) |
| S2 | [Native upgrade command validation](https://github.com/MystenLabs/sui/blob/51d177ad7d65102fc368b582408f466d97b31548/sui-execution/latest/sui-adapter/src/static_programmable_transactions/execution/interpreter.rs) |
