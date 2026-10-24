// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l6_capacity_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun issuance_rejects_an_improvement_larger_than_sixteen_orders_can_deliver() {
    destroy(state::issue<Product>(&blast_acl::witness_for_testing(), vault_policy(policy::long(), 9_000), 100_000, 100_000_000, 0, 0));
}

#[test]
fun a_full_batch_keeps_its_progress_when_the_live_vault_outgrows_the_nav_cap() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        let mut equity = 100_000_000;
        let mut base = 290_000_000;
        let mut plan = state.prepare_rebalance(position(side, equity, base), 10, NOW);
        16u64.do!(|_| {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            assert_eq!(filled, 990);
            base = base - filled;
            equity = equity - 11;
            state.accept_rebalance_fill(&mut plan, order, position(side, equity, base), filled, NOW);
        });
        assert_eq!(base, 289_984_160);
        assert_eq!(equity, 99_999_824);
        state.complete_rebalance(plan);
        state.destroy_for_testing();
    });
}

#[test]
fun the_capacity_boundary_accepts_equality() {
    let policy = vault_policy(policy::long(), 160);
    destroy(state::issue<Product>(&blast_acl::witness_for_testing(), policy, 1_000, 1_000_000, 0, 0));
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun the_capacity_boundary_rejects_one_basis_point_more() {
    destroy(state::issue<Product>(&blast_acl::witness_for_testing(), vault_policy(policy::long(), 161), 1_000, 1_000_000, 0, 0));
}

#[test]
fun capacity_comparison_does_not_overflow_at_maximum_width() {
    let max = std::u64::max_value!();
    policy::new_rebalance_policy(1, 2, 3, 4, 0, 0, 160_000).assert_rebalance_capacity(max, max);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun maximum_width_improvement_cannot_wrap_the_capacity_guard() {
    let max = std::u64::max_value!();
    policy::new_rebalance_policy(1, 2, 3, 4, 0, 0, max).assert_rebalance_capacity(max, max);
}

#[test]
fun both_live_limit_setters_accept_exact_capacity() {
    let mut state = new_state(policy::long());
    state.set_nav_cap(1_600_000);
    state.set_nav_cap(1_000_000);
    state.set_order_cap(625);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun raising_the_nav_cap_cannot_make_the_minimum_unreachable() {
    let mut state = new_state(policy::long());
    state.set_nav_cap(1_600_001);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun lowering_the_order_cap_cannot_make_the_minimum_unreachable() {
    let mut state = new_state(policy::short());
    state.set_order_cap(624);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun an_impossible_order_cap_fails_before_stale_oracles() {
    let mut state = new_state(policy::long());
    state.set_max_order_notional(624, observation::new_price(PRICE, 0, 0), observation::new_price(PRICE, 0, 0), 1, NOW);
    state.destroy_for_testing();
}

#[test]
fun reducing_the_deposit_limit_below_live_value_keeps_rebalance_reachable() {
    let mut state = new_state(policy::long());
    state.set_nav_cap(1);
    state.finish_batch(policy::long(), 100_000_000, 290_000_000, 16, 100, 11);
    state.destroy_for_testing();
}

#[test]
fun full_batch_progress_smaller_than_one_basis_point_is_preserved() {
    let state = new_state(policy::short());
    state.finish_batch(policy::short(), 1_000_000_000, 2_900_000_000, 16, 100, 11);
    state.destroy_for_testing();
}

#[test]
fun a_full_emergency_batch_can_keep_progress_before_restoring_the_cap() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        // Emergency cap sizing permits 952 base atoms. Worst cost is ceil(952 * 5%) plus the fee = 49.
        state.finish_batch(side, 100_000_000, 320_000_000, 16, 100, 49);
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun fifteen_full_orders_cannot_claim_the_full_batch_exception() {
    let state = new_state(policy::long());
    state.finish_batch(policy::long(), 100_000_000, 290_000_000, 15, 100, 0);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun sixteen_partial_orders_cannot_claim_the_full_batch_exception() {
    let state = new_state(policy::short());
    state.finish_batch(policy::short(), 100_000_000, 290_000_000, 16, 1, 0);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun a_full_batch_with_costs_worse_than_the_projection_cannot_commit() {
    let state = new_state(policy::long());
    state.finish_batch(policy::long(), 100_000_000, 290_000_000, 16, 100, 12);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun selling_base_is_not_enough_when_net_leverage_worsens() {
    let state = new_state(policy::long());
    state.finish_batch(policy::long(), 100_000_000, 290_000_000, 16, 100, 400);
    state.destroy_for_testing();
}

#[test]
fun ordinary_minimum_progress_still_allows_early_completion() {
    let state = new_state(policy::long());
    state.finish_batch(policy::long(), 1_000_000, 2_900_000, 11, 100, 0);
    state.destroy_for_testing();
}

#[test]
fun reaching_target_still_allows_early_completion() {
    let state = new_state(policy::short());
    state.finish_batch(policy::short(), 1_000, 2_900, 1, 100, 0);
    state.destroy_for_testing();
}

#[test]
fun the_core_stops_sizing_after_its_sixteenth_fill() {
    let state = new_state(policy::long());
    let (plan, _) = state.filled_batch(policy::long(), 100_000_000, 290_000_000, 16, 100, 11);
    assert_eq!(state::max_rebalance_orders(), 16);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderLimit, location = blast_boosts_core::state)]
fun a_retained_order_cannot_extend_the_core_budget() {
    let state = new_state(policy::long());
    let (mut plan, equity) = state.filled_batch(policy::long(), 100_000_000, 290_000_000, 15, 100, 11);
    let retained = state.next_rebalance_order(&plan);
    let last = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, last, position(policy::long(), equity - 11, 289_984_160), 990, NOW);
    state.accept_rebalance_fill(&mut plan, retained, position(policy::long(), equity - 22, 289_983_170), 990, NOW);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
fun capacity_distance_matches_an_independent_small_integer_oracle() {
    vector[3u64, 9].do!(|before_notional| {
        vector[1u64, 3].do!(|before_nav| {
            1u64.range_do!(7, |after_notional| {
                1u64.range_do!(4, |after_nav| {
                    1u64.range_do!(7, |projected_notional| {
                        1u64.range_do!(4, |projected_nav| {
                            // Six is divisible by all these NAVs: exact leverage in sixths.
                            let before = (before_notional * 6 / before_nav).diff(12);
                            let after = (after_notional * 6 / after_nav).diff(12);
                            let projected = (projected_notional * 6 / projected_nav).diff(12);
                            assert_eq!(rebalance_math::reduction_matches_capacity(
                                before_notional, before_nav, after_notional, after_nav,
                                projected_notional, projected_nav, 20_000,
                            ), projected < before && after < before && after <= projected);
                        });
                    });
                });
            });
        });
    });
}

#[test]
fun capacity_distance_handles_maximum_width_and_sub_basis_point_changes() {
    let max = std::u64::max_value!();
    assert!(rebalance_math::reduction_matches_capacity(max, max / 3, max - 100, max / 3, max - 50, max / 3, 20_000));
    assert!(rebalance_math::reduction_matches_capacity(300_000_000, 100_000_000, 299_999_999, 100_000_000, 299_999_999, 100_000_000, 20_000));
    assert!(!rebalance_math::reduction_matches_capacity(300, 100, 300, 100, 300, 100, 20_000));
    assert!(!rebalance_math::reduction_matches_capacity(300, 100, 150, 100, 310, 100, 20_000));
    assert!(!rebalance_math::reduction_matches_capacity(300, 100, 50, 100, 250, 100, 20_000));
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::rebalance_math)]
fun capacity_distance_rejects_zero_projected_nav() {
    rebalance_math::reduction_matches_capacity(300, 100, 250, 100, 250, 0, 20_000);
}

#[test]
fun the_capacity_projection_excludes_and_preserves_the_reserve() {
    let mut state = new_state(policy::long());
    state.settle_funding(observation::funding_credit(1_000));
    assert_eq!(state.maintenance_reserve(), 1_000);
    state.finish_batch(policy::long(), 100_001_000, 290_000_000, 16, 100, 11);
    assert_eq!(state.maintenance_reserve(), 1_000);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun a_projection_that_worsens_leverage_does_not_lower_the_threshold() {
    let side = policy::short();
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy(side, 1_000_000), 1_000, 160, 0, 0,
    ).activate(position(side, 100, 200), 0, NOW);
    let mut plan = state.prepare_rebalance(position(side, 1_000_000, 2_900_000), 10_000, NOW);
    let mut base = 2_900_000;
    16u64.do!(|_| {
        let order = state.next_rebalance_order(&plan);
        let filled = order.order_base();
        base = base - filled;
        state.accept_rebalance_fill(&mut plan, order, position(side, 1_000_000, base), filled, NOW);
    });
    // All cost-free orders filled; the real improvement is below this fixture's
    // configured minimum. The fee projection worsens leverage and must still reject it.
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun cheaper_complete_emergency_fills_can_finish_with_a_smaller_last_order() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        state.finish_cheaper_batch(side, 100_000_000, 300_014_261, 100);
        state.destroy_for_testing();
    });
}

#[test]
fun complete_emergency_batches_cover_the_transition_from_capped_to_tail_orders() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        57u64.do!(|i| state.finish_cheaper_batch(side, 100_000_000, 300_010_000 + i * 125, 100));
        state.destroy_for_testing();
    });
}

#[test]
fun complete_ordinary_batches_cover_shrinking_tail_orders_with_cheaper_fills() {
    vector[policy::long(), policy::short()].do!(|side| {
        let vault_policy = policy::new_vault_policy(
            side, policy::new_rebalance_policy(18_000, 20_000, 20_001, 30_000, 100, 500, 100),
            policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 1_000,
        );
        let (state, _, _) = state::issue<Product>(
            &blast_acl::witness_for_testing(), vault_policy, 1_000, 1_000_000, 0, 0,
        ).activate(position(side, 1_000_000, 2_000_000), 0, NOW);
        57u64.do!(|i| state.finish_cheaper_batch(side, 100_000_000, 200_010_001 + i * 125, 0));
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun invalid_nav_cap_precedes_its_impossible_rebalance_capacity() {
    let mut state = new_state(policy::long());
    state.set_nav_cap(std::u64::max_value!());
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceCapacity, location = blast_boosts_core::policy)]
fun impossible_issuance_capacity_precedes_invalid_asset_decimals() {
    destroy(state::issue<Product>(&blast_acl::witness_for_testing(), vault_policy(policy::long(), 161), 1_000, 1_000_000, 19, 19));
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOrderLimit, location = blast_boosts_core::state)]
fun the_order_budget_precedes_a_malformed_seventeenth_fill() {
    let state = new_state(policy::long());
    let (mut plan, equity) = state.filled_batch(policy::long(), 100_000_000, 290_000_000, 16, 100, 11);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), equity, 289_984_160), 0, NOW);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
