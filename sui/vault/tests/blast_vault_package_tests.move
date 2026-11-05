// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_vault::blast_vault_package_tests;

// === Constants ===

const ADMISSION_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// A venue that applies for admission during a test.
public struct NewVenue() has drop;

// === Tests ===

// Launch

#[test]
/// Publication leaves the package fully paused with a zero admission delay: Blast lists its
/// product and venue witnesses at once, raises the delay, and only then unpauses.
fun products_and_venues_are_listed_at_launch_while_the_package_is_paused() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let treasury = guarded_treasury(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::valid_pause_bits!());

    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    registry.apply_witness<NewVenue>(f.version(), f.clock());
    registry.schedule_witness<SaleWitness>(&venue_admin(), f.version(), f.clock());
    registry.apply_witness<SaleWitness>(f.version(), f.clock());
    registry.schedule_witness_delay(&venue_admin(), f.version(), ADMISSION_DELAY_MS, f.clock());
    registry.apply_witness_delay(f.version(), f.clock());
    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::valid_pause_bits!(),
    );

    assert_eq!(f.version().paused_for_testing(), 0);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    let vault = vault::new<VAULT_FIXTURE, QUOTE, _>(
        &mut registry,
        &NewVenue(),
        f.version(),
        terms,
        vault_fixture::pool_id(),
    );
    destroy(vault);
    destroy(treasury);
    destroy(package_admin);
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedDelay,
    location = blast_vault::blast_vault_package,
)]
fun unpause_waits_for_a_nonzero_admission_delay() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let treasury = guarded_treasury(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedDelay,
    location = blast_vault::blast_vault_package,
)]
fun unpause_waits_while_a_zero_admission_delay_is_pending() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let treasury = guarded_treasury(scenario.ctx());
    registry.schedule_witness_delay(&venue_admin(), f.version(), 0, f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedDelay,
    location = blast_vault::blast_vault_package,
)]
/// An admission still pending when the delay is raised keeps the set unguarded until it is
/// applied or cancelled.
fun unpause_waits_while_an_admission_is_pending() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let treasury = guarded_treasury(scenario.ctx());
    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedDelay,
    location = blast_vault::blast_vault_package,
)]
/// The core treasury's delay is part of the vault's release gate: a pending change to zero keeps
/// the package paused until it is cancelled.
fun unpause_waits_while_a_zero_treasury_delay_is_pending() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let mut treasury = guarded_treasury(scenario.ctx());
    let treasury_admin: AdminWitness<TreasuryAdmin> = blast_acl::witness_for_testing();
    treasury.schedule_destination(&treasury_admin, vault_fixture::treasury_address(), 0, f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
/// Stale vault bytecode cannot release pause bits, whatever its own gate checked.
fun unpause_rejects_a_stale_version() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let treasury = guarded_treasury(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());
    f.version_mut().set_version_for_testing(constants::version!() + 1);

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
fun venues_are_admitted_while_paused_after_launch() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_DELAY_MS);
    registry.apply_witness<NewVenue>(f.version(), f.clock());

    destroy(registry);
    f.end();
    scenario.end();
}

// Venue admission after launch

#[test]
fun an_admitted_venue_creates_vaults_after_its_delay() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_DELAY_MS);

    registry.apply_witness<NewVenue>(f.version(), f.clock());

    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    let vault = vault::new<VAULT_FIXTURE, QUOTE, _>(
        &mut registry,
        &NewVenue(),
        f.version(),
        terms,
        vault_fixture::pool_id(),
    );
    destroy(vault);
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun a_venue_cannot_be_admitted_before_its_delay() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_DELAY_MS - 1);

    registry.apply_witness<NewVenue>(f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_cancelled_admission_cannot_apply() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    registry.cancel_witness<NewVenue>(&cancel_admin(), f.version());
    f.clock_mut().increment_for_testing(ADMISSION_DELAY_MS);

    registry.apply_witness<NewVenue>(f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedVenue,
    location = blast_vault::blast_vault_package,
)]
fun a_removed_venue_cannot_create_vaults() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::registry_for_testing<NewVenue, SaleWitness>(scenario.ctx());
    registry.remove_witness<NewVenue>(&venue_admin(), f.version());

    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    destroy(
        vault::new<VAULT_FIXTURE, QUOTE, _>(
            &mut registry,
            &NewVenue(),
            f.version(),
            terms,
            vault_fixture::pool_id(),
        ),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidWitness,
    location = blast_vault::blast_vault_package,
)]
fun a_primitive_type_cannot_be_admitted() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());

    registry.schedule_witness<u64>(&venue_admin(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidWitness,
    location = blast_vault::blast_vault_package,
)]
fun a_move_standard_library_type_cannot_be_admitted() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());

    registry.schedule_witness<String>(&venue_admin(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidWitness,
    location = blast_vault::blast_vault_package,
)]
fun a_sui_framework_type_cannot_be_admitted() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());

    registry.schedule_witness<ID>(&venue_admin(), f.version(), f.clock());

    abort
}

