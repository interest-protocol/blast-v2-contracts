## Delayed UpgradeCap manager

A framework-only manager holds several native UpgradeCaps. Each cap can have
one pending exact-digest upgrade or terminal immutability request. Both wait a
full 48 hours from their own request transaction. Several upgrades and
immutability requests may wait concurrently, including requests created in one PTB.

### Objects, authority and enrollment

`blast_upgrade_cap_manager::UpgradeCapManager` is shared and holds an ObjectTable
of up to 256 active caps, keyed by original UpgradeCap ID. Original cap objects
remain discoverable below the embedded table UID. Requests are dynamic fields
on the manager UID, keyed by that same cap ID. A package ID changes on upgrade;
the original cap ID used to select actions does not.

Its transferable `blast_upgrade_cap_manager::ManagerCap` authorizes enrollment,
requests and cancellation for every cap in that manager. Keep it address-owned;
sharing or freezing it exposes that borrowed authority publicly. Losing or
destroying it prevents further enrollment, requests and cancellation across all
managed caps. Already pending actions remain permissionlessly executable.

Independently verify the manager publication immutable before valuable enrollment:
destroy its own original native cap directly through Sui, verify its actual effects,
cap/package binding, bytecode and publication history, and publish the transaction
digest as an evidence locator. No proof object or enrollment gate enforces this.

1. First cap holder: call `blast_upgrade_cap_manager::new` with a native cap,
   share its returned manager through `blast_upgrade_cap_manager::share`, and
   transfer its returned controller to the custodian in the same PTB.
   `blast_upgrade_cap_manager::ManagerCreated` identifies manager and controller.
2. Matching controller holder: call `blast_upgrade_cap_manager::add_upgrade_cap`
   with manager, controller and an additional native cap. The original cap ID is
   derived from the supplied object. Each enrollment, including the first, emits
   `blast_upgrade_cap_manager::UpgradeCapAdded` with cap ID, package and policy.
   No Blast Publication, OTW or target package import is needed. A cap with an
   outstanding native ticket is rejected. Burning a cap frees an enrollment slot;
   even a manager whose last cap was burned can enroll again.

### Independent requests and cancellation

Matching controller holder:

- Call `blast_upgrade_cap_manager::request_upgrade` with manager, controller,
  selected UpgradeCap ID, exact native 32-byte digest and immutable Clock at 0x6.
  Compute the digest from actual modules and dependency package IDs through Sui
  tooling. Publish reproducible artifacts for observers; a source commit is not
  the native digest. `blast_upgrade_cap_manager::UpgradeRequested` records the
  cap ID, digest, request timestamp and deadline.
- Alternatively call `blast_upgrade_cap_manager::request_make_immutable` with
  manager, controller, selected cap ID and Clock. Its
  `blast_upgrade_cap_manager::ImmutabilityRequested` event records that cap's
  timestamp and deadline. Check required application exits and dependency routes
  before permanently ending native upgrades.
- Call `blast_upgrade_cap_manager::cancel_request` with manager, controller and
  cap ID to cancel only that cap's action. Cancellation is allowed after maturity
  until execution wins transaction ordering; it has no priority over execution.
  `blast_upgrade_cap_manager::RequestCancelled` preserves cap ID, original action
  and original deadline. Explicit cancellation is required before replacement,
  which starts a fresh full delay. Other caps' deadlines never reset.

### Upgrade execution

Anyone, without a controller, may execute a mature upgrade:

1. Call `blast_upgrade_cap_manager::authorize_upgrade` with manager, selected
   cap ID and Clock. It consumes only that cap's request and returns a native
   UpgradeTicket bound to the stored digest and the cap's native policy.
2. Feed the ticket into the native Upgrade command with exact modules,
   dependencies and the cap's current package ID. Different bytes/dependencies
   or a policy-incompatible upgrade abort. The result is a native UpgradeReceipt.
3. Call `blast_upgrade_cap_manager::commit_upgrade` with manager and receipt.
   The native receipt determines the cap ID; callers cannot redirect it. The
   `blast_upgrade_cap_manager::UpgradeAuthorized` and
   `blast_upgrade_cap_manager::UpgradeCommitted` events identify the cap and
   consumed digest/deadline or new package/version, respectively.

Several caps may have native tickets outstanding in one PTB and commit in any
order. Every ticket and receipt must be consumed in that PTB. Any failure rolls
back requests, native cap state and events atomically. A new request for a cap
with an outstanding ticket is rejected; other caps remain usable. After that
receipt commits, a fresh request for the same cap can begin, including in the
same PTB. Target business-version activation and migration are separate.

### Per-cap immutability and controller cleanup

Anyone may call `blast_upgrade_cap_manager::make_immutable` with a mutable manager
reference, selected cap ID and Clock after its immutability request matures. It
removes and destroys only that native cap, its custody field and pending request,
and emits `blast_upgrade_cap_manager::PackageMadeImmutable`. The manager,
ObjectTable, controller, other caps and their pending requests survive. It ends
native upgrades for the selected target; application objects retain their own
rules. An upgrade request cannot authorize immutability, or vice versa.

The controller holder may call `blast_upgrade_cap_manager::destroy_cap` to
renounce enrollment, request and cancellation authority for the entire manager.
All pending actions remain executable. Idle native caps become inaccessible if
the sole controller is destroyed; controller destruction does not burn those caps.

### Time, state and failures

Every request stores canonical Clock plus 172,800,000 milliseconds. Execution is
allowed inclusively at that deadline and has no expiry. Overflow is rejected.
Independent deadlines still use Sui's ordering on the shared manager.

`blast_upgrade_cap_manager::pending_request` takes manager and cap ID and returns
that cap's optional request (none when idle or no longer managed).
`blast_upgrade_cap_manager::action` and `blast_upgrade_cap_manager::ready_at_ms`
read its action and deadline. Outside code cannot extract or mutably borrow a
managed cap. Individual actions perform bounded lookups without iterating caps;
pending requests cannot exceed the number of enrolled caps.

Wrong controllers, unknown or removed caps, duplicate/absent requests, wrong
actions, malformed digests, overflow, early execution and excess enrollment
abort. Native digest, policy and receipt checks remain enforced. There is no
raw-cap withdrawal, loan, delay setter, policy setter or emergency bypass. The
package charges no protocol fee; ordinary Sui costs apply.