fun partial_long_emergency_fills_can_commit_at_10000_excess() {
    let state = new_state(policy::long());
    state.finish_batch(policy::long(), 100_000_000, 300_010_000, 16, 1, 0);
    state.destroy_for_testing();
}

#[test]
fun partial_long_emergency_fills_can_commit_at_17000_excess() {
    let state = new_state(policy::long());
    state.finish_batch(policy::long(), 100_000_000, 300_017_000, 16, 1, 0);
    state.destroy_for_testing();
}

#[test]
fun partial_short_emergency_fills_can_commit_at_10000_excess() {
    let state = new_state(policy::short());
    state.finish_batch(policy::short(), 100_000_000, 300_010_000, 16, 1, 0);
    state.destroy_for_testing();
}

#[test]
fun partial_short_emergency_fills_can_commit_at_17000_excess() {
    let state = new_state(policy::short());
    state.finish_batch(policy::short(), 100_000_000, 300_017_000, 16, 1, 0);
    state.destroy_for_testing();
}

#[test]
fun favorable_fills_followed_by_costs_cannot_fail_an_independent_base_floor() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        let mut equity = 100_000_000;
        let mut base = 300_014_261;
        let mut plan = state.prepare_rebalance(position(side, equity, base), 10, NOW);
        16u64.do!(|i| {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            base = base - filled;
            equity = if (i < 14) { equity + 1 } else if (i == 14) { equity - 10 } else { equity - 1 };
            state.accept_rebalance_fill(&mut plan, order, position(side, equity, base), filled, NOW);
        });
        assert_eq!(base, 300_000_012);
        assert_eq!(equity, 100_000_003);
        state.complete_rebalance(plan);
        state.destroy_for_testing();
    });
}

