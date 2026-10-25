// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::a9_order_plan_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;
const INCREASE_BASE: u64 = 1_500_000;
const REDUCE_BASE: u64 = 2_900_000;
const EMERGENCY_BASE: u64 = 3_100_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun long_increase_rejects_a_reduction_order() {
    mismatched_fill(policy::long(), INCREASE_BASE, REDUCE_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun short_increase_rejects_a_reduction_order() {
    mismatched_fill(policy::short(), INCREASE_BASE, REDUCE_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun long_reduction_rejects_an_increase_order() {
    mismatched_fill(policy::long(), REDUCE_BASE, INCREASE_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun short_reduction_rejects_an_increase_order() {
    mismatched_fill(policy::short(), REDUCE_BASE, INCREASE_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun long_ordinary_reduction_rejects_an_emergency_order() {
    mismatched_fill(policy::long(), REDUCE_BASE, EMERGENCY_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun short_ordinary_reduction_rejects_an_emergency_order() {
    mismatched_fill(policy::short(), REDUCE_BASE, EMERGENCY_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun long_emergency_reduction_rejects_an_ordinary_order() {
    mismatched_fill(policy::long(), EMERGENCY_BASE, REDUCE_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun short_emergency_reduction_rejects_an_ordinary_order() {
    mismatched_fill(policy::short(), EMERGENCY_BASE, REDUCE_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun both_mismatched_flags_are_rejected() {
    mismatched_fill(policy::long(), INCREASE_BASE, EMERGENCY_BASE, 1_000, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun order_pairing_is_checked_before_fill_size() {
    mismatched_fill(policy::long(), INCREASE_BASE, REDUCE_BASE, 0, NOW);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderMismatch, location = blast_boosts_core::state)]
fun order_pairing_is_checked_before_oracle_freshness() {
    mismatched_fill(policy::short(), REDUCE_BASE, EMERGENCY_BASE, 1_000, NOW + 30_001);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderLimit, location = blast_boosts_core::state)]
fun the_order_budget_still_precedes_order_pairing() {
    let state = seeded(policy::long());
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, REDUCE_BASE), 10, NOW);
    let mut base = REDUCE_BASE;
    state::max_rebalance_orders().do!(|_| {
        let order = state.next_rebalance_order(&plan);
        base = base - 1;
        state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 1_000_000, base), 1, NOW);
    });
    let foreign_plan = state.prepare_rebalance(position(policy::long(), 1_000_000, INCREASE_BASE), 10, NOW);
    let order = state.next_rebalance_order(&foreign_plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 2_000_000, base + 1), 1, NOW);
    destroy(foreign_plan);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
fun matching_full_and_partial_fills_complete_for_every_plan_kind_and_side() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[INCREASE_BASE, REDUCE_BASE, EMERGENCY_BASE].do!(|before_base| {
            vector[false, true].do!(|partial| {
                let state = seeded(side);
                let mut plan = state.prepare_rebalance(position(side, 1_000_000, before_base), 10, NOW);
                let order = state.next_rebalance_order(&plan);
                assert_eq!(order.is_increase(), plan.is_increasing());
                assert_eq!(order.is_emergency(), plan.is_emergency_rebalance());
                let increase = plan.is_increasing();
                let filled = if (partial) order.order_base() / 2 else order.order_base();
                assert!(filled > 0);
                let after_base = if (increase) before_base + filled else before_base - filled;
                state.accept_rebalance_fill(&mut plan, order, position(side, 1_000_000, after_base), filled, NOW);
                let (before_equity, after_equity, initial_base, final_base, increased) = state.complete_rebalance(plan);
                assert_eq!(before_equity, 1_000_000);
                assert_eq!(after_equity, 1_000_000);
                assert_eq!(initial_base, before_base);
                assert_eq!(final_base, after_base);
                assert_eq!(increased, increase);
                assert_eq!(state.maintenance_reserve(), 0);
                state.destroy_for_testing();
            });
        });
    });
}

// === Test Helpers ===

/// Both orders come from real core plans: no malformed-value hook can bypass
/// the public constructors. The post-fill observation follows the foreign
/// order, so the old checker accepts it when the fill and prices are valid.
fun mismatched_fill(side: PositionSide, plan_base: u64, foreign_base: u64, filled: u64, now_at_ms: u64) {
    let state = seeded(side);
    let mut plan = state.prepare_rebalance(position(side, 1_000_000, plan_base), 10, NOW);
    let foreign_plan = state.prepare_rebalance(position(side, 1_000_000, foreign_base), 10, NOW);
    let order = state.next_rebalance_order(&foreign_plan);
    assert!(order.is_increase() != plan.is_increasing() || order.is_emergency() != plan.is_emergency_rebalance());
    let after_base = if (order.is_increase()) plan_base + filled else plan_base - filled;
    // Increased equity keeps a foreign increase below target, isolating pairing
    // from the existing leverage guard. Base, prices and lot otherwise match.
    let after_equity = if (order.is_increase()) 2_000_000 else 1_000_000;
    state.accept_rebalance_fill(&mut plan, order, position(side, after_equity, after_base), filled, now_at_ms);
    destroy(foreign_plan);
    destroy(plan);
    state.destroy_for_testing();
}

fun seeded(side: PositionSide): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, 100),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 1_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 100_000, 1_000_000, 0, 0,
    ).activate(position(side, 1_000_000, 2_000_000), 0, NOW);
    state
}

fun position(side: PositionSide, equity: u64, base: u64): PositionObservation {
    observation::new_position(
        equity, base, 1, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_core::{errors, observation::{Self, PositionObservation}, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::{assert_eq, destroy};
