// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l10_reserve_reduction_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun crossing_the_opening_reserve_does_not_block_the_next_order() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 50_000, 500, 102_001);
        let mut plan = state.prepare_rebalance(position(side, 51_000, 1_000_000, 1), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 49_750);
        state.accept_rebalance_fill(&mut plan, order, position(side, 50_005, 950_250, 1), 49_750, NOW);
        let next = state.next_rebalance_order(&plan);
        assert_eq!(next.order_base(), 100_000);
        state.accept_rebalance_fill(&mut plan, next, position(side, 48_005, 850_250, 1), 100_000, NOW);
        // Actual reserve is 42,512; 5,493 belongs to holders. The old 50,000
        // opening reserve exceeds equity and used to abort the next order.
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 100_000);
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 50_000);
        state.destroy_for_testing();
    });
}

#[test]
fun crossing_the_opening_reserve_does_not_undo_completion() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 50_000, 500, 102_001);
        let mut plan = state.prepare_rebalance(position(side, 51_000, 1_000_000, 1), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        state.accept_rebalance_fill(&mut plan, order, position(side, 50_005, 950_250, 1), 49_750, NOW);
        let next = state.next_rebalance_order(&plan);
        state.accept_rebalance_fill(&mut plan, next, position(side, 48_005, 850_250, 1), 100_000, NOW);
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 50_000);
        state.destroy_for_testing();
    });
}

#[test]
fun an_emergency_partial_close_can_commit_even_when_costs_worsen_leverage() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 0, 500, 102_001);
        let mut plan = state.prepare_rebalance(position(side, 10_000, 1_000_000, 1), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert!(order.order_base() > 10_000);
        state.accept_rebalance_fill(&mut plan, order, position(side, 9_800, 990_000, 1), 10_000, NOW);
        // 100x -> over 101x, but exposure really fell and holder value is positive.
        state.complete_rebalance(plan);
        state.destroy_for_testing();
    });
}

#[test]
fun reserve_release_stops_the_emergency_at_the_actual_cap() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 500_000, 5_000, 2_000_000);
        // N=1m, E=700k, admitted reserve=500k: 5x initially. With zero
        // execution cost the closest 3x position is N=840k, reserve=420k.
        let mut plan = state.prepare_rebalance(position(side, 700_000, 1_000_000, 1), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 160_000);
        assert!(order.is_emergency());
        state.accept_rebalance_fill(&mut plan, order, position(side, 700_000, 840_000, 1), 160_000, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        let ordinary = state.prepare_rebalance(position(side, 700_000, 840_000, 1), 0, NOW);
        assert!(!ordinary.is_emergency_rebalance());
        assert_eq!(state.next_rebalance_order(&ordinary).bound().slippage_bps(), 100);
        destroy(ordinary);
        assert_eq!(state.maintenance_reserve(), 500_000);
        state.destroy_for_testing();
    });
}

#[test]
fun ordinary_sizing_also_uses_the_reserve_at_the_remaining_position() {
    let state = seeded(policy::long(), 500, 5_000, 2_000_000);
    let mut plan = state.prepare_rebalance(position(policy::long(), 850, 1_000, 1), 0, NOW);
    assert!(!plan.is_emergency_rebalance());
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 150);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 849, 850, 1), 150, NOW);
    state.complete_rebalance(plan);
    assert_eq!(state.maintenance_reserve(), 500);
    state.destroy_for_testing();
}

#[test]
fun reduction_sizing_matches_independent_whole_lot_enumeration() {
    vector[0u64, 40, 100].do!(|reserve| {
        vector[1_000u64, 5_000].do!(|reserve_bps| {
            vector[1u64, 7].do!(|lot| {
                let state = seeded(policy::long(), reserve, reserve_bps, 2_000_000);
                let before = observation::new_position(
                    150, 280, lot, policy::long(), observation::new_price(PRICE * 13 / 10, 0, NOW),
                    observation::new_price(PRICE, 0, NOW), PRICE * 13 / 10,
                );
                let plan = state.prepare_rebalance(before, 37, NOW);
                let target = if (plan.is_emergency_rebalance()) 3 else 2;
                let mut remaining = 0;
                let mut candidate = lot;
                while (candidate <= 280) {
                    let notional = (candidate * 13).div_ceil(10);
                    let admitted = reserve.min(notional * reserve_bps / 10_000);
                    if (notional <= target * (150 - admitted)) remaining = candidate;
                    candidate = candidate + lot;
                };
                assert!(remaining > 0);
                assert_eq!(state.next_rebalance_order(&plan).order_base(), 280 - remaining);
                destroy(plan);
                state.destroy_for_testing();
            });
        });
    });
}

