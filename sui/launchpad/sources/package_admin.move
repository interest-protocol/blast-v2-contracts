// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Custodies the package Publisher and UpgradeCap and governs package administration.
module blast_fun::package_admin;

use blast_fun::{
    acl::AdminWitness,
    blast::BLAST,
    constants,
    events,
    package_version::PackageVersion,
};
use std::type_name;
use sui::package::{Self, Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};

// === Public Structs ===

/// Shared custody for the package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
}

// === Public Functions ===

/// Validates and permanently wraps Blast's Publisher and raw UpgradeCap in shared custody.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    assert!(
        publisher.from_package<BLAST>() && publisher.from_module<BLAST>(),
        blast_fun::errors::invalid_package_publisher!(),
    );

    let package_id = upgrade_cap.package();
    assert!(
        package_id.to_address() == type_name::original_id<BLAST>(),
        blast_fun::errors::invalid_upgrade_cap!(),
    );

    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    let package_version = upgrade_cap.version();
    let policy = upgrade_cap.policy();
    let package_admin = new(publisher, upgrade_cap, ctx);
    let package_admin_id = package_admin.id.to_inner();

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
    _: &AdminWitness,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
    assert!(
        digest.length() == constants::package_digest_length!(),
        blast_fun::errors::invalid_package_digest!(),
    );

    let package_id = self.upgrade_cap.package();
    let package_version = self.upgrade_cap.version();
    let policy = self.upgrade_cap.policy();
    let ticket = self.upgrade_cap.authorize(policy, digest);

    events::upgrade_authorized(
        package_id,
        package_version,
        policy,
        *ticket.digest(),
    );

    ticket
}

/// Irreversibly narrows the wrapped UpgradeCap to additive upgrades.
public fun restrict_to_additive(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness,
) {
    package_version.assert_current();
    let previous_policy = self.upgrade_cap.policy();
    self.assert_policy_can_be_restricted_to(package::additive_policy());
    self.upgrade_cap.only_additive_upgrades();

    events::upgrade_policy_restricted(previous_policy, self.upgrade_cap.policy());
}

/// Irreversibly narrows the wrapped UpgradeCap to dependency-only upgrades.
public fun restrict_to_dependency_only(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness,
) {
    package_version.assert_current();
    let previous_policy = self.upgrade_cap.policy();
    self.assert_policy_can_be_restricted_to(package::dep_only_policy());
    self.upgrade_cap.only_dep_upgrades();

    events::upgrade_policy_restricted(previous_policy, self.upgrade_cap.policy());
}

/// Commits the native upgrade receipt into the same wrapped framework cap.
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

/// Activates bytecode that is exactly one operational generation after shared state.
public fun activate_package_version(
    package_version: &mut PackageVersion,
    _: &AdminWitness,
) {
    package_version.activate();
}

// === Private Functions ===

fun new(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext): PackageAdmin {
    PackageAdmin {
        id: object::new(ctx),
        publisher,
        upgrade_cap,
    }
}

fun assert_policy_can_be_restricted_to(self: &PackageAdmin, new_policy: u8) {
    assert!(
        new_policy > self.upgrade_cap.policy(),
        blast_fun::errors::upgrade_policy_not_more_restrictive!(),
    );
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
/// Creates a Publisher from this package but not from the canonical Blast module.
public fun non_blast_publisher_for_testing(ctx: &mut TxContext): Publisher {
    package::test_claim(TEST_PACKAGE_ADMIN(), ctx)
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
