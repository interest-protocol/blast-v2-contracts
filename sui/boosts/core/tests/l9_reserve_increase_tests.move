// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l9_reserve_increase_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun audit_example_sizes_against_the_reserve_after_the_increase() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 400_000, 2_000, 2_000_000);
        let plan = state.prepare_rebalance(position(side, 1_000_000, 300_000, 1), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        let final_notional = 300_000 + order.order_base();
        let cost = rebalance_math::execution_cost_up(order.order_base(), 0, 100) as u64;
        let reserve = 400_000u64.min(final_notional / 5);
        assert!(final_notional <= 2 * (1_000_000 - cost - reserve));
        destroy(plan);
        state.destroy_for_testing();
    });
}

#[test]
fun repeated_increases_reprice_the_reserve_and_preserve_its_recorded_balance() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 400_000, 2_000, 300_000);
        let mut equity = 1_000_000;
        let mut base = 300_000;
        assert!(state.needs_rebalance(position(side, equity, base, 1), observation::funding_credit(0), true, 10, NOW));
        let mut plan = state.prepare_rebalance(position(side, equity, base, 1), 10, NOW);
        let mut steps = 0;
        loop {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            if (filled == 0) break;
            equity = equity - (rebalance_math::execution_cost_up(filled, 10, 100) as u64);
            base = base + filled;
            state.accept_rebalance_fill(&mut plan, order, position(side, equity, base, 1), filled, NOW);
            assert!(base <= 2 * (equity - 400_000u64.min(base / 5)));
            steps = steps + 1;
        };
        assert!(steps > 1 && steps <= state::max_rebalance_orders());
        state.complete_rebalance(plan);
        assert!(!state.needs_rebalance(position(side, equity, base, 1), observation::funding_credit(0), true, 10, NOW));
        assert_eq!(state.maintenance_reserve(), 400_000);
        state.destroy_for_testing();
    });
}

#[test]
fun sizing_matches_independent_enumeration_across_reserve_and_rounding_boundaries() {
    vector[0u64, 7, 40].do!(|reserve| {
        vector[2_000u64, 10_000].do!(|reserve_bps| {
            vector[0u64, 37].do!(|fee_bps| {
                vector[1u64, 7].do!(|lot| {
                    let state = seeded(policy::long(), reserve, reserve_bps, 2_000_000);
                    let before = fractional_position(100, 14, lot);
                    let plan = state.prepare_rebalance(before, fee_bps, NOW);
                    let mut expected = 0;
                    let mut candidate = lot;
                    // At 1.3 collateral per base, 200 base already exceeds the
                    // 2x target even with no reserve or execution cost.
                    while (candidate <= 200) {
                        let order_quote = (candidate * 13).div_ceil(10);
                        let notional = ((14 + candidate) * 13).div_ceil(10);
                        let adverse = order_quote.div_ceil(100);
                        let fee = ((order_quote + adverse) * fee_bps).div_ceil(10_000);
                        let admitted = reserve.min(notional * reserve_bps / 10_000);
                        let used = adverse + fee + admitted;
                        if (used < 100 && notional <= 2 * (100 - used)) expected = candidate;
                        candidate = candidate + lot;
                    };
                    assert!(expected > 0);
                    assert_eq!(state.next_rebalance_order(&plan).order_base(), expected);
                    destroy(plan);
                    state.destroy_for_testing();
                });
            });
        });
    });
}

#[test]
fun an_already_fully_admitted_reserve_keeps_the_fixed_nav_result() {
    let state = seeded(policy::long(), 50_000, 2_000, 2_000_000);
    let plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 300_000, 1), 10, NOW);
    let expected = rebalance_math::increase_base_down(950_000, 300_000, 20_000, PRICE, PRICE, 1, 2_000_000, 10, 100, 1, 1);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), expected);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun the_audits_1880000_fill_is_rejected_on_actual_reserve() {
    let state = seeded(policy::long(), 400_000, 2_000, 2_000_000);
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 300_000, 1), 0, NOW);
    // A retained, larger sealed order isolates the actual-fill guard from the
    // sizing fix. The old code accepted precisely this audit result as 2x.
    let other_plan = state.prepare_rebalance(position(policy::long(), 2_000_000, 300_000, 1), 0, NOW);
    let oversized_order = state.next_rebalance_order(&other_plan);
    destroy(other_plan);
    state.accept_rebalance_fill(&mut plan, oversized_order, position(policy::long(), 1_000_000, 1_880_000, 1), 1_580_000, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun an_adverse_long_fill_is_checked_independently_of_sizing() { adverse_fill(policy::long()); }

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun an_adverse_short_fill_is_checked_independently_of_sizing() { adverse_fill(policy::short()); }

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun completion_rechecks_the_current_reserve_after_an_accepted_fill() {
    let mut state = seeded(policy::long(), 0, 2_000, 2_000_000);
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 300_000, 1), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 1_000_000, 1_800_000, 1), 1_500_000, NOW);
    state.settle_funding(observation::funding_credit(400_000));
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun the_one_lot_band_exception_survives_the_final_reserve_check() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 500, 2_000, 2_000_000);
        assert!(state.needs_rebalance(position(side, 1_350, 1_000, 1_000), observation::funding_credit(0), true, 0, NOW));
        let mut plan = state.prepare_rebalance(position(side, 1_350, 1_000, 1_000), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 1_000);
        // Reserve grows from 200 to 400. Actual leverage is 2,000 / 940,
        // above target but within the permitted one-lot band landing.
        state.accept_rebalance_fill(&mut plan, order, position(side, 1_340, 2_000, 1_000), 1_000, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 500);
        state.destroy_for_testing();
    });
}

