// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l8_emergency_price_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;
const DIVERGENT_MARK: u64 = 1_100_000_000;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
fun emergency_reductions_accept_a_divergent_mark_through_the_cap_restoring_fill() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[900_000_000, DIVERGENT_MARK].do!(|mark| {
            let state = new_state(side);
            let mut base = 3_001_000;
            let mut plan = state.prepare_rebalance(position(side, 1_000_000, base, mark), 10, NOW);
            assert!(plan.is_emergency_rebalance());
            assert!(!plan.is_increasing());
            let mut steps = 0;
            loop {
                let order = state.next_rebalance_order(&plan);
                let filled = order.order_base();
                if (filled == 0) break;
                assert!(order.is_emergency());
                assert!(!order.is_increase());
                base = base - filled;
                state.accept_rebalance_fill(&mut plan, order, position(side, 1_000_000, base, mark), filled, NOW);
                steps = steps + 1;
            };
            assert!(steps > 1 && steps <= state::max_rebalance_orders());
            assert_eq!(base, 3_000_000);
            let (_, _, before_base, after_base, increase) = state.complete_rebalance(plan);
            assert_eq!(before_base, 3_001_000);
            assert_eq!(after_base, base);
            assert!(!increase);
            state.destroy_for_testing();
        });
    });
}

#[test]
fun keeper_hint_reports_emergency_even_without_opening_margin_or_matching_mark() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = new_state(side);
        assert!(state.needs_rebalance(position(side, 1_000_000, 3_000_001, DIVERGENT_MARK), observation::funding_credit(0), false, 10, NOW));
        state.destroy_for_testing();
    });
}

#[test]
fun emergency_classification_excludes_the_maintenance_reserve_from_holder_backing() {
    let state = new_state_with_reserve(policy::long(), 100_000);
    let plan = state.prepare_rebalance(position(policy::long(), 1_100_000, 3_000_001, DIVERGENT_MARK), 10, NOW);
    assert!(plan.is_emergency_rebalance());
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
fun an_ordinary_reduction_accepts_exactly_the_existing_mark_tolerance() {
    let state = new_state(policy::long());
    let plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 2_900_000, 1_050_000_000), 10, NOW);
    assert!(!plan.is_emergency_rebalance());
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun exactly_at_the_cap_still_requires_the_mark_check() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 1_000_000, 3_000_000, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun one_atom_below_the_cap_still_requires_the_mark_check() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 1_000_000, 2_999_999, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun an_increase_still_requires_the_mark_check() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 1_000_000, 1_500_000, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun inside_the_band_still_requires_the_mark_check() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 1_000_000, 2_000_000, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun one_unit_beyond_the_ordinary_mark_tolerance_fails() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 1_000_000, 2_900_000, 1_050_000_001), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun keeper_hint_at_the_cap_keeps_the_mark_check() {
    let state = new_state(policy::long());
    state.needs_rebalance(position(policy::long(), 1_000_000, 3_000_000, DIVERGENT_MARK), observation::funding_credit(0), false, 10, NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun mint_does_not_inherit_the_emergency_exception() {
    let state = new_state(policy::long());
    destroy(state.prepare_mint(position(policy::long(), 1_000_000, 3_000_001, DIVERGENT_MARK), 100, 1_000, 0, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun redemption_keeps_its_existing_mark_check() {
    let state = new_state(policy::long());
    destroy(state.prepare_redemption(position(policy::long(), 1_000_000, 3_000_001, DIVERGENT_MARK), 1, 1_000, 0, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun an_ordinary_plan_cannot_gain_the_exception_after_adverse_costs() {
    let state = new_state(policy::long());
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 2_900_000, PRICE), 10, NOW);
    let order = state.next_rebalance_order(&plan);
    let filled = order.order_base();
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 900_000, 2_900_000 - filled, DIVERGENT_MARK), filled, NOW);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy)]
fun a_later_ordinary_plan_after_recovery_requires_the_mark_check() {
    let state = new_state(policy::long());
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 3_000_001, DIVERGENT_MARK), 10, NOW);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 1);
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 1_000_000, 3_000_000, DIVERGENT_MARK), 1, NOW);
    state.complete_rebalance(plan);
    destroy(state.prepare_rebalance(position(policy::long(), 1_000_000, 3_000_000, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun emergency_start_rejects_stale_base_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, 0), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    );
    destroy(state.prepare_rebalance(observed, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EFuturePrice, location = blast_boosts_core::policy)]
fun emergency_start_rejects_future_base_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW + 2_001), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    );
    destroy(state.prepare_rebalance(observed, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy)]
fun emergency_start_rejects_uncertain_base_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 10_000_001, NOW), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    );
    destroy(state.prepare_rebalance(observed, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun emergency_start_rejects_stale_collateral_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, 0), DIVERGENT_MARK,
    );
    destroy(state.prepare_rebalance(observed, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EFuturePrice, location = blast_boosts_core::policy)]
