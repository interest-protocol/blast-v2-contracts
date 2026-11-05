## Administration

### What it is

Package `blast_admin` is Blast's administration layer. It holds one shared
access-control list (ACL) for every Blast package, with one cold root capability
and a Table of administrator capabilities with no inline cardinality limit. Each
administrator holds roles, and a role is a Move type that a consumer package
declares, so a role from one package can never act in another. The package also
provides the delayed-notice primitives Blast's settings embed, and one generic
package administration that every upgradeable Blast package uses: a shared
`PackageVersion<OTW>` that rejects calls into outdated bytecode and holds the
package's pause bits, and a shared `PackageAdmin<OTW>` that seals the package's
`Publisher` and `UpgradeCap` so upgrades happen only through role-gated,
48-hour-notice calls and only the package itself can borrow its `Publisher`. No package can build a second version or PackageAdmin:
both are created only by `blast_admin::package_admin::wrap` from the package's
own publication. Blast publishes `blast_admin` immutable (its `UpgradeCap` is
destroyed in the publish transaction), so none of these rules can change.

### Objects and authority

| Object | Kind | Held by | Authorizes |
| --- | --- | --- | --- |
| `blast_acl::ACL` | shared singleton, created once in `init` | nobody | stores the root cap ID, every live `AdminCap` ID with its roles, and the pending root transfer |
| `blast_acl::SuperAdminCap` | owned, `key` only (cannot be transferred or wrapped by anyone) | Blast's cold root: `init` delivers it to the `blast_acl_root` address in `Move.toml`, not the publisher | grant and revoke admins and roles; start and cancel a root transfer |
| `blast_acl::AdminCap` | owned, `key, store` (transferable, wrappable) | a Blast operator | nothing by itself; `blast_acl::sign_in` turns it into a role witness |
| `blast_acl::AdminWitness<Role>` | transaction-local value, `drop` only | the PTB that signed in | the one role `Role` in every consumer call that takes `&AdminWitness<Role>` |
| `package_version::Publication<OTW>` | owned, `key` only | the publisher, from the package's `init` until wrap | nothing but the one wrap of package `OTW` |
| `package_version::PackageVersion<OTW>` | shared, `key` only, created at wrap | nobody | the version and pause bits package `OTW`'s operations check |
| `blast_admin::package_admin::PackageAdmin<OTW>` | shared, `key` only, created at wrap | nobody | package `OTW`'s sealed `Publisher` (borrowed only by `OTW` itself) and `UpgradeCap`, and its delayed upgrade decisions |

`OTW` is the package's one-time witness type, named as in the framework's
`sui::package::claim<OTW: drop>`, for example the vault's
`blast_vault::blast_vault_package::BLAST_VAULT_PACKAGE`.

`ACL` fields: `super_admin_cap_id` (the one root cap that works), `admins` (a
map from `AdminCap` ID to a set of role type names), and `super_admin_transfer`
(a `delayed_action::DelayedAction<blast_acl::SuperAdminTransfer, address>` with a
fixed seven-day notice; see "Delayed values, actions, sets and maps").

Root powers are narrow: membership, roles, and its own delayed transfer. Root
cannot sign in to any role and cannot call any consumer function. Every
operational action needs an `AdminCap` holding the right role.

### Roles

A role is an ability-free struct. The ACL stores its type name with defining
IDs and type arguments: the address of the package that first declared it, then
module, struct and any type arguments. Same-named roles in different packages,
or with different type arguments, are different roles.

