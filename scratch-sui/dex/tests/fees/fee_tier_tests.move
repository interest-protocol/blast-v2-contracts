// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::fee_tier_tests;

// === Constants ===

const ADMIN: address = @0xA;
const CREATOR: address = @0xB;
const SQRT_PRICE_ONE_X96: u256 = 1 << 96;
const FEE_TIER_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;
const MAX_PENDING_FEE_TIERS: u32 = 32;

// === Test-Only Types ===

public struct ASSET has drop {}
public struct QUOTE has drop {}

// === Tests ===

#[test]
fun an_added_tier_is_available_to_new_pools_without_repricing_existing_pools() {
    let mut scenario = setup();
    let version = dex::version_for_testing(scenario.ctx());
    scenario.grant_fee_tier_role();
    scenario.next_tx(ADMIN);
    let mut tiers = scenario.take_shared<BlastDexFeeTiers>();
    let witness = scenario.sign_in_as_fee_tier_admin();
    let original = pool::new_with_fixed_fee<ASSET, QUOTE>(&version, &tiers, 60, 3_000, SQRT_PRICE_ONE_X96, scenario.ctx());
    original.finalize(&version).share(&version);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let ready_at_ms = tiers.schedule_fee_tier(&version, &witness, 2_000, &clock);
    assert_eq!(ready_at_ms, FEE_TIER_DELAY_MS);
    assert!(!tiers.is_fee_tier(2_000));
    assert!(event::events_by_type<BlastDexFeeTierAdded>().is_empty());
    test_scenario::return_shared(tiers);

    scenario.next_tx(CREATOR);
    let mut tiers = scenario.take_shared<BlastDexFeeTiers>();
    clock.set_for_testing(ready_at_ms);
    assert!(!tiers.is_fee_tier(2_000));
    tiers.apply_fee_tier(&version, 2_000, &clock);
    let added = event::events_by_type<BlastDexFeeTierAdded>().map!(|event| event.added_fee_ppm_for_testing());
    assert_eq!(added, vector[2_000]);
    let original = scenario.take_shared<Pool<ASSET, QUOTE>>();
    let fixed = pool::new_with_fixed_fee<ASSET, QUOTE>(&version, &tiers, 60, 2_000, SQRT_PRICE_ONE_X96, scenario.ctx())
        .finalize(&version);
    let dynamic = pool::new_with_dynamic_fee<ASSET, QUOTE>(
        &version,
        &tiers,
        60,
        2_000,
        10_000,
        1_000_000,
        SQRT_PRICE_ONE_X96,
        scenario.ctx(),
    ).finalize(&version);

    assert_eq!(original.lp_fee().base_fee_ppm(), 3_000);
    assert_eq!(fixed.lp_fee().base_fee_ppm(), 2_000);
    assert_eq!(dynamic.lp_fee().base_fee_ppm(), 2_000);
    assert_eq!(dynamic.lp_fee().max_fee_ppm(), 10_000);

    let fixed_path = lp_fee::new_fee_path(fixed.lp_fee(), SQRT_PRICE_ONE_X96);
    let dynamic_path = lp_fee::new_fee_path(dynamic.lp_fee(), SQRT_PRICE_ONE_X96);
    let end_x96 = 2 * SQRT_PRICE_ONE_X96;
    assert_eq!(fixed_path.next_step(SQRT_PRICE_ONE_X96, end_x96).net_budget_down(10_000), 9_980);
    assert_eq!(dynamic_path.next_step(SQRT_PRICE_ONE_X96, end_x96).net_budget_down(10_000), 9_980);
    assert_eq!(dynamic_path.next_step(end_x96, 3 * SQRT_PRICE_ONE_X96).net_budget_down(10_000), 9_900);
    test_scenario::return_shared(tiers);
    test_scenario::return_shared(original);
    clock.destroy_for_testing();
    destroy(fixed);
    destroy(dynamic);
    destroy(version);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidFeeTierRate, location = blast_fun_dex::lp_fee)]
fun scheduling_a_zero_tier_aborts() {
    schedule_tier(0);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidFeeTierRate, location = blast_fun_dex::lp_fee)]
fun scheduling_the_first_tier_above_the_cap_aborts() {
    schedule_tier(100_001);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EFeeTierAlreadyExists, location = blast_fun_dex::lp_fee)]
fun scheduling_an_existing_tier_aborts() {
    schedule_tier(3_000);
}

#[test]
fun the_minimum_and_maximum_rates_can_be_admitted_independently() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<BlastDexFeeTierAdmin>();

    let ready_at_ms = tiers.schedule_fee_tier(&version, &witness, 1, &clock);
    clock.set_for_testing(1);
    let max_ready_at_ms = tiers.schedule_fee_tier(&version, &witness, 100_000, &clock);
    assert_eq!(max_ready_at_ms, ready_at_ms + 1);
    clock.set_for_testing(ready_at_ms);
    tiers.apply_fee_tier(&version, 1, &clock);
    assert!(tiers.is_fee_tier(1));
    assert!(!tiers.is_fee_tier(100_000));
    clock.set_for_testing(max_ready_at_ms);
    tiers.apply_fee_tier(&version, 100_000, &clock);
    assert!(tiers.is_fee_tier(100_000));

    clock.destroy_for_testing();
    destroy(version);
    destroy(tiers);
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_map)]
fun rescheduling_a_tier_restarts_its_delay() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<BlastDexFeeTierAdmin>();
    let ready_at_ms = tiers.schedule_fee_tier(&version, &witness, 2_000, &clock);
    clock.set_for_testing(1);
    assert_eq!(tiers.schedule_fee_tier(&version, &witness, 2_000, &clock), ready_at_ms + 1);
    clock.set_for_testing(ready_at_ms);

    tiers.apply_fee_tier(&version, 2_000, &clock);

    clock.destroy_for_testing();
    destroy(version);
    destroy(tiers);
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_map)]
fun a_ready_tier_can_be_cancelled() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<BlastDexFeeTierAdmin>();
    let cancel_admin = blast_acl::witness_for_testing<CancelAdmin<BLAST_FUN_DEX>>();
    let ready_at_ms = tiers.schedule_fee_tier(&version, &witness, 2_000, &clock);
    clock.set_for_testing(ready_at_ms);

    tiers.cancel_fee_tier(&version, &cancel_admin, 2_000);
    assert!(!tiers.is_fee_tier(2_000));
    tiers.apply_fee_tier(&version, 2_000, &clock);

    clock.destroy_for_testing();
    destroy(version);
    destroy(tiers);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ETooManyPendingFeeTiers, location = blast_fun_dex::lp_fee)]
