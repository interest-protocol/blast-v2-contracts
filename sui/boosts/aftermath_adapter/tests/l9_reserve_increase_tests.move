// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Real adapter admission with simulated venue snapshots; no live execution claim.
module blast_boosts_aftermath::l9_reserve_increase_tests;

// === Constants ===

const NOW: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;
const BASE_PER_NOTIONAL: u64 = 1_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun captures_complete_reserve_aware_increases_for_both_sides() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side);
        state.settle_funding(observation::funding_credit(400));
        let mut base = 300 * BASE_PER_NOTIONAL;
        let mut equity = 1_000;
        let (ready, _) = capture(side, equity, base).into_rebalance_readiness(&state, 10, NOW);
        assert!(ready);
        let (mut plan, _) = capture(side, equity, base).into_rebalance_plan(&state, 10, NOW);
        let mut steps = 0;
        loop {
            let order = state.next_rebalance_order(&plan);
            let filled = order.order_base();
            if (filled == 0) break;
            assert!(order.is_increase() && !order.is_emergency());
            let quote = filled.div_ceil(BASE_PER_NOTIONAL);
            let adverse = quote.div_ceil(100);
            let fee = (quote + adverse).div_ceil(1_000);
            equity = equity - adverse - fee;
            base = base + filled;
            let (after, _) = capture(side, equity, base).into_rebalance_observation(&plan);
            state.accept_rebalance_fill(&mut plan, order, after, filled, NOW);
            let notional = base.div_ceil(BASE_PER_NOTIONAL);
            assert!(notional <= 2 * (equity - 400u64.min(notional / 5)));
            steps = steps + 1;
        };
        assert!(steps > 1 && steps <= state::max_rebalance_orders());
        state.complete_rebalance(plan);
        assert_eq!(state.maintenance_reserve(), 400);
        state.destroy_for_testing();
    });
}

// === Test Helpers ===

fun seeded(side: PositionSide): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 100),
        policy::new_price_policy(60_000, 1_000, 100, 100), 0, 0, 100, 100, 3_000, 65, 2_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 300, 160_000, 9, 6,
    ).activate(observation::new_position(
        1_000, 2_000 * BASE_PER_NOTIONAL, 1, side,
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), PRICE,
    ), 0, NOW);
    state
}

fun capture(side: PositionSide, equity: u64, base: u64): CapturedSnapshot {
    snapshot::captured_position_for_testing(
        checkpoint::checkpoint_for_testing(0, 1_000_000_000_000_000, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, false, 1, 1, 1),
        equity, base, side, true, true,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_aftermath::{checkpoint, snapshot::{Self, CapturedSnapshot}};
use blast_boosts_core::{observation, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::assert_eq;
