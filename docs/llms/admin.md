## Administration

### What it is

Package `blast_admin` is Blast's administration layer. It holds one shared
access-control list (ACL) for every Blast package, with one cold root capability
and a Table of administrator capabilities with no inline cardinality limit. Each administrator holds roles, and a
role is a Move type that a consumer package declares, so a role from one package
can never act in another. The package also provides two primitives that
upgradeable Blast packages embed: an operational version that rejects calls into
outdated bytecode, and an upgrade custody that seals a package's `Publisher` and
`UpgradeCap` so upgrades happen only through role-gated calls. Blast publishes
`blast_admin` immutable (its `UpgradeCap` is destroyed in the publish
transaction), so none of these rules can change. The launchpad (`blast_fun`),
migrators (`blast_fun_migrators`), Blast SUI (`blast_sui`), Boosts
(`blast_boosts_core` and `blast_boosts_aftermath`), partners
(`blast_partners`), and presales (`blast_presale`) use it.

### Objects and authority

| Object | Kind | Held by | Authorizes |
| --- | --- | --- | --- |
| `blast_acl::ACL` | shared singleton, created once in `init` | nobody | stores the root cap ID, every live `AdminCap` ID with its roles, and the pending root transfer |
| `blast_acl::SuperAdminCap` | owned, `key` only (cannot be transferred or wrapped by anyone) | Blast's cold root: `init` delivers it to the `blast_acl_root` address in `Move.toml`, not the publisher | grant and revoke admins and roles; start and cancel a root transfer |
| `blast_acl::AdminCap` | owned, `key, store` (transferable, wrappable) | a Blast operator | nothing by itself; `blast_acl::sign_in` turns it into a role witness |
| `blast_acl::AdminWitness<Role>` | transaction-local value, `drop` only | the PTB that signed in | the one role `Role` in every consumer call that takes `&AdminWitness<Role>` |
| `operational_version::OperationalVersion<M>` | `store` value inside a consumer's shared version object | the consumer package | the generation check behind every protected call |
| `upgrade_custody::UpgradeCustody<M>` | `store` value inside a consumer's shared `PackageAdmin` | the consumer package | holds the `Publisher` and `UpgradeCap`; acts only through named transitions |
| `package_version::Publication<M>` | owned, `key` only | the publisher, from the package's `init` until wrap | nothing but the one wrap of package `M` |
| `package_version::PackageVersion<M>` | shared, `key` only, created at wrap | nobody | the generation and pause bits package `M`'s operations check |
| `blast_admin::package_admin::PackageAdmin<M>` | shared, `key` only, created at wrap | nobody | package `M`'s sealed custody and its 48-hour upgrade decisions |

`ACL` fields: `super_admin_cap_id` (the one root cap that works), `admins` (a
map from `AdminCap` ID to a set of role type names), and `super_admin_transfer`
(a `delayed_action::DelayedAction<blast_acl::SuperAdminTransfer, address>` with a
fixed seven-day notice; see "Delayed values, actions, sets and maps").

Root powers are narrow: membership, roles, and its own delayed transfer. Root
cannot sign in to any role and cannot call any consumer function. Every
operational action needs an `AdminCap` holding the right role.

### Roles by package

A role is an ability-free struct. The ACL stores its type name with defining
IDs: the address of the package that first declared it, then module and struct.
Same-named roles in different packages are different types.