| Declared in | Roles | Used by |
| --- | --- | --- |
| `blast_admin::package_admin` | `blast_admin::package_admin::UpgradeAdmin<OTW>` (schedule, authorize and commit upgrades, schedule and execute immutability, change the upgrade notice), `blast_admin::package_admin::PauseAdmin<OTW>` (set pause bits), `blast_admin::package_admin::UnpauseAdmin<OTW>` (clear pause bits through the package's own unpause), `blast_admin::package_admin::CancelAdmin<OTW>` (cancel the pending upgrade action or notice change) | every upgradeable package, typed by its one-time witness `OTW` |
| `blast_core::blast_domain` | `blast_domain::TreasuryAdmin`, `blast_domain::FeeAdmin`, `blast_domain::ListingAdmin`, `blast_domain::VenueAdmin`, `blast_domain::RewardsAdmin`, `blast_domain::BuybackAdmin`, `blast_domain::CreatorAdmin`, `blast_domain::ClaimSignerAdmin`, `blast_domain::CancelAdmin` | the launch products, the vault and the migrators |
| `blast_partners` | `blast_partners::blast_partners::PartnerAdmin` (register partners, schedule shares and caps) | partners |
| `blast_boosts_core` | `blast_boosts_core::blast_boosts_core::VaultIssuer`, `blast_boosts_core::blast_boosts_core::RiskAdmin`, `blast_boosts_core::blast_boosts_core::ShutdownAdmin`, `blast_boosts_core::blast_boosts_core::UpgradeAdmin` | Boosts |

Two `CancelAdmin` roles exist by design: `blast_admin::package_admin::CancelAdmin<OTW>`
cancels one package's upgrade actions; `blast_domain::CancelAdmin` cancels product
proposals.

### Lifecycle

**Administrator.** `blast_acl::grant_admin` mints a roleless `AdminCap` to a
recipient. `blast_acl::grant_role` and `blast_acl::revoke_role` add or remove
one role at a time. `blast_acl::revoke_admin` removes the cap's entry and all
its roles without needing the cap; the object remains but signs in to nothing.
`blast_acl::destroy_admin_cap` lets the holder delete its cap, live or revoked.
Transferring an `AdminCap` moves its roles with it, because the ACL tracks caps
by ID.

**Root transfer.** No nomination → nominated (waiting seven days) → ready →
accepted. Root nominates with `blast_acl::begin_super_admin_transfer`; a new
nomination replaces the old one and restarts the delay. Root can cancel at any
time with `blast_acl::cancel_super_admin_transfer`, even after the delay. After
seven days the nominee calls `blast_acl::accept_super_admin_transfer`, which
mints a new `SuperAdminCap` to the nominee and makes the old one inert. The old
holder may then delete it with `blast_acl::destroy_retired_super_admin_cap`.

**Package.** Published (owned `Publication<OTW>`) → wrapped (shared
`PackageAdmin<OTW>` and `PackageVersion<OTW>`, version 1, every defined bit
paused) → unpaused by the package's own `unpause` → upgraded any number of
times (each commit advances the version by exactly one) → optionally
immutable. The cap's upgrade policy is never narrowed: it stays compatible (0,
the policy after a plain publish) until `blast_admin::package_admin::make_immutable`
destroys it, the one terminal upgrade action. Narrowing is deliberately absent:
under an additive or dependency-only policy a release cannot change existing
modules, so it could not compile the next version, and after
`blast_admin::package_admin::commit_upgrade_and_advance` every version-gated call
would abort forever.

### Flows

Integrators cannot call admin functions. These flows explain what Blast does and
what each transaction leaves on chain.

#### Use a role in an admin PTB (Blast admin)

1. `blast_acl::sign_in` with type argument `Role` (the role's full type), the
   shared `ACL` by immutable reference, and the operator's owned `AdminCap` by
   reference. It aborts unless the cap is live and holds `Role`. It returns an
   `AdminWitness<Role>`.
2. Pass the witness by reference to each consumer call that names that role, in
   the same PTB, for example `blast_admin::package_admin::pause` with
   `AdminWitness<blast_admin::package_admin::PauseAdmin<OTW>>`. One witness serves
   any number of calls of the same role.
3. A PTB that needs two roles signs in twice. The witness drops at the end of
   the transaction; it cannot be stored or sent.

#### Grant or remove an administrator (root)

1. `blast_acl::grant_admin` with the shared `ACL`, the owned `SuperAdminCap`,
   and the recipient. Emits `AdminGranted`; the new cap's ID is in the event.
2. `blast_acl::grant_role` with type argument `Role` and the cap ID. Emits
   `AdminRoleGranted`. Repeat per role.
3. To remove: `blast_acl::revoke_role` (one role, emits `AdminRoleRevoked`) or
   `blast_acl::revoke_admin` (the whole cap, emits `AdminRevoked` with the roles
   it held).

#### Transfer root (root, then nominee)

1. Root calls `blast_acl::begin_super_admin_transfer` with the recipient and
   `Clock` at `0x6`. Emits `delayed_action::ActionScheduled<blast_acl::SuperAdminTransfer, address>`
   with the nominee and `ready_at_ms` (and `delayed_action::ActionCancelled` first
   for a replaced nominee).
2. At or after `ready_at_ms`, the nominee's address calls
   `blast_acl::accept_super_admin_transfer` with the `ACL` and `Clock`. Emits
   `delayed_action::ActionApplied` and `SuperAdminTransferred` with the old and new
   cap IDs.
3. The old holder may call `blast_acl::destroy_retired_super_admin_cap`. Emits
   `SuperAdminCapDestroyed`.

#### Publish and wrap a package (publisher)

1. The package's `init` calls `package_version::new_publication` with its
   one-time witness by value, the bits it defines (`valid_pause_bits`; zero
   defines none) and a second type argument, the package's package witness: a
   struct of that package, other than its OTW, whose value only the package's
   own code constructs and never returns or stores. It is the one type that
   clears the package's pause bits and borrows its `Publisher`. The publication stores that exact type (with
   defining IDs) and aborts with code 24 for a primitive, the OTW itself, or a
   type from another package. It then claims the package's `Publisher`, which the
   framework allows only with a genuine one-time witness, and
   `package_version::keep` transfers the `Publication<OTW>` to the publisher.