#[test]
fun the_admin_pause_never_stops_cancellation_or_removal() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::registry_for_testing<TestVenue, SaleWitness>(scenario.ctx());
    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.cancel_witness<NewVenue>(&cancel_admin(), f.version());
    registry.remove_witness<TestVenue>(&venue_admin(), f.version());

    destroy(registry);
    f.end();
    scenario.end();
}

// Unpause and delay changes

#[test]
fun unpause_clears_the_bits_while_every_delay_is_guarded() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    let treasury = guarded_treasury(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        &treasury,
        constants::admin_pause_bit!(),
    );

    assert_eq!(f.version().paused_for_testing(), 0);
    destroy(treasury);
    destroy(package_admin);
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
fun an_admission_delay_change_applies_after_the_current_delay() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_witness_delay(&venue_admin(), f.version(), 1, f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_DELAY_MS);
    registry.apply_witness_delay(f.version(), f.clock());

    registry.schedule_witness<NewVenue>(&venue_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(1);
    registry.apply_witness<NewVenue>(f.version(), f.clock());

    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_cancelled_admission_delay_change_cannot_apply() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_witness_delay(&venue_admin(), f.version(), 1, f.clock());
    registry.cancel_witness_delay(&cancel_admin(), f.version());
    f.clock_mut().increment_for_testing(ADMISSION_DELAY_MS);

    registry.apply_witness_delay(f.version(), f.clock());

    abort
}

#[test]
/// After its delay, the vault's own make_immutable on the live version destroys the cap.
fun the_vault_makes_itself_immutable_after_the_delay() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut package_admin = new_package_admin(scenario.ctx());
    package_admin.schedule_make_immutable(&upgrade_admin(), f.clock());
    f.clock_mut().increment_for_testing(package_admin.upgrade_delay_ms());

    blast_vault_package::make_immutable(&mut package_admin, &upgrade_admin(), f.version(), f.clock());

    assert!(!package_admin.has_upgrade_cap());
    assert!(package_admin.upgrade_cap_id().is_none());
    destroy(package_admin);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
/// Stale vault bytecode cannot end the package's upgrades.
fun make_immutable_rejects_a_stale_version() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut package_admin = new_package_admin(scenario.ctx());
    package_admin.schedule_make_immutable(&upgrade_admin(), f.clock());
    f.clock_mut().increment_for_testing(package_admin.upgrade_delay_ms());
    f.version_mut().set_version_for_testing(constants::version!() + 1);

    blast_vault_package::make_immutable(&mut package_admin, &upgrade_admin(), f.version(), f.clock());

    abort
}

// === Test Helpers ===

/// A registry after launch: only the test sale's issuer admitted, with the 48-hour admission
/// delay applied.
fun guarded_registry(f: &VaultFixture, ctx: &mut TxContext): VaultRegistry {
    let mut registry = blast_vault_package::empty_registry_for_testing(ctx);
    registry.schedule_witness<SaleWitness>(&venue_admin(), f.version(), f.clock());
    registry.apply_witness<SaleWitness>(f.version(), f.clock());
    registry.schedule_witness_delay(&venue_admin(), f.version(), ADMISSION_DELAY_MS, f.clock());
    registry.apply_witness_delay(f.version(), f.clock());

    registry
}

/// The core treasury at its 48-hour publication delay, as a released stack has it.
fun guarded_treasury(ctx: &mut TxContext): Treasury {
    blast_treasury::new_for_testing(vault_fixture::treasury_address(), ctx)
}

/// Package administration for the vault package with its production upgrade delay.
fun new_package_admin(ctx: &mut TxContext): PackageAdmin<BLAST_VAULT_PACKAGE> {
    package_admin::new_for_testing(
        package::test_claim(test_utils::create_one_time_witness<BLAST_VAULT_PACKAGE>(), ctx),
        package::test_publish(@blast_vault.to_id(), ctx),
        ctx,
    )
}

fun venue_admin(): AdminWitness<VenueAdmin> { blast_acl::witness_for_testing() }

fun cancel_admin(): AdminWitness<CancelAdmin> { blast_acl::witness_for_testing() }

fun upgrade_admin(): AdminWitness<UpgradeAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

fun unpause_admin(): AdminWitness<UnpauseAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    package_admin::{Self, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin}
};

use blast_core::{
    blast_domain::{VenueAdmin, CancelAdmin, TreasuryAdmin},
    blast_treasury::{Self, Treasury}
};

use blast_vault::{
    blast_vault_package::{Self, BLAST_VAULT_PACKAGE, VaultRegistry},
    constants,
    vault,
    vault_fixture::{
        Self,
        QUOTE,
        SaleWitness,
        TestVenue,
        VAULT_FIXTURE,
        VaultFixture,
        owner_split
    }
};

use std::{string::String, unit_test::{assert_eq, destroy}};

use sui::{package, test_utils};