#[test]
fun keeper_hint_refuses_a_lot_that_only_fits_with_the_old_reserve() {
    let state = seeded(policy::long(), 500, 2_000, 2_000_000);
    assert!(!state.needs_rebalance(position(policy::long(), 1_150, 1_000, 1_000), observation::funding_credit(0), true, 0, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNotActionable, location = blast_boosts_core::state)]
fun preparation_refuses_the_same_unsafe_one_lot() {
    let state = seeded(policy::long(), 500, 2_000, 2_000_000);
    destroy(state.prepare_rebalance(position(policy::long(), 1_150, 1_000, 1_000), 0, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOutsideBand, location = blast_boosts_core::state)]
fun the_one_lot_fill_cannot_hide_a_reserve_driven_band_overshoot() {
    let state = seeded(policy::long(), 500, 2_000, 2_000_000);
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_350, 1_000, 1_000), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 1_300, 2_000, 1_000), 1_000, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun mint_catch_up_keeps_its_opening_admitted_reserve_basis() {
    let mut state = seeded(policy::long(), 500, 2_000, 2_000_000);
    let plan = state.prepare_mint(position(policy::long(), 1_150, 1_000, 1_000), 5_400, 600, 1, 0, NOW);
    let base_after = 1_000 + plan.base_to_buy();
    state.complete_mint(plan, position(policy::long(), 6_450, base_after, 1_000), NOW);
    assert_eq!(state.maintenance_reserve(), 200);
    state.destroy_for_testing();
}

#[test]
fun reopening_a_flat_position_uses_the_ceiling_at_the_new_exposure() {
    let state = seeded(policy::long(), 400_000, 2_000, 2_000_000);
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 0, 1), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    let filled = order.order_base();
    assert!(filled > 1_200_000);
    let equity = 1_000_000 - (rebalance_math::execution_cost_up(filled, 0, 100) as u64);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), equity, filled, 1), filled, NOW);
    state.complete_rebalance(plan);
    assert_eq!(state.maintenance_reserve(), 400_000);
    state.destroy_for_testing();
}

#[test]
fun candidate_base_near_u64_max_is_bounded_before_addition() {
    let state = seeded(policy::long(), 0, 2_000, 2_000_000);
    let before = observation::new_position(
        1_000_000_000_000, std::u64::max_value!() - 100, 1, policy::long(),
        observation::new_price(1, 0, NOW), observation::new_price(PRICE, 0, NOW), 1,
    );
    let plan = state.prepare_rebalance(before, 0, NOW);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 100);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNotActionable, location = blast_boosts_core::state)]
fun candidate_notional_beyond_u64_is_not_executable() {
    let state = seeded(policy::long(), 0, 2_000, std::u64::max_value!());
    let before = observation::new_position(
        std::u64::max_value!(), PRICE, 1, policy::long(),
        observation::new_price(std::u64::max_value!(), 0, NOW), observation::new_price(PRICE, 0, NOW), std::u64::max_value!(),
    );
    destroy(state.prepare_rebalance(before, 0, NOW));
    state.destroy_for_testing();
}

#[test]
fun an_ordinary_fill_then_a_one_lot_exception_keeps_the_last_fills_rule() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 5_000, 2_000, 2_000_000);
        let mut plan = state.prepare_rebalance(position(side, 13_900, 9_000, 3_000), 0, NOW);
        let first = state.next_rebalance_order(&plan);
        assert_eq!(first.order_base(), 9_000);
        // First fill: reserve grows 1,800 -> 3,600; 90 execution cost.
        // Leverage 18,000 / 10,210 is still below the 1.8x band edge.
        state.accept_rebalance_fill(&mut plan, first, position(side, 13_810, 18_000, 3_000), 9_000, NOW);
        let second = state.next_rebalance_order(&plan);
        assert_eq!(second.order_base(), 3_000);
        // Second fill: reserve grows to 4,200, and cost adds 30. Its 2.19x
        // landing needs the last order's exception, not the first order's rule.
        state.accept_rebalance_fill(&mut plan, second, position(side, 13_780, 21_000, 3_000), 3_000, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 5_000);
        state.destroy_for_testing();
    });
}

// === Test Helpers ===

fun adverse_fill(side: PositionSide) {
    let state = seeded(side, 400_000, 2_000, 2_000_000);
    let mut plan = state.prepare_rebalance(position(side, 1_000_000, 300_000, 1), 0, NOW);
    let order = state.next_rebalance_order(&plan);
    let filled = order.order_base();
    state.accept_rebalance_fill(&mut plan, order, position(side, 900_000, 300_000 + filled, 1), filled, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

fun fractional_position(equity: u64, base: u64, lot: u64): PositionObservation {
    observation::new_position(
        equity, base, lot, policy::long(), observation::new_price(PRICE * 13 / 10, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE * 13 / 10,
    )
}


fun seeded(side: PositionSide, reserve: u64, reserve_bps: u64, order_cap: u64): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, 100),
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
use blast_boosts_core::{errors, observation::{Self, PositionObservation}, policy::{Self, PositionSide}, rebalance_math, state::{Self, State}};
use std::unit_test::{assert_eq, destroy};
