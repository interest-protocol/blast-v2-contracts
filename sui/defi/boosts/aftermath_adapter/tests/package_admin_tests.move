// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_aftermath::package_admin_tests;

// === Tests ===

#[test]
fun wrap_pauses_deposits_and_seals_the_cap_under_notice() {
    let mut scenario = wrapped();
    let mut admin = scenario.take_shared<PackageAdmin<BLAST_BOOSTS_AFTERMATH>>();
    let protocol = scenario.take_shared<Protocol>();
    let mut version = scenario.take_shared<PackageVersion<BLAST_BOOSTS_AFTERMATH>>();
    assert!(admin.has_upgrade_cap());
    assert!(version.is_paused(marker::deposits!()));
    let treasury = blast_core::blast_treasury::new_for_testing(@0xB, scenario.ctx());
    package_admin::unpause(&protocol, &admin, &mut version, &treasury, &blast_acl::witness_for_testing());
    std::unit_test::destroy(treasury);
    version.assert_not_paused(marker::deposits!());
    shared_admin::pause(&mut version, &blast_acl::witness_for_testing(), marker::deposits!());
    assert!(version.is_paused(marker::deposits!()));
    let mut clock = clock::create_for_testing(scenario.ctx());
    let witness = blast_acl::witness_for_testing();
    admin.schedule_make_immutable(&witness, &clock);
    assert!(admin.has_upgrade_cap());
    clock.set_for_testing(172_800_000);
    package_admin::make_immutable(&mut admin, &protocol, &version, &witness, &clock);
    assert!(!admin.has_upgrade_cap());
    clock.destroy_for_testing();
    test_scenario::return_shared(version);
    test_scenario::return_shared(protocol);
    test_scenario::return_shared(admin);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = package_admin::EUnguardedTreasuryDelay, location = blast_boosts_aftermath::package_admin)]
fun a_pending_zero_treasury_delay_prevents_releasing_deposits() {
    let mut scenario = wrapped();
    let admin = scenario.take_shared<PackageAdmin<BLAST_BOOSTS_AFTERMATH>>();
    let protocol = scenario.take_shared<Protocol>();
    let mut version = scenario.take_shared<PackageVersion<BLAST_BOOSTS_AFTERMATH>>();
    let mut treasury = blast_core::blast_treasury::new_for_testing(@0xB, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    treasury.schedule_destination(&blast_acl::witness_for_testing(), @0xC, 0, &clock);
    package_admin::unpause(&protocol, &admin, &mut version, &treasury, &blast_acl::witness_for_testing());
    clock.destroy_for_testing();
    std::unit_test::destroy(treasury);
    test_scenario::return_shared(version);
    test_scenario::return_shared(protocol);
    test_scenario::return_shared(admin);
    scenario.end();
}

// === Test Helpers ===

fun wrapped(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(@0xA);
    marker::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let proof = scenario.take_from_sender<Publication<BLAST_BOOSTS_AFTERMATH>>();
    let cap = package::test_publish(@blast_boosts_aftermath.to_id(), scenario.ctx());
    shared_admin::wrap(proof, cap, scenario.ctx());
    scenario.next_tx(@0xA);
    scenario
}

// === Imports ===

use blast_admin::{blast_acl, package_admin::{Self as shared_admin, PackageAdmin}, package_version::{PackageVersion, Publication}};
use blast_boosts_aftermath::{blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH, Protocol}, package_admin};
use sui::{clock, package, test_scenario};
