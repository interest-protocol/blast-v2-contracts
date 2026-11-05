// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the package module's abort location.
#[allow(lint(abort_without_constant))]
/// The vault package's publication, its witness admission, and its unpause.
///
/// One list of admitted witness types decides who may create a vault: the venue whose witness
/// calls `vault::new`, and the issuer whose witness sealed the vault's terms, must both be on it.
/// Each witness is the one its module alone can construct. The launchpad and presale witnesses
/// are issuers and the venue witnesses are venues. The list does not distinguish the two roles, so an admitted product witness would
/// also pass the venue check; both are Blast-reviewed code, and products never call `vault::new`.
/// Gating venues binds every position key to venue code Blast reviewed; gating issuers keeps a
/// stranger's terms, with a Blast share and partner of its choosing, out of Blast vaults.
///
/// An admitted venue obtains `VaultTerms` only from `migration::redeem`; it never accepts
/// `VaultTerms` from its caller. Terms
/// are `copy`, so a venue that took them as an argument would let anyone who obtained a sale's
/// terms create a second vault claiming that sale.
///
/// An `VenueAdmin` schedules an admission, anyone applies it once its delay has passed, a
/// `CancelAdmin` cancels it, and an `VenueAdmin` removes a witness at once. Removing a venue
/// stops it creating vaults; removing an issuer stops every vault for its sales, so a migration
/// sealed by it can no longer complete. Existing vaults keep working either way.
///
/// The admission delay starts at zero and admissions ignore the pause, so Blast lists the
/// launchpad, presale, and venue witnesses and raises the delay while publication keeps the
/// package paused; `unpause` refuses until that delay is guarded. The product and venue packages
/// must therefore be published before the vault is unpaused.
module blast_vault::blast_vault_package;

// === Public Types ===

/// The package's one-time witness (OTW), typing its version, publication, and roles.
public struct BLAST_VAULT_PACKAGE() has drop;

/// The package witness `blast_admin` pins at publication: `unpause` passes it to clear pause bits.
/// Only this module constructs it, and it is never stored or returned.
public struct PackageWitness() has drop;

/// Keys the admitted witnesses' delayed lifecycle.
public struct WitnessesKey() has copy, drop, store;

/// Shared singleton holding the venue and issuer witness types that may create vaults.
public struct VaultRegistry has key {
    id: UID,
    witnesses: DelayedSet<WitnessesKey, TypeName>,
}

// === Private Initialization ===

fun init(otw: BLAST_VAULT_PACKAGE, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
    transfer::share_object(new_registry(ctx));
}

// === Public Functions ===

/// Schedules `Witness`'s admission after the applied delay. Framework and primitive types are
/// rejected because anyone can construct them.
public fun schedule_witness<Witness: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<VenueAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let witness = type_name::with_original_ids<Witness>();
    assert!(!witness.is_primitive(), blast_vault::errors::invalid_witness!());
    let origin = type_name::original_id<Witness>();
    assert!(origin != @0x1 && origin != @0x2, blast_vault::errors::invalid_witness!());

    self.witnesses.schedule_add(witness, clock);
}

/// Applies `Witness`'s ready admission; anyone may call it.
public fun apply_witness<Witness: drop>(
    self: &mut VaultRegistry,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.witnesses.apply_add(type_name::with_original_ids<Witness>(), clock);
}

/// Cancels `Witness`'s pending admission, even a ready one.
public fun cancel_witness<Witness: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::version!());

    self.witnesses.cancel_add(type_name::with_original_ids<Witness>());
}

/// Removes an admitted witness at once; existing vaults keep working.
public fun remove_witness<Witness: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<VenueAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::version!());

    self.witnesses.remove(type_name::with_original_ids<Witness>());
}

/// Schedules a new admission delay after the applied one.
public fun schedule_witness_delay(
    self: &mut VaultRegistry,
    _: &AdminWitness<VenueAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.witnesses.schedule_delay(delay_ms, clock);
}

/// Applies a ready admission-delay change; anyone may call it.
public fun apply_witness_delay(
    self: &mut VaultRegistry,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.witnesses.apply_delay(clock);
}