#[test]
fun an_unaffordable_flat_close_leaves_one_lot_and_keeps_the_valid_reduction() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 50_000, 500, 102_001);
        let mut plan = state.prepare_rebalance(position(side, 110, 2_000, 1_000), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 1_000);
        state.accept_rebalance_fill(&mut plan, order, position(side, 90, 1_000, 1_000), 1_000, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        assert!(!state.needs_rebalance(position(side, 90, 1_000, 1_000), true, 0, NOW));
        assert_eq!(state.maintenance_reserve(), 50_000);
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNotActionable, location = blast_boosts_core::state)]
fun preparation_rejects_the_same_unaffordable_last_lot() {
    let state = seeded(policy::long(), 50_000, 500, 102_001);
    destroy(state.prepare_rebalance(position(policy::long(), 90, 1_000, 1_000), 0, NOW));
    state.destroy_for_testing();
}

#[test]
fun a_flat_close_keeps_the_full_reserve_and_positive_holder_value() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 5, 500, 102_001);
        let mut plan = state.prepare_rebalance(position(side, 100, 1_000, 1_000), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 1_000);
        state.accept_rebalance_fill(&mut plan, order, position(side, 80, 0, 1_000), 1_000, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 5);
        state.destroy_for_testing();
    });
}

#[test]
fun flat_preflight_includes_the_fee_and_requires_strictly_positive_nav() {
    let state = seeded(policy::long(), 5, 500, 102_001);
    // 20 slippage + 11 fee + 1 price precision + 1 precision fee + 3 capture + 5 reserve = 41.
    assert!(!state.needs_rebalance(position(policy::long(), 41, 1_000, 1_000), true, 100, NOW));
    assert!(state.needs_rebalance(position(policy::long(), 42, 1_000, 1_000), true, 100, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun emergency_reduction_cannot_consume_current_holder_value() {
    let state = seeded(policy::long(), 50_000, 500, 102_001);
    let mut plan = state.prepare_rebalance(position(policy::long(), 51_000, 1_000_000, 1), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 47_512, 950_250, 1), 49_750, NOW);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun an_emergency_plan_without_a_fill_cannot_complete() {
    let state = seeded(policy::long(), 0, 500, 102_001);
    let plan = state.prepare_rebalance(position(policy::long(), 10_000, 1_000_000, 1), 0, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun a_base_reduction_that_does_not_lower_oracle_notional_is_not_emergency_progress() {
    let state = seeded(policy::long(), 0, 500, 102_001);
    let mut plan = state.prepare_rebalance(dust_position(24_000), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, dust_position(23_999), 1, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun an_ordinary_partial_close_still_needs_substantive_progress() {
    let state = seeded(policy::long(), 50_000, 500, 102_001);
    let mut plan = state.prepare_rebalance(position(policy::long(), 450_000, 1_000_000, 1), 0, NOW);
    assert!(!plan.is_emergency_rebalance());
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 450_000, 999_999, 1), 1, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun an_ordinary_full_batch_projects_the_shrinking_reserve_after_every_fill() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 150_000_000, 5_000, 10_201);
        let mut base = 290_000_000;
        let mut equity = 245_000_000;
        let mut plan = state.prepare_rebalance(position(side, equity, base, 1), 10, NOW);
        assert!(!plan.is_emergency_rebalance());
        16u64.do!(|_| {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            equity = equity - (rebalance_math::execution_cost_up(filled, 10, 100) as u64);
            base = base - filled;
            state.accept_rebalance_fill(&mut plan, order, position(side, equity, base, 1), filled, NOW);
        });
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 150_000_000);
        state.destroy_for_testing();
    });
}

#[test]
fun a_below_target_position_stops_before_an_inverse_quote_could_overflow() {
    let state = seeded(policy::long(), 0, 500, 102_001);
    let max = std::u64::max_value!();
    let before = observation::new_position(
        7_000_000_000, max - 15, 1, policy::long(), observation::new_price(1, 0, NOW),
        observation::new_price(PRICE, 0, NOW), 1,
    );
    let mut plan = state.prepare_rebalance(before, 0, NOW);
    assert!(!plan.is_emergency_rebalance());
    let order = state.next_rebalance_order(&plan);
    let after = observation::new_position(
        max - 1, max - 16, 1, policy::long(), observation::new_price(1, 0, NOW),
        observation::new_price(PRICE, 0, NOW), 1,
    );
    state.accept_rebalance_fill(&mut plan, order, after, 1, NOW);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun a_smaller_retained_order_cannot_claim_an_ordinary_full_batch() {
    let state = seeded(policy::long(), 0, 500, 102_001);
    let small_plan = state.prepare_rebalance(position(policy::long(), 100, 221, 1), 0, NOW);
    let small_order = state.next_rebalance_order(&small_plan);
    assert_eq!(small_order.order_base(), 21);
    destroy(small_plan);
    let mut base = 2_900_000_000;
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000_000, base, 1), 0, NOW);
    15u64.do!(|_| {
        let order = state.next_rebalance_order(&plan);
        let filled = order.order_base();
        base = base - filled;
        state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 1_000_000_000, base, 1), filled, NOW);
    });
    state.accept_rebalance_fill(&mut plan, small_order, position(policy::long(), 1_000_000_000, base - 21, 1), 21, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun a_full_emergency_batch_stops_before_its_permitted_costs_erase_holder_value() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 0, 500, 102_001);
        let mut equity = 10_000;
        let mut base = 1_000_000;
        let mut plan = state.prepare_rebalance(position(side, equity, base, 1), 0, NOW);
        let mut steps = 0u64;
        loop {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            if (filled == 0) break;
            // Captured equity loses two atoms beyond the ordinary cost model.
            equity = equity - (rebalance_math::execution_cost_up(filled, 0, 200) as u64) - 2;
            base = base - filled;
            state.accept_rebalance_fill(&mut plan, order, position(side, equity, base, 1), filled, NOW);
            steps = steps + 1;
        };
        assert_eq!(steps, 5);
        assert_eq!(equity, 3);
        assert_eq!(base, 500_650);
        state.complete_rebalance(plan);
        assert!(!state.needs_rebalance(position(side, equity, base, 1), true, 0, NOW));
        state.destroy_for_testing();
    });
}

