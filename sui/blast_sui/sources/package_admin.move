// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for package capabilities.
module blast_sui::package_admin;

use blast_sui::{
    acl::AdminWitness,
    blast::BLAST,
    blast_sui::BLAST_SUI,
    constants,
    deposit_receipt::BlastSuiDepositReceipt,
    events,
    fun_sui::FUN_SUI,
    package_version::PackageVersion,
};
use std::type_name;
use sui::{
    coin_registry::MetadataCap,
    display_registry::DisplayCap,
    dynamic_object_field,
    package::{Self, Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket},
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
#[test_only]
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
use fun dynamic_object_field::exists_with_type as UID.has_dynamic_object_field_with_type;

// === Public Structs ===

/// Shared, non-releasable custody for package and update authority.
public struct PackageAdmin has key {
    id: UID,
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
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
        publisher.from_module<BLAST>(),
        blast_sui::errors::invalid_package_publisher!(),
    );
    let package_id = upgrade_cap.package();
    assert!(
        package_id.to_address() == type_name::original_id<BLAST>(),
        blast_sui::errors::invalid_upgrade_cap!(),
    );

    new_unchecked(publisher, upgrade_cap, ctx)
}

/// Attaches one exact capability type under active routine-admin authority.
public fun add_capability<Capability: key + store>(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness,
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
    _: &AdminWitness,
) {
    package_version.assert_current();
    let previous_policy = self.upgrade_cap.policy();
    self.assert_policy_can_be_restricted_to(package::additive_policy());

    self.upgrade_cap.only_additive_upgrades();

    events::upgrade_policy_restricted(previous_policy, self.upgrade_cap.policy());
}

/// Activates bytecode that is exactly one operational generation after shared state.
///
/// The activation PTB signs in an active routine admin before this call.
public fun activate_package_version(
    package_version: &mut PackageVersion,
    _: &AdminWitness,
) {
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

fun assert_policy_can_be_restricted_to(self: &PackageAdmin, new_policy: u8) {
    assert!(
        new_policy > self.upgrade_cap.policy(),
        blast_sui::errors::upgrade_policy_not_more_restrictive!(),
    );
}

// === Test-Only Types ===

#[test_only]
public struct TEST_PACKAGE_ADMIN() has drop;

// === Test-Only Functions ===

#[test_only]
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(
    package_id: ID,
    fun_metadata_cap: MetadataCap<FUN_SUI>,
    blast_metadata_cap: MetadataCap<BLAST_SUI>,
    display_cap: DisplayCap<BlastSuiDepositReceipt>,
    ctx: &mut TxContext,
): PackageAdmin {
    let mut self = new_unchecked(
        package::test_claim(TEST_PACKAGE_ADMIN(), ctx),
        package::test_publish(package_id, ctx),
        ctx,
    );
    self.attach_capability(fun_metadata_cap);
    self.attach_capability(blast_metadata_cap);
    self.attach_capability(display_cap);
    self
}

#[test_only]
/// Creates incomplete custody for staged-construction rejection tests.
public fun new_empty_for_testing(package_id: ID, ctx: &mut TxContext): PackageAdmin {
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