fun emergency_start_rejects_future_collateral_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW + 2_001), DIVERGENT_MARK,
    );
    destroy(state.prepare_rebalance(observed, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy)]
fun emergency_start_rejects_uncertain_collateral_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 10_000_001, NOW), DIVERGENT_MARK,
    );
    destroy(state.prepare_rebalance(observed, 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPositionObservation, location = blast_boosts_core::state)]
fun emergency_start_checks_wrong_side_before_mark_divergence() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::short(), 1_000_000, 3_000_048, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun emergency_start_checks_zero_nav_before_mark_divergence() {
    let state = new_state(policy::long());
    destroy(state.prepare_rebalance(position(policy::long(), 0, 3_000_048, DIVERGENT_MARK), 10, NOW));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun emergency_fill_rejects_stale_base_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, 0), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    );
    state.accept_emergency_observation(observed);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EFuturePrice, location = blast_boosts_core::policy)]
fun emergency_fill_rejects_future_base_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW + 2_001), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    );
    state.accept_emergency_observation(observed);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy)]
fun emergency_fill_rejects_uncertain_base_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 10_000_001, NOW), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    );
    state.accept_emergency_observation(observed);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun emergency_fill_rejects_stale_collateral_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, 0), DIVERGENT_MARK,
    );
    state.accept_emergency_observation(observed);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EFuturePrice, location = blast_boosts_core::policy)]
fun emergency_fill_rejects_future_collateral_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW + 2_001), DIVERGENT_MARK,
    );
    state.accept_emergency_observation(observed);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy)]
fun emergency_fill_rejects_uncertain_collateral_price() {
    let state = new_state(policy::long());
    let observed = observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 10_000_001, NOW), DIVERGENT_MARK,
    );
    state.accept_emergency_observation(observed);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPositionObservation, location = blast_boosts_core::state)]
fun emergency_fill_checks_wrong_side_before_mark_divergence() {
    let state = new_state(policy::long());
    state.accept_emergency_observation(position(policy::short(), 1_000_000, 3_000_048, DIVERGENT_MARK));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun emergency_fill_checks_zero_nav_before_mark_divergence() {
    let state = new_state(policy::long());
    state.accept_emergency_observation(position(policy::long(), 0, 3_000_048, DIVERGENT_MARK));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun emergency_fill_cannot_change_base_price() {
    let state = new_state(policy::long());
    state.accept_emergency_observation(observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE + 1, 0, NOW), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    ));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun emergency_fill_cannot_change_collateral_price() {
    let state = new_state(policy::long());
    state.accept_emergency_observation(observation::new_position(
        1_000_000, 3_000_048, 1, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE + 1, 0, NOW), DIVERGENT_MARK,
    ));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun emergency_fill_cannot_change_lot_size() {
    let state = new_state(policy::long());
    state.accept_emergency_observation(observation::new_position(
        1_000_000, 3_000_048, 2, policy::long(),
        observation::new_price(PRICE, 0, NOW), observation::new_price(PRICE, 0, NOW), DIVERGENT_MARK,
    ));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun emergency_fill_still_proves_the_exact_base_movement() {
    let state = new_state(policy::long());
    state.accept_emergency_observation(position(policy::long(), 1_000_000, 3_000_049, DIVERGENT_MARK));
    state.destroy_for_testing();
}

#[test]
fun emergency_fill_can_keep_real_exposure_reduction_despite_ratio_costs() {
    let state = new_state(policy::long());
    let mut plan = state.prepare_rebalance(position(policy::long(), 1_000_000, 3_001_000, DIVERGENT_MARK), 10, NOW);
    let order = state.next_rebalance_order(&plan);
    let filled = order.order_base();
    state.accept_rebalance_fill(&mut plan, order, position(policy::long(), 900_000, 3_001_000 - filled, DIVERGENT_MARK), filled, NOW);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

// === Test Helpers ===

fun accept_emergency_observation(self: &State<Product>, after: PositionObservation) {
    let mut plan = self.prepare_rebalance(position(policy::long(), 1_000_000, 3_001_000, DIVERGENT_MARK), 10, NOW);
    let order = self.next_rebalance_order(&plan);
    let filled = order.order_base();
    self.accept_rebalance_fill(&mut plan, order, after, filled, NOW);
    destroy(plan);
}

fun new_state(side: PositionSide): State<Product> {
    new_state_with_reserve(side, 0)
}

fun new_state_with_reserve(side: PositionSide, reserve: u64): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, 100),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 1_000,
    );
    let (state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 1_000, 1_000_000, 0, 0,
    ).activate(position(side, 1_000_000 + reserve, 2_000_000, PRICE), reserve, NOW);
    state
}

fun position(side: PositionSide, equity: u64, base: u64, mark: u64): PositionObservation {
    observation::new_position(
        equity, base, 1, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), mark,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_core::{errors, observation::{Self, PositionObservation}, policy::{Self, PositionSide}, state::{Self, State}};
use std::unit_test::{assert_eq, destroy};

use fun accept_emergency_observation as State.accept_emergency_observation;