2. In the publication PTB the publisher calls
   `blast_admin::package_admin::wrap` with that `Publication` and the fresh
   `UpgradeCap`. Wrap aborts with code 10 unless the cap belongs to the OTW's
   package and was never upgraded (UpgradeCap version 1, no outstanding ticket). It
   seals both capabilities in the new `PackageAdmin<OTW>` with a 48-hour upgrade
   notice (emits `PackageAdminCreated`) and shares it beside the
   `PackageVersion<OTW>` with every defined bit paused.

#### Upgrade a package (Blast admin)

1. Sign in with `UpgradeAdmin<OTW>` and call
   `blast_admin::package_admin::schedule_upgrade` with the shared
   `PackageAdmin<OTW>`, the witness, the 32-byte digest and `Clock`. It replaces
   any pending action or notice change and is ready after the applied notice.
   It aborts with code 12 once the package is immutable and with code 11 for a
   digest that is not 32 bytes.
2. After the notice, in one PTB: sign in again;
   `blast_admin::package_admin::authorize_upgrade` with the same digest and
   `Clock` consumes the ready action (code 22 when it is not the upgrade of that
   digest) and returns an `UpgradeTicket` under the cap's current policy (emits
   `UpgradeAuthorized`); the native `Upgrade` command returns an
   `UpgradeReceipt`; `blast_admin::package_admin::commit_upgrade_and_advance`
   takes the `PackageAdmin<OTW>`, the witness, the `PackageVersion<OTW>` by mutable
   reference, and the receipt. It commits the receipt into the sealed cap and
   advances the stored version by one in the same call (emits
   `UpgradeCommitted` and `VersionAdvanced`). Any failure rolls back
   the whole upgrade.

From the next transaction, calls into the previous bytecode abort with code 9
and the new bytecode, which must compile the next version, is the only one
that works. Because `blast_admin` is immutable, these administration calls check
no consumer version: a package whose new bytecode compiled the wrong
version can still schedule and install a repair.

`blast_admin::package_admin::schedule_make_immutable` and
`blast_admin::package_admin::make_immutable` destroy the `UpgradeCap` the same
way (emits `UpgradeCapDestroyed`); the `Publisher` stays sealed. Once the cap is
destroyed, both schedule calls abort with code 12. `make_immutable` also takes
a value of the package witness and the `PackageVersion<OTW>`, and aborts with
code 26 for any other type before it consumes the action. Only the package's
own code can therefore end its upgrades. Each package that may end them wraps
the call in a thin function that first runs
`package_version::assert_current(constants::version!())`, so only its live
bytecode can: the vault does, with `blast_vault::blast_vault_package::make_immutable`.
The launchpad, presale and migrators are upgradeable and have no such wrapper
yet; one of their upgrades must add it before they can be made immutable.
`blast_admin::package_admin::schedule_upgrade_delay` proposes only a new notice,
which anyone applies with `blast_admin::package_admin::apply_upgrade_delay` once
ready; `blast_admin::package_admin::cancel_upgrade_action` (`CancelAdmin<OTW>`)
discards whatever is pending, even when ready.

#### Pause and unpause a package (Blast admin)

1. `blast_admin::package_admin::pause` with the `PackageVersion<OTW>` by mutable
   reference, the `PauseAdmin<OTW>` witness and the bits sets them at once and emits
   `blast_admin_events::Paused`.
2. Clearing goes through the package's own `unpause`, which checks the current
   version, the package's own configuration notices and the core treasury's, then calls
   `blast_admin::package_admin::clear_pause_bits` with the `PackageAdmin<OTW>`, the
   `UnpauseAdmin<OTW>` witness, a value of the package witness type pinned at
   publication, the `PackageVersion<OTW>`, and the bits. Any other type aborts with
   code 25, including every other droppable type the package defines or returns,
   so an `UnpauseAdmin<OTW>` cannot skip the package's own checks by calling
   `blast_admin` directly. It then aborts with code 23 while any upgrade notice
   still to come could be zero, and emits `blast_admin_events::Unpaused`.

Pause and unpause requests must name nonzero bits the package defines (code 19)
and must change at least one bit (code 20); the witness and notice checks come
first. `package_version::assert_not_paused` aborts with code 21 while an
operation's bit is set; it is a mask check only, so a bit the package never
defined never aborts.

#### Borrow the package's Publisher (the package's own code)

