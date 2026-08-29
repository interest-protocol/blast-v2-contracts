// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for the framework Publisher and UpgradeCap.
module blast_sui::package_admin;

use blast_sui::{
    acl::{ProtocolAuthority, SuperAdminCap},
    blast::BLAST,
    constants,
    events,
    package_version::PackageVersion,
};
use std::type_name;
use sui::package::{Self, Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};

// === Public Structs ===

/// Shared, non-releasable custody for package provenance and upgrade authority.
public struct PackageAdmin has key {
    id: UID,
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
}

// === Public Functions ===

/// Validates and permanently wraps this package's Publisher and raw UpgradeCap.
///
/// Deployment must call this before any raw-cap upgrade. An upgraded cap names
/// the replacement package, while this intake deliberately accepts only the
/// original package ID.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    // from_module compares both the package address and the module name.
    assert!(
        publisher.from_module<BLAST>(),
        blast_sui::errors::invalid_package_publisher!(),
    );
    let package_id = upgrade_cap.package();
    assert!(
        package_id.to_address() == type_name::original_id<BLAST>(),
        blast_sui::errors::invalid_upgrade_cap!(),
    );

    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    let package_version = upgrade_cap.version();
    let policy = upgrade_cap.policy();
    let package_admin = new(publisher, upgrade_cap, ctx);
    let package_admin_id = object::id(&package_admin);

    transfer::share_object(package_admin);

    events::package_admin_created(
        package_admin_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        package_version,
        policy,
    );
}

/// Authorizes the exact package digest under the wrapped cap's current policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    authority: &ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
    authority.assert_super_admin(super_admin_cap);
    assert!(
        digest.length() == constants::package_digest_length!(),
        blast_sui::errors::invalid_package_digest!(),
    );

    // The native cap clears its package id while a ticket is outstanding; read first.
    let package_id = self.upgrade_cap.package();
    let cap_version = self.upgrade_cap.version();
    let policy = self.upgrade_cap.policy();
    let ticket = self.upgrade_cap.authorize(policy, digest);

    events::upgrade_authorized(package_id, cap_version, policy, *ticket.digest());
    ticket
}

/// Commits a native receipt into the same wrapped UpgradeCap.
public fun commit_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    receipt: UpgradeReceipt,
) {
    package_version.assert_current();
    let new_package_id = receipt.package();
    let previous_version = self.upgrade_cap.version();

    self.upgrade_cap.commit(receipt);

    events::upgrade_committed(new_package_id, previous_version, self.upgrade_cap.version());
}

/// Irreversibly narrows upgrades to additive changes.
///
/// Additive is the strictest exposed policy. A dependency-only restriction
/// is deliberately not exposed: it would foreclose adding a rescue entry
/// point if a defensive invariant abort ever froze the vault, while
/// additive still permits new code beside the frozen path.
public fun restrict_to_additive(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    authority: &ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
) {
    package_version.assert_current();
    authority.assert_super_admin(super_admin_cap);
    let previous_policy = self.assert_policy_can_be_restricted_to(package::additive_policy());

    self.upgrade_cap.only_additive_upgrades();

    events::upgrade_policy_restricted(previous_policy, self.upgrade_cap.policy());
}

/// Activates bytecode that is exactly one operational generation after shared state.
///
/// The activation PTB passes the existing authority and active super-admin cap
/// to this new-generation function.
public fun activate_package_version(
    package_version: &mut PackageVersion,
    authority: &ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
) {
    authority.assert_super_admin(super_admin_cap);

    package_version.activate();
}

// === Private Functions ===

fun new(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext): PackageAdmin {
    PackageAdmin { id: object::new(ctx), publisher, upgrade_cap }
}

fun assert_policy_can_be_restricted_to(self: &PackageAdmin, new_policy: u8): u8 {
    let previous_policy = self.upgrade_cap.policy();
    assert!(
        new_policy > previous_policy,
        blast_sui::errors::upgrade_policy_not_more_restrictive!(),
    );

    previous_policy
}

// === Test-Only Types ===

#[test_only]
public struct TEST_PACKAGE_ADMIN() has drop;

// === Test-Only Functions ===

#[test_only]
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(package_id: ID, ctx: &mut TxContext): PackageAdmin {
    new(
        package::test_claim(TEST_PACKAGE_ADMIN(), ctx),
        package::test_publish(package_id, ctx),
        ctx,
    )
}

#[test_only]
public fun publisher_id_for_testing(self: &PackageAdmin): ID {
    object::id(&self.publisher)
}

#[test_only]
public fun upgrade_cap_id_for_testing(self: &PackageAdmin): ID {
    object::id(&self.upgrade_cap)
}

#[test_only]
public fun package_id_for_testing(self: &PackageAdmin): ID {
    self.upgrade_cap.package()
}

#[test_only]
public fun version_for_testing(self: &PackageAdmin): u64 {
    self.upgrade_cap.version()
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.upgrade_cap.policy()
}
