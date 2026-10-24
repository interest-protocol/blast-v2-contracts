// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l3_recovery_tests;

// === Constants ===

const NOW: u64 = 100_000;
const LOT: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun a_small_long_or_short_can_buy_one_lot_past_target_inside_the_band() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        let mut plan = state.prepare_rebalance(position(side, 2_994, 5 * LOT), 10, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), LOT);
        state.accept_rebalance_fill(&mut plan, order, position(side, 2_984, 6 * LOT), LOT, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        state.destroy_for_testing();
    });
}

#[test]
fun a_deposit_can_recover_a_position_too_small_for_any_standalone_buy() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = new_state(side);
        assert!(!state.needs_rebalance(position(side, 600, LOT), true, 10, NOW));
        let plan = state.prepare_mint(position(side, 600, LOT), 5_400, 600, 5_380, 10, NOW);
        let base_after = LOT + plan.base_to_buy();
        let (shares, contribution, _, _, _) = state.complete_mint(plan, position(side, 5_990, base_after), NOW);
        assert_eq!(shares, 5_390);
        assert_eq!(contribution, 5_390);
        assert!(!state.needs_rebalance(position(side, 5_990, base_after), true, 10, NOW));
        assert_eq!(state.maintenance_reserve(), 0);
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNotActionable, location = blast_boosts_core::state)]
fun genuine_lot_dust_is_rejected_before_creating_a_rebalance_plan() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 600, LOT), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOutsideBand, location = blast_boosts_core::state)]
fun the_single_lot_exception_cannot_cross_the_upper_band() {
    finish_one_lot(policy::long(), 2_700);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceOutsideBand, location = blast_boosts_core::state)]
fun a_favorable_single_lot_fill_must_still_reach_the_lower_band() {
    finish_one_lot(policy::short(), 3_400);
}