#[test]
fun a_minimum_close_can_use_its_own_reserve_release_after_a_larger_order_is_unaffordable() {
    let state = seeded(policy::long(), 10, 100, 102_001);
    let mut plan = state.prepare_rebalance(position(policy::long(), 16, 1_000, 100), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    // A full close is unaffordable. Closing 900 is also unaffordable, but
    // closing one lot costs 6 with precision allowances and releases 1 reserve: NAV remains 1.
    assert_eq!(order.order_base(), 100);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 10, 900, 100), 100, NOW);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
    state.complete_rebalance(plan);
    assert_eq!(state.maintenance_reserve(), 10);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun ordinary_capacity_projection_rejects_costs_that_consume_gross_equity() {
    reject_exhausted_projection(0);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun ordinary_capacity_projection_rejects_costs_that_consume_holder_nav() {
    reject_exhausted_projection(20);
}

#[test]
fun an_emergency_order_is_affordable_even_before_a_partial_fill_releases_reserve() {
    let state = seeded(policy::long(), 50_000, 500, 2_000_000);
    let mut plan = state.prepare_rebalance(position(policy::long(), 51_000, 2_000_000, 1), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    // A very large full close could release reserve, but an intermediate
    // partial fill might not. Bound costs by current NAV for every fill size.
    assert_eq!(order.order_base(), 49_750);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 50_500, 1_975_000, 1), 25_000, NOW);
    let next = state.next_rebalance_order(&plan);
    assert_eq!(next.order_base(), 24_750);
    destroy(next);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun long_closes_budget_the_full_sub_price_atom_loss_not_just_its_slippage() {
    let state = seeded(policy::long(), 0, 500, 102_001);
    let mut base = 1_000_000 * PRICE;
    let mut equity = 10_000;
    let mut plan = state.prepare_rebalance(low_price_position(equity, base), 0, NOW);
    let mut steps = 0u64;
    loop {
        let order = state.next_rebalance_order(&plan);
        let filled = order.order_base();
        if (filled == 0) break;
        // True oracle = 1.5 normalized atoms, truncated observation = 1.
        // Selling at 0.98 loses 0.52, plus two capture atoms. The old cost
        // model charged only 0.02 and could erase equity on its first fill.
        let cost = ((filled as u128) * 52).div_ceil((PRICE as u128) * 100) as u64;
        assert!(cost + 2 < equity);
        equity = equity - cost - 2;
        base = base - filled;
        state.accept_rebalance_fill(&mut plan, order, low_price_position(equity, base), filled, NOW);
        steps = steps + 1;
    };
    assert!(steps > 1 && steps <= state::max_rebalance_orders());
    assert!(equity > 0);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

// === Test Helpers ===

fun low_price_position(equity: u64, base: u64): PositionObservation {
    observation::new_position(
        equity, base, 1, policy::long(), observation::new_price(1, 0, NOW),
        observation::new_price(PRICE, 0, NOW), 1,
    )
}

fun reject_exhausted_projection(reserve: u64) {
    let vault_policy = policy::new_vault_policy(
        policy::long(), policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 9_000),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 1_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 6, 100, 0, 0,
    ).activate(position(policy::long(), 100 + reserve, 200, 1), reserve, NOW);
    let mut base = 290;
    let mut plan = state.prepare_rebalance(position(policy::long(), 100 + reserve, base, 1), 10_000, NOW);
    assert!(!plan.is_emergency_rebalance());
    16u64.do!(|_| {
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 5);
        base = base - 5;
        state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 100 + reserve, base, 1), 5, NOW);
    });
    // Actual cost-free fills improve 0.8x, below the configured 0.9x. The
    // conservative projection costs 7 per order and exhausts equity or NAV.
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

fun dust_position(base: u64): PositionObservation {
    observation::new_position(
        6, base, 1, policy::long(), observation::new_price(PRICE / 1_000, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE / 1_000,
    )
}

fun seeded(side: PositionSide, reserve: u64, reserve_bps: u64, order_cap: u64): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 100),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, reserve_bps,
    );
    let (mut state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, order_cap, 10_000_000, 0, 0,
    ).activate(position(side, 1_000_000, 2_000_000, 1), 0, NOW);
    state.settle_funding(observation::funding_credit(reserve));
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
use blast_boosts_core::{errors, rebalance_math, observation::{Self, PositionObservation}, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::{assert_eq, destroy};
