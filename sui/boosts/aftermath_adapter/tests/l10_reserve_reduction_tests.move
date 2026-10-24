// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Real capture admission and core transitions; venue execution is simulated.
module blast_boosts_aftermath::l10_reserve_reduction_tests;

// === Constants ===

const NOW: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;
const BASE_PER_NOTIONAL: u64 = 1_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun partial_emergency_captures_cross_the_old_reserve_without_undoing_the_batch() {
    vector[policy::long(), policy::short()].do!(|side| {
        finish_partial_batch(side, 50_000, 51_000, 10_000);
    });
}

#[test]
fun partial_emergency_captures_can_reduce_exposure_despite_a_worse_ratio() {
    vector[policy::long(), policy::short()].do!(|side| {
        finish_partial_batch(side, 0, 10_000, 1_000);
    });
}

#[test]
fun full_emergency_captures_stop_before_the_next_bound_priced_fill_would_erase_nav() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side);
        let mut base = 1_000_000 * BASE_PER_NOTIONAL;
        let mut equity = 10_000;
        let (mut plan, _) = capture(side, equity, base).into_rebalance_plan(&state, 0, NOW);
        let mut steps = 0u64;
        loop {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            if (filled == 0) break;
            // Two extra atoms model conservative capture rounding.
            let cost = filled.div_ceil(BASE_PER_NOTIONAL).div_ceil(50) + 2;
            assert!(cost < equity);
            equity = equity - cost;
            base = base - filled;
            let (after, _) = capture(side, equity, base).into_rebalance_observation(&plan);
            state.accept_rebalance_fill(&mut plan, order, after, filled, NOW);
            steps = steps + 1;
        };
        assert!(steps > 1 && steps < state::max_rebalance_orders());
        assert_eq!(equity, 3);
        state.complete_rebalance(plan);
        state.destroy_for_testing();
    });
}

// === Test Helpers ===

fun finish_partial_batch(side: PositionSide, reserve: u64, mut equity: u64, quote_per_fill: u64) {
    let mut state = seeded(side);
    state.settle_funding(observation::funding_credit(reserve));
    let mut base = 1_000_000 * BASE_PER_NOTIONAL;
    let (ready, _) = capture(side, equity, base).into_rebalance_readiness(&state, 0, NOW);
    assert!(ready);
    let (mut plan, _) = capture(side, equity, base).into_rebalance_plan(&state, 0, NOW);
    assert!(plan.is_emergency_rebalance());
    16u64.do!(|_| {
        let order = state.next_rebalance_order(&plan);
        let filled = quote_per_fill * BASE_PER_NOTIONAL;
        assert!(order.is_emergency() && !order.is_increase());
        assert!(filled < order.order_base());
        assert_eq!(order.bound().slippage_bps(), 200);
        equity = equity - quote_per_fill / 50;
        base = base - filled;
        let (after, _) = capture(side, equity, base).into_rebalance_observation(&plan);
        state.accept_rebalance_fill(&mut plan, order, after, filled, NOW);
    });
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
    let (_, _, before_base, after_base, increase) = state.complete_rebalance(plan);
    assert!(after_base < before_base && !increase);
    assert_eq!(state.maintenance_reserve(), reserve);
    state.destroy_for_testing();
}

fun seeded(side: PositionSide): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 100),
        policy::new_price_policy(60_000, 1_000, 100, 100), 0, 0, 100, 100, 3_000, 65, 500,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 102_001, 10_000_000, 9, 6,
    ).activate(observation::new_position(
        1_000_000, 2_000_000 * BASE_PER_NOTIONAL, 1, side,
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), PRICE,
    ), 0, NOW);
    state
}

fun capture(side: PositionSide, equity: u64, base: u64): CapturedSnapshot {
    snapshot::captured_position_for_testing(
        checkpoint::checkpoint_for_testing(0, 1_000_000_000_000_000, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, false, 1, 1, 1),
        equity, base, side, false, true,
    ).with_mark_for_testing(PRICE * 102 / 100)
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_aftermath::{checkpoint, snapshot::{Self, CapturedSnapshot}};
use blast_boosts_core::{observation, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::assert_eq;