`blast_admin::package_admin::publisher` takes the shared `PackageAdmin<OTW>`, a value
of `OTW`'s package witness and the shared `PackageVersion<OTW>`, and returns
`&Publisher`: the one the `OTW` value claimed at publication. Only `OTW`'s
own modules can construct that witness, so only package `OTW` can borrow its
Publisher, for example to create a `sui::display::Display` or a transfer policy
for its own types inside one of its functions. Any other type aborts with code
26. `blast_admin::package_admin::publisher_mut` is the same call returning
`&mut Publisher`, for framework calls that take one, such as
`sui::display_registry::new_with_publisher`; it checks the same witness and
aborts with the same code 26 (`EWrongPackageWitness`). A `Publisher` has no `drop`, so neither reference
can overwrite or burn it, and the pinned framework has no call that moves a
value out from behind a mutable reference. Should a later framework add a
generic swap, only package `OTW` itself, the holder of its witness, could use it,
and the Publisher would then leave this PackageAdmin; no other caller can.

### Version

Every protected call of an upgradeable package passes its shared
`PackageVersion<OTW>` and runs `package_version::assert_current` with the
version compiled into that bytecode, which aborts with code 9 unless it
equals the stored one. The version starts at 1 at wrap and changes only in
`blast_admin::package_admin::commit_upgrade_and_advance`, by exactly one.
`VersionAdvanced<OTW>` carries `container_id` (the `PackageVersion<OTW>`
ID), `original_package_id`, and the old and new versions. Integrators pass
the version object as a shared, immutable input to every call that takes it and
must call the latest package version.

### Delayed values, actions, sets and maps

The delayed modules are a timelock in the Compound/OpenZeppelin sense: schedule,
wait the applied notice, then apply; cancellable until applied. Each module owns
one type; consumers store four:

| Type | Holds | Used for |
| --- | --- | --- |
| `delayed::Delayed<K, T>` | an applied `value`, its applied `delay_ms`, at most one `delayed::Proposal<T>` | fees, shares, treasuries, destinations, fee splits |
| `delayed_action::DelayedAction<K, A>` | an applied `delay_ms`, at most one `delayed::Proposal<delayed_action::Change<A>>` | one-shot actions: upgrades, immutability, creator-cap reassignment, holder-reward rounds, the root transfer |
| `delayed_set::DelayedSet<K, E>` | admitted `members`, an applied `delay_ms`, pending admissions with fixed deadlines (each a `delayed::PendingDelay`), at most one proposed notice | witness and venue allowlists, the launchpad's account-claim signer keys |
| `delayed_map::DelayedMap<K, E, V>` | applied values by entry `E` in a `Table`, one applied `delay_ms`, at most one pending change per entry with a fixed deadline, at most one proposed notice | keyed values such as per-coin overrides |

Every value carries an `owner` (the ID of the object that stores it) and a `key`
of type `K`. `delayed::new`, `delayed_action::new`, `delayed_set::new` and
`delayed_map::new` take the owner object's `&UID`, which only the code creating
or holding that object has, so no package can attribute a value or its events to
another package's object. Blast keys are structs without public constructors, so
only their module can produce events under them. Partition delayed events by
`owner`, then by `K`.

Rules shared by all four:

- **Old notice governs.** Every proposal is ready at its scheduling time plus the
  notice applied then. A shorter notice, zero included, waits the applied one.
- **Explicit application.** Nothing changes until `delayed::apply`,
  `delayed_action::take_action`, `delayed_set::apply_add`, `delayed_map::apply`,
  or a notice `apply_delay` consumes a ready proposal. Readiness alone changes no
  value. Reads need no Clock, except the `is_ready` and `is_delay_ready`
  predicates, which answer whether the matching apply would succeed now.
- **Cancellation until applied.** `delayed::cancel`, `delayed_action::cancel`,
  `delayed_set::cancel_add`, `delayed_map::cancel` and the notice cancels work
  even after readiness. Scheduling over a pending proposal cancels it and
  restarts the full applied notice.
- **Zero-notice bootstrap.** A notice can start at zero, so a schedule and its
  apply in one PTB act as a setter. Raising a notice from zero applies at once.
  There is no other mutation path. `delayed::is_guarded`, `delayed_action::is_guarded`,
  `delayed_set::is_guarded` and `delayed_map::is_guarded` report whether every
  change still to come waits a nonzero notice (for a set or map, also that no
  admission or entry change is pending); each package's `unpause` requires it of
  its policies and of the core treasury destination.
- **Ceiling.** No notice exceeds `delayed::max_delay_ms` (2,592,000,000 ms, 30
  days): constructors and every proposed next notice abort with code 15 above it,
  so any notice can always be changed again.
- **No-op rejection.** A `Delayed` proposal that changes neither value nor notice,
  a notice proposal equal to the applied notice, admitting a current member, and
  a map change to the entry's applied value abort with code 16.
- **Overflow.** Scheduling and application abort with code 15 when a notice exceeds
  the ceiling, or a deadline or the next notice would not fit in a `u64` millisecond
  timestamp.
- **Destruction.** `delayed::destroy`, `delayed_action::destroy`,
  `delayed_set::destroy` and `delayed_map::destroy` delete a value whose owner is
  being deleted. Each aborts with code 17 while anything is pending, so every
  proposal ends in an event, and emits its module's `Destroyed` event.
  Destroying a set or map also ends its remaining members or entries.

