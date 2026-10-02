# 0097: One singleton ACL with typed roles

- Status: proposed
- Date: 2026-09-27
- Amended in place: 2026-10-02 (admin package review) — Publisher read access,
  UID-bound generation advance, and the publication-record gate
- Supersedes: [0094](0094-one-role-per-administrator-action.md)'s role bits,
  checks, and gate map; keeps its role grouping
- Amends: [0061](0061-blastsui-routine-admin-and-composable-package-custody.md),
  [0073](0073-series-one-adapter-owned-vaults.md), and
  [0085](0085-explorer-visible-type-naming.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

`type_name::with_defining_ids` names a type by the ID of the package that first
introduced it
(`sui@06734f6:crates/sui-framework/packages/move-stdlib/sources/type_name.move:42-45`).

## Context

`blast_admin::acl::new` let every package create its own `Authority<Domain>` and
`SuperAdminCap<Domain>` from its one-time witness. By 2026-09-26 that meant five
roots and five registries: launchpad and migrators, Boosts, Blast SUI, partners,
and presale, with more to come with every package. On 2026-09-27 the owner asked
for one admin: one shared object, one type, one package, created on `init`, with
strict roles so that a role in one package can never act in another.

Role bitmaps also needed a runtime `assert_role` in every function. ADR 0094 found
fourteen launchpad and migrator functions without one, and Blast SUI still had two.

## Decision

**One ACL.** `blast_admin::blast_acl` creates one shared `ACL` and one
`SuperAdminCap` in its `init` and sends the cap to the publisher. Nothing else
can create either. The ACL lists every live `AdminCap` ID with its roles' type
names, up to 32 admins of up to 32 roles each, inline so an explorer shows every
admin in one object. Root keeps its narrow powers: grant and revoke admins and
roles, and transfer itself after a delay.

**A timelocked root transfer.** The nominated next super admin is one field, a
`blast_fun_timelock::Timelocked<Option<address>>` from the published immutable
util package: none until 7 days after the nomination, then the nominee, who must
accept. The 7 days is fixed in the timelock and cannot change. Beginning,
cancelling, or accepting a transfer stores a fresh timelock, so a replaced or
cancelled nominee can never accept, even after its delay has passed.

**A role is a type.** Each consumer package declares its roles as ability-free
structs in its `*_domain` module, for example `blast_fun_domain::FeeAdmin`. The
role's package address is part of its type, so `blast_fun_domain::FeeAdmin` and
`blast_boosts_core::RiskAdmin` can never be confused.

**Many roles per cap.** `grant_admin` mints a roleless `AdminCap`; root then adds
or removes each role with `grant_role<Role>` and `revoke_role<Role>`.
`sign_in<Role>` checks that the cap is live and holds `Role`, and returns
`AdminWitness<Role>`. A transaction that uses several roles signs in once per
role. A roleless cap signs in to nothing.

**The signature is the check.** An administrator function takes
`_: &AdminWitness<Role>` and has no `assert_role` line. A function cannot forget
its role, and no witness reaches a function that names a different role.
Package source gates reject any `AdminWitness<` that does not name one of the
package's declared roles.

**Roles.** ADR 0094's launchpad grouping carries over one-for-one as types
(`UpgradeAdmin`, `CreatorAdmin`, `BuybackAdmin`, `TreasuryAdmin`, `FeeAdmin`,
`ListingAdmin`, `AdapterAdmin`, `ClaimSignerAdmin`, `RewardsAdmin`); migrators use
the launchpad's roles. Boosts core declares `VaultIssuer`, `RiskAdmin`,
`ShutdownAdmin`, and `UpgradeAdmin`, which the Aftermath adapter also uses. Blast
SUI declares `UpgradeAdmin` for package custody, including capability intake, and
`FeeAdmin` for the redemption fee. Both used to accept any live admin.

**Names.** The package keeps the Move name `blast_admin`. Its ACL module is
`blast_acl` and its event module is `blast_admin_events`. Explorers show
`blast_acl::ACL`, `blast_acl::SuperAdminCap`, `blast_acl::AdminCap`, and
`blast_admin_events::AdminRoleGranted`, whose role field names the role type. Events carry no ACL ID because there is one
ACL. Role fields hold the `with_defining_ids` type name, which never changes once
the role's package introduces it. Initialization emits no event (ADR 0058).

**Publication.** The ACL package is published immutable, like the `blast_admin`
it replaces, together with `upgrade_custody` and `operational_version`. An
upgradeable ACL would make its UpgradeCap a hidden root over every package.
Because nothing can be added later, two seams were settled before publication
(2026-10-02):

- `upgrade_custody::publisher` borrows the sealed `Publisher`. Every framework
  path that moves or burns a `Publisher` takes it by value, so the reference
  cannot end custody, but it lets a consumer wrapper gate `Display`,
  `TransferPolicy`, and other provenance-gated features behind a role instead
  of losing them forever when it wraps. A consumer exposes it only when a
  feature needs it.
- `operational_version::advance` takes the versioned object's `&UID` instead of
  a caller-chosen `ID`. Anyone can instantiate `OperationalVersion<M>` for any
  marker, so the event type alone is forgeable; binding `container_id` to a UID
  the caller holds means a reducer keyed on the container recorded in
  publication effects (ADR 0058) cannot be fed a forged generation.

The `blast_admin` at `0x247b…` is the retired `acl::Authority<Domain>` lineage
with different modules; the NVDA deployment record holds its publication.
`Published.toml` carries no entry until this lineage is published, and the
boundary gate then requires a deployment record whose `sourceDigest`
(`scripts/source_digest.sh`) matches the published source, so a stale record
can never again point consumers at the wrong package.

## Alternatives considered

**Namespaced bitmaps.** `sign_in<Namespace>` returning a `u64` bitmap per
package. This is the smallest consumer change, but it keeps the forgettable
`assert_role` call and the gate maps.

**One role per cap.** `AdminCap<Role>` would name its role in the wallet and
need no role functions, but an operator with several concerns would hold one cap
per role. The owner rejected it on 2026-09-27: an admin must be able to hold
several roles.

**Namespace by package address.** Coarser than a type, with the same runtime
check as bitmaps.

**Require a witness from the role's package to grant it.** Only root grants, and
a cap for a role that no function names authorizes nothing, so this adds a
function without adding safety.

## Consequences

- There is one root cap to custody and one object to audit for every Blast
  package, including packages that do not exist yet.
- One operator's cap may hold several roles; deploy runbooks still grant each
  concern deliberately, by role.
- Every consumer's public signatures name this ACL package's `AdminWitness`. A
  future ACL replacement means republishing consumers. Timelocked grants need no
  ACL change, because `AdminCap` has `store` and a custodian can hold it.
- `blast_admin` now depends on the immutable `blast_fun_timelock`, pinned at the
  same util revision the partners package uses.
- The live Boosts core and adapter on mainnet stay on the old `blast_admin`
  (`0x247b…`) until the planned fresh Boosts redeploy. Boosts core is immutable,
  so that deployment cannot move.
- The launchpad `admin_roles.awk` map, the role constants and getters, and
  per-package authority fixtures are deleted.

## Verification

- A custody test creates a `Display` from the sealed `Publisher`; the advance tests
  pin the container UID in the emitted fact; the boundary self-test rejects a
  by-value or mutable `Publisher` return and a `Published.toml` entry that no
  record carries or whose recorded digest differs from the source.
- `blast_admin` tests cover init, admin and role grant and revocation, roleless and
  missing-role sign-in, both capacities, destroy, foreign ACL and root rejection,
  and the root transfer, including that a cancelled, replaced, or already accepted
  nominee cannot accept after the delay. The boundary self-test rejects a typed
  ACL, a storable root, a copyable witness, a per-domain constructor, an
  untimelocked nominee, and an unpinned timelock.
- Each consumer's source gate pins its declared roles and rejects a witness naming
  any other type. Consumer tests use `blast_acl::witness_for_testing<Role>()`.
