# Walrus `UpgradeCap` custody and Publisher handling

- Date: 2026-08-25
- Status: primary-source research
- Interpreted reference: `MystenLabs/walrus`
- Walrus pin: `3c1cacc11c9292ed498f01f798cf790f02ea5062`
- Sui framework pin: `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

## Name resolution

“Warros” is ambiguous and does not identify a repository by itself. This note
interprets it as **Walrus** because the pinned `MystenLabs/walrus` Move package
implements every behavior in the question: it receives the package
`UpgradeCap` during second-stage initialization, proves the cap belongs to the
Walrus package, wraps it, exposes an emergency authorization path, and retains a
`Publisher`
([Walrus initializer](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/init.move#L19-L64),
[Walrus upgrade manager](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/upgrade.move#L61-L94)).
If a different repository was intended, its URL is needed before treating its
code as precedent.

## What Walrus does

### It keeps the Publisher, but not with the upgrade capability

Walrus declares `INIT` as its OTW, consumes it through `package::claim`, stores
the resulting `Publisher` inside a one-use `InitCap`, and transfers that
`InitCap` to the publishing sender
([`walrus@3c1cacc:contracts/walrus/sources/init.move:19-37`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/init.move#L19-L37)).
Its later `initialize_walrus` call consumes the `InitCap`, deletes its UID, and
passes the Publisher to the display concern before wrapping the `UpgradeCap`
([`init.move:42-64`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/init.move#L42-L64)).

The display module borrows that Publisher to create three framework `Display`
objects, then stores the Publisher in an `ObjectBag` inside a shared
`ObjectDisplay`. The Publisher is therefore retained for the display concern;
it is not a field of `UpgradeManager`
([`display.move:22-40`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/display.move#L22-L40),
[`display.move:43-86`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/display.move#L43-L86)).

This differs from Blast's final design in ownership concern, not in provenance
semantics. Blast's [`blast.move`](../../sui/sources/blast.move) uses
`claim_and_keep`, so the publishing sender owns the retained Publisher only
until the deployment-time `package_admin::wrap` call moves it into the shared
package-administration object. Walrus gives Publisher to its concrete display
concern; Blast keeps it in neutral package custody until a concrete feature is
approved.

### It validates the raw UpgradeCap before wrapping it

`initialize_walrus` reads `upgrade_cap.package()` and compares it with the
defining package address of Walrus' own `InitCap`. A mismatch aborts with
`EInvalidUpgradeCap`
([`init.move:10-15,42-59`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/init.move#L10-L59)).
This is the important package-provenance check to adapt: ownership of some
`UpgradeCap` is insufficient; it must be the capability for this package.

After that check, package-only `upgrade::new` moves the raw cap into a shared
`UpgradeManager` and returns an owned `EmergencyUpgradeCap` bound to that
manager's object ID
([`upgrade.move:61-94`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/upgrade.move#L61-L94)).
The raw framework capability is no longer address-owned or directly usable.

### Authorization and commit are separate steps

Walrus has two ticket-authorization paths:

- the normal path removes a current-epoch proposal, checks quorum and the next
  version, then calls `UpgradeCap.authorize` with the cap's current policy and
  the approved digest
  ([`upgrade.move:134-154`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/upgrade.move#L134-L154));
- the emergency path checks that the supplied `EmergencyUpgradeCap` names this
  exact manager, then calls the same framework authorization method
  ([`upgrade.move:156-171`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/upgrade.move#L156-L171)).

The upgrade PTB threads the returned `UpgradeTicket` through the native upgrade
command and gives the resulting `UpgradeReceipt` back to
`commit_upgrade`. Walrus records the new package ID in its two version-gated
shared objects and then commits the receipt into the wrapped framework cap
([`upgrade.move:173-188`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/upgrade.move#L173-L188)).
Its tests exercise both the emergency
authorize → upgrade → commit sequence and the quorum sequence
([`upgrade_tests.move:13-39`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/tests/upgrade_tests.move#L13-L39),
[`upgrade_tests.move:41-76`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/tests/upgrade_tests.move#L41-L76)).

Walrus can irreversibly burn the emergency capability, after which its old
emergency authorization function can no longer be satisfied and upgrades rely
on quorum governance
([`upgrade.move:209-218`](https://github.com/MystenLabs/walrus/blob/3c1cacc11c9292ed498f01f798cf790f02ea5062/contracts/walrus/sources/upgrade.move#L209-L218)).

## What the pinned Sui API guarantees

`Publisher` and `UpgradeCap` are independent framework objects with independent
fields and authority. `Publisher` records the package and module that created
it; `UpgradeCap` records the current package ID, applied version, and upgrade
policy
([`sui@06734f6:package.move:79-99`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move#L79-L99)).
`claim` validates an OTW and returns a Publisher, while `claim_and_keep`
performs the same claim and transfers it to the publishing sender. Public
`from_package<T>` and `from_module<T>` checks use original type identity
([`package.move:133-174`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move#L133-L174)).

The framework deliberately makes `UpgradeTicket` and `UpgradeReceipt` hot
potatoes: a cap can have only one pending authorization, and the receipt must be
committed before the transaction ends
([`package.move:101-131`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move#L101-L131)).
`authorize_upgrade` binds the ticket to the cap ID, package, policy, and digest
and temporarily clears the cap's package field. `commit_upgrade` verifies the
receipt names that same cap, installs the new package ID, and increments the cap
version
([`package.move:273-308`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/package.move#L273-L308)).

One consequence is worth making explicit: a Publisher is proof of the original
package lineage, but it is not a durable equality proxy for
`UpgradeCap.package()`. The Publisher is populated from the OTW's original type
identity, whereas a successful commit replaces `UpgradeCap.package()` with the
new package version's ID. This is an inference from the two framework paths
above. Check the raw cap against Blast's package identity when it first enters
custody; do not repeat a Publisher/cap equality check after every upgrade.

## Blast comparison and recommendation

Blast already has the two prerequisites:

- [`blast.move`](../../sui/sources/blast.move) claims and keeps the package
  Publisher separately; and
- [`acl.move`](../../sui/sources/acl.move) exposes `sign_in`, which validates a
  live registered `AdminCap` and returns a non-copyable, non-storable,
  drop-only `AdminWitness`.

The adopted Walrus-informed design is:

1. Add a concern-owning `package_admin` module with a shared, non-store
   `PackageAdmin` containing the framework `Publisher`, `UpgradeCap`, and a
   one-way admin-authorization flag. Do not put this state in ACL.
2. Expose one deployment-time intake that consumes both raw capabilities,
   verifies the Publisher was claimed by the canonical `blast::BLAST` module,
   checks `upgrade_cap.package()` against that marker's defining/original ID,
   then shares the manager. Neither capability may be returned or transferred.
3. For the requested interim policy, expose
   `authorize_upgrade(&mut PackageAdmin, &AdminWitness, digest): UpgradeTicket`.
   It should use the wrapped cap's current policy and exact digest. Any active
   routine Blast admin would then be able to authorize arbitrary code allowed by
   that policy; this materially expands the current routine-admin compromise
   scope and must be accepted explicitly in the upgrade ADR.
4. Expose a separate `commit_upgrade(&mut PackageAdmin, receipt)` that consumes
   the hot-potato receipt and calls the wrapped cap's `commit`. Requiring the
   witness again at commit adds no authorization: an unforgeable receipt already
   proves that the manager authorized the upgrade earlier in the same PTB.
5. Expose explicit admin-witness operations for Sui's only two irreversible
   policy restrictions—additive and dependency-only—and reject equal or looser
   requests before mutation. Do not present framework policy as a mutable value.
6. Make the admin path durably disableable in version 1 with a package-only
   one-way transition. A future governance module must install replacement
   authorization before setting the flag false; every original admin upgrade
   and policy function checks it. Adding governance without disabling the old
   path would not reduce admin upgrade power.

This deliberately departs from Walrus' placement of Publisher in its display
state. Blast currently has no display feature, and shared neutral custody avoids
leaving a unique retained capability under a deployment key while preserving it
for a later reviewed package-provenance use.

If “admin” is intended to mean cold root rather than any routine admin, use a
dedicated upgrade capability or a root sign-in witness instead of reusing
`AdminWitness`. The current `SuperAdminCap` should not be passed directly into
the upgrade module without an ACL-owned validation seam, because possession
alone does not prove it is the live registered root.

## Verification to require with an implementation

- intake rejects an `UpgradeCap` for another package before creating or sharing
  any manager;
- exactly one package-administration object owns the Blast Publisher and
  UpgradeCap, and no public/test-only escape hatch releases either capability;
- a live admin can authorize the exact digest, while revoked and foreign admin
  caps cannot produce the required witness;
- the full ticket → native upgrade → receipt → commit PTB succeeds and a wrong
  receipt/cap pairing aborts atomically;
- any shared-state package/version gate is advanced in the same upgrade flow so
  old entrypoints cannot bypass the new code;
- admin-path retirement is irreversible and makes the original authorization
  and policy functions unsatisfiable; and
- intake proves both Publisher module provenance and UpgradeCap package
  provenance, while the creation fact records their final shared custodian.
