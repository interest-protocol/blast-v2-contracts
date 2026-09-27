// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for package capabilities.
module blast_sui::package_admin;

// === Public Types ===

/// Shared, non-releasable custody for package and update authority.
///
/// The reusable Publisher/UpgradeCap seal is the shared custody value; the
/// package-specific metadata and display capabilities remain dynamic object
/// children of this wrapper.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_SUI_PACKAGE>,
}

/// Type-derived key for a capability owned as a dynamic object field.
public struct CapabilityKey<phantom Capability>() has copy, drop, store;

// === Public Functions ===

/// Validates the fixed package capabilities and returns composable custody.
///
/// Deployment must call this before any raw-cap upgrade. The returned key-only
/// object must receive its required child capabilities before `share`.
public fun new(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin {
    // from_module compares both the package address and the module name.
    assert!(
        publisher.from_module<BLAST_SUI_PACKAGE>(),
        blast_sui::errors::invalid_package_publisher!(),
    );

    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_SUI_PACKAGE>(id.to_inner(), publisher, upgrade_cap);

    PackageAdmin { id, custody }
}

/// Attaches one exact capability type under upgrade-admin authority.
public fun add_capability<Capability: key + store>(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    capability: Capability,
) {
    package_version.assert_current();
    let capability_id = self.attach_capability(capability);

    events::package_capability_added<Capability>(self.id.to_inner(), capability_id);
}

/// Verifies required bootstrap capabilities and irreversibly shares custody.
public fun share(self: PackageAdmin) {
    assert!(
        self.has_capability<MetadataCap<FUN_SUI>>(),
        blast_sui::errors::missing_package_capability!(),
    );
    assert!(
        self.has_capability<MetadataCap<BLAST_SUI>>(),
        blast_sui::errors::missing_package_capability!(),
    );
    assert!(
        self.has_capability<DisplayCap<BlastSuiDepositReceipt>>(),
        blast_sui::errors::missing_package_capability!(),
    );

    transfer::share_object(self);
}

/// Authorizes the exact package digest under the wrapped cap's current policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
    let custodian_id = self.id.to_inner();

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the native receipt and advances one operational generation at once.
///
/// This is the only upgrade finalizer. Both mutations belong to the same
/// transaction, so a failure at either step rolls back the whole upgrade.
public fun commit_upgrade_and_advance(
    self: &mut PackageAdmin,
    package_version: &mut PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    package_version.assert_next();
    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    package_version.advance();
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
    _: &AdminWitness<UpgradeAdmin>,
) {
    package_version.assert_current();
    let custodian_id = self.id.to_inner();

    self.custody.restrict_to_additive(custodian_id);
}

/// Irreversibly destroys native upgrade authority for this package.
///
/// Publisher custody and every sealed child capability survive, so metadata and
/// display administration continue at the final operational generation.
public fun make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
) {
    package_version.assert_current();
    let custodian_id = self.id.to_inner();

    self.custody.make_immutable(custodian_id);
}

/// Reports whether native upgrade authority remains sealed in custody.
public fun has_upgrade_cap(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

// === Private Functions ===

fun attach_capability<Capability: key + store>(
    self: &mut PackageAdmin,
    capability: Capability,
): ID {
    assert!(
        !self.has_capability<Capability>(),
        blast_sui::errors::package_capability_already_exists!(),
    );
    let capability_id = object::id(&capability);
    self.id.add_dynamic_object_field(CapabilityKey<Capability>(), capability);
    capability_id
}

fun has_capability<Capability: key + store>(self: &PackageAdmin): bool {
    self.id
        .has_dynamic_object_field_with_type<_, Capability>(CapabilityKey<Capability>())
}

// === Test-Only Types ===

#[test_only]
public struct TEST_PACKAGE_ADMIN() has drop;

// === Test-Only Functions ===

#[test_only]
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(
    fun_metadata_cap: MetadataCap<FUN_SUI>,
    blast_metadata_cap: MetadataCap<BLAST_SUI>,
    display_cap: DisplayCap<BlastSuiDepositReceipt>,
    ctx: &mut TxContext,
): PackageAdmin {
    let mut self = new_empty_for_testing(ctx);
    self.attach_capability(fun_metadata_cap);
    self.attach_capability(blast_metadata_cap);
    self.attach_capability(display_cap);
    self
}

#[test_only]
/// Creates incomplete custody for staged-construction rejection tests.
public fun new_empty_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_SUI_PACKAGE>(
        id.to_inner(),
        blast_sui::blast_sui_package::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_SUI_PACKAGE>().to_id(),
            ctx,
        ),
    );

    PackageAdmin { id, custody }
}

#[test_only]
/// A Publisher from this package but not from its canonical module.
public fun non_canonical_publisher_for_testing(ctx: &mut TxContext): Publisher {
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
public fun blast_metadata_cap_id_for_testing(self: &PackageAdmin): ID {
    self.capability_id_for_testing<MetadataCap<BLAST_SUI>>()
}

#[test_only]
public fun fun_metadata_cap_id_for_testing(self: &PackageAdmin): ID {
    self.capability_id_for_testing<MetadataCap<FUN_SUI>>()
}

#[test_only]
public fun display_cap_id_for_testing(self: &PackageAdmin): ID {
    self.capability_id_for_testing<DisplayCap<BlastSuiDepositReceipt>>()
}

#[test_only]
public fun capability_id_for_testing<Capability: key + store>(
    self: &PackageAdmin,
): ID {
    let capability = self
        .id
        .dynamic_object_field<_, Capability>(CapabilityKey<Capability>());
    object::id(capability)
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

use blast_sui::{
    blast_sui_package::BLAST_SUI_PACKAGE,
    blast_sui::BLAST_SUI,
    blast_sui_domain::UpgradeAdmin,
    deposit_receipt::BlastSuiDepositReceipt,
    events,
    fun_sui::FUN_SUI,
    package_version::PackageVersion,
};

use sui::{
    coin_registry::MetadataCap,
    display_registry::DisplayCap,
    dynamic_object_field,
    package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket},
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

#[test_only]
use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::exists_with_type as UID.has_dynamic_object_field_with_type;
