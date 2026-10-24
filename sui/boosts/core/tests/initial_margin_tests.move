// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::initial_margin_tests;

// === Tests ===

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun no_cost_inverse_has_no_cushion() {
    policy_with_bounds(0, 0).assert_initial_margin_headroom(4000, 0, 0);
}

#[test]
fun nominal_below_inverse() {
    policy_with_bounds(0, 0).assert_initial_margin_headroom(3999, 0, 0);
}

#[test]
fun execution_room() {
    policy_with_bounds(1000, 0).assert_initial_margin_headroom(2999, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun execution_equality() {
    policy_with_bounds(1000, 0).assert_initial_margin_headroom(3000, 0, 0);
}

#[test]
fun haircut_room() {
    policy_with_bounds(1000, 0).assert_initial_margin_headroom(2849, 500, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun haircut_equality() {
    policy_with_bounds(1000, 0).assert_initial_margin_headroom(2850, 500, 0);
}

#[test]
fun mark_room() {
    policy_with_bounds(1000, 500).assert_initial_margin_headroom(2238, 500, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun mark_shortfall() {
    policy_with_bounds(1000, 500).assert_initial_margin_headroom(2239, 500, 0);
}

#[test]
fun fee_room() {
    policy_with_bounds(1000, 500).assert_initial_margin_headroom(2138, 500, 100);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun fee_shortfall() {
    policy_with_bounds(1000, 500).assert_initial_margin_headroom(2139, 500, 100);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun cost_exhausts_equity() {
    policy_with_bounds(4000, 0).assert_initial_margin_headroom(1, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun zero_margin() {
    policy_with_bounds(0, 0).assert_initial_margin_headroom(0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun full_haircut() {
    policy_with_bounds(0, 0).assert_initial_margin_headroom(1, 10000, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun fee_above_one() {
    policy_with_bounds(0, 0).assert_initial_margin_headroom(1, 0, 10001);
}

#[test]
fun maximum_leverage_still_has_a_strict_one_bps_boundary() {
    policy_at_leverage_ceiling().assert_initial_margin_headroom(99, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitialMarginHeadroom, location = blast_boosts_core::policy)]
fun maximum_leverage_rejects_equality_without_arithmetic_overflow() {
    policy_at_leverage_ceiling().assert_initial_margin_headroom(100, 0, 0);
}

// === Test Helpers ===

fun policy_with_bounds(slippage: u64, divergence: u64): VaultPolicy {
    policy::new_vault_policy(
        policy::long(), policy::new_rebalance_policy(18_000, 20_000, 22_000, 25_000, 0, slippage, 100),
        policy::new_price_policy(60_000, 1_000, 100, divergence),
        0, 0, 100, 100, 3_000, 65, 1_000,
    )
}

fun policy_at_leverage_ceiling(): VaultPolicy {
    policy::new_vault_policy(
        policy::long(), policy::new_rebalance_policy(18_000, 20_000, 22_000, 1_000_000, 0, 0, 100),
        policy::new_price_policy(60_000, 1_000, 100, 0),
        0, 0, 100, 100, 3_000, 65, 1_000,
    )
}

// === Imports ===

use blast_boosts_core::{errors, policy::{Self, VaultPolicy}};