fun a_full_pending_queue_allows_replacement_but_rejects_another_tier() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<BlastDexFeeTierAdmin>();

    let mut rate = 1;
    while (rate <= MAX_PENDING_FEE_TIERS) {
        tiers.schedule_fee_tier(&version, &witness, rate, &clock);
        rate = rate + 1;
    };
    clock.set_for_testing(1);
    assert_eq!(tiers.schedule_fee_tier(&version, &witness, 1, &clock), FEE_TIER_DELAY_MS + 1);

    tiers.schedule_fee_tier(&version, &witness, rate, &clock);

    clock.destroy_for_testing();
    destroy(version);
    destroy(tiers);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_revoked_fee_tier_admin_cannot_schedule_a_tier() {
    let mut scenario = setup();
    let version = dex::version_for_testing(scenario.ctx());
    scenario.grant_fee_tier_role();
    scenario.next_tx(@blast_acl_root);
    scenario.revoke_fee_tier_role();

    scenario.next_tx(ADMIN);
    let mut tiers = scenario.take_shared<BlastDexFeeTiers>();
    let clock = clock::create_for_testing(scenario.ctx());
    let witness = scenario.sign_in_as_fee_tier_admin();
    tiers.schedule_fee_tier(&version, &witness, 2_000, &clock);

    clock.destroy_for_testing();
    test_scenario::return_shared(tiers);
    destroy(version);
    scenario.end();
}

// === Test Helpers ===

fun setup(): Scenario {
    let mut scenario = test_scenario::begin(@blast_acl_root);
    blast_acl::init_for_testing(scenario.ctx());
    lp_fee::init_for_testing(scenario.ctx());
    scenario.next_tx(@blast_acl_root);

    let root = scenario.take_from_sender<SuperAdminCap>();
    let mut acl = scenario.take_shared<ACL>();
    acl.grant_admin(&root, ADMIN, scenario.ctx());
    scenario.return_to_sender(root);
    test_scenario::return_shared(acl);
    scenario.next_tx(@blast_acl_root);

    scenario
}

fun grant_fee_tier_role(scenario: &Scenario) {
    let root = scenario.take_from_sender<SuperAdminCap>();
    let mut acl = scenario.take_shared<ACL>();
    let admin_cap_id = ADMIN.owned_ids<AdminCap>()[0];
    acl.grant_role<BlastDexFeeTierAdmin>(&root, admin_cap_id);
    scenario.return_to_sender(root);
    test_scenario::return_shared(acl);
}

fun revoke_fee_tier_role(scenario: &Scenario) {
    let root = scenario.take_from_sender<SuperAdminCap>();
    let mut acl = scenario.take_shared<ACL>();
    acl.revoke_role<BlastDexFeeTierAdmin>(&root, ADMIN.owned_ids<AdminCap>()[0]);
    scenario.return_to_sender(root);
    test_scenario::return_shared(acl);
}

fun sign_in_as_fee_tier_admin(scenario: &Scenario): AdminWitness<BlastDexFeeTierAdmin> {
    let cap = scenario.take_from_sender<AdminCap>();
    let acl = scenario.take_shared<ACL>();
    let witness = acl.sign_in<BlastDexFeeTierAdmin>(&cap);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(acl);

    witness
}

fun schedule_tier(fee_ppm: u32) {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<BlastDexFeeTierAdmin>();
    let clock = clock::create_for_testing(&mut ctx);

    tiers.schedule_fee_tier(&version, &witness, fee_ppm, &clock);

    clock.destroy_for_testing();
    destroy(version);
    destroy(tiers);
}

// === Imports ===

use blast_admin::{blast_acl::{Self, ACL, AdminCap, AdminWitness, SuperAdminCap}, package_admin::CancelAdmin};
use blast_fun_dex::{
    blast_events::BlastDexFeeTierAdded,
    blast_fun_dex::{Self as dex, BLAST_FUN_DEX},
    blast_fun_dex_domain::BlastDexFeeTierAdmin,
    lp_fee::{Self, BlastDexFeeTiers},
    pool::{Self, Pool},
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, event, test_scenario::{Self, Scenario}};

use fun grant_fee_tier_role as Scenario.grant_fee_tier_role;
use fun revoke_fee_tier_role as Scenario.revoke_fee_tier_role;
use fun sign_in_as_fee_tier_admin as Scenario.sign_in_as_fee_tier_admin;

use fun test_scenario::ids_for_address as address.owned_ids;
