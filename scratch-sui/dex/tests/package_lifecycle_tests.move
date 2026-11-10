// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::package_lifecycle_tests;

// === Constants ===

const PUBLISHER: address = @0xA;

// === Test-Only Types ===

public struct WrappedDex {
    scenario: Scenario,
    admin: PackageAdmin<BLAST_FUN_DEX>,
    version: PackageVersion<BLAST_FUN_DEX>,
}

// === Tests ===

#[test]
fun publication_wraps_custody_and_starts_with_every_bit_paused() {
    let mut dex = start_wrapped_dex();

    assert_eq!(dex.admin.current_package_id().destroy_some(), @blast_fun_dex.to_id());
    assert_eq!(dex.admin.upgrade_cap_version().destroy_some(), 1);
    assert_eq!(dex.admin.upgrade_policy().destroy_some(), package::compatible_policy());
    assert_eq!(dex.admin.upgrade_delay_ms(), package_admin::initial_upgrade_delay_ms());
    assert_eq!(dex.version.version(), constants::version!());
    assert_eq!(dex.version.valid_pause_bits(), constants::valid_pause_bits!());
    assert_eq!(dex.version.paused(), constants::valid_pause_bits!());

    dex.unpause_creation();
    assert_eq!(dex.version.paused(), constants::swap_pause_bit!() | constants::liquidity_in_pause_bit!());

    let pause_admin = blast_acl::witness_for_testing<PauseAdmin<BLAST_FUN_DEX>>();
    dex.version.pause(&pause_admin, constants::create_pause_bit!());
    assert_eq!(dex.version.paused(), constants::valid_pause_bits!());
    dex.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun stale_dex_bytecode_cannot_unpause() {
    let mut dex = start_wrapped_dex();
    dex.version.set_version_for_testing(constants::version!() + 1);

    dex.unpause_creation();
    dex.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnguardedUpgradeDelay, location = blast_admin::package_admin)]
fun unpause_rejects_a_pending_zero_upgrade_delay() {
    let mut dex = start_wrapped_dex();
    dex.schedule_zero_upgrade_delay();

    dex.unpause_creation();
    dex.end();
}

// === Test Helpers ===

fun start_wrapped_dex(): WrappedDex {
    let mut scenario = test_scenario::begin(PUBLISHER);
    dex::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    assert!(!test_scenario::has_most_recent_shared<PackageVersion<BLAST_FUN_DEX>>());

    let publication = scenario.take_from_sender<Publication<BLAST_FUN_DEX>>();
    let upgrade_cap = package::test_publish(@blast_fun_dex.to_id(), scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, scenario.ctx());
    scenario.next_tx(PUBLISHER);
    assert!(!scenario.has_most_recent_for_sender<Publication<BLAST_FUN_DEX>>());

    let admin = scenario.take_shared<PackageAdmin<BLAST_FUN_DEX>>();
    let version = scenario.take_shared<PackageVersion<BLAST_FUN_DEX>>();
    WrappedDex { scenario, admin, version }
}

fun end(self: WrappedDex) {
    let WrappedDex { scenario, admin, version } = self;
    test_scenario::return_shared(admin);
    test_scenario::return_shared(version);
    scenario.end();
}

fun unpause_creation(self: &mut WrappedDex) {
    let WrappedDex { admin, version, .. } = self;
    let unpause_admin = blast_acl::witness_for_testing<UnpauseAdmin<BLAST_FUN_DEX>>();
    version.unpause(&unpause_admin, admin, constants::create_pause_bit!());
}

fun schedule_zero_upgrade_delay(self: &mut WrappedDex) {
    let upgrade_admin = blast_acl::witness_for_testing<UpgradeAdmin<BLAST_FUN_DEX>>();
    let clock = clock::create_for_testing(self.scenario.ctx());
    self.admin.schedule_upgrade_delay(&upgrade_admin, 0, &clock);
    clock.destroy_for_testing();
}

// === Imports ===

use blast_admin::{
    blast_acl,
    package_admin::{Self, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::{PackageVersion, Publication},
};
use blast_fun_dex::{blast_fun_dex::{Self as dex, BLAST_FUN_DEX}, constants};
use std::unit_test::assert_eq;
use sui::{clock, package, test_scenario::{Self, Scenario}};

use fun dex::unpause as PackageVersion.unpause;
use fun package_admin::pause as PackageVersion.pause;
