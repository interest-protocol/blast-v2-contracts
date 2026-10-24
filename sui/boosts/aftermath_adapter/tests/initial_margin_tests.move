// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_aftermath::initial_margin_tests;

// === Test-Only Types ===

public struct Product() has drop;

// === Tests ===

#[test]
fun valid_live_rates() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000000, 50000000000000000, 50000000000000000, 1000000000000000);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun zero_position_ratio() {
    let issuance = issuance();
    issuance.assert_initial_margin(0, 0, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun negative_position_ratio() {
    let issuance = issuance();
    issuance.assert_initial_margin(std::u256::max_value!(), 0, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun above_unit_ratio() {
    let issuance = issuance();
    issuance.assert_initial_margin(1000000000000000001, 0, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun below_market_exact_raw() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000001, 100000000000000002, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun negative_market_ratio() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000000, std::u256::max_value!(), 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::operations)]
fun negative_haircut() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000000, 0, std::u256::max_value!(), 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::operations)]
fun full_haircut() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000000, 0, 1000000000000000000, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = core_errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun market_floor_exceeds_cushion() {
    let issuance = issuance();
    issuance.assert_initial_margin(400000000000000000, 400000000000000000, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = core_errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun old_inverse_has_no_cushion() {
    let issuance = issuance();
    issuance.assert_initial_margin(400000000000000000, 0, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = core_errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun raw_ratio_rounds_up() {
    let issuance = issuance();
    issuance.assert_initial_margin(389900000000000001, 0, 0, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = core_errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun full_fee() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000000, 0, 0, 1000000000000000000);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EVenueFeeUnusable, location = blast_boosts_aftermath::operations)]
fun oversized_fee() {
    let issuance = issuance();
    issuance.assert_initial_margin(100000000000000000, 0, 0, 1000000000000000001);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun invalid_position_precedes_unusable_fee() {
    let issuance = issuance();
    issuance.assert_initial_margin(0, 0, 0, 1000000000000000001);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EVenueFeeUnusable, location = blast_boosts_aftermath::operations)]
fun unusable_fee_precedes_exhausted_headroom() {
    let issuance = issuance();
    issuance.assert_initial_margin(400000000000000000, 0, 0, 1000000000000000001);
    destroy(issuance);
}

// === Test Helpers ===

fun issuance(): Issuance<Product> {
    state::issue<Product>(
        &blast_acl::witness_for_testing<VaultIssuer>(),
        policy::new_vault_policy(
            policy::long(), policy::new_rebalance_policy(18_000, 20_000, 22_000, 25_000, 30, 100, 100),
            policy::new_price_policy(60_000, 1_000, 100, 0),
            0, 0, 100, 100, 3_000, 65, 1_000,
        ), 1_000, 1_000_000, 9, 6,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_aftermath::{errors, operations};
use blast_boosts_core::{blast_boosts_core::VaultIssuer, errors as core_errors, policy, state::{Self, Issuance}};
use std::unit_test::destroy;
use fun operations::assert_initial_margin_for_testing as Issuance.assert_initial_margin;