#[test]
fun a_single_lot_fill_accepts_the_exact_upper_band_edge() {
    let state = new_state(policy::long());
    let mut plan = state.prepare_rebalance(priced_position(32_934, 5 * LOT), 10, NOW);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), LOT);
    // 66,000 / 30,000 = exactly 2.2; this tests the core's final guard.
    // The adapter independently rejects any fill outside its price bound.
    state.accept_rebalance_fill(&mut plan, order, priced_position(30_000, 6 * LOT), LOT, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun recovery_deposits_do_not_skip_an_available_single_lot_rebalance() {
    let state = new_state(policy::long());
    destroy(state.prepare_mint(position(policy::long(), 2_994, 5 * LOT), 5_400, 600, 1, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun recovery_deposits_do_not_skip_an_ordinary_rebalance() {
    let state = new_state(policy::long());
    destroy(state.prepare_mint(position(policy::long(), 6_000, 5 * LOT), 5_400, 600, 1, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun recovery_deposits_cannot_enter_from_above_the_band() {
    let state = new_state(policy::short());
    destroy(state.prepare_mint(position(policy::short(), 2_000, 5 * LOT), 5_400, 600, 1, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun a_price_move_that_makes_the_cap_too_small_is_not_reported_as_lot_dust() {
    let state = small_cap_state();
    state.needs_rebalance(expensive_position(), true, 10, NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun recovery_deposits_do_not_bypass_a_cap_smaller_than_one_lot() {
    let state = small_cap_state();
    destroy(state.prepare_mint(expensive_position(), 540_000, 600, 1, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EVenueFeeUnusable, location = blast_boosts_core::state)]
fun an_invalid_fee_is_rejected_before_recovery_sizing() {
    let state = new_state(policy::long());
    destroy(state.prepare_mint(position(policy::long(), 600, LOT), 5_400, 600, 1, 10_001, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_recovery_deposit_cannot_finish_below_the_band() {
    finish_recovery(6_200, 10 * LOT, 1);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_recovery_deposit_cannot_finish_above_the_band() {
    finish_recovery(4_990, 10 * LOT, 1);
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun a_recovery_deposit_rejects_a_partial_catch_up() {
    finish_recovery(5_990, 9 * LOT, 1);
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun a_recovery_deposit_rejects_extra_exposure() {
    finish_recovery(5_990, 11 * LOT, 1);
}

#[test]
#[expected_failure(abort_code = errors::ESharesOutBelowMinimum, location = blast_boosts_core::accounting_math)]
fun the_recovery_depositor_controls_their_maximum_cost_through_minimum_shares() {
    finish_recovery(5_990, 10 * LOT, 5_391);
}

#[test]
#[expected_failure(abort_code = errors::EOrderBelowMinLots, location = blast_boosts_core::accounting_math)]
fun actual_recovery_contribution_must_still_fund_the_minimum_size() {
    finish_recovery(1_000, 10 * LOT, 1);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_deposit_that_cannot_be_recovered_inside_one_order_cap_is_rejected_early() {
    let state = small_cap_state();
    destroy(state.prepare_mint(position(policy::long(), 600, LOT), 5_400, 600, 1, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state)]
fun recovery_keeps_the_nav_cap() {
    let mut state = new_state(policy::long());
    state.set_nav_cap(5_000);
    let plan = state.prepare_mint(position(policy::long(), 600, LOT), 5_400, 600, 1, 10, NOW);
    state.complete_mint(plan, position(policy::long(), 5_990, 11 * LOT), NOW);
    state.destroy_for_testing();
}

#[test]
fun favorable_recovery_execution_does_not_credit_more_than_the_deposit() {
    let mut state = new_state(policy::long());
    let plan = state.prepare_mint(position(policy::long(), 600, LOT), 5_400, 600, 1, 10, NOW);
    let (shares, contribution, _, _, _) = state.complete_mint(plan, position(policy::long(), 6_010, 11 * LOT), NOW);
    assert_eq!(shares, 5_400);
    assert_eq!(contribution, 5_400);
    assert!(6_010u128 * 600 >= 600u128 * (600 + shares as u128));
    state.destroy_for_testing();
}

#[test]
fun recovery_uses_final_reserve_after_protocol_fees() {
    let mut state = new_state(policy::short());
    state.set_fees(100, 0, 0);
    let plan = state.prepare_mint(position(policy::short(), 600, LOT), 5_400, 600, 1, 10, NOW);
    let (shares, contribution, fee, admin, reserve) = state.complete_mint(plan, position(policy::short(), 5_990, 11 * LOT), NOW);
    assert_eq!(vector[shares, contribution, fee, admin, reserve], vector[5_336, 5_336, 54, 0, 54]);
    assert_eq!(state.maintenance_reserve(), 54);
    state.destroy_for_testing();
}

#[test]
fun the_next_deposit_returns_to_normal_proportional_sizing() {
    let mut state = new_state(policy::long());
    let plan = state.prepare_mint(position(policy::long(), 600, LOT), 5_400, 600, 1, 10, NOW);
    let (shares, _, _, _, _) = state.complete_mint(plan, position(policy::long(), 5_990, 11 * LOT), NOW);
    let next = state.prepare_mint(position(policy::long(), 5_990, 11 * LOT), 5_990, 600 + shares, 1, 10, NOW);
    assert_eq!(next.base_to_buy(), 11 * LOT);
    state.complete_mint(next, position(policy::long(), 11_980, 22 * LOT), NOW);
    state.destroy_for_testing();
}

#[test]
fun readiness_and_execution_match_an_independent_small_position_sweep() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        12u64.do!(|index| {
            let base = (index + 1) * LOT;
            vector[570, 600, 700].do!(|equity_per_lot| {
                let equity = (index + 1) * equity_per_lot;
                let mut expected = 0;
                // Enumerate executable integer orders instead of the production binary search.
                16u64.do!(|step| {
                    let buy = (step + 1) * LOT;
                    let cost = reference_cost(buy);
                    if (equity > cost && (base + buy) * 10_000 <= 20_000 * (equity - cost)) expected = buy;
                });
                if (expected == 0 && equity > reference_cost(LOT)) {
                    let after_equity = equity - reference_cost(LOT);
                    if ((base + LOT) * 10_000 >= 18_000 * after_equity
                        && (base + LOT) * 10_000 <= 22_000 * after_equity) expected = LOT;
                };
                assert_eq!(state.needs_rebalance(position(side, equity, base), true, 10, NOW), expected > 0);
                if (expected > 0) {
                    let mut plan = state.prepare_rebalance(position(side, equity, base), 10, NOW);
                    let order = state.next_rebalance_order(&plan);
                    assert_eq!(order.order_base(), expected);
                    state.accept_rebalance_fill(
                        &mut plan, order, position(side, equity - reference_cost(expected), base + expected), expected, NOW,
                    );
                    state.complete_rebalance(plan);
                };
            });
        });
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::EOrderBelowMinLots, location = blast_boosts_core::accounting_math)]
fun a_recovery_deposit_below_the_proportional_minimum_is_rejected_before_sizing() {
    let state = new_state(policy::long());
    destroy(state.prepare_mint(position(policy::long(), 600, LOT), 1_199, 600, 1, 10, NOW));
    state.destroy_for_testing();
}

#[test]
fun the_calibrated_65_lot_minimum_also_supports_recovery() {
    let mut state = new_state_with_minimum(policy::long(), 65);
    let plan = state.prepare_mint(position(policy::long(), 600, LOT), 40_000, 600, 39_900, 10, NOW);
    let base_after = LOT + plan.base_to_buy();
    let (shares, contribution, _, _, _) = state.complete_mint(plan, position(policy::long(), 40_500, base_after), NOW);
    assert_eq!(shares, 39_900);
    assert_eq!(contribution, 39_900);
    assert!(!state.needs_rebalance(position(policy::long(), 40_500, base_after), true, 10, NOW));
    state.destroy_for_testing();
}

// === Test Helpers ===

fun reference_cost(notional: u64): u64 {
    let slippage = (notional + 99) / 100;
    slippage + (notional + slippage + 999) / 1_000
}

fun finish_one_lot(side: PositionSide, final_equity: u64) {
    let state = new_state(side);
    let mut plan = state.prepare_rebalance(position(side, 2_994, 5 * LOT), 10, NOW);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, position(side, final_equity, 6 * LOT), LOT, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

fun finish_recovery(final_equity: u64, filled: u64, minimum_shares: u64) {
    let mut state = new_state(policy::long());
    let plan = state.prepare_mint(position(policy::long(), 600, LOT), 5_400, 600, minimum_shares, 10, NOW);
    state.complete_mint(plan, position(policy::long(), final_equity, LOT + filled), NOW);
    state.destroy_for_testing();
}

fun small_cap_state(): State<Product> {
    let mut state = new_state(policy::long());
    state.set_max_order_notional(2_500, observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), LOT, NOW);
    state
}

fun priced_position(equity: u64, base: u64): PositionObservation {
    observation::new_position(
        equity, base, LOT, policy::long(), observation::new_price(11 * PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), 11 * PRICE,
    )
}

fun expensive_position(): PositionObservation {
    observation::new_position(
        60_000, LOT, LOT, policy::long(), observation::new_price(100 * PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), 100 * PRICE,
    )
}


fun new_state(side: PositionSide): State<Product> {
    new_state_with_minimum(side, 2)
}

fun new_state_with_minimum(side: PositionSide, minimum_lots: u64): State<Product> {
    let witness = blast_acl::witness_for_testing();
    let policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, minimum_lots, 1_000,
    );
    let (state, _, _) = state::issue<Product>(&witness, policy, 1_000_000, 1_000_000, 0, 0)
        .activate(position(side, (minimum_lots + 8) * LOT / 2, (minimum_lots + 8) * LOT), 0, NOW);
    state
}

fun position(side: PositionSide, equity: u64, base: u64): PositionObservation {
    observation::new_position(
        equity, base, LOT, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_core::{
    errors,
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide},
    state::{Self, State},
};
use std::unit_test::{assert_eq, destroy};
