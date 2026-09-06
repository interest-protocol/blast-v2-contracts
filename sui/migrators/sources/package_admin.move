/// Sealed custody for the migrators package's Publisher and UpgradeCap.
///
/// Migrators shares the Launchpad administration domain, so its governed
/// transitions accept `AdminWitness<LAUNCHPAD_DOMAIN>` and assert the role that
/// Launchpad exports. Custody itself stays package-local: advancing Migrators
/// leaves Launchpad and Distributor on their own generations.
module blast_fun_migrators::package_admin;

use blast_admin::{
    acl::AdminWitness,
    upgrade_custody::{Self, UpgradeCustody},
};
use blast_fun::launchpad_domain::{Self, LAUNCHPAD_DOMAIN};
use blast_fun_migrators::{package_marker::PACKAGE_MARKER, package_version::PackageVersion};
use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};

// === Errors ===

#[error(code = 0)]
const EInvalidPackagePublisher: vector<u8> =
    b"Publisher must be claimed by the canonical migrators package module.";

// === Public Structs ===

/// Shared custody for this package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<PACKAGE_MARKER>,
}

// === Public Functions ===

/// Validates and permanently seals the migrators Publisher and raw UpgradeCap.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    // from_module compares both the package address and the canonical module name.
    assert!(publisher.from_module<PACKAGE_MARKER>(), EInvalidPackagePublisher);

    let id = object::new(ctx);
    let custody = upgrade_custody::new<PACKAGE_MARKER>(id.to_inner(), publisher, upgrade_cap);

    transfer::share_object(PackageAdmin { id, custody });
}

/// Authorizes the exact package digest under the sealed cap's current policy.
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

/// Commits the native receipt and advances one operational generation at once.
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

/// Irreversibly narrows the sealed UpgradeCap to additive upgrades.
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

/// Irreversibly narrows the sealed UpgradeCap to dependency-only upgrades.
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

/// Irreversibly destroys native upgrade authority for this package.
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

/// Reports whether native upgrade authority remains sealed in custody.
public fun has_upgrade_cap(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<PACKAGE_MARKER>(
        id.to_inner(),
        blast_fun_migrators::package_marker::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<PACKAGE_MARKER>().to_id(),
            ctx,
        ),
    );

    PackageAdmin { id, custody }
}

#[test_only]
public fun id_for_testing(self: &PackageAdmin): ID {
    self.id.to_inner()
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.custody.policy_for_testing()
}
