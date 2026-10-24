// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for the adapter Publisher and UpgradeCap.
///
/// Authorization, activation and immutability take `AdminWitness<UpgradeAdmin>`,
/// the upgrade role the core declares for every adapter. Receipt commit carries
/// the native authorization proof instead. Custody itself stays package-local:
/// this adapter's generation advances without touching the core, which is
/// immutable and has no generation of its own.
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
/// Version-independent so the live UpgradeAdmin can repair a mismatched build.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
): UpgradeTicket {
    self.custody.authorize_upgrade(self.id.to_inner(), digest)
}

/// Commits the receipt bound to this cap without changing the active generation.
///
/// Authorization, native upgrade and receipt commit complete in one transaction.
/// The receipt already proves authorization; repair finalization is version-independent.
public fun commit_upgrade(
    self: &mut PackageAdmin,
    receipt: UpgradeReceipt,
) {
    self.custody.commit_upgrade(self.id.to_inner(), receipt);
}

/// Activates the running successor in a follow-up transaction, only if its
/// compiled generation is exactly next. A mismatched build leaves the old
/// generation serving. The caller cannot choose the target generation.
public fun activate_upgrade(
    protocol: &mut Protocol,
    _: &AdminWitness<UpgradeAdmin>,
) {
    protocol.activate();
}

/// Irreversibly destroys native upgrade authority for this adapter.
/// The running code must match the active generation before giving up repair.
public fun make_immutable(
    self: &mut PackageAdmin,
    protocol: &Protocol,
    _: &AdminWitness<UpgradeAdmin>,
) {
    protocol.assert_current();

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
    blast_acl::AdminWitness,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_boosts_aftermath::blast_boosts_aftermath::{BLAST_BOOSTS_AFTERMATH, Protocol};

use blast_boosts_core::blast_boosts_core::UpgradeAdmin;

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