`Delayed`: `delayed::schedule` proposes a value and the next notice together;
`delayed::schedule_value` keeps the notice; `delayed::schedule_delay` keeps the
value. `delayed::assert_ready` checks readiness without changing anything, so an
owner can settle accrued economics under the applied value before `delayed::apply`.

`DelayedAction`: `delayed_action::schedule` proposes an action under the applied
notice; `delayed_action::schedule_delay` proposes only a notice change.
`delayed_action::take_action` returns a ready action to its owner and aborts with
code 18 when the proposal is a notice change; `delayed_action::apply_delay` does
the reverse. `delayed_action::Change` is `Action(A)` or `Delay`.

`DelayedSet`: `delayed_set::schedule_add` snapshots a member's deadline from the
applied notice; a later notice change never moves it. `delayed_set::apply_add`
admits a ready member; `delayed_set::remove` removes a member and discards its
pending admission at once (removal is never delayed). `delayed_set::SetChange` is
`Admission(E)` or `Delay`.

`DelayedMap`: `delayed_map::schedule` proposes setting an entry to a value, or
clearing it with none, and snapshots its deadline from the applied notice; a
later notice change never moves it. Clearing is a delayed change like any other.
`delayed_map::apply` sets or clears a ready entry. `delayed_map::MapChange` is
`Entry { entry, value }` or `Delay`.

#### Delayed readers

Every reader is read-only. The same name means the same concept on every type.

| Concept | `Delayed` | `DelayedAction` | `DelayedSet` | `DelayedMap` |
| --- | --- | --- | --- | --- |
| owner object ID, key | `delayed::owner`, `delayed::key` | `delayed_action::owner`, `delayed_action::key` | `delayed_set::owner`, `delayed_set::key` | `delayed_map::owner`, `delayed_map::key` |
| applied state | `delayed::value` | none | `delayed_set::contains`, `delayed_set::members`, `delayed_set::length` | `delayed_map::value`, `delayed_map::contains`, `delayed_map::length` |
| applied notice | `delayed::delay_ms` | `delayed_action::delay_ms` | `delayed_set::delay_ms` | `delayed_map::delay_ms` |
| pending proposal | `delayed::pending` | `delayed_action::pending`, `delayed_action::pending_action` | `delayed_set::is_pending`, `delayed_set::admission_delay`, `delayed_set::admission_ready_at_ms`, `delayed_set::pending_count` | `delayed_map::is_pending`, `delayed_map::pending`, `delayed_map::entry_ready_at_ms`, `delayed_map::pending_count` |
| ready now | `delayed::is_ready` | `delayed_action::is_ready` | `delayed_set::is_ready` (per member) | `delayed_map::is_ready` (per entry) |
| pending notice change | in `delayed::pending` | `delayed_action::pending_delay`, `delayed_action::is_delay_ready` | `delayed_set::pending_delay`, `delayed_set::is_delay_ready` | `delayed_map::pending_delay`, `delayed_map::is_delay_ready` |
| guarded | `delayed::is_guarded` | `delayed_action::is_guarded` | `delayed_set::is_guarded` | `delayed_map::is_guarded` |

Value types: `delayed::Proposal` exposes `delayed::proposal_value`,
`delayed::proposal_delay_ms` and `delayed::proposal_ready_at_ms` (also as `value`,
`delay_ms` and `ready_at_ms` on the value); `delayed::PendingDelay` exposes
`delayed::pending_delay_ms` and `delayed::pending_delay_ready_at_ms` (also as `delay_ms`
and `ready_at_ms`); `delayed_map::EntryProposal` exposes
`delayed_map::entry_proposal_value` (none clears) and
`delayed_map::entry_proposal_delay`; `delayed_action::action`,
`delayed_set::member`, `delayed_map::changed_entry` and
`delayed_map::changed_value` read a change, each none for a delay change.
`delayed_map::changed_value` returns `Option<Option<V>>`: `some(some(v))` sets
the entry to `v` and `some(none)` clears it.

The launchpad's account-claim signer keys are a `DelayedSet`: ClaimSignerAdmin's admissions wait
the set's notice, so a compromised ClaimSignerAdmin cannot sign claims without warning, and its
revocations are immediate. ACL administrator and role grants remain immediate.

### Time rules

- Root transfer delay: 604,800,000 ms (seven days), fixed in immutable code. The
  nominee may accept from the first transaction whose `Clock` reads
  `ready_at_ms` or later.
- The root transfer is a `DelayedAction` with no notice-change path. Accepting
  consumes the nomination; cancelling or replacing it discards the old nominee,
  so a replaced, cancelled, or already accepted nominee can never accept.