/// Cancels the pending admission-delay change, even a ready one.
public fun cancel_witness_delay(
    self: &mut VaultRegistry,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::version!());

    self.witnesses.cancel_delay();
}

/// Clears pause bits once the witness admission delay and the core treasury's delay are guarded:
/// nonzero, with no pending change that would set one to zero and no pending admission. It runs
/// only on the live version; the generic administration then checks the upgrade delay and the
/// pinned witness.
public fun unpause(
    self: &VaultRegistry,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_VAULT_PACKAGE>>,
    package_admin: &PackageAdmin<BLAST_VAULT_PACKAGE>,
    package_version: &mut PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    bits: u8,
) {
    package_version.assert_current(constants::version!());

    assert!(
        self.witnesses.is_guarded() && treasury.is_guarded(),
        blast_vault::errors::unguarded_delay!(),
    );

    package_admin.clear_pause_bits(unpause_admin, PackageWitness(), package_version, bits);
}

/// Ends the vault package's upgrades once its scheduled immutability action is ready (#195,
/// after the audit). It runs only on the live version; the generic administration then checks
/// the package witness, consumes the action and destroys the UpgradeCap.
public fun make_immutable(
    package_admin: &mut PackageAdmin<BLAST_VAULT_PACKAGE>,
    upgrade_admin: &AdminWitness<UpgradeAdmin<BLAST_VAULT_PACKAGE>>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    package_admin.make_immutable(upgrade_admin, PackageWitness(), package_version, clock);
}

// === Package Functions ===

/// Aborts unless `Venue` is an admitted witness.
public(package) fun assert_venue<Venue>(self: &VaultRegistry) {
    assert!(
        self.witnesses.contains(&type_name::with_original_ids<Venue>()),
        blast_vault::errors::unadmitted_venue!(),
    );
}

/// Aborts unless `issuer`, a terms' sealing witness in its original-ID form, is admitted.
public(package) fun assert_package_witness(self: &VaultRegistry, package_witness: TypeName) {
    assert!(
        self.witnesses.contains(&package_witness),
        blast_vault::errors::unadmitted_package_witness!(),
    );
}

/// The registry's UID, from which `vault::new` derives each vault's ID; nothing else in the
/// package writes it.
public(package) fun uid_mut(self: &mut VaultRegistry): &mut UID {
    &mut self.id
}

// === Private Functions ===

fun new_registry(ctx: &mut TxContext): VaultRegistry {
    let id = object::new(ctx);
    let witnesses = delayed_set::new(
        WitnessesKey(),
        &id,
        constants::witness_admission_delay_ms!(),
    );

    VaultRegistry { id, witnesses }
}

// === Test-Only Functions ===

#[test_only]
/// An unshared registry with `Venue` and `PackageWitness` already admitted at the launch delay of zero.
public fun registry_for_testing<Venue, PackageWitness>(ctx: &mut TxContext): VaultRegistry {
    let mut registry = new_registry(ctx);
    let clock = sui::clock::create_for_testing(ctx);
    let venue = type_name::with_original_ids<Venue>();
    registry.witnesses.schedule_add(venue, &clock);
    registry.witnesses.apply_add(venue, &clock);
    let package_witness = type_name::with_original_ids<PackageWitness>();
    registry.witnesses.schedule_add(package_witness, &clock);
    registry.witnesses.apply_add(package_witness, &clock);
    clock.destroy_for_testing();

    registry
}

#[test_only]
/// An unshared registry as publication creates it: nothing admitted, at zero delay.
public fun empty_registry_for_testing(ctx: &mut TxContext): VaultRegistry {
    new_registry(ctx)
}

#[test_only]
/// An unshared, unpaused version for tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_VAULT_PACKAGE> {
    package_version::new_for_testing<_, PackageWitness>(constants::valid_pause_bits!(), ctx)
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed_set::{Self, DelayedSet},
    package_admin::{PackageAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::{Self, PackageVersion}
};

use blast_core::{blast_domain::{VenueAdmin, CancelAdmin}, blast_treasury::Treasury};

use blast_vault::constants;

use std::type_name::{Self, TypeName};

use sui::clock::Clock;
