// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::a2_funding_preview_tests;

// === Constants ===

const NOW: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun costs_project_reserve_exhaustion_and_new_deficits_for_both_sides() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[0, 100, 200, 201, 500].do!(|amount| {
            assert_projection_matches_settlement(side, 200, 0, true, amount);
        });
    });
}

#[test]
fun credits_repay_deficits_before_rebuilding_reserve_for_both_sides() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[0, 99, 100, 101, 500].do!(|amount| {
            assert_projection_matches_settlement(side, 0, 100, false, amount);
        });
    });
}

#[test]
fun credits_can_cross_the_reserve_ceiling_without_mutating_state() {
    vector[policy::long(), policy::short()].do!(|side| {
        assert_projection_matches_settlement(side, 200, 0, false, 500);
    });
}

#[test]
fun projected_cost_restores_positive_nav_before_position_validation() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side, 200, 0, 2_000);
        // The old reserve equals equity, but the paid cost leaves no reserve.
        assert!(state.needs_rebalance(position(side, 200, 2_000, 1), observation::funding_cost(200), true, 0, NOW));
        assert_eq!(state.maintenance_reserve(), 200);
        state.settle_funding(observation::funding_cost(200));
        let plan = state.prepare_rebalance(position(side, 200, 2_000, 1), 0, NOW);
        assert!(state.next_rebalance_order(&plan).order_base() > 0);
        destroy(plan);
        state.destroy_for_testing();
    });
}

#[test]
fun an_increase_prices_the_projected_reserve_at_the_candidate_notional() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 0, 0, 2_000);
        assert!(state.needs_rebalance(position(side, 1_150, 1_000, 1_000), observation::funding_credit(0), true, 0, NOW));
        // The candidate doubles notional, admitting 400 reserve instead of 200.
        assert!(!state.needs_rebalance(position(side, 1_150, 1_000, 1_000), observation::funding_credit(500), true, 0, NOW));
        assert_eq!(state.maintenance_reserve(), 0);
        state.destroy_for_testing();
    });
}

#[test]
fun a_flat_close_uses_the_full_projected_reserve_at_the_exact_cost_boundary() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 0, 0, 500);
        // Cost allowance is 36; equity 41 can retain 4 reserve, but not 5.
        assert!(state.needs_rebalance(position(side, 41, 1_000, 1_000), observation::funding_credit(4), true, 100, NOW));
        assert!(!state.needs_rebalance(position(side, 41, 1_000, 1_000), observation::funding_credit(5), true, 100, NOW));
        assert_eq!(state.maintenance_reserve(), 0);
        state.destroy_for_testing();
    });
}

#[test]
fun preview_keeps_wide_conservation_totals_when_the_final_reserve_fits() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side, 1, 1, 2_000);
        let before = bcs::to_bytes(&state);
        let ready = state.needs_rebalance(position(side, 1_000, 2_000, 1), observation::funding_credit(std::u64::max_value!()), true, 0, NOW);
        assert_eq!(before, bcs::to_bytes(&state));
        state.settle_funding(observation::funding_credit(std::u64::max_value!()));
        assert_eq!(state.maintenance_reserve(), std::u64::max_value!());
        assert_eq!(state.uncovered_deficit(), 0);
        assert_eq!(ready, state.needs_rebalance(position(side, 1_000, 2_000, 1), observation::funding_credit(0), true, 0, NOW));
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::state)]
fun preview_rejects_reserve_overflow_before_price_validation() {
    let state = seeded(policy::long(), 2, 1, 2_000);
    state.needs_rebalance(position(policy::long(), 1_000, 2_000, 1), observation::funding_credit(std::u64::max_value!()), true, 0, NOW + 60_001);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::state)]