- Upgrade and immutability actions wait the package's upgrade notice, 172,800,000
  ms (48 hours) from wrap until an applied notice change.
- Grants, revocations, role changes and pauses take effect in the same transaction.

### Reading state

`blast_admin` is immutable and keeps a complete read-only API for every type it
defines, so a future package can explain any state on chain; off-chain readers
can also read object content over RPC, or replay events.

- ACL: `blast_acl::super_admin_cap_id` (the active root; any other
  `SuperAdminCap` is inert), `blast_acl::is_admin`, `blast_acl::has_role`,
  `blast_acl::admin_roles` (aborts with code 1 for an unknown cap),
  `blast_acl::admin_count`, `blast_acl::super_admin_transfer` (the root transfer's
  `DelayedAction`, whose `pending` holds `Action(nominee)` and its `ready_at_ms`),
  and the fixed `blast_acl::max_roles_per_admin` and
  `blast_acl::super_admin_transfer_delay_ms`. Role type-name strings use 64
  lowercase hex characters for the address, without `0x`.
- Package version: `package_version::version`, `package_version::valid_pause_bits`,
  `package_version::paused`, `package_version::is_paused` (any of the given bits
  set) and `package_version::package_witness`; a `Publication` exposes
  `package_version::publication_valid_pause_bits` and
  `package_version::publication_package_witness` and
  `package_version::publication_publisher_id`.
- Package administration: `blast_admin::package_admin::upgrade_delay_ms`,
  `blast_admin::package_admin::pending_upgrade` (read its action with
  `delayed_action::action` and the digest with
  `blast_admin::package_admin::upgrade_digest`, none for immutability),
  `blast_admin::package_admin::is_upgrade_delay_guarded`,
  `blast_admin::package_admin::has_upgrade_cap`,
  `blast_admin::package_admin::upgrade_cap_id`,
  `blast_admin::package_admin::current_package_id`,
  `blast_admin::package_admin::upgrade_cap_version` and
  `blast_admin::package_admin::upgrade_policy` (each none once immutable),
  `blast_admin::package_admin::publisher_id`, and
  `blast_admin::package_admin::initial_upgrade_delay_ms`.

`ACL`, `PackageVersion` and `PackageAdmin` are shared for the life of the
protocol and have no destructor; a `Publication` has none either, because its
one exit, wrap, keeps the Publisher in custody. `AdminCap` and a retired
`SuperAdminCap` have their destroy calls above.

### Events

All `blast_admin` events are emitted directly (no envelope). ACL, version and
PackageAdmin events come from module `blast_admin_events` and carry no ACL ID because
there is one ACL. Delayed lifecycle events come from the module that owns the
type (`delayed`, `delayed_action`, `delayed_set` or `delayed_map`), are generic in
the owner's key `K` and the value, action, member or entry types, and carry
`owner` and `key`. Each map event's `change` names its entry.