| Package | Declared in | Roles |
| --- | --- | --- |
| `blast_fun` (launchpad) | `blast_fun_domain` | `blast_fun_domain::UpgradeAdmin` (govern upgrade notice, authorize and commit upgrades, make a package immutable), `blast_fun_domain::CreatorAdmin` (revoke and reissue a launch's creator caps), `blast_fun_domain::BuybackAdmin` (swap a vault's burn Quote for Meme to burn), `blast_fun_domain::TreasuryAdmin` (where Blast is paid, Blast's share of future launches, claim migration residuals), `blast_fun_domain::FeeAdmin` (creation and trade fees, fee share, partners new launches may name), `blast_fun_domain::ListingAdmin` (Quotes and Meme decimals new launches may use), `blast_fun_domain::AdapterAdmin` (migration adapters), `blast_fun_domain::ClaimSignerAdmin` (propose and revoke the keys that sign account claims, and their notice), `blast_fun_domain::RewardsAdmin` (publish holder-reward rounds), `blast_fun_domain::PauseAdmin`, `blast_fun_domain::UnpauseAdmin`, `blast_fun_domain::CancelAdmin` |
| `blast_fun_migrators` | declares none | uses the launchpad's `UpgradeAdmin` (its own delay policy and upgrades), `FeeAdmin` (LP-fee shares), `TreasuryAdmin` (where Blast's LP fees go, migration residuals), `BuybackAdmin` (buyback and burn), `RewardsAdmin` (holder-reward rounds), and `CancelAdmin` (pending administration) |
| `blast_sui` | `blast_sui_domain` | `blast_sui_domain::UpgradeAdmin` (govern upgrade notice, schedule and execute upgrades or immutability), `blast_sui_domain::FeeAdmin` (schedule blastSUI redemption-fee changes), `blast_sui_domain::CancelAdmin`, `blast_sui_domain::PauseAdmin` (pause deposits only), `blast_sui_domain::UnpauseAdmin` |
| `blast_boosts_core` | `blast_boosts_core` | `blast_boosts_core::blast_boosts_core::VaultIssuer` (issue a Vault and its share currency, update its metadata), `blast_boosts_core::blast_boosts_core::RiskAdmin` (fees, NAV cap, max order notional, withdraw admin fees, accepted partners), `blast_boosts_core::blast_boosts_core::ShutdownAdmin` (begin a Vault's shutdown), `blast_boosts_core::blast_boosts_core::UpgradeAdmin` (adapter package upgrades) |
| `blast_boosts_aftermath` | declares none | uses the four Boosts core roles |
| `blast_partners` | `blast_partners` | `blast_partners::blast_partners::PartnerAdmin` (register partners, schedule shares and caps) |
| `blast_presale` | `blast_presale_domain` | `blast_presale_domain::UpgradeAdmin` (govern upgrade notice, schedule and execute compatible upgrades or immutability), `blast_presale_domain::TreasuryAdmin` (govern the presale fee destination), `blast_presale_domain::FeeAdmin` (rates for new sales, one sale before its start, and one vault; partners new sales may name), `blast_presale_domain::ListingAdmin` (Quotes new sales may use), `blast_presale_domain::AdapterAdmin` (migrators that may create sales), `blast_presale_domain::RewardsAdmin` (fund holder-reward rounds and settle their gas reserves), `blast_presale_domain::PauseAdmin`, `blast_presale_domain::UnpauseAdmin`, `blast_presale_domain::CancelAdmin` |

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

**Operational generation.** Each upgradeable consumer starts at generation 1.
Each committed upgrade advances it by exactly one (see "Operational versions").

**Upgrade policy.** A sealed `UpgradeCap` can only narrow its policy:
compatible (0, the policy after a plain publish) → additive (128) →
dependency-only (192) → destroyed (immutable). Each step is irreversible, and
each package exposes only some steps (see "Upgrade custody").

### Flows

Integrators cannot call admin functions. These flows explain what Blast does and
what each transaction leaves on chain.

#### Use a role in an admin PTB (Blast admin)

1. `blast_acl::sign_in` with type argument `Role` (the role's full type), the
   shared `ACL` by immutable reference, and the operator's owned `AdminCap` by
   reference. It aborts unless the cap is live and holds `Role`. It returns an
   `AdminWitness<Role>`.
2. Pass the witness by reference to each consumer call that names that role, in
   the same PTB, for example `launch_config::schedule_creation_fee` with
   `AdminWitness<blast_fun_domain::FeeAdmin>`. One witness serves any number of
   calls of the same role.
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

#### Upgrade a consumer package (Blast admin)

Launchpad, presale, migrators and Blast SUI first require `schedule_upgrade` with the exact
digest and `Clock`, followed by that package custody's applied upgrade notice. A `CancelAdmin` can cancel
even a ready action. Their `authorize_upgrade` also takes `Clock` and consumes
the matching ready action. Immutability follows the same scheduling rule. Action
schedules retain the applied notice; only the explicit `schedule_upgrade_delay` /
`apply_upgrade_delay` policy path changes it.

For consumers other than the Boosts adapter, execution uses one PTB:

1. `blast_acl::sign_in` with the package's upgrade role (for example
   `blast_sui_domain::UpgradeAdmin`).
2. The package's `authorize_upgrade` (for example
   `blast_sui::package_admin::authorize_upgrade`) with its shared
   `PackageAdmin`, its shared version object, the witness, and the 32-byte
   package digest. Returns an `UpgradeTicket` under the cap's current policy and
   emits `UpgradeAuthorized` with the digest.