fun preview_rejects_uncovered_deficit_overflow() {
    let state = seeded(policy::long(), 0, std::u64::max_value!(), 2_000);
    state.needs_rebalance(position(policy::long(), 1_000, 2_000, 1), observation::funding_cost(1), true, 0, NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun preview_rejects_inactive_state_before_funding_overflow() {
    let mut state = seeded(policy::long(), 1, 0, 2_000);
    state.begin_shutdown(NOW);
    state.needs_rebalance(position(policy::long(), 1_000, 2_000, 1), observation::funding_credit(std::u64::max_value!()), true, 0, NOW);
    state.destroy_for_testing();
}

#[test]
fun a_projected_credit_can_enable_emergency_reduction_despite_mark_divergence() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side, 0, 0, 2_000);
        // Stored reserve gives 2.7x; the credit raises reserve to 200 and leverage to 3.375x.
        assert!(state.needs_rebalance(divergent_position(side), observation::funding_credit(200), false, 0, NOW));
        state.settle_funding(observation::funding_credit(200));
        let plan = state.prepare_rebalance(divergent_position(side), 0, NOW);
        assert!(plan.is_emergency_rebalance());
        assert!(state.next_rebalance_order(&plan).order_base() > 0);
        destroy(plan);
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun a_projected_cost_restores_the_ordinary_long_mark_guard() {
    cost_restores_mark_guard(policy::long(), false);
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun a_projected_cost_restores_the_ordinary_short_mark_guard() {
    cost_restores_mark_guard(policy::short(), false);
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun a_settled_cost_restores_the_same_long_mark_guard_in_execution() {
    cost_restores_mark_guard(policy::long(), true);
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun a_settled_cost_restores_the_same_short_mark_guard_in_execution() {
    cost_restores_mark_guard(policy::short(), true);
}

// === Test Helpers ===

fun cost_restores_mark_guard(side: PositionSide, settle: bool) {
    let mut state = seeded(side, 200, 0, 2_000);
    // Paying 200 consumes the reserve; the same capture is now 2.7x rather than 3.375x.
    if (settle) {
        state.settle_funding(observation::funding_cost(200));
        destroy(state.prepare_rebalance(divergent_position(side), 0, NOW));
    } else {
        state.needs_rebalance(divergent_position(side), observation::funding_cost(200), false, 0, NOW);
    };
    state.destroy_for_testing();
}

fun divergent_position(side: PositionSide): PositionObservation {
    observation::new_position(
        1_000, 2_700, 1, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE * 102 / 100,
    )
}


fun assert_projection_matches_settlement(side: PositionSide, reserve: u64, deficit: u64, cost: bool, amount: u64) {
    let preview_state = seeded(side, reserve, deficit, 2_000);
    let mut settled = seeded(side, reserve, deficit, 2_000);
    let stored = bcs::to_bytes(&preview_state);
    let events_before = sui::event::num_events();
    settled.settle_funding(funding(cost, amount));
    let expected_reserve = if (cost) reserve - reserve.min(amount) else reserve + amount - deficit.min(amount);
    let expected_deficit = if (cost) deficit + amount - reserve.min(amount) else deficit - deficit.min(amount);
    assert_eq!(settled.maintenance_reserve(), expected_reserve);
    assert_eq!(settled.uncovered_deficit(), expected_deficit);
    // Both band edges, increases across reserve caps, ordinary reductions and emergency sizing.
    vector[300, 1_800, 2_000, 2_200, 3_001, 10_000].do!(|base| {
        vector[false, true].do!(|margin_safe| {
            let ready = preview_state.needs_rebalance(position(side, 1_000, base, 1), funding(cost, amount), margin_safe, 100, NOW);
            assert_eq!(ready, settled.needs_rebalance(position(side, 1_000, base, 1), observation::funding_credit(0), margin_safe, 100, NOW));
            if (ready) {
                let plan = settled.prepare_rebalance(position(side, 1_000, base, 1), 100, NOW);
                assert!(settled.next_rebalance_order(&plan).order_base() > 0);
                destroy(plan);
            };
        });
    });
    assert_eq!(stored, bcs::to_bytes(&preview_state));
    assert_eq!(sui::event::num_events(), events_before);
    preview_state.destroy_for_testing();
    settled.destroy_for_testing();
}

fun funding(cost: bool, amount: u64): FundingSettlement {
    if (cost) observation::funding_cost(amount) else observation::funding_credit(amount)
}

fun seeded(side: PositionSide, reserve: u64, deficit: u64, reserve_bps: u64): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 100),
        policy::new_price_policy(60_000, 1_000, 100, 100), 0, 0, 100, 100, 3_000, 65, reserve_bps,
    );
    let (mut state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 2_000_000, 10_000_000, 0, 0,
    ).activate(position(side, 1_000_000, 2_000_000, 1), 0, NOW);
    state.settle_funding(observation::funding_cost(deficit));
    if (reserve > 0) state.donate(position(side, 1_000_000, 2_000_000, 1), reserve, NOW);
    state
}

fun position(side: PositionSide, equity: u64, base: u64, lot: u64): PositionObservation {
    observation::new_position(
        equity, base, lot, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_core::{errors, observation::{Self, FundingSettlement, PositionObservation}, policy::{Self, PositionSide}, state::{Self, State}};
use std::{bcs, unit_test::{assert_eq, destroy}};
