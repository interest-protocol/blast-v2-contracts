// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Real admission and core planning with external captures replaced by fixtures.
module blast_boosts_aftermath::margin_recovery_tests;

// === Constants ===

const NOW: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;
const BASE_PER_NOTIONAL: u64 = 1_000;

// === Test-Only Types ===

public struct Product() has drop;

// === Tests ===

#[test]
fun long_emergency_can_reduce_in_steps_while_below_opening_margin() {
    reduce_below_margin(policy::long(), 3_600, true);
}

#[test]
fun short_emergency_can_reduce_in_steps_while_below_opening_margin() {
    reduce_below_margin(policy::short(), 3_600, true);
}

#[test]
fun a_bounded_emergency_can_commit_before_the_hard_cap_is_fully_restored() {
    let remaining = reduce_below_margin(policy::long(), 12_000, true);
    assert!(remaining > 2_700 * BASE_PER_NOTIONAL);
}

#[test]
fun ordinary_long_reduction_does_not_need_opening_margin() {
    reduce_below_margin(policy::long(), 2_500, false);
}

#[test]
fun ordinary_short_reduction_does_not_need_opening_margin() {
    reduce_below_margin(policy::short(), 2_500, false);
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun low_margin_cannot_authorize_an_increase() {
    let state = seeded(policy::long());
    let (plan, _) = capture(1_000, policy::long(), false).into_rebalance_plan(&state, 10, NOW);
    destroy(plan);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun an_increasing_fill_must_still_have_opening_margin() {
    let state = seeded(policy::long());
    let (plan, _) = capture(1_000, policy::long(), true).into_rebalance_plan(&state, 10, NOW);
    capture(1_100, policy::long(), false).into_rebalance_observation(&plan);
    destroy(plan);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun reduction_does_not_bypass_pending_orders() {
    let state = seeded(policy::long());
    let (plan, _) = snapshot::captured_health_for_testing(checkpoint(), 1_000, false, 1, true, true)
        .into_rebalance_plan(&state, 10, NOW);
    destroy(plan);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun reduction_does_not_bypass_a_paused_or_frozen_venue() {
    let state = seeded(policy::long());
    let (plan, _) = snapshot::captured_health_for_testing(checkpoint(), 1_000, false, 0, false, true)
        .into_rebalance_plan(&state, 10, NOW);
    destroy(plan);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::snapshot)]
fun reduction_does_not_accept_unrepresentable_economics() {
    let state = seeded(policy::long());
    let (plan, _) = snapshot::captured_health_for_testing(checkpoint(), 1_000, false, 0, true, false)
        .into_rebalance_plan(&state, 10, NOW);
    destroy(plan);
    destroy(state);
}

#[test]
fun keeper_readiness_admits_low_margin_reductions_in_both_directions() {
    vector[false, true].do!(|short| {
        let side = if (short) { policy::short() } else { policy::long() };
        let state = seeded(side);
        vector[2_500, 3_600].do!(|notional| {
            let (ready, _) = capture(notional, side, false).into_rebalance_readiness(&state, 10, NOW);
            assert!(ready);
        });
        destroy(state);
    });
}

#[test]
fun keeper_readiness_filters_only_unsafe_increases() {
    let state = seeded(policy::long());
    let (unsafe_increase, _) = capture(1_000, policy::long(), false).into_rebalance_readiness(&state, 10, NOW);
    let (safe_increase, _) = capture(1_000, policy::long(), true).into_rebalance_readiness(&state, 10, NOW);
    assert!(!unsafe_increase && safe_increase);
    destroy(state);
}

#[test]
fun keeper_readiness_does_not_trigger_inside_the_band_without_opening_margin() {
    let state = seeded(policy::long());
    let (ready, _) = capture(1_800, policy::long(), false).into_rebalance_readiness(&state, 10, NOW);
    assert!(!ready);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun keeper_readiness_still_rejects_a_paused_venue() {
    let state = seeded(policy::long());
    snapshot::captured_health_for_testing(checkpoint(), 1_000, false, 0, false, true)
        .into_rebalance_readiness(&state, 10, NOW);
    destroy(state);
}

// === Test Helpers ===

fun reduce_below_margin(side: PositionSide, initial_notional: u64, emergency: bool): u64 {
    let state = seeded(side);
    let (mut plan, _) = capture(initial_notional, side, false).into_rebalance_plan(&state, 10, NOW);
    assert!(!plan.is_increasing());
    assert_eq!(plan.is_emergency_rebalance(), emergency);
    let mut base = initial_notional * BASE_PER_NOTIONAL;
    let mut steps = 0u64;
    while (steps < 16) {
        let order = state.next_rebalance_order(&plan);
        let filled = order.order_base();
        if (filled == 0) break;
        assert!(!order.is_increase());
        base = base - filled;
        let (after, _) = snapshot::captured_position_for_testing(
            checkpoint(), 1_000, base, side, false, true,
        ).into_rebalance_observation(&plan);
        state.accept_rebalance_fill(&mut plan, order, after, filled, NOW);
        steps = steps + 1;
    };
    assert!(steps > 1);
    let (_, _, before_base, after_base, increased) = state.complete_rebalance(plan);
    assert!(!increased && after_base < before_base);
    assert_eq!(state.maintenance_reserve(), 100);
    destroy(state);
    after_base
}

fun seeded(side: PositionSide): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(16_000, 20_000, 26_000, 30_000, 100, 200, 100),
        policy::new_price_policy(60_000, 1_000, 100, 100),
        0, 0, 100, 100, 3_000, 65, 1_000,
    );
    let (state, _, _) = state::issue<Product>(&blast_admin::blast_acl::witness_for_testing<blast_boosts_core::blast_boosts_core::VaultIssuer>(), vault_policy, 100, 1_000_000, 9, 6).activate(
        observation::new_position(
            1_000, 1_800 * BASE_PER_NOTIONAL, 1, side,
            observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), PRICE,
        ), 100, NOW,
    );
    state
}

fun capture(notional: u64, side: PositionSide, margin_safe: bool): CapturedSnapshot {
    snapshot::captured_position_for_testing(checkpoint(), 1_000, notional * BASE_PER_NOTIONAL, side, margin_safe, true)
}

fun checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 1_000_000_000_000_000, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, false, 1, 1, 1)
}

// === Imports ===

use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint}, errors, snapshot::{Self, CapturedSnapshot}};
use blast_boosts_core::{observation, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::{assert_eq, destroy};
