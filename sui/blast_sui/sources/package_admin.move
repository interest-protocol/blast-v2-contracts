// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Permanent shared custody for package capabilities and delayed upgrade authority.
module blast_sui::package_admin;

// === Public Types ===

/// A proposed upgrade, repair upgrade, or irreversible immutability.
///
/// `Upgrade` advances the operational generation; `Repair` installs code without
/// advancing it, for the case where a committed upgrade's bytecode did not compile the
/// generation its finalizer advanced to and so rejects every gated call.
/// No policy narrowing exists: under a narrowed policy the compiled generation constants
/// could never change again, so the only finalizer would stop every gated vault entry point.
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>),
    Repair(vector<u8>),
    MakeImmutable,
}

/// Keys the upgrade custody's delayed lifecycle.
public struct UpgradeKey() has copy, drop, store;

/// Shared, non-releasable custody for package and update authority.
///
/// The reusable Publisher/UpgradeCap seal is the shared custody value; the
/// package-specific metadata and display capabilities are dynamic object
/// children sealed by `wrap`. Every upgrade, repair and immutability action waits
/// the applied notice of `upgrade`. `repairing` is true only between
/// `authorize_repair` and `commit_repair` in one transaction, so each authorization
/// can reach only its own finalizer.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_SUI_PACKAGE>,
    upgrade: DelayedAction<UpgradeKey, UpgradeAction>,
    repairing: bool,
}

/// Type-derived key for a capability owned as a dynamic object field.
public struct CapabilityKey<phantom Capability>() has copy, drop, store;

// === Public Functions ===

/// Consumes the unique publication proof and seals native custody before activation.
///
/// The UpgradeCap must be the original package's at native version 1. The receipt
/// Display is created here, so every package child is sealed in the same transaction
/// that shares `PackageAdmin` and the usable `PackageVersion`, with every deposit
/// paused. Upgrade custody starts at the 48-hour notice.
public fun wrap(
    publication: Publication,
    upgrade_cap: UpgradeCap,
    fun_metadata_cap: MetadataCap<FUN_SUI>,
    blast_metadata_cap: MetadataCap<BLAST_SUI>,
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    let (publisher, generation) = publication.destroy();
    let mut id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_SUI_PACKAGE>(id.to_inner(), publisher, upgrade_cap);
    let upgrade = delayed_action::new(UpgradeKey(), &id, constants::initial_notice_ms!());

    id.add_capability(fun_metadata_cap);
    id.add_capability(blast_metadata_cap);
    id.add_capability(deposit_receipt::new_display(display_registry, ctx));

    transfer::share_object(PackageAdmin { id, custody, upgrade, repairing: false });
    generation.share_version(ctx);
}

/// Schedules one exact code digest under the applied notice, replacing any previous action.
public fun schedule_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(
        digest.length() == constants::package_digest_length!(),
        blast_sui::errors::invalid_digest!(),
    );

    self.upgrade.schedule(UpgradeAction::Upgrade(digest), clock);
}

/// Schedules a repair upgrade to one exact digest under the applied notice.
///
/// A repair is the recovery path when no bytecode matches the stored generation, so it
/// deliberately reads no package version: the repaired bytecode must compile
/// `PACKAGE_VERSION` equal to the stored generation. It replaces any previous action,
/// waits the same notice as an upgrade, and `CancelAdmin` can cancel it.
public fun schedule_repair(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
) {
    assert!(
        digest.length() == constants::package_digest_length!(),
        blast_sui::errors::invalid_digest!(),
    );

    self.upgrade.schedule(UpgradeAction::Repair(digest), clock);
}

/// Schedules the irreversible destruction of upgrade authority under the applied notice.
public fun schedule_make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    clock: &Clock,
) {
    package_version.assert_current();

    self.upgrade.schedule(UpgradeAction::MakeImmutable, clock);
}

/// Schedules only a new upgrade notice, after the currently applied notice.
/// Replaces any pending upgrade or immutability action.
public fun schedule_upgrade_delay(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    self.upgrade.schedule_delay(delay_ms, clock);
}

/// Applies a ready notice-only proposal; it cannot consume an upgrade or immutability action.
public fun apply_upgrade_delay(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.upgrade.apply_delay(clock);
}

/// Cancels any scheduled upgrade, repair, immutability or notice change, even after its
/// deadline. Cancelling never applies anything, so it reads no package version and stays
/// available while every bytecode is stale.
public fun cancel_upgrade_action(self: &mut PackageAdmin, _: &AdminWitness<CancelAdmin>) {
    self.upgrade.cancel();
}

