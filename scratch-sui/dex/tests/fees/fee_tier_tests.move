// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::fee_tier_tests;

// === Constants ===

const ADMIN: address = @0xA;
const CREATOR: address = @0xB;
const SQRT_PRICE_ONE_X96: u256 = 1 << 96;

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
    assert!(!tiers.is_fee_tier(2_000));

    tiers.add_fee_tier(&version, &witness, 2_000);
    tiers.add_fee_tier(&version, &witness, 1);
    tiers.add_fee_tier(&version, &witness, 100_000);
    let added = event::events_by_type<BlastDexFeeTierAdded>().map!(|event| event.added_fee_ppm_for_testing());
    assert_eq!(added, vector[2_000, 1, 100_000]);
    test_scenario::return_shared(tiers);

    scenario.next_tx(CREATOR);
    let tiers = scenario.take_shared<BlastDexFeeTiers>();
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
    assert!(tiers.is_fee_tier(1));
    assert!(tiers.is_fee_tier(100_000));
    test_scenario::return_shared(tiers);
    test_scenario::return_shared(original);
    destroy(fixed);
    destroy(dynamic);
    destroy(version);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidFeeTierRate, location = blast_fun_dex::lp_fee)]
fun adding_a_zero_tier_aborts() {
    add_tier(0);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidFeeTierRate, location = blast_fun_dex::lp_fee)]
fun adding_the_first_tier_above_the_cap_aborts() {
    add_tier(100_001);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EFeeTierAlreadyExists, location = blast_fun_dex::lp_fee)]
fun adding_an_existing_tier_aborts() {
    add_tier(3_000);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_revoked_fee_tier_admin_cannot_add_a_tier() {
    let mut scenario = setup();
    let version = dex::version_for_testing(scenario.ctx());
    scenario.grant_fee_tier_role();
    scenario.next_tx(@blast_acl_root);
    scenario.revoke_fee_tier_role();

    scenario.next_tx(ADMIN);
    let mut tiers = scenario.take_shared<BlastDexFeeTiers>();
    let witness = scenario.sign_in_as_fee_tier_admin();
    tiers.add_fee_tier(&version, &witness, 2_000);

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

fun add_tier(fee_ppm: u32) {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<BlastDexFeeTierAdmin>();

    tiers.add_fee_tier(&version, &witness, fee_ppm);

    destroy(version);
    destroy(tiers);
}

// === Imports ===

use blast_admin::blast_acl::{Self, ACL, AdminCap, AdminWitness, SuperAdminCap};
use blast_fun_dex::{
    blast_fun_dex as dex,
    blast_events::BlastDexFeeTierAdded,
    lp_fee::{Self, BlastDexFeeTierAdmin, BlastDexFeeTiers},
    pool::{Self, Pool},
};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self, Scenario}};

use fun grant_fee_tier_role as Scenario.grant_fee_tier_role;
use fun revoke_fee_tier_role as Scenario.revoke_fee_tier_role;
use fun sign_in_as_fee_tier_admin as Scenario.sign_in_as_fee_tier_admin;

use fun test_scenario::ids_for_address as address.owned_ids;
