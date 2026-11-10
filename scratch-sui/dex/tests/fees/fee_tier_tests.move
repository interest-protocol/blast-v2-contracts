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
    let mut tiers = scenario.take_shared<BlastDexFeeTiers>();
    let cap = scenario.take_from_sender<BlastDexFeeTierAdminCap>();
    let original = pool::new_with_fixed_fee<ASSET, QUOTE>(&tiers, 60, 3_000, SQRT_PRICE_ONE_X96, scenario.ctx());
    original.finalize().share();
    assert!(!tiers.is_fee_tier(2_000));

    tiers.add_fee_tier(&cap, 2_000);
    tiers.add_fee_tier(&cap, 1);
    tiers.add_fee_tier(&cap, 100_000);
    let added = event::events_by_type<BlastDexFeeTierAdded>().map!(|event| event.added_fee_ppm_for_testing());
    assert_eq!(added, vector[2_000, 1, 100_000]);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(tiers);

    scenario.next_tx(CREATOR);
    let tiers = scenario.take_shared<BlastDexFeeTiers>();
    let original = scenario.take_shared<Pool<ASSET, QUOTE>>();
    let fixed = pool::new_with_fixed_fee<ASSET, QUOTE>(&tiers, 60, 2_000, SQRT_PRICE_ONE_X96, scenario.ctx())
        .finalize();
    let dynamic = pool::new_with_dynamic_fee<ASSET, QUOTE>(
        &tiers,
        60,
        2_000,
        10_000,
        1_000_000,
        SQRT_PRICE_ONE_X96,
        scenario.ctx(),
    ).finalize();

    assert_eq!(original.lp_fee().base_fee_ppm(), 3_000);
    assert_eq!(fixed.lp_fee().base_fee_ppm(), 2_000);
    assert_eq!(dynamic.lp_fee().base_fee_ppm(), 2_000);
    assert_eq!(dynamic.lp_fee().max_fee_ppm(), 10_000);
    assert!(tiers.is_fee_tier(1));
    assert!(tiers.is_fee_tier(100_000));
    test_scenario::return_shared(tiers);
    test_scenario::return_shared(original);
    destroy(fixed);
    destroy(dynamic);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::lp_fee::EInvalidFeeTierRate, location = blast_fun_dex::lp_fee)]
fun adding_a_zero_tier_aborts() {
    add_tier(0);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::lp_fee::EInvalidFeeTierRate, location = blast_fun_dex::lp_fee)]
fun adding_the_first_tier_above_the_cap_aborts() {
    add_tier(100_001);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::lp_fee::EFeeTierAlreadyExists, location = blast_fun_dex::lp_fee)]
fun adding_an_existing_tier_aborts() {
    add_tier(3_000);
}

// === Test Helpers ===

fun setup(): Scenario {
    let mut scenario = test_scenario::begin(ADMIN);
    lp_fee::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    scenario
}

fun add_tier(fee_ppm: u32) {
    let scenario = setup();
    let mut tiers = scenario.take_shared<BlastDexFeeTiers>();
    let cap = scenario.take_from_sender<BlastDexFeeTierAdminCap>();

    tiers.add_fee_tier(&cap, fee_ppm);

    scenario.return_to_sender(cap);
    test_scenario::return_shared(tiers);
    scenario.end();
}

// === Imports ===

use blast_fun_dex::{
    lp_fee::{Self, BlastDexFeeTierAdded, BlastDexFeeTierAdminCap, BlastDexFeeTiers},
    pool::{Self, Pool},
};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self, Scenario}};