3. The native `Upgrade` command consumes the ticket and returns an
   `UpgradeReceipt`.
4. The package's `commit_upgrade_and_advance` (for example
   `blast_sui::package_admin::commit_upgrade_and_advance`) with the
   `PackageAdmin`, the version object by mutable reference, the witness, and the
   receipt. It checks that the stored generation plus one equals the compiled
   next generation, commits the receipt into the sealed cap (emits
   `UpgradeCommitted`), and advances the generation (emits
   `OperationalVersionAdvanced`). Any failure rolls back the whole upgrade.

From the next transaction, calls into the previous bytecode abort and the new
bytecode is the only one that works.

The Boosts adapter separates native upgrade from activation. A Blast UpgradeAdmin
signs in, calls `blast_boosts_aftermath::package_admin::authorize_upgrade` with
custody, witness and digest, feeds its ticket into native Upgrade, then calls
`blast_boosts_aftermath::package_admin::commit_upgrade` with custody and receipt.
These calls neither read nor change Protocol and stay available during a version
mismatch. The receipt proves authorization; commit needs no second witness.

In a follow-up transaction, sign in again and call the successor's
`blast_boosts_aftermath::package_admin::activate_upgrade` with mutable Protocol
and the UpgradeAdmin witness. The running code must accept exactly the next
generation. Failed activation leaves the old generation serving; a corrected
upgrade can be installed. Native upgrade count and operational generation can
diverge after failed attempts. `blast_boosts_aftermath::package_admin::make_immutable`
still requires the running code to match the active generation before destroying
repair authority. Historical repair functions retain live ACL checks; retiring
their UpgradeAdmin authority requires revoking that role, not just a cutover.

### Operational versions

Each upgradeable consumer keeps one shared version object holding an
`OperationalVersion<M>`, where `M` is the package's one-time witness type.
`operational_version::new` takes that witness by reference and checks it is a
genuine one-time witness, so the value can only be created in that package's
`init`, and an `OperationalVersionAdvanced<M>` event cannot be forged.

| Package | Version object |
| --- | --- |
| `blast_fun` | `blast_fun::blast_fun::PackageVersion` |
| `blast_fun_migrators` | `blast_fun_migrators::blast_fun_migrators::PackageVersion` |
| `blast_sui` | `blast_sui_package::PackageVersion` |
| `blast_boosts_aftermath` | `blast_boosts_aftermath::blast_boosts_aftermath::Protocol` |

