// `errors` intentionally centralizes package abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for the Series1 Publisher and UpgradeCap.
module blast_leverage_series_one::package_admin;

use blast_leverage_series_one::{
    acl::AdminWitness,
    constants,
    events,
    package_version::PackageVersion,
    series_one::SERIES_ONE,
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

/// Validates the Series1 capabilities and returns composable unshared custody.
public fun new(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin {
    assert!(
        publisher.from_module<SERIES_ONE>(),
        blast_leverage_series_one::errors::invalid_package_publisher!(),
    );
    assert!(
        upgrade_cap.package().to_address() == type_name::original_id<SERIES_ONE>(),
        blast_leverage_series_one::errors::invalid_upgrade_cap!(),
    );

    new_unchecked(publisher, upgrade_cap, ctx)
}

/// Irreversibly shares custody and emits its complete creation fact.
public fun share(self: PackageAdmin) {
    let package_admin_id = self.id.to_inner();
    let publisher_id = object::id(&self.publisher);
    let upgrade_cap_id = object::id(&self.upgrade_cap);
    let package_id = self.upgrade_cap.package();
    let package_version = self.upgrade_cap.version();
    let policy = self.upgrade_cap.policy();

    transfer::share_object(self);
    events::package_admin_created(
        package_admin_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        package_version,
        policy,
    );
}

/// Authorizes one exact package digest under the wrapped cap's current policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
    admin_witness.assert_role(constants::package_admin_role!());
    assert!(
        digest.length() == constants::package_digest_length!(),
        blast_leverage_series_one::errors::invalid_package_digest!(),
    );

    // Native authorization clears the cap's package id until the receipt is committed.
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
    events::upgrade_committed(
        new_package_id,
        previous_version,
        self.upgrade_cap.version(),
    );
}

/// Irreversibly narrows upgrades to additive changes.
public fun restrict_to_additive(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness,
) {
    package_version.assert_current();
    admin_witness.assert_role(constants::package_admin_role!());
    let previous_policy = self.upgrade_cap.policy();
    self.assert_policy_can_be_restricted_to(package::additive_policy());

    self.upgrade_cap.only_additive_upgrades();
    events::upgrade_policy_restricted(previous_policy, self.upgrade_cap.policy());
}

/// Irreversibly narrows upgrades to dependency-only changes.
public fun restrict_to_dependency_only(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness,
) {
    package_version.assert_current();
    admin_witness.assert_role(constants::package_admin_role!());
    let previous_policy = self.upgrade_cap.policy();
    self.assert_policy_can_be_restricted_to(package::dep_only_policy());

    self.upgrade_cap.only_dep_upgrades();
    events::upgrade_policy_restricted(previous_policy, self.upgrade_cap.policy());
}

/// Activates bytecode exactly one operational generation after shared state.
///
/// The activation transaction signs in through the old active bytecode before
/// invoking this function from the newly published package generation.
public fun activate_package_version(
    package_version: &mut PackageVersion,
    admin_witness: &AdminWitness,
) {
    admin_witness.assert_role(constants::package_admin_role!());
    package_version.activate();
}

// === Private Functions ===

fun new_unchecked(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin {
    PackageAdmin { id: object::new(ctx), publisher, upgrade_cap }
}

fun assert_policy_can_be_restricted_to(self: &PackageAdmin, new_policy: u8) {
    assert!(
        new_policy > self.upgrade_cap.policy(),
        blast_leverage_series_one::errors::upgrade_policy_not_more_restrictive!(),
    );
}

// === Test-Only Types ===

#[test_only]
public struct TEST_PACKAGE_ADMIN() has drop;

// === Test-Only Functions ===

#[test_only]
/// Creates unshared administration around simulated package capabilities.
public fun new_for_testing(package_id: ID, ctx: &mut TxContext): PackageAdmin {
    new_unchecked(
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
