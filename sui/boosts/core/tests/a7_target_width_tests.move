// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::a7_target_width_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;
const ORDER_CAP: u64 = 2_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun profit_above_the_nav_cap_and_old_target_limit_keeps_rebalancing() {
    let max = std::u64::max_value!();
    vector[policy::long(), policy::short()].do!(|side| {
        vector[max / 2, max / 2 + 1, max].do!(|equity| {
            let state = seeded(side);
            assert!(equity > state.nav_cap_for_testing());
            assert!(state.needs_rebalance(position(side, equity, 2_000_000), observation::funding_credit(0), true, 37, NOW));
            let mut plan = state.prepare_rebalance(position(side, equity, 2_000_000), 37, NOW);
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            // Independent execution-price cap, with the same atomic units.
            assert!(filled > 0 && (filled as u128) * 1_010_000_001 <= (ORDER_CAP as u128) * (PRICE as u128));
            let cost = filled.div_ceil(100);
            let fee = ((filled + cost) * 37).div_ceil(10_000);
            let final_equity = equity - cost - fee;
            state.accept_rebalance_fill(&mut plan, order, position(side, final_equity, 2_000_000 + filled), filled, NOW);
            let (equity_before, equity_after, base_before, base_after, increase) = state.complete_rebalance(plan);
            assert!(increase);
            assert_eq!(equity_before, equity);
            assert_eq!(equity_after, final_equity);
            assert_eq!(base_before, 2_000_000);
            assert_eq!(base_after, 2_000_000 + filled);
            assert_eq!(state.maintenance_reserve(), 0);
            state.destroy_for_testing();
        });
    });
}

#[test]
fun an_unreachable_target_stops_at_the_actual_position_limit() {
    vector[policy::long(), policy::short()].do!(|side| {
        let max = std::u64::max_value!();
        let state = seeded(side);
        let mut plan = state.prepare_rebalance(position(side, max, max - 5), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 5);
        state.accept_rebalance_fill(&mut plan, order, position(side, max - 1, max), 5, NOW);
        assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
        state.complete_rebalance(plan);
        assert!(!state.needs_rebalance(position(side, max - 1, max), observation::funding_credit(0), true, 0, NOW));
        state.destroy_for_testing();
    });
}

// === Test Helpers ===

fun seeded(side: PositionSide): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, 100),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 2_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, ORDER_CAP, 10_000_000, 0, 0,
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
use blast_boosts_core::{observation::{Self, PositionObservation}, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::assert_eq;
