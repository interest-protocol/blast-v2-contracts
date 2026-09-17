// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Custodies the package Publisher and UpgradeCap and governs package administration.
///
/// Sealing, native transitions, and their replay events belong to
/// `blast_admin::upgrade_custody`. This module owns only the canonical shared
/// container, the Blast module provenance rule, and the guard order every
/// governed transition must follow.
module blast_fun::package_admin;

// === Public Structs ===

/// Shared custody for the package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST>,
}

// === Public Functions ===

/// Validates and permanently wraps Blast's Publisher and raw UpgradeCap in shared custody.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    // from_module compares both the package address and the canonical module name.
    assert!(
        publisher.from_module<BLAST>(),
        blast_fun::errors::invalid_package_publisher!(),
    );

    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST>(id.to_inner(), publisher, upgrade_cap);

    transfer::share_object(PackageAdmin { id, custody });
}

/// Authorizes the exact package digest under the wrapped cap's current policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
    admin_witness.assert_role(launchpad_domain::package_admin_role());
    let custodian_id = self.id.to_inner();

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the native receipt and advances one operational generation in one call.
///
/// This is the only upgrade finalizer. Both mutations belong to the same
/// transaction, so a failure at either step rolls back the whole upgrade.
public fun commit_upgrade_and_advance(
    self: &mut PackageAdmin,
    package_version: &mut PackageVersion,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
    receipt: UpgradeReceipt,
) {
    admin_witness.assert_role(launchpad_domain::package_admin_role());
    package_version.assert_next();
    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    package_version.advance();
}

/// Irreversibly narrows the wrapped UpgradeCap to additive upgrades.
public fun restrict_to_additive(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
) {
    package_version.assert_current();
    admin_witness.assert_role(launchpad_domain::package_admin_role());
    let custodian_id = self.id.to_inner();

    self.custody.restrict_to_additive(custodian_id);
}

/// Irreversibly narrows the wrapped UpgradeCap to dependency-only upgrades.
public fun restrict_to_dependency_only(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
) {
    package_version.assert_current();
    admin_witness.assert_role(launchpad_domain::package_admin_role());
    let custodian_id = self.id.to_inner();

    self.custody.restrict_to_dependency_only(custodian_id);
}

/// Irreversibly destroys native upgrade authority and freezes this package generation.
public fun make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
) {
    package_version.assert_current();
    admin_witness.assert_role(launchpad_domain::package_admin_role());
    let custodian_id = self.id.to_inner();

    self.custody.make_immutable(custodian_id);
}

/// Reports whether native upgrade authority remains sealed in this package's custody.
public fun has_upgrade_cap(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

// === Test-Only Types ===

#[test_only]
public struct TEST_PACKAGE_ADMIN() has drop;

// === Test-Only Functions ===

#[test_only]
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST>(
        id.to_inner(),
        blast_fun::blast::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST>().to_id(),
            ctx,
        ),
    );

    PackageAdmin { id, custody }
}

#[test_only]
/// Creates a Publisher from this package but not from the canonical Blast module.
public fun non_blast_publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(TEST_PACKAGE_ADMIN(), ctx)
}

#[test_only]
public fun id_for_testing(self: &PackageAdmin): ID {
    self.id.to_inner()
}

#[test_only]
public fun publisher_id_for_testing(self: &PackageAdmin): ID {
    self.custody.publisher_id_for_testing()
}

#[test_only]
public fun upgrade_cap_id_for_testing(self: &PackageAdmin): ID {
    self.custody.upgrade_cap_id_for_testing()
}

#[test_only]
public fun package_id_for_testing(self: &PackageAdmin): ID {
    self.custody.current_package_id_for_testing()
}

#[test_only]
public fun version_for_testing(self: &PackageAdmin): u64 {
    self.custody.native_version_for_testing()
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.custody.policy_for_testing()
}

// === Imports ===

use blast_admin::{
    acl::AdminWitness,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_fun::{
    blast::BLAST,
    launchpad_domain::{Self, LAUNCHPAD_DOMAIN},
    package_version::PackageVersion,
};

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