#[test]
fun a_partial_emergency_tail_does_not_need_the_capacity_exception() {
    let state = new_state(policy::long());
    let (mut plan, equity) = state.filled_batch(policy::long(), 100_000_000, 300_014_261, 15, 100, 11);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), equity, 299_999_980), 1, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun an_emergency_reduction_does_not_need_a_full_canonical_fill() {
    let state = new_state(policy::short());
    let small_plan = state.prepare_rebalance(position(policy::short(), 100_000_000, 300_000_001), 10, NOW);
    let small_order = state.next_rebalance_order(&small_plan);
    assert_eq!(small_order.order_base(), 1);
    destroy(small_plan);
    let (mut plan, equity) = state.filled_batch(policy::short(), 100_000_000, 320_000_000, 15, 100, 0);
    state.accept_rebalance_fill(&mut plan, small_order, position(policy::short(), equity, 319_985_719), 1, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

// === Test Helpers ===

/// Full fills pay the supplied real slippage and a 0.1% fee; costs round per order.
fun finish_cheaper_batch(self: &State<Product>, side: PositionSide, mut equity: u64, mut base: u64, slippage_bps: u64) {
    let mut plan = self.prepare_rebalance(position(side, equity, base), 10, NOW);
    16u64.do!(|_| {
        let order = self.next_rebalance_order(&plan);
        let filled = order.order_base();
        if (filled > 0) {
            base = base - filled;
            let slippage = (filled * slippage_bps).div_ceil(10_000);
            equity = equity - slippage - (filled + slippage).div_ceil(1_000);
            self.accept_rebalance_fill(&mut plan, order, position(side, equity, base), filled, NOW);
        };
    });
    self.complete_rebalance(plan);
}

fun finish_batch(self: &State<Product>, side: PositionSide, equity: u64, base: u64, count: u64, fill_percent: u64, cost: u64) {
    let (plan, _) = self.filled_batch(side, equity, base, count, fill_percent, cost);
    self.complete_rebalance(plan);
}

fun filled_batch(self: &State<Product>, side: PositionSide, mut equity: u64, mut base: u64, count: u64, fill_percent: u64, cost: u64): (RebalancePlan<Product>, u64) {
    let mut plan = self.prepare_rebalance(position(side, equity, base), 10, NOW);
    count.do!(|_| {
        let order = self.next_rebalance_order(&plan);
        let filled = order.order_base() * fill_percent / 100;
        assert!(filled > 0);
        base = base - filled;
        equity = equity - cost;
        self.accept_rebalance_fill(&mut plan, order, position(side, equity, base), filled, NOW);
    });
    (plan, equity)
}

fun set_order_cap(self: &mut State<Product>, cap: u64) {
    self.set_max_order_notional(cap, observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), 1, NOW);
}

fun new_state(side: PositionSide): State<Product> {
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy(side, 100), 1_000, 1_000_000, 0, 0,
    ).activate(position(side, 1_000_000, 2_000_000), 0, NOW);
    state
}

fun vault_policy(side: PositionSide, improvement: u64): VaultPolicy {
    policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, improvement),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 1_000,
    )
}

fun position(side: PositionSide, equity: u64, base: u64): PositionObservation {
    observation::new_position(
        equity, base, 1, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_core::{
    errors,
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide, VaultPolicy},
    rebalance_math,
    state::{Self, RebalancePlan, State},
};
use std::unit_test::{assert_eq, destroy};

use fun finish_cheaper_batch as State.finish_cheaper_batch;
use fun finish_batch as State.finish_batch;
use fun filled_batch as State.filled_batch;
use fun set_order_cap as State.set_order_cap;