| Event | Emitted by | Use |
| --- | --- | --- |
| `blast_admin_events::AdminGranted` | `grant_admin` | new cap ID and recipient |
| `blast_admin_events::AdminRoleGranted` / `blast_admin_events::AdminRoleRevoked` | `grant_role` / `revoke_role` | role added or removed (`role` is the type name) |
| `blast_admin_events::AdminRevoked` | `revoke_admin` | cap removed with the roles it held |
| `blast_admin_events::AdminDestroyed` | `destroy_admin_cap` | cap deleted; `was_active` and the roles it still held |
| `blast_admin_events::SuperAdminTransferred` | `accept_super_admin_transfer` | old and new root cap IDs, recipient |
| `blast_admin_events::SuperAdminCapDestroyed` | `destroy_retired_super_admin_cap` | retired root deleted |
| `blast_admin_events::PackageAdminCreated` | `blast_admin::package_admin::wrap` | `PackageAdmin<OTW>` created: Publisher, cap, package, UpgradeCap version, policy |
| `blast_admin_events::PackageVersionCreated` | `blast_admin::package_admin::wrap` | `PackageVersion<OTW>` created beside its `PackageAdmin<OTW>` (`package_admin_id`): defined and paused bits, package witness, version 1 |
| `blast_admin_events::UpgradeAuthorized` | `blast_admin::package_admin::authorize_upgrade` | the exact digest authorized, from `current_package_id` |
| `blast_admin_events::UpgradeCommitted` | `blast_admin::package_admin::commit_upgrade_and_advance` | new package ID and UpgradeCap version |
| `blast_admin_events::VersionAdvanced` | `blast_admin::package_admin::commit_upgrade_and_advance` | version bump of package `OTW` |
| `blast_admin_events::UpgradeCapDestroyed` | `blast_admin::package_admin::make_immutable` | final UpgradeCap version and policy |
| `blast_admin_events::Paused` | `blast_admin::package_admin::pause` | bits set on package `OTW`'s version and the resulting mask; the one pause event of every package |
| `blast_admin_events::Unpaused` | `blast_admin::package_admin::clear_pause_bits` | bits cleared and the resulting mask |
| `delayed::DelayedCreated` | `delayed::new` | initial value and notice |
| `delayed::DelayedScheduled` / `delayed::DelayedCancelled` | schedule, replace, cancel | proposed value, next notice, `ready_at_ms` |
| `delayed::DelayedApplied` | `delayed::apply` | previous and new value, applied notice |
| `delayed::DelayedDestroyed` | `delayed::destroy` | the setting ends |
| `delayed_action::ActionCreated` | `delayed_action::new` | initial notice |
| `delayed_action::ActionScheduled` / `delayed_action::ActionCancelled` | action or notice proposals | `change`, notice in force once applied, `ready_at_ms` |
| `delayed_action::ActionApplied` | `delayed_action::take_action`, `delayed_action::apply_delay` | `change` and the notice now applied |
| `delayed_action::ActionDestroyed` | `delayed_action::destroy` | the action slot ends |
| `delayed_set::SetCreated` | `delayed_set::new` | initial notice |
| `delayed_set::SetScheduled` / `delayed_set::SetCancelled` | admission or notice proposals; a removal cancels a pending admission | `change`, the notice an admission waits or the proposed notice, `ready_at_ms` |
| `delayed_set::SetApplied` | `delayed_set::apply_add`, `delayed_set::apply_delay` | `change` and the notice it waited or now applied |
| `delayed_set::MemberRemoved` | `delayed_set::remove` | member removed at once |
| `delayed_set::SetDestroyed` | `delayed_set::destroy` | the set and its members end |
| `delayed_map::MapCreated` | `delayed_map::new` | initial notice |
| `delayed_map::MapScheduled` / `delayed_map::MapCancelled` | entry or notice proposals | `change` (entry and value, none to clear), the notice an entry change waits or the proposed notice, `ready_at_ms` |
| `delayed_map::MapApplied` | `delayed_map::apply`, `delayed_map::apply_delay` | `change` and the notice it waited or now applied |
| `delayed_map::MapDestroyed` | `delayed_map::destroy` | the map and its entries end |

Every upgrade event names the package's `original_package_id`, except
`UpgradeAuthorized`, which names the `current_package_id` the digest upgrades
from. Replaying the ACL events in order reconstructs `ACL.admins` and every root
transfer exactly. `ACL` creation emits only the root transfer's
`delayed_action::ActionCreated`, so the first root cap's ID comes from the publish
transaction's created objects (or the first `SuperAdminTransferred`, as
`previous_super_admin_cap_id`). A proposal ends in exactly one `Applied` or
`Cancelled` event.

### Aborts

Codes are plain `u64` values raised in the `blast_admin` module named. An error a
delayed type raises in its own call is located in that type's module; readiness
and overflow checked through the shared deadline rules are located in `delayed`.