Consumers other than Boosts compile two private constants: their own generation
and the next one. Boosts compiles only its own generation and checks it during
successor activation. Every ordinary protected call passes the shared version object and runs
`operational_version::assert_current`, which aborts unless the stored generation
equals the compiled one. The other consumers' upgrade finalizer runs
`operational_version::assert_next` and then `operational_version::advance`,
which increments the stored generation by exactly one and emits
`OperationalVersionAdvanced` with `container_id` (the version object's ID),
`original_package_id`, and the old and new generations. Every upgrade event names the
package's `original_package_id`, except `UpgradeAuthorized`, which names the
`current_package_id` the digest upgrades from.
Integrators pass the version object as a shared, immutable input to every call
that takes it and must call the latest package version.

### Upgrade custody

`upgrade_custody::new` seals a package's `Publisher` and never-upgraded
`UpgradeCap` (version 1) after checking both belong to the package of `M`.
Neither can leave the custody. The consumer's shared `PackageAdmin` wraps it and
gates authorization behind its upgrade role. Boosts receipt commit instead carries
the native authorized receipt. Wrap in launchpad, presale and migrators consumes their
unique Publication and matching fresh UpgradeCap; Blast SUI's wrap also seals both
coins' metadata caps and creates the receipt Display. Publication carries
provenance only and is permanently consumed at wrap. Ordinary ACL operations
configure policies using each publication-owned policy operation's initial zero notice; upgrade
custody starts at 48 hours. Each operation
stores its own notice in a delayed value; see "Delayed values, actions, sets and maps".

| Package | Custody object | Transitions exposed |
| --- | --- | --- |
| `blast_fun` | `blast_fun::package_admin::PackageAdmin` | `blast_fun::package_admin::wrap`, `blast_fun::package_admin::authorize_upgrade`, `blast_fun::package_admin::commit_upgrade_and_advance`, `blast_fun::package_admin::make_immutable` |
| `blast_fun_migrators` | `blast_fun_migrators::package_admin::PackageAdmin` | `blast_fun_migrators::package_admin::wrap`, `blast_fun_migrators::package_admin::authorize_upgrade`, `blast_fun_migrators::package_admin::commit_upgrade_and_advance`, delayed `blast_fun_migrators::package_admin::make_immutable` |
| `blast_sui` | `blast_sui::package_admin::PackageAdmin` | `blast_sui::package_admin::wrap`, `blast_sui::package_admin::authorize_upgrade`, `blast_sui::package_admin::commit_upgrade_and_advance`, delayed `blast_sui::package_admin::authorize_repair` and `blast_sui::package_admin::commit_repair` (install code without advancing, no version check), delayed `blast_sui::package_admin::make_immutable`, `blast_sui::package_admin::unpause`, `blast_sui::package_admin::has_upgrade_cap` |
| `blast_boosts_aftermath` | `blast_boosts_aftermath::package_admin::PackageAdmin` | `blast_boosts_aftermath::package_admin::wrap`, `blast_boosts_aftermath::package_admin::authorize_upgrade`, `blast_boosts_aftermath::package_admin::commit_upgrade`, `blast_boosts_aftermath::package_admin::activate_upgrade`, `blast_boosts_aftermath::package_admin::make_immutable` |

The custody primitives: `upgrade_custody::authorize_upgrade` (exactly one
32-byte digest under the current policy), `upgrade_custody::commit_upgrade`
(commits the receipt into the same cap), `upgrade_custody::restrict_to_additive`
and `upgrade_custody::restrict_to_dependency_only` (irreversible narrowing),
`upgrade_custody::make_immutable` (destroys the cap, keeps the `Publisher`),
`upgrade_custody::has_upgrade_cap`, and `upgrade_custody::publisher` (borrows
the `Publisher` by reference for features like Display; no current consumer
exposes it). After `make_immutable`, every transition that needs the
`UpgradeCap` (authorize, commit, restrict, make immutable) aborts with code 14.
The packages
`blast_admin`, `blast_partners`, and `blast_boosts_core` are published immutable
and have no custody at all.

### Generic package administration

`package_version` and `blast_admin::package_admin` implement, once, the
publication, operational generation, pause bits and 48-hour upgrade custody that
an upgradeable package needs, typed by the package's one-time witness `M`. No
package uses them yet; the launchpad, presale and migrators still carry their own
copies (see "Upgrade custody").

**Roles.** `blast_admin::package_admin` declares four ability-free roles generic
over the package marker: `blast_admin::package_admin::UpgradeAdmin<M>` (schedule,
authorize and commit upgrades, schedule and execute immutability, change the
upgrade notice), `blast_admin::package_admin::PauseAdmin<M>` (set pause bits),
`blast_admin::package_admin::UnpauseAdmin<M>` (clear pause bits through the
package's own unpause) and `blast_admin::package_admin::CancelAdmin<M>` (cancel
the pending upgrade action or notice change). The ACL stores a role's type name
with its type arguments, so `UpgradeAdmin<A>` and `UpgradeAdmin<B>` are separate
grants and one package's administrator cannot sign in for another package.

**Publication and wrap.** The package's `init` calls
`package_version::new_publication` with its one-time witness by value, the bits
it defines (`valid_pause_bits`; zero defines none) and a second type argument,
the package's unpause witness: a struct of that package, other than its marker,
whose value only the package's own unpause constructs. The publication stores
that exact type (with defining IDs) and aborts with code 28 for a primitive, the
marker itself, or a type from another package. It claims the
`Publisher`, seeds generation 1 and returns a `Publication<M>`, which
`package_version::keep` transfers to the publisher. In the publication PTB the
publisher calls `blast_admin::package_admin::wrap` with that `Publication` and
the fresh `UpgradeCap`. Wrap seals both capabilities in `upgrade_custody`, starts
the upgrade notice at 48 hours, and shares the `PackageAdmin<M>` and the
`PackageVersion<M>` with every defined bit paused.

**Generation.** The package compiles its own generation and passes it to
`package_version::assert_current` in every protected call, which aborts with code
9 unless it equals the stored one.
`blast_admin::package_admin::commit_upgrade_and_advance` computes the next
generation (code 10 at the end of the range), then commits the native receipt
into the sealed cap and advances the stored generation by one in the same call
(emits `UpgradeCommitted` and `OperationalVersionAdvanced`), so the new bytecode
must compile the next generation. Because `blast_admin` is immutable, these
administration calls check no consumer generation: a package whose new bytecode
compiled the wrong generation can still schedule and install a repair.

**Upgrade flow (Blast admin).**

1. Sign in with `UpgradeAdmin<M>` and call
   `blast_admin::package_admin::schedule_upgrade` with the shared
   `PackageAdmin<M>`, the witness, the 32-byte digest and `Clock`. It replaces
   any pending action or notice change and is ready after the applied notice.
2. After the notice, in one PTB: sign in again;
   `blast_admin::package_admin::authorize_upgrade` with the same digest and
   `Clock` consumes the ready action and returns an `UpgradeTicket`; the native
   `Upgrade` command returns an `UpgradeReceipt`;
   `blast_admin::package_admin::commit_upgrade_and_advance` takes the
   `PackageAdmin<M>`, the witness, the `PackageVersion<M>` by mutable reference,
   and the receipt.

`blast_admin::package_admin::schedule_make_immutable` and
`blast_admin::package_admin::make_immutable` destroy the `UpgradeCap` the same
way; once the cap is destroyed, both schedule calls abort with code 14.
`blast_admin::package_admin::schedule_upgrade_delay` proposes only a new
notice, which anyone applies with `blast_admin::package_admin::apply_upgrade_delay`
once ready; `blast_admin::package_admin::cancel_upgrade_action` (CancelAdmin)
discards whatever is pending, even when ready.

**Pause bits.** Each package defines its own bits at publication.
`blast_admin::package_admin::pause` (PauseAdmin) sets bits at once and emits
`blast_admin_events::Paused`; `package_version::assert_not_paused` aborts with
code 25 while an operation's bit is set; it is a mask check only, so a bit the
package never defined never aborts. Clearing goes through the package's own
`unpause`, which checks the package's own configuration notices, then calls
`blast_admin::package_admin::clear_pause_bits` with the `PackageAdmin<M>`, the
`UnpauseAdmin<M>` witness, a value of the unpause witness type pinned at
publication, the `PackageVersion<M>`, and the bits. Any other type aborts with code
29, including every other droppable type the package defines or returns, so an
`UnpauseAdmin<M>` cannot skip the package's own checks by calling `blast_admin`
directly. It then aborts with code 27 while any upgrade notice still to come
could be zero, and emits `blast_admin_events::Unpaused`. Pause and unpause
requests must name nonzero bits the package defines (code 23) and must change at
least one bit (code 24); the witness and notice checks come first.

### Delayed values, actions, sets and maps

The delayed modules are a timelock in the Compound/OpenZeppelin sense: schedule,
wait the applied notice, then apply; cancellable until applied. They are unrelated
to the retired blast_fun_timelock package, whose values switch by themselves; no Blast
package depends on it. Each module owns one type; consumers store four:

| Type | Holds | Used for |
| --- | --- | --- |
| `delayed::Delayed<K, T>` | an applied `value`, its applied `delay_ms`, at most one `delayed::Proposal<T>` | fees, shares, treasuries, destinations, fee splits |
| `delayed_action::DelayedAction<K, A>` | an applied `delay_ms`, at most one `delayed::Proposal<delayed_action::Change<A>>` | one-shot actions: upgrades, immutability, creator-cap reassignment, the root transfer |
| `delayed_set::DelayedSet<K, E>` | admitted `members`, an applied `delay_ms`, pending admissions with fixed deadlines, at most one proposed notice | migration-witness allowlists, the launchpad's account-claim signer keys |
| `delayed_map::DelayedMap<K, E, V>` | applied values by entry `E` in a `Table`, one applied `delay_ms`, at most one pending change per entry with a fixed deadline, at most one proposed notice | per-coin LP-share overrides |

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
  `delayed::Proposal` exposes the proposed `value`, the `delay_ms` in force once it
  applies, and `ready_at_ms`; `delayed::Notice` exposes a notice's `delay_ms` and
  `ready_at_ms`.
- **Explicit application.** Nothing changes until `delayed::apply`,
  `delayed_action::take_action`, `delayed_set::apply_add`, `delayed_map::apply`,
  or a notice `apply_delay` consumes a ready proposal. Readiness alone changes no
  value. Reads need no Clock.
- **Cancellation until applied.** `delayed::cancel`, `delayed_action::cancel`,
  `delayed_set::cancel_add`, `delayed_map::cancel` and the notice cancels work
  even after readiness. Scheduling over a pending proposal cancels it and restarts
  the full applied notice.
- **Zero-notice bootstrap.** A notice can start at zero, so a schedule and its
  apply in one PTB act as a setter. Raising a notice from zero applies at once.
  There is no other mutation path. `delayed::is_guarded`, `delayed_action::is_guarded`
  and `delayed_set::is_guarded` report whether every change still to come waits a
  nonzero notice (for a set, also that no admission is pending); the launchpad and
  presale `unpause` require it of their policies.
- **Ceiling.** No notice exceeds `delayed::max_delay_ms` (2,592,000,000 ms, 30 days):
  constructors and every proposed next notice abort with code 19 above it, so any
  notice can always be changed again.
- **No-op rejection.** A `Delayed` proposal that changes neither value nor notice,
  a notice proposal equal to the applied notice, admitting a current member, and
  a map change to the entry's applied value abort with code 20.
- **Overflow.** Scheduling and application abort with code 19 when a notice exceeds
  the ceiling, or a deadline or the next notice would not fit in a `u64` millisecond
  timestamp.

`Delayed`: `delayed::schedule` proposes a value and the next notice together;
`delayed::schedule_value` keeps the notice; `delayed::schedule_delay` keeps the
value. `delayed::assert_ready` checks readiness without changing anything, so an
owner can settle accrued economics under the applied value before `delayed::apply`.

`DelayedAction`: `delayed_action::schedule` proposes an action under the applied
notice; `delayed_action::schedule_delay` proposes only a notice change.
`delayed_action::take_action` returns a ready action to its owner and aborts with
code 22 when the proposal is a notice change; `delayed_action::apply_delay` does
the reverse. `delayed_action::Change` is `Action(A)` or `Delay`;
`delayed_action::action` returns the action or none.

`DelayedSet`: `delayed_set::schedule_add` snapshots a member's deadline from the
applied notice; a later notice change never moves it. `delayed_set::apply_add`
admits a ready member; `delayed_set::remove` removes a member and discards its
pending admission at once. `delayed_set::contains` is the membership check, and
`delayed_set::pending_count` counts pending admissions (an owner capping its set adds it to the
member count). `delayed_set::SetChange` is `Admission(E)` or `Delay`.

`DelayedMap`: `delayed_map::schedule` proposes setting an entry to a value, or
clearing it with none, and snapshots its deadline from the applied notice; a later
notice change never moves it. Clearing is a delayed change like any other.
`delayed_map::apply` sets or clears a ready entry; `delayed_map::value` reads an
entry's applied value and `delayed_map::pending` its pending
`delayed_map::EntryProposal` (the proposed value and its `delayed::Notice`).
`delayed_map::MapChange` is `Entry { entry, value }` or `Delay`.

The destroy calls (`delayed::destroy`, `delayed_action::destroy`,
`delayed_set::destroy`, `delayed_map::destroy`) abort with code 21 while anything
is pending, so every proposal ends in an event; each emits its module's
`Destroyed` event. Destroying a set or map also ends its remaining members or
entries.

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
- Grants, revocations and role changes take effect in the same transaction.
  Boosts upgrades use a follow-up activation transaction; root transfer waits
  for its delay.

### Reading state

`blast_admin` has no public getters on the `ACL`; read the shared object's
content over RPC, or replay events.

- Active root: `ACL.super_admin_cap_id`. Any other `SuperAdminCap` is inert.
- Who holds which role: `ACL.admins` maps each live `AdminCap` ID to its role
  type names. Type-name strings use 64 lowercase hex characters for the address,
  without `0x`.
- Pending root transfer: `super_admin_transfer.pending` holds a proposal whose
  `value` is `Action(nominee)` and whose `ready_at_ms` is when it becomes
  acceptable; none when nothing is pending.
- Upgrade authority: the consumer's `PackageAdmin` content shows whether its
  `UpgradeCap` remains (`blast_sui::package_admin::has_upgrade_cap` returns it
  for Blast SUI), its policy, and its version.
- Current generation: the consumer's version object content.

### Events

All `blast_admin` events are emitted directly (no envelope). ACL, version and
custody events come from module `blast_admin_events` and carry no ACL ID because
there is one ACL. Delayed lifecycle events come from the module that owns the
type (`delayed`, `delayed_action`, `delayed_set` or `delayed_map`), are generic in
the owner's key `K` and the value, action, member or entry types, and carry `owner`
and `key`. Each map event's `change` names its entry.

| Event | Emitted by | Use |
| --- | --- | --- |
| `blast_admin_events::AdminGranted` | `grant_admin` | new cap ID and recipient |
| `blast_admin_events::AdminRoleGranted` / `blast_admin_events::AdminRoleRevoked` | `grant_role` / `revoke_role` | role added or removed (`role` is the type name) |
| `blast_admin_events::AdminRevoked` | `revoke_admin` | cap removed with the roles it held |
| `blast_admin_events::AdminDestroyed` | `destroy_admin_cap` | cap deleted; `was_active` and the roles it still held |
| `blast_admin_events::SuperAdminTransferred` | `accept_super_admin_transfer` | old and new root cap IDs, recipient |
| `blast_admin_events::SuperAdminCapDestroyed` | `destroy_retired_super_admin_cap` | retired root deleted |
| `blast_admin_events::OperationalVersionAdvanced` | `operational_version::advance` | generation bump of package `M` |
| `blast_admin_events::UpgradeCustodyCreated` | `upgrade_custody::new` | custody sealed: Publisher, cap, package, policy |
| `blast_admin_events::UpgradeAuthorized` | `upgrade_custody::authorize_upgrade` | the exact digest authorized |
| `blast_admin_events::UpgradeCommitted` | `upgrade_custody::commit_upgrade` | new package ID and native version |
| `blast_admin_events::UpgradePolicyRestricted` | the restrict calls | old and new policy |
| `blast_admin_events::UpgradeCapDestroyed` | `upgrade_custody::make_immutable` | final version and policy |
| `blast_admin_events::Paused` | `blast_admin::package_admin::pause` | bits set on package `M`'s version and the resulting mask |
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

Replaying the ACL events in order reconstructs `ACL.admins` and every root
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
| 1 | `EInvalidAdminCap` | `blast_acl` | the `AdminCap` is revoked or unknown (in `sign_in`, `grant_role`, `revoke_role`, `revoke_admin`) |
| 2 | `EInvalidAdminRecipient` | `blast_acl` | `grant_admin` to `0x0` |
| 3 | `EAdminRoleCapacityReached` | `blast_acl` | the cap already holds 32 roles |
| 4 | `EAdminRoleAlreadyGranted` | `blast_acl` | the cap already holds the role |
| 5 | `EAdminRoleNotGranted` | `blast_acl` | `sign_in` or `revoke_role` for a role the cap does not hold; grant it first or use the right role type |
| 6 | `EInvalidSuperAdminRecipient` | `blast_acl` | nominee is `0x0` or the sender; or publish with `blast_acl_root` left at `0x0` |
| 7 | `ENotPendingSuperAdminRecipient` | `blast_acl` | accept from an address that is not the nominee, or with no nomination pending; checked before readiness |
| 8 | `ESuperAdminCapStillActive` | `blast_acl` | destroying the active root |
| 9 | `EOperationalVersionMismatch` | `operational_version` | the call reached outdated bytecode; call the latest package version (or the upgrade did not compile the next generation) |
| 10 | `EOperationalVersionOverflow` | `operational_version` | generation at `u64` max |
| 11 | `EInvalidPackagePublisher` | `upgrade_custody` | the `Publisher` is not from the package |
| 12 | `EInvalidUpgradeCap` | `upgrade_custody` | the cap is for another package or already upgraded |
| 13 | `EInvalidPackageDigest` | `upgrade_custody`; `blast_admin::package_admin` when scheduling | digest is not 32 bytes |
| 14 | `EUpgradeCapUnavailable` | `upgrade_custody`; `blast_admin::package_admin` when scheduling | the package was made immutable |
| 15 | `EUpgradePolicyNotMoreRestrictive` | `upgrade_custody` | the policy is already that strict or stricter |
| 16 | `EInvalidPackageMarker` | `operational_version` | the marker passed to `operational_version::new` or `package_version::new_publication` is not a one-time witness |
| 17 | `ENotReady` | `delayed`; `delayed_set` for `delayed_set::apply_add`, `delayed_map` for `delayed_map::apply` | applying a proposal, or accepting a root transfer, before its `ready_at_ms` |
| 18 | `ENoPending` | the type's module | applying or cancelling when nothing is pending |
| 19 | `EInvalidDelay` | `delayed` | a notice above `delayed::max_delay_ms` (30 days), or a deadline or next notice that would overflow a Unix millisecond timestamp; choose a notice of at most 30 days |
| 20 | `EUnchanged` | the type's module | the proposal changes nothing, the member is already admitted, `remove` names an unknown member, or a map change repeats the entry's applied value (clearing an absent entry included) |
| 21 | `EProposalPending` | the type's module | destroying a delayed value, action slot, set or map while a proposal is pending; cancel it first |
| 22 | `EWrongChange` | `delayed_action` | `take_action` on a notice change, or a notice `apply_delay` on an action; checked before readiness |
| 23 | `EInvalidPauseBits` | `package_version` | pause or unpause names zero bits or a bit the package does not define |
| 24 | `EPauseUnchanged` | `package_version` | pausing only bits already set, or clearing only bits already clear |
| 25 | `EPaused` | `package_version` | the operation's pause bit is set; wait for Blast to unpause it |
| 26 | `EWrongUpgradeAction` | `blast_admin::package_admin` | the ready action is not the upgrade of this digest (authorize) or not immutability (make immutable) |
| 27 | `EUnguardedUpgradeNotice` | `blast_admin::package_admin` | clearing pause bits while the upgrade notice is zero or a pending change would make it zero |
| 28 | `EInvalidPackageWitness` | `package_version` | the unpause witness type given to `new_publication` is a primitive, the package's marker, or from another package |
| 29 | `EWrongUnpauseWitness` | `package_version` | `clear_pause_bits` received a value of a type other than the unpause witness pinned at publication |

The one an integrator most often meets is code 9 from `operational_version`: a
PTB built against an old package ID after an upgrade.

### Pitfalls

- An `AdminWitness` exists only inside one transaction. There is no reusable
  admin token to hand to a bot; a bot needs its own `AdminCap`.
- A revoked `AdminCap` still exists in its holder's wallet. Check `ACL.admins`,
  not ownership, to know whether a cap works.
- Role names repeat across packages (`UpgradeAdmin`, `FeeAdmin`). Always compare
  the full type name, including the package address.
- After any upgrade of `blast_fun`, `blast_fun_migrators`, `blast_sui`, or
  `blast_boosts_aftermath`, PTBs pinned to the old package ID abort with code
  9.

### Q&A

**Who can change Blast's fees or settings?** Only an
`AdminCap` listed in `ACL.admins` with that package's specific role, signed in
within the same transaction. The root cannot act on any package directly.

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
package is a different type, so the transaction does not type-check.

**Which Blast packages can still be upgraded?** Those whose `PackageAdmin` still
holds an `UpgradeCap`: check each one's custody. `blast_admin`,
`blast_partners`, and `blast_boosts_core` are immutable. `blast_fun_migrators`
exposes no way to restrict or seal itself.

**What stops a stale package version from moving funds?** Every protected call
checks the shared generation against the generation compiled into the bytecode,
and the upgrade finalizer advances the generation in the same transaction that
commits the upgrade.

**What does an upgrade leave on chain?** `UpgradeAuthorized` with the exact
digest, `UpgradeCommitted` with the new package ID, and
`OperationalVersionAdvanced` with the new generation, all in one transaction.

**Can someone forge a version bump event?** No. `OperationalVersion<M>` can only
be created with `M`'s one-time witness inside `M`'s package `init`, and only the
module holding it can advance it.

**Does the presale use this ACL?** Yes. `blast_presale_domain` declares nine
presale roles, granted like any other package's.