/// Consumes the ready upgrade action and authorizes exactly its digest.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
): UpgradeTicket {
    package_version.assert_current();

    let custodian_id = self.id.to_inner();

    let action = self.upgrade.take_action(clock);
    assert!(
        action == UpgradeAction::Upgrade(digest),
        blast_sui::errors::wrong_upgrade_action!(),
    );

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the native receipt and advances one operational generation at once.
///
/// This is the only finalizer for an `Upgrade` action. Both mutations belong to the
/// same transaction, so a failure at either step rolls back the whole upgrade. A
/// repair's receipt cannot reach it.
public fun commit_upgrade_and_advance(
    self: &mut PackageAdmin,
    package_version: &mut PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    package_version.assert_next();

    assert!(!self.repairing, blast_sui::errors::wrong_upgrade_action!());

    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    package_version.advance();
}

/// Consumes the ready repair action and authorizes exactly its digest.
///
/// Like `schedule_repair`, it reads no package version, so a repair stays reachable
/// when every bytecode rejects the stored generation.
public fun authorize_repair(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
): UpgradeTicket {
    let custodian_id = self.id.to_inner();

    let action = self.upgrade.take_action(clock);
    assert!(
        action == UpgradeAction::Repair(digest),
        blast_sui::errors::wrong_upgrade_action!(),
    );
    self.repairing = true;

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits a repair's native receipt without advancing the operational generation.
///
/// Only a receipt authorized by `authorize_repair` in the same transaction reaches it.
public fun commit_repair(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    assert!(self.repairing, blast_sui::errors::wrong_upgrade_action!());
    self.repairing = false;

    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
}

/// Consumes the ready immutability action and destroys native upgrade authority.
///
/// The generation does not advance, so every vault operation continues at the final
/// bytecode. Publisher custody and every sealed child capability survive.
public fun make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    clock: &Clock,
) {
    package_version.assert_current();

    let action = self.upgrade.take_action(clock);
    assert!(action == UpgradeAction::MakeImmutable, blast_sui::errors::wrong_upgrade_action!());

    self.custody.make_immutable(self.id.to_inner());
}

/// Clears the requested deposit pause bits once every notice is guarded.
///
/// Upgrade custody and the vault's redemption fee must each have a nonzero applied
/// notice and no pending change to zero, so a release never leaves a change that could
/// apply without notice. Exits never require unpausing.
public fun unpause(
    self: &PackageAdmin,
    package_version: &mut PackageVersion,
    _: &AdminWitness<UnpauseAdmin>,
    vault: &Vault,
    bits: u8,
) {
    package_version.assert_current();

    assert!(
        self.upgrade.is_guarded() && vault.is_redeem_fee_guarded(),
        blast_sui::errors::unguarded_notice!(),
    );

    package_version.clear_pause_bits(bits);
}

/// Reports whether native upgrade authority remains sealed in custody.
public fun has_upgrade_cap(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

/// The applied notice, in milliseconds, every upgrade, repair or immutability action waits.
public fun upgrade_delay_ms(self: &PackageAdmin): u64 {
    self.upgrade.delay_ms()
}

// === Private Functions ===

fun add_capability<Capability: key + store>(id: &mut UID, capability: Capability) {
    id.add_dynamic_object_field(CapabilityKey<Capability>(), capability);
}

// === Test-Only Functions ===

#[test_only]
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(
    fun_metadata_cap: MetadataCap<FUN_SUI>,
    blast_metadata_cap: MetadataCap<BLAST_SUI>,
    display_cap: DisplayCap<BlastSuiDepositReceipt>,
    ctx: &mut TxContext,
): PackageAdmin {
    let mut id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_SUI_PACKAGE>(
        id.to_inner(),
        blast_sui::blast_sui_package::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_SUI_PACKAGE>().to_id(),
            ctx,
        ),
    );
    let upgrade = delayed_action::new(UpgradeKey(), &id, constants::initial_notice_ms!());

    id.add_capability(fun_metadata_cap);
    id.add_capability(blast_metadata_cap);
    id.add_capability(display_cap);

    PackageAdmin { id, custody, upgrade, repairing: false }
}

#[test_only]
/// Creates unshared custody without package children for vault release tests.
public fun new_bare_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_SUI_PACKAGE>(
        id.to_inner(),
        blast_sui::blast_sui_package::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_SUI_PACKAGE>().to_id(),
            ctx,
        ),
    );
    let upgrade = delayed_action::new(UpgradeKey(), &id, constants::initial_notice_ms!());

    PackageAdmin { id, custody, upgrade, repairing: false }
}

#[test_only]
/// Exercises both public phases of an upgrade with a synthetic notice advance.
public fun authorize_upgrade_for_testing(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    ctx: &mut TxContext,
): UpgradeTicket {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_upgrade(package_version, admin, digest, &clock);
    clock.set_for_testing(self.upgrade.delay_ms());
    let ticket = self.authorize_upgrade(package_version, admin, digest, &clock);
    clock.destroy_for_testing();

    ticket
}

#[test_only]
/// Exercises both public phases of immutability with a synthetic notice advance.
public fun make_immutable_for_testing(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin: &AdminWitness<UpgradeAdmin>,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_make_immutable(package_version, admin, &clock);
    clock.set_for_testing(self.upgrade.delay_ms());
    self.make_immutable(package_version, admin, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun upgrade_for_testing(self: &PackageAdmin): &DelayedAction<UpgradeKey, UpgradeAction> {
    &self.upgrade
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
    delayed_action::{Self, DelayedAction},
    operational_version::OperationalVersion,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_sui::{
    blast_sui::BLAST_SUI,
    blast_sui_domain::{CancelAdmin, UnpauseAdmin, UpgradeAdmin},
    blast_sui_package::{Self, BLAST_SUI_PACKAGE, PackageVersion, Publication},
    constants,
    deposit_receipt::{Self, BlastSuiDepositReceipt},
    fun_sui::FUN_SUI,
    vault::Vault,
};

use sui::{
    clock::Clock,
    coin_registry::MetadataCap,
    display_registry::{DisplayCap, DisplayRegistry},
    dynamic_object_field,
    package::{UpgradeCap, UpgradeReceipt, UpgradeTicket},
};

use fun add_capability as UID.add_capability;

use fun blast_sui_package::share_version as OperationalVersion.share_version;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

#[test_only]
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
