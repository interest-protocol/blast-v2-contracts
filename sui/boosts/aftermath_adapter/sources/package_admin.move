// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for the adapter Publisher and UpgradeCap.
///
/// The adapter shares the Boosts core administration domain, so its governed
/// transitions accept `AdminWitness<BLAST_BOOSTS_CORE>` and assert the role that
/// core exports. Custody itself stays package-local: this adapter's
/// generation advances without touching the core, which is immutable and has no
/// generation of its own.
module blast_boosts_aftermath::package_admin;

// === Public Types ===

/// Shared, non-releasable adapter package authority.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_BOOSTS_AFTERMATH>,
}

// === Public Functions ===

/// Validates the canonical adapter capabilities and seals them into custody.
///
/// `upgrade_custody::new` owns the complete provenance check: the Publisher must
/// belong to this package and the cap must be this package's never-upgraded one.
/// No later call re-reads those fields, because the sealed value cannot hold
/// anything else.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    // from_module compares both the package address and the canonical module name.
    assert!(
        publisher.from_module<BLAST_BOOSTS_AFTERMATH>(),
        blast_boosts_aftermath::errors::invalid_package_publisher!(),
    );

    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_BOOSTS_AFTERMATH>(id.to_inner(), publisher, upgrade_cap);

    transfer::share_object(PackageAdmin { id, custody });
}

/// Authorizes one exact adapter digest under the sealed cap's current policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    digest: vector<u8>,
): UpgradeTicket {
    protocol.assert_current();
    admin_witness.assert_role(domain::package_admin_role());

    self.custody.authorize_upgrade(self.id.to_inner(), digest)
}

/// Commits the native receipt and advances one operational generation at once.
///
/// This is the only upgrade finalizer. Both mutations belong to the same
/// transaction, so a failure at either step rolls back the whole upgrade.
public fun commit_upgrade_and_advance(
    self: &mut PackageAdmin,
    protocol: &mut Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    receipt: UpgradeReceipt,
) {
    admin_witness.assert_role(domain::package_admin_role());
    protocol.assert_next();

    self.custody.commit_upgrade(self.id.to_inner(), receipt);
    protocol.advance();
}

/// Irreversibly narrows adapter upgrades to additive changes.
public fun restrict_to_additive(
    self: &mut PackageAdmin,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::package_admin_role());

    self.custody.restrict_to_additive(self.id.to_inner());
}

/// Irreversibly narrows adapter upgrades to dependency-only changes.
public fun restrict_to_dependency_only(
    self: &mut PackageAdmin,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::package_admin_role());

    self.custody.restrict_to_dependency_only(self.id.to_inner());
}

/// Irreversibly destroys native upgrade authority for this adapter.
public fun make_immutable(
    self: &mut PackageAdmin,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::package_admin_role());

    self.custody.make_immutable(self.id.to_inner());
}

// === Test-Only Functions ===

#[test_only]
/// Reports whether native upgrade authority remains sealed in custody.
public fun has_upgrade_cap_for_testing(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

#[test_only]
/// Creates unshared custody around this package's simulated capabilities.
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_BOOSTS_AFTERMATH>(
        id.to_inner(),
        blast_boosts_aftermath::blast_boosts_aftermath::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_BOOSTS_AFTERMATH>().to_id(),
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

use blast_boosts_aftermath::{blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH, protocol::Protocol};

use blast_boosts_core::blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE};

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
