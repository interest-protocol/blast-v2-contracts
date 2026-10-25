// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Exercises real capture admission and core plans with simulated venue facts.
module blast_boosts_aftermath::l8_emergency_price_tests;

// === Constants ===

const NOW: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;
const DIVERGENT_MARK: u64 = 1_020_000_000;
const BASE_PER_NOTIONAL: u64 = 1_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun emergency_capture_and_fills_allow_divergence_without_opening_margin() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[980_000_000, DIVERGENT_MARK].do!(|mark| {
            let state = seeded(side);
            let mut base = 3_000 * BASE_PER_NOTIONAL;
            let (mut plan, _) = capture(side, base, false).with_mark_for_testing(mark)
                .into_rebalance_plan(&state, 10, NOW);
            assert!(plan.is_emergency_rebalance());
            let mut steps = 0;
            loop {
                let order = state.next_rebalance_order(&plan);
                let filled = order.order_base();
                if (filled == 0) break;
                assert!(order.is_emergency() && !order.is_increase());
                assert_eq!(order.bound().slippage_bps(), 200);
                base = base - filled;
                let (after, _) = capture(side, base, false).with_mark_for_testing(mark).into_rebalance_observation(&plan);
                state.accept_rebalance_fill(&mut plan, order, after, filled, NOW);
                steps = steps + 1;
            };
            assert!(steps > 1 && steps <= state::max_rebalance_orders());
            // 100 of the 1,000 collateral belongs to the reserve: cap = 3 * 900.
            assert_eq!(base, 2_700 * BASE_PER_NOTIONAL);
            let (_, _, before_base, after_base, increase) = state.complete_rebalance(plan);
            assert!(before_base > after_base && !increase);
            assert_eq!(state.maintenance_reserve(), 100);
            state.destroy_for_testing();
        });
    });
}

#[test]
fun keeper_capture_reports_emergency_despite_divergence_and_low_margin() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side);
        let ready = capture(side, 3_000 * BASE_PER_NOTIONAL, false).with_mark_for_testing(DIVERGENT_MARK)
            .into_rebalance_readiness(&state, checkpoint::unchanged_change(), 10, NOW);
        assert!(ready);
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = core_errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun ordinary_capture_at_the_cap_still_requires_mark_agreement() {
    let state = seeded(policy::long());
    let (plan, _) = capture(policy::long(), 2_700 * BASE_PER_NOTIONAL, false).with_mark_for_testing(DIVERGENT_MARK)
        .into_rebalance_plan(&state, 10, NOW);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = core_errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun ordinary_keeper_capture_still_requires_mark_agreement() {
    let state = seeded(policy::long());
    capture(policy::long(), 2_700 * BASE_PER_NOTIONAL, false).with_mark_for_testing(DIVERGENT_MARK)
        .into_rebalance_readiness(&state, checkpoint::unchanged_change(), 10, NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun emergency_with_a_divergent_mark_cannot_bypass_market_readiness() {
    let state = seeded(policy::long());
    let (plan, _) = snapshot::captured_position_for_testing(checkpoint(), 1_000, 3_000 * BASE_PER_NOTIONAL, policy::long(), false, false)
        .with_mark_for_testing(DIVERGENT_MARK).into_rebalance_plan(&state, 10, NOW);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun emergency_fill_with_a_divergent_mark_cannot_bypass_pending_orders() {
    let state = seeded(policy::long());
    let (plan, _) = capture(policy::long(), 3_000 * BASE_PER_NOTIONAL, false).with_mark_for_testing(DIVERGENT_MARK)
        .into_rebalance_plan(&state, 10, NOW);
    snapshot::captured_health_for_testing(checkpoint(), 1_000, false, 1, true, true)
        .with_mark_for_testing(DIVERGENT_MARK).into_rebalance_observation(&plan);
    destroy(plan);
    state.destroy_for_testing();
}

// === Test Helpers ===

fun seeded(side: PositionSide): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(16_000, 20_000, 26_000, 30_000, 100, 200, 100),
        policy::new_price_policy(60_000, 1_000, 100, 100), 0, 0, 100, 100, 3_000, 65, 1_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 100, 160_000, 9, 6,
    ).activate(observation::new_position(
        1_000, 1_800 * BASE_PER_NOTIONAL, 1, side,
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), PRICE,
    ), 100, NOW);
    state
}

fun capture(side: PositionSide, base: u64, margin_safe: bool): CapturedSnapshot {
    snapshot::captured_position_for_testing(checkpoint(), 1_000, base, side, margin_safe, true)
}

fun checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 1_000_000_000_000_000, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, false, 1, 1, 1)
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint}, errors, snapshot::{Self, CapturedSnapshot}};
use blast_boosts_core::{errors as core_errors, observation, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::{assert_eq, destroy};