| Code | Name | Module | Cause and fix |
| --- | --- | --- | --- |
| 0 | `EInvalidSuperAdminCap` | `blast_acl` | the root cap is not the active one |
| 1 | `EInvalidAdminCap` | `blast_acl` | the `AdminCap` is revoked or unknown (in `sign_in`, `grant_role`, `revoke_role`, `revoke_admin`, `admin_roles`) |
| 2 | `EInvalidAdminRecipient` | `blast_acl` | `grant_admin` to `0x0` |
| 3 | `EAdminRoleCapacityReached` | `blast_acl` | the cap already holds 32 roles |
| 4 | `EAdminRoleAlreadyGranted` | `blast_acl` | the cap already holds the role |
| 5 | `EAdminRoleNotGranted` | `blast_acl` | `sign_in` or `revoke_role` for a role the cap does not hold; grant it first or use the right role type |
| 6 | `EInvalidSuperAdminRecipient` | `blast_acl` | nominee is `0x0` or the sender; or publish with `blast_acl_root` left at `0x0` |
| 7 | `ENotPendingSuperAdminRecipient` | `blast_acl` | accept from an address that is not the nominee, or with no nomination pending; checked before readiness |
| 8 | `ESuperAdminCapStillActive` | `blast_acl` | destroying the active root |
| 9 | `EVersionMismatch` | `package_version` | the call reached outdated bytecode; call the latest package version (or the upgrade did not compile the next version) |
| 10 | `EInvalidUpgradeCap` | `blast_admin::package_admin` | wrap received a cap for another package, an already upgraded cap, or one with an outstanding ticket |
| 11 | `EInvalidPackageDigest` | `blast_admin::package_admin` | scheduling a digest that is not 32 bytes |
| 12 | `EUpgradeCapUnavailable` | `blast_admin::package_admin` | the package was made immutable |
| 13 | `ENotReady` | `delayed`; `delayed_set` for `delayed_set::apply_add`, `delayed_map` for `delayed_map::apply` | applying a proposal, or accepting a root transfer, before its `ready_at_ms` |
| 14 | `ENoPending` | the type's module | applying or cancelling when nothing is pending |
| 15 | `EInvalidDelay` | `delayed` | a notice above `delayed::max_delay_ms` (30 days), or a deadline or next notice that would overflow a Unix millisecond timestamp; choose a notice of at most 30 days |
| 16 | `EUnchanged` | the type's module | the proposal changes nothing, the member is already admitted, `remove` names an unknown member, or a map change repeats the entry's applied value (clearing an absent entry included) |
| 17 | `EProposalPending` | the type's module | destroying a delayed value, action slot, set or map while a proposal is pending; cancel it first |
| 18 | `EWrongChange` | `delayed_action` | `take_action` on a notice change, or a notice `apply_delay` on an action; checked before readiness |
| 19 | `EInvalidPauseBits` | `package_version` | pause or unpause names zero bits or a bit the package does not define |
| 20 | `EPauseUnchanged` | `package_version` | pausing only bits already set, or clearing only bits already clear |
| 21 | `EPaused` | `package_version` | the operation's pause bit is set; wait for Blast to unpause it |
| 22 | `EWrongUpgradeAction` | `blast_admin::package_admin` | the ready action is not the upgrade of this digest (authorize) or not immutability (make immutable) |
| 23 | `EUnguardedUpgradeDelay` | `blast_admin::package_admin` | clearing pause bits while the upgrade notice is zero or a pending change would make it zero |
| 24 | `EInvalidPackageWitness` | `package_version` | the package witness type given to `new_publication` is a primitive, the package's OTW, or from another package |
| 25 | `EWrongUnpauseWitness` | `package_version` | `clear_pause_bits` received a value of a type other than the package witness pinned at publication |
| 26 | `EWrongPackageWitness` | `package_version` | `blast_admin::package_admin::publisher`, `blast_admin::package_admin::publisher_mut` or `blast_admin::package_admin::make_immutable` received a value of a type other than the package witness pinned at publication |

An `OTW` that is not a genuine one-time witness aborts in the framework's
`sui::package::claim` inside `package_version::new_publication`.

The one an integrator most often meets is code 9 from `package_version`: a PTB
built against an old package ID after an upgrade.

### Pitfalls

- An `AdminWitness` exists only inside one transaction. There is no reusable
  admin token to hand to a bot; a bot needs its own `AdminCap`.
- A revoked `AdminCap` still exists in its holder's wallet. Check `ACL.admins`,
  not ownership, to know whether a cap works.
- Role names repeat across packages (`UpgradeAdmin`, `CancelAdmin`). Always
  compare the full type name, including the package address and type arguments.
- After any upgrade of a package, PTBs pinned to its old package ID abort with
  code 9.
- Only the package's own code can borrow its `Publisher`: its package witness
  is never handed out, so an integrator cannot create Display or transfer
  policies for a Blast package's types.

### Q&A

**Who can change Blast's fees or settings?** Only an `AdminCap` listed in
`ACL.admins` with the specific role, signed in within the same transaction. The
root cannot act on any package directly.

**Can Blast add a new kind of admin power later?** A new or upgraded consumer
package can declare a new role type, and root can grant it. The ACL itself is
immutable and cannot change how sign-in works.

**How do I see every Blast administrator?** Read the shared `ACL` object: each
key of `admins` is a live `AdminCap` ID and each value lists its roles. Replay
`blast_admin_events` for the full history.

**How much notice is there before root changes hands?** Seven days, fixed. The
nomination emits `delayed_action::ActionScheduled` and is visible in
`super_admin_transfer`, and root can cancel it at any time before acceptance.

**Can a role from one package authorize actions in another?** No. A consumer
function names its role type in its signature, and a role type from another
package, or the same generic role with another package's OTW, is a different
type, so the transaction does not type-check.

**How much notice is there before an upgrade?** The package's applied upgrade
notice, 48 hours from wrap. A notice change itself waits the applied notice, and
the package cannot be unpaused while any upgrade notice still to come could be zero.

**Which Blast packages can still be upgraded?** Those whose `PackageAdmin`
still holds an `UpgradeCap`. `blast_admin` and `blast_partners` are immutable.

**What stops a stale package version from moving funds?** Every protected call
checks the shared version against the version compiled into the bytecode,
and the upgrade finalizer advances the version in the same transaction that
commits the upgrade.

**What does an upgrade leave on chain?** `UpgradeAuthorized` with the exact
digest, `UpgradeCommitted` with the new package ID, and
`VersionAdvanced` with the new version, all in one transaction.

**Can someone forge a version bump event?** No. A `PackageVersion<OTW>` exists
only through `OTW`'s own publication, which needs the `OTW` value inside
its package `init`, and only `blast_admin::package_admin::commit_upgrade_and_advance`
advances it.
