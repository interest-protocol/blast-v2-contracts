// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Real preview admission with simulated captures; external venue execution is not exercised.
module blast_boosts_aftermath::a2_funding_preview_tests;

// === Constants ===

const NOW: u64 = 1_000;
const PRICE: u64 = 1_000_000_000;
const BASE_PER_NOTIONAL: u64 = 1_000;
const ATOM_SCALE: u256 = 1_000_000_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun already_settled_cost_prevents_an_unnecessary_rebalance() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 200);
        let ready = state.preview_rebalance(side, 1_000, 2_000, true, 200 * ATOM_SCALE);
        assert!(!ready);
        state.destroy_for_testing();
    });
}

#[test]
fun already_settled_credit_reveals_a_needed_rebalance() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = seeded(side, 0);
        let ready = state.preview_rebalance(side, 1_100, 2_000, false, 200 * ATOM_SCALE);
        assert!(ready);
        state.destroy_for_testing();
    });
}

#[test]
fun fractional_external_funding_rounds_credits_down_and_costs_up() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[false, true].do!(|cost| {
            vector[1, ATOM_SCALE - 1, ATOM_SCALE, ATOM_SCALE + 1].do!(|raw| {
                let mut state = seeded(side, 200);
                let ready = state.preview_rebalance(side, 1_100, 2_000, cost, raw);
                let amount = (if (cost) raw.div_ceil(ATOM_SCALE) else raw / ATOM_SCALE) as u64;
                state.settle_funding(if (cost) observation::funding_cost(amount) else observation::funding_credit(amount));
                assert_eq!(state.maintenance_reserve(), if (cost) 200 - amount else 200 + amount);
                assert_eq!(ready, capture(side, 1_100, 2_000).into_rebalance_readiness(&state, checkpoint::unchanged_change(), 10, NOW));
                state.destroy_for_testing();
            });
        });
    });
}

#[test]
fun later_market_rates_do_not_hide_funding_already_settled() {
    let state = seeded(policy::long(), 0);
    // Position snapshots reached 1; market has subsequently advanced to 2.
    let before = checkpoint(1_000 * ATOM_SCALE, 0, 1);
    let after = checkpoint(1_200 * ATOM_SCALE, 1, 2);
    let captured = snapshot::captured_position_for_testing(after, 1_100, 2_000 * BASE_PER_NOTIONAL, policy::long(), true, true);
    assert!(captured.into_rebalance_readiness(&state, before.classify_preexisting(&after), 10, NOW));
    assert_eq!(state.maintenance_reserve(), 0);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::snapshot)]
fun unexplained_changes_are_rejected_before_unavailable_venue_admission() {
    let state = seeded(policy::long(), 0);
    let before = checkpoint(1_000 * ATOM_SCALE, 0, 1);
    // Collateral changed without a funding-snapshot refresh.
    let after = checkpoint(1_200 * ATOM_SCALE, 0, 1);
    snapshot::captured_position_for_testing(after, 1_100, 2_000 * BASE_PER_NOTIONAL, policy::long(), true, false)
        .into_rebalance_readiness(&state, before.classify_preexisting(&after), 10, NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::snapshot)]
fun unrepresentable_external_funding_is_rejected_before_pricing() {
    let state = seeded(policy::long(), 0);
    state.preview_rebalance(policy::long(), 1_100, 2_000, false, ((std::u64::max_value!() as u256) + 1) * ATOM_SCALE);
    state.destroy_for_testing();
}

// === Test Helpers ===

fun preview_rebalance(state: &State<Product>, side: PositionSide, equity: u64, notional: u64, cost: bool, raw: u256): bool {
    let before = checkpoint(if (cost) raw else 0, 0, 1);
    let after = checkpoint(if (cost) 0 else raw, 1, 1);
    let stored_state = bcs::to_bytes(state);
    let stored_checkpoint = bcs::to_bytes(&before);
    let events_before = sui::event::num_events();
    let captured = snapshot::captured_position_for_testing(after, equity, notional * BASE_PER_NOTIONAL, side, true, true);
    let ready = captured.into_rebalance_readiness(state, before.classify_preexisting(&after), 10, NOW);
    assert_eq!(stored_state, bcs::to_bytes(state));
    assert_eq!(stored_checkpoint, bcs::to_bytes(&before));
    assert_eq!(events_before, sui::event::num_events());
    ready
}

fun checkpoint(allocated: u256, snapshot: u256, market: u256): Checkpoint {
    checkpoint::checkpoint_for_testing(0, allocated, 1, 1, snapshot, snapshot, market, market, 1, 0, 0, 0, 0, false, 1, 1, 1)
}


fun seeded(side: PositionSide, reserve: u64): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 100),
        policy::new_price_policy(60_000, 1_000, 100, 100), 0, 0, 100, 100, 3_000, 65, 2_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 300, 160_000, 9, 6,
    ).activate(observation::new_position(
        1_000 + reserve, 2_000 * BASE_PER_NOTIONAL, 1, side,
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), PRICE,
    ), reserve, NOW);
    state
}

fun capture(side: PositionSide, equity: u64, notional: u64): CapturedSnapshot {
    snapshot::captured_position_for_testing(
        checkpoint::checkpoint_for_testing(0, 1_000_000_000_000_000, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, false, 1, 1, 1),
        equity, notional * BASE_PER_NOTIONAL, side, true, true,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint}, errors, snapshot::{Self, CapturedSnapshot}};
use blast_boosts_core::{observation, policy::{Self, PositionSide}, state::{Self, State}};

use std::{bcs, unit_test::assert_eq};

use fun preview_rebalance as State.preview_rebalance;
