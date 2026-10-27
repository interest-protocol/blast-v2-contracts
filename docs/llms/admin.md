## Administration

### What it is

Package `blast_admin` is Blast's administration layer. It holds one shared
access-control list (ACL) for every Blast package, with one cold root capability
and up to 32 administrator capabilities. Each administrator holds roles, and a
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

`ACL` fields: `super_admin_cap_id` (the one root cap that works), `admins` (a
map from `AdminCap` ID to a set of role type names), and `pending_super_admin`
(a timelocked `Option<address>`; see "Time rules").

Root powers are narrow: membership, roles, and its own delayed transfer. Root
cannot sign in to any role and cannot call any consumer function. Every
operational action needs an `AdminCap` holding the right role.

### Roles by package

A role is an ability-free struct. The ACL stores its type name with defining
IDs: the address of the package that first declared it, then module and struct.
Same-named roles in different packages are different types.

| Package | Declared in | Roles |
| --- | --- | --- |
| `blast_sui` | `blast_sui_domain` | `blast_sui_domain::UpgradeAdmin` (attach package capabilities; authorize, commit, restrict, or seal upgrades), `blast_sui_domain::FeeAdmin` (blastSUI redemption fee) |
| `blast_boosts_core` | `blast_boosts_core` | `blast_boosts_core::blast_boosts_core::VaultIssuer` (issue a Vault and its share currency, update its metadata), `blast_boosts_core::blast_boosts_core::RiskAdmin` (fees, NAV cap, max order notional, withdraw admin fees, accepted partners), `blast_boosts_core::blast_boosts_core::ShutdownAdmin` (begin a Vault's shutdown), `blast_boosts_core::blast_boosts_core::UpgradeAdmin` (adapter package upgrades) |
| `blast_boosts_aftermath` | declares none | uses the four Boosts core roles |
| `blast_partners` | `blast_partners` | `blast_partners::blast_partners::PartnerAdmin` (register partners, schedule shares and caps) |

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
   the same PTB, for example `launch_config::set_creation_fee` with
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
   `Clock` at `0x6`. Emits `SuperAdminTransferStarted` with `execute_after_ms`
   (and `SuperAdminTransferCancelled` for a replaced nominee).
2. At or after `execute_after_ms`, the nominee's address calls
   `blast_acl::accept_super_admin_transfer` with the `ACL` and `Clock`. Emits
   `SuperAdminTransferred` with the old and new cap IDs.
3. The old holder may call `blast_acl::destroy_retired_super_admin_cap`. Emits
   `SuperAdminCapDestroyed`.

#### Upgrade a consumer package (Blast admin)

For consumers other than the Boosts adapter, use one PTB:

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
`package_id` (the package's original ID), and the old and new generations.
Integrators pass the version object as a shared, immutable input to every call
that takes it and must call the latest package version.

### Upgrade custody

`upgrade_custody::new` seals a package's `Publisher` and never-upgraded
`UpgradeCap` (version 1) after checking both belong to the package of `M`.
Neither can leave the custody. The consumer's shared `PackageAdmin` wraps it and
gates authorization behind its upgrade role. Boosts receipt commit instead carries
the native authorized receipt. Boosts `wrap`, and Blast SUI's `new` and `share`, need
only the package's own `Publisher` and `UpgradeCap`:

| Package | Custody object | Transitions exposed |
| --- | --- | --- |
| `blast_sui` | `blast_sui::package_admin::PackageAdmin` | `blast_sui::package_admin::new`, `blast_sui::package_admin::add_capability`, `blast_sui::package_admin::share`, `blast_sui::package_admin::authorize_upgrade`, `blast_sui::package_admin::commit_upgrade_and_advance`, `blast_sui::package_admin::restrict_to_additive`, `blast_sui::package_admin::make_immutable`, `blast_sui::package_admin::has_upgrade_cap` |
| `blast_boosts_aftermath` | `blast_boosts_aftermath::package_admin::PackageAdmin` | `blast_boosts_aftermath::package_admin::wrap`, `blast_boosts_aftermath::package_admin::authorize_upgrade`, `blast_boosts_aftermath::package_admin::commit_upgrade`, `blast_boosts_aftermath::package_admin::activate_upgrade`, `blast_boosts_aftermath::package_admin::make_immutable` |

The custody primitives: `upgrade_custody::authorize_upgrade` (exactly one
32-byte digest under the current policy), `upgrade_custody::commit_upgrade`
(commits the receipt into the same cap), `upgrade_custody::restrict_to_additive`
and `upgrade_custody::restrict_to_dependency_only` (irreversible narrowing),
`upgrade_custody::make_immutable` (destroys the cap, keeps the `Publisher`),
`upgrade_custody::has_upgrade_cap`, and `upgrade_custody::publisher` (borrows
the `Publisher` by reference for features like Display; no current consumer
exposes it). After `make_immutable`, every transition that needs the
`UpgradeCap` (authorize, commit, restrict, make immutable) aborts with code 18.
The packages
`blast_admin`, `blast_partners`, and `blast_boosts_core` are published immutable
and have no custody at all.

### Time rules

- Root transfer delay: 604,800,000 ms (seven days), fixed in immutable code. The
  nominee may accept from the first transaction whose `Clock` reads
  `execute_after_ms` or later.
- `pending_super_admin` is a `Timelocked<Option<address>>` with fields `before`,
  `after`, `at_ms`, `delay_ms`. Begin, cancel, and accept each store a fresh
  value, so a replaced, cancelled, or already accepted nominee can never accept.
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
- Pending root transfer: `pending_super_admin.after` holds the nominee (none
  when nothing is pending) and `pending_super_admin.at_ms` when it becomes
  acceptable.
- Upgrade authority: the consumer's `PackageAdmin` content shows whether its
  `UpgradeCap` remains (`blast_sui::package_admin::has_upgrade_cap` returns it
  for Blast SUI), its policy, and its version.
- Current generation: the consumer's version object content.

### Events

All `blast_admin` events are emitted directly (no envelope) from module
`blast_admin_events`, and carry no ACL ID because there is one ACL.

| Event | Emitted by | Use |
| --- | --- | --- |
| `blast_admin_events::AdminGranted` | `grant_admin` | new cap ID and recipient |
| `blast_admin_events::AdminRoleGranted` / `blast_admin_events::AdminRoleRevoked` | `grant_role` / `revoke_role` | role added or removed (`role` is the type name) |
| `blast_admin_events::AdminRevoked` | `revoke_admin` | cap removed with the roles it held |
| `blast_admin_events::AdminDestroyed` | `destroy_admin_cap` | cap deleted; `was_active` and the roles it still held |
| `blast_admin_events::SuperAdminTransferStarted` / `blast_admin_events::SuperAdminTransferCancelled` | begin, replace, cancel | nominee and `execute_after_ms` |
| `blast_admin_events::SuperAdminTransferred` | `accept_super_admin_transfer` | old and new root cap IDs, recipient |
| `blast_admin_events::SuperAdminCapDestroyed` | `destroy_retired_super_admin_cap` | retired root deleted |
| `blast_admin_events::OperationalVersionAdvanced` | `operational_version::advance` | generation bump of package `M` |
| `blast_admin_events::UpgradeCustodyCreated` | `upgrade_custody::new` | custody sealed: Publisher, cap, package, policy |
| `blast_admin_events::UpgradeAuthorized` | `upgrade_custody::authorize_upgrade` | the exact digest authorized |
| `blast_admin_events::UpgradeCommitted` | `upgrade_custody::commit_upgrade` | new package ID and native version |
| `blast_admin_events::UpgradePolicyRestricted` | the restrict calls | old and new policy |
| `blast_admin_events::UpgradeCapDestroyed` | `upgrade_custody::make_immutable` | final version and policy |

Replaying the ACL events in order reconstructs `ACL.admins` and every root
transfer exactly. `ACL` creation emits no event, so the first root cap's ID
comes from the publish transaction's created objects (or the first
`SuperAdminTransferred`, as `previous_super_admin_cap_id`).

### Aborts

Codes are plain `u64` values raised in the `blast_admin` module named.

| Code | Name | Module | Cause and fix |
| --- | --- | --- | --- |
| 0 | `EInvalidSuperAdminCap` | `blast_acl` | the root cap is not the active one |
| 1 | `EInvalidAdminCap` | `blast_acl` | the `AdminCap` is revoked or unknown (in `sign_in`, `grant_role`, `revoke_role`, `revoke_admin`) |
| 2 | `EInvalidAdminRecipient` | `blast_acl` | `grant_admin` to `0x0` |
| 3 | `EAdminCapacityReached` | `blast_acl` | 32 admins already live |
| 4 | `EAdminRoleCapacityReached` | `blast_acl` | the cap already holds 32 roles |
| 5 | `EAdminRoleAlreadyGranted` | `blast_acl` | the cap already holds the role |
| 6 | `EAdminRoleNotGranted` | `blast_acl` | `sign_in` or `revoke_role` for a role the cap does not hold; grant it first or use the right role type |
| 7 | `EInvalidSuperAdminRecipient` | `blast_acl` | nominee is `0x0` or the sender; or publish with `blast_acl_root` left at `0x0` |
| 8 | `ESuperAdminTransferUnchanged` | `blast_acl` | that address is already the nominee |
| 9 | `ENoPendingSuperAdminTransfer` | `blast_acl` | cancel with nothing pending |
| 10 | `ENotPendingSuperAdminRecipient` | `blast_acl` | accept from an address that is not the nominee |
| 11 | `ESuperAdminTransferNotReady` | `blast_acl` | accept before `execute_after_ms` |
| 12 | `ESuperAdminCapStillActive` | `blast_acl` | destroying the active root |
| 13 | `EOperationalVersionMismatch` | `operational_version` | the call reached outdated bytecode; call the latest package version (or the upgrade did not compile the next generation) |
| 14 | `EOperationalVersionOverflow` | `operational_version` | generation at `u64` max |
| 15 | `EInvalidPackagePublisher` | `upgrade_custody` | the `Publisher` is not from the package |
| 16 | `EInvalidUpgradeCap` | `upgrade_custody` | the cap is for another package or already upgraded |
| 17 | `EInvalidPackageDigest` | `upgrade_custody` | digest is not 32 bytes |
| 18 | `EUpgradeCapUnavailable` | `upgrade_custody` | the package was made immutable |
| 19 | `EUpgradePolicyNotMoreRestrictive` | `upgrade_custody` | the policy is already that strict or stricter |
| 20 | `EInvalidPackageMarker` | `operational_version` | the marker passed to `new` is not a one-time witness |

The one an integrator most often meets is code 13 from `operational_version`: a
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
  13.

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

**How much notice is there before root changes hands?** Seven days. The
nomination emits `SuperAdminTransferStarted` and is visible in
`pending_super_admin`, and root can cancel it at any time.

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

**Does the presale use this ACL?** Yes. `blast_presale_domain` declares six
presale roles, granted like any other package's.
