// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for construction of adapter-custodied Series1 state.
module blast_boosts_core::state_tests;

// === Constants ===

const MAX_ORDER_NOTIONAL: u64 = 250;
const REFERENCE_AT_MS: u64 = 100_000;
const SEED_RESERVE: u64 = 100_000;
const SEED_VENUE_EQUITY: u64 = 1_100_000;
const SEED_NAV: u64 = 1_000_000;
const SEED_BASE: u64 = 2_000_000_000;
const SEED_NOTIONAL: u64 = 2_000_000;
const LOT_SIZE: u64 = 1_000;
const MIN_EXPOSURE_LOTS: u64 = 100;
/// Sixteen 250-atom orders can improve leverage by 10 bps at this ceiling.
const NAV_CAP: u64 = 4_000_000;
/// Half of notional: wide enough that ordinary fixtures never touch the ceiling.
const MAX_RESERVE_BPS: u64 = 5_000;
const HEALTH_SHARE_SUPPLY: u64 = 1_000_000;

// === Test-Only Types ===

public struct Product {}

public struct ObservationSpec has copy, drop {
    venue_equity: u64,
    position_base: u64,
    lot_size: u64,
    observed_side: PositionSide,
    base_price: u64,
    base_confidence: u64,
    base_publish_time_ms: u64,
    collateral_price: u64,
    collateral_confidence: u64,
    collateral_publish_time_ms: u64,
    mark_price: u64,
}

// === Tests ===

#[test]
fun profit_realization_preserves_position_and_accounting_for_long_and_short() {
    vector[policy::long(), policy::short()].do!(|side| {
        let state = rebalance_state(side);
        let before = standard_observation(side);
        let plan = state.prepare_profit_realization(before.into_position_observation(), 300_000, 600_000, 10, REFERENCE_AT_MS);
        let base = plan.base_to_realize();
        assert!(base > 0 && base < SEED_BASE && base % LOT_SIZE == 0);
        assert!(base <= state.max_order_base(&plan.realization_position(), false));
        let (equity_before, equity_after, realized, cost) = state.complete_profit_realization(
            plan, before.with_venue_equity(SEED_VENUE_EQUITY - 1_000).into_position_observation(), REFERENCE_AT_MS,
        );
        assert_eq!(equity_before, SEED_VENUE_EQUITY);
        assert_eq!(equity_after, SEED_VENUE_EQUITY - 1_000);
        assert_eq!(realized, base);
        assert_eq!(cost, 1_000);
        assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
        assert_eq!(state.uncovered_deficit(), 0);
        assert!(state.is_active_for_testing());
        state.destroy_for_testing();
    });
}

#[test]
fun profit_realization_small_order_cap_allows_bounded_repeated_progress() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 300_000, 600_000, 10, REFERENCE_AT_MS);
    assert_eq!(plan.base_to_realize(), state.max_order_base(&plan.realization_position(), false));
    let (_, _, _, cost) = state.complete_profit_realization(
        plan, before.with_venue_equity(SEED_VENUE_EQUITY - 5).into_position_observation(), REFERENCE_AT_MS,
    );
    assert_eq!(cost, 5);
    state.destroy_for_testing();
}

#[test]
fun profit_realization_sizes_a_useful_minimum_for_a_one_atom_shortfall() {
    let state = rebalance_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 1, 600_000, 10, REFERENCE_AT_MS);
    assert!(plan.base_to_realize() > LOT_SIZE && plan.base_to_realize() < SEED_BASE / 1_000);
    state.complete_profit_realization(plan, before.into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
fun profit_realization_size_is_monotonic_whole_lots_and_capped() {
    let state = rebalance_state(policy::short());
    let mut previous = 0;
    vector[1, 2, 10, 100, 1_000, 10_000, 100_000, 300_000, 555_597].do!(|shortfall| {
        let before = standard_observation(policy::short());
        let plan = state.prepare_profit_realization(before.into_position_observation(), shortfall, 600_000, 10, REFERENCE_AT_MS);
        let base = plan.base_to_realize();
        assert!(base >= previous && base <= SEED_BASE && base % LOT_SIZE == 0);
        assert!(base <= state.max_order_base(&plan.realization_position(), false));
        previous = base;
        state.complete_profit_realization(plan, before.into_position_observation(), REFERENCE_AT_MS);
    });
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationNotNeeded, location = blast_boosts_core::state)]
fun profit_realization_rejects_no_shortfall() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long())).into_position_observation(), 0, 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationNotNeeded, location = blast_boosts_core::state)]
fun profit_realization_rejects_no_profit() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long())).into_position_observation(), 100, 0, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationUneconomic, location = blast_boosts_core::state)]
fun profit_realization_rejects_profit_that_cannot_cover_costs() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long())).into_position_observation(), 100, 10_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationUneconomic, location = blast_boosts_core::state)]
fun profit_realization_rejects_a_shortfall_larger_than_all_profit() {
    let state = rebalance_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long())).into_position_observation(), 700_000, 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationUneconomic, location = blast_boosts_core::state)]
fun profit_realization_rejects_shortfall_one_atom_above_cost_headroom() {
    let state = rebalance_state(policy::short());
    // 600,000 profit minus 44,400 full-position cost minus three rounding atoms.
    let plan = state.prepare_profit_realization((standard_observation(policy::short())).into_position_observation(), 555_598, 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationUneconomic, location = blast_boosts_core::state)]
fun profit_realization_rejects_maximum_shortfall_without_overflow() {
    let state = rebalance_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long())).into_position_observation(), std::u64::max_value!(), 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationUneconomic, location = blast_boosts_core::state)]
fun profit_realization_capped_sequence_stops_when_cost_consumes_headroom() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 555_597, 600_000, 10, REFERENCE_AT_MS);
    let realized = 600_000u64.mul_div(plan.base_to_realize(), SEED_BASE);
    assert!(realized < 555_597);
    let after = before.with_venue_equity(SEED_VENUE_EQUITY - 1);
    state.complete_profit_realization(plan, after.into_position_observation(), REFERENCE_AT_MS);
    // The same position costs the same to close and reopen. The first step's
    // one-atom cost consumes the slack even though it converted profit to cash.
    let plan = state.prepare_profit_realization(
        after.into_position_observation(), 555_597 - realized + 1, 600_000 - realized, 10, REFERENCE_AT_MS,
    );
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EVenueFeeUnusable, location = blast_boosts_core::state)]
fun profit_realization_rejects_unusable_live_fee() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long())).into_position_observation(), 100, 600_000, 10_001, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun profit_realization_rejects_emergency_leverage() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long()).with_venue_equity(700_000)).into_position_observation(), 100, 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun profit_realization_rejects_cost_that_crosses_the_hard_cap() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long()).with_venue_equity(766_667);
    let plan = state.prepare_profit_realization(before.into_position_observation(), 100, 600_000, 10, REFERENCE_AT_MS);
    // One atom is within the trade-cost allowance but leaves NAV just below
    // the 666,667 atoms needed to support 2,000,000 notional at the 3x cap.
    state.complete_profit_realization(plan, before.with_venue_equity(766_666).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun profit_realization_rejects_stale_prices() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long()).with_base_price_published_at_ms(1)).into_position_observation(), 100, 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationNotNeeded, location = blast_boosts_core::state)]
fun profit_realization_rejects_flat_position() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_profit_realization((standard_observation(policy::long()).with_position_base(0)).into_position_observation(), 100, 600_000, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun profit_realization_rejects_incomplete_reopening() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 300_000, 600_000, 10, REFERENCE_AT_MS);
    state.complete_profit_realization(plan, before.with_position_base(SEED_BASE - LOT_SIZE).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun profit_realization_rejects_extra_exposure() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 300_000, 600_000, 10, REFERENCE_AT_MS);
    state.complete_profit_realization(plan, before.with_position_base(SEED_BASE + LOT_SIZE).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationUneconomic, location = blast_boosts_core::state)]
fun profit_realization_rejects_cost_above_bound() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 300_000, 600_000, 10, REFERENCE_AT_MS);
    state.complete_profit_realization(plan, before.with_venue_equity(SEED_VENUE_EQUITY - 100).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun profit_realization_rejects_changed_oracle_pair() {
    let state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_profit_realization(before.into_position_observation(), 300_000, 600_000, 10, REFERENCE_AT_MS);
    state.complete_profit_realization(plan, before.with_base_price(1_010_000_000).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}


#[test]
fun terminal_claim_quote_conserves_zero_dust_and_maximum_cash_for_both_sides() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = initialized_state(side);
        state.begin_shutdown(REFERENCE_AT_MS);
        let (eligible, reserve_cash, seed_cash) = state.finalize_shutdown(7, 2, 13);
        assert_eq!(vector[eligible, reserve_cash, seed_cash], vector[5, 0, 0]);
        assert_eq!(state.shutdown_claim_quote(13, 7, 2, 2, 5), 5);
        assert_eq!(state.shutdown_claim_quote(8, 5, 2, 3, 8), 8);
        assert_eq!(state.shutdown_claim_quote(0, 7, 2, 5, 0), 0);
        let maximum = std::u64::max_value!();
        assert_eq!(state.shutdown_claim_quote(maximum, maximum, 0, maximum, maximum), maximum);
        state.destroy_for_testing();
    });
}

#[test]
#[expected_failure(abort_code = errors::EZeroNetPayout, location = blast_boosts_core::state)]
fun terminal_partial_dust_requires_combining_native_shares() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(7, 2, 0);
    state.shutdown_claim_quote(1, 7, 2, 1, 0);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::ERedemptionOutputBelowMinimum, location = blast_boosts_core::state)]
fun terminal_zero_pool_requires_explicit_zero_minimum() {
    let mut state = initialized_state(policy::short());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(7, 2, 0);
    state.shutdown_claim_quote(0, 7, 2, 5, 1);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::state)]
fun terminal_claim_cannot_include_locked_seed() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(7, 2, 0);
    state.shutdown_claim_quote(13, 7, 2, 6, 0);
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareSupply, location = blast_boosts_core::state)]
fun terminal_supply_below_locked_seed_fails_closed() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(1, 2, 0);
    destroy(state);
}

/// Insolvency and the reserve never enter a close-only order; the step prices
/// at fresh oracles and, when shutdown has just begun, at the ordinary bound.
#[test]
fun unwind_prices_both_sides_at_the_ordinary_bound_when_shutdown_has_just_begun() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = initialized_state(side);
        state.begin_shutdown(REFERENCE_AT_MS);
        let (actual_side, max_order_base, base_price, collateral_price, bound) = state.unwind_constraints(
            observation::new_price(1_000_000_000, 0, REFERENCE_AT_MS),
            observation::new_price(1_000_000_000, 0, REFERENCE_AT_MS), LOT_SIZE, REFERENCE_AT_MS,
        );
        assert_eq!(actual_side, side);
        // Prices are 1:1, so base is notional scaled by `10^(9 - 6)`, floored to the lot.
        assert_eq!(max_order_base, 247_000);
        assert_eq!(base_price, 1_000_000_000);
        assert_eq!(collateral_price, 1_000_000_000);
        assert_eq!(bound.slippage_bps(), 100);
        bound.assert_execution(1_000_000_000, 1_010_000_000);
        bound.assert_execution(1_000_000_000, 990_000_000);
        state.destroy_for_testing();
    });
}

/// The close-only bound widens with the time since shutdown began and reaches
/// the emergency bound after a day; a clock behind the shutdown counts as no time.
#[test]
fun unwind_bound_widens_with_the_time_since_shutdown_began() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);

    assert_eq!(state.unwind_bound_bps_at(REFERENCE_AT_MS - 1), 100);
    assert_eq!(state.unwind_bound_bps_at(REFERENCE_AT_MS), 100);
    assert_eq!(state.unwind_bound_bps_at(REFERENCE_AT_MS + 43_200_000), 300);
    assert_eq!(state.unwind_bound_bps_at(REFERENCE_AT_MS + 86_400_000), 500);
    assert_eq!(state.unwind_bound_bps_at(REFERENCE_AT_MS + 86_400_001), 500);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun a_fresh_shutdown_rejects_a_close_at_the_emergency_bound() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    let (_, _, _, _, bound) = state.unwind_constraints(
        observation::new_price(1_000_000_000, 0, REFERENCE_AT_MS),
        observation::new_price(1_000_000_000, 0, REFERENCE_AT_MS), LOT_SIZE, REFERENCE_AT_MS,
    );
    bound.assert_execution(1_000_000_000, 950_000_000);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun ordinary_unwind_never_falls_back_to_a_stale_price() {
    let mut state = initialized_state(policy::short());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.unwind_constraints(
        observation::new_price(1_000_000_000, 0, 0),
        observation::new_price(1_000_000_000, 0, 0), LOT_SIZE, REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun settled_cash_cannot_reopen_a_funding_buffer() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(5, 2, 0);
    state.settle_funding(observation::funding_credit(1));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EVenueFeeUnusable, location = blast_boosts_core::state)]
fun invalid_rebalance_fee_precedes_invalid_observation() {
    let state = initialized_state(policy::long());
    let invalid = standard_observation(policy::long()).with_observed_side(policy::short());
    destroy(state.prepare_rebalance(invalid.into_position_observation(), 10_001, REFERENCE_AT_MS));
    destroy(state);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun mint_outside_band_precedes_deposit_arithmetic() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_mint(standard_observation(policy::long()).with_notional(1_000_000).into_position_observation(), 0, 1_000_000, 1, 10, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun mint_completion_rejects_missing_attributable_fill() {
    let mut state = initialized_state(policy::long());
    let plan = state.prepare_mint(standard_observation(policy::long()).into_position_observation(), 1_000_000, 1_000_000, 1, 10, REFERENCE_AT_MS);
    state.complete_mint(plan, standard_observation(policy::long()).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERedemptionOutputBelowMinimum, location = blast_boosts_core::state)]
fun redemption_rejects_output_one_above_net() {
    let mut state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_redemption(before.into_position_observation(), 500_000, 1_000_000, 499_501, REFERENCE_AT_MS);
    state.complete_redemption(plan, before.with_position_base(1_000_000_000).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ESharesOutBelowMinimum, location = blast_boosts_core::accounting_math)]
fun mint_amount_supply_swap_cannot_satisfy_the_original_minimum() {
    let mut state = initialized_state(policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_mint(before.into_position_observation(), 1_000_000, 500_000, 600_000, 10, REFERENCE_AT_MS);
    state.complete_mint(plan, before.with_venue_equity(2_098_000).with_position_base(3_998_000_000).into_position_observation(), REFERENCE_AT_MS);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::accounting_math)]
fun redemption_shares_supply_swap_is_rejected() {
    let state = initialized_state(policy::long());
    let plan = state.prepare_redemption(standard_observation(policy::long()).into_position_observation(), 1_000_000, 500_000, 1, REFERENCE_AT_MS);
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun issuance_rejects_a_zero_nav_cap() {
    let witness = vault_issuer();
    destroy(state::issue<Product>(&witness, vault_policy(policy::long()), 2_000_000, 0, 9, 6));
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun issuance_rejects_a_nav_cap_whose_max_leverage_notional_overflows() {
    let witness = vault_issuer();
    destroy(state::issue<Product>(&witness, vault_policy(policy::long()), 2_000_000, std::u64::max_value!(), 9, 6));
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAssetDecimals, location = blast_boosts_core::state)]
fun issuance_rejects_asset_decimals_above_the_maximum() {
    let witness = vault_issuer();
    destroy(state::issue<Product>(&witness, vault_policy(policy::long()), 2_000_000, NAV_CAP, 19, 6));
    abort
}

#[test]
fun nav_cap_setter_replaces_the_initial_cap_and_returns_the_previous_one() {
    let mut state = initialized_state(policy::long());
    assert_eq!(state.nav_cap_for_testing(), NAV_CAP);
    assert!(state.is_within_nav_cap_for_testing(NAV_CAP));
    assert!(!state.is_within_nav_cap_for_testing(NAV_CAP + 1));

    assert_eq!(state.set_nav_cap(NAV_CAP / 2), NAV_CAP);

    assert_eq!(state.nav_cap_for_testing(), NAV_CAP / 2);
    assert!(!state.is_within_nav_cap_for_testing(NAV_CAP / 2 + 1));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENavCapUnchanged, location = blast_boosts_core::state)]
fun nav_cap_setter_rejects_an_unchanged_cap() {
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(NAV_CAP);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun nav_cap_setter_rejects_zero() {
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(0);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun nav_cap_setter_rejects_a_cap_whose_max_leverage_notional_overflows() {
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(std::u64::max_value!());
    abort
}

#[test]
fun live_fee_setter_accepts_each_exact_immutable_cap() {
    let witness = vault_issuer();
    let issuance: Issuance<Product> = state::issue(
        &witness, fee_capped_vault_policy(100, 200, 3_000), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6,
    );
    let (mut state, _) = issuance.activate_with(standard_observation(policy::long()), SEED_RESERVE);
    state.set_fees(100, 200, 3_000);
    let (mint, redeem, admin) = state.fee_settings();
    assert_eq!(vector[mint, redeem, admin], vector[100, 200, 3_000]);
    state.destroy_for_testing();
}

#[test]
fun active_mint_and_redemption_are_generic_for_long_and_short_2x_4x_6x() {
    vector[20_000, 40_000, 60_000].do!(|target| {
        vector[policy::long(), policy::short()].do!(|side| {
            let witness = vault_issuer();
            let vault_policy = policy::new_vault_policy(
                side, policy::new_rebalance_policy(target - 2_000, target, target + 2_000, target + 10_000, 100, 500, 10),
                policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 0, 0, 0, 100, MAX_RESERVE_BPS,
            );
            let notional = target * 100;
            let (mut state, _, _) = state::issue<Product>(&witness, vault_policy, 2_000_000, NAV_CAP, 9, 6)
                .activate(rebalance_observation(1_100_000, notional, side), 100_000, REFERENCE_AT_MS);
            let plan = state.prepare_mint(rebalance_observation(1_100_000, notional, side), 1_000_000, 1_000_000, 1_000_000, 10, REFERENCE_AT_MS);
            assert_eq!(plan.base_to_buy(), notional * 1_000);
            let (shares, contribution, _, _, _) = state.complete_mint(plan, rebalance_observation(2_100_000, notional * 2, side), REFERENCE_AT_MS);
            assert_eq!(vector[shares, contribution, state.maintenance_reserve()], vector[1_000_000, 1_000_000, 100_000]);
            let plan = state.prepare_redemption(rebalance_observation(2_100_000, notional * 2, side), 500_000, 2_000_000, 500_000, REFERENCE_AT_MS);
            assert_eq!(plan.base_to_sell(), notional * 500);
            let (net, admin, fee, _) = state.complete_redemption(plan, rebalance_observation(2_100_000, notional * 3 / 2, side), REFERENCE_AT_MS);
            assert_eq!(vector[net, admin, fee], vector[500_000, 0, 0]);
            state.destroy_for_testing();
        });
    });
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun active_redemption_rejects_a_stale_price() {
    let state = initialized_state(policy::short());
    let mut invalid = standard_observation(policy::short());
    invalid.base_publish_time_ms = 0;
    destroy(state.prepare_redemption(invalid.into_position_observation(), 500_000, HEALTH_SHARE_SUPPLY, 1, REFERENCE_AT_MS));
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_update_cannot_raise_the_immutable_cap() {
    let mut state = initialized_state(policy::long());
    state.set_fees(11, 10, 0);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EFeeSettingsUnchanged, location = blast_boosts_core::state)]
fun fee_update_rejects_an_unchanged_tuple() {
    let mut state = initialized_state(policy::long());
    state.set_fees(10, 10, 0);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENonpositiveContribution, location = blast_boosts_core::state)]
fun mint_rejects_input_consumed_by_rounded_fee_before_sizing_exposure() {
    let state = initialized_state(policy::long());
    destroy(state.prepare_mint(standard_observation(policy::long()).into_position_observation(), 1, HEALTH_SHARE_SUPPLY, 0, 10, REFERENCE_AT_MS));
    state.destroy_for_testing();
}

#[test]
fun a_rebalance_plan_reports_whether_it_buys_or_sells() {
    let state = rebalance_state(policy::long());
    let buying = state.prepare_rebalance(rebalance_observation(1_100_000, 1_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let selling = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    assert!(buying.is_increasing() && !selling.is_increasing());
    assert!(!buying.is_emergency_rebalance() && !selling.is_emergency_rebalance());
    destroy(buying);
    destroy(selling);
    state.destroy_for_testing();
}

#[test]
fun rebalance_increase_reserves_cost_and_keeps_buffer_unchanged() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 1_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 978_452_000);
    assert!(order.is_increase() && !order.is_emergency());
    let filled = order.order_base();
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_089_226, 1_978_452, policy::long()), filled, REFERENCE_AT_MS);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
    let (before_equity, after_equity, before_base, after_base, increased) = state.complete_rebalance(plan);
    assert_eq!(before_equity, 1_100_000);
    assert_eq!(after_equity, 1_089_226);
    assert_eq!(before_base, 1_000_000_000);
    assert_eq!(after_base, 1_978_452_000);
    assert!(increased);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
}

/// An emergency reduction sells only what brings leverage back to the hard cap,
/// under the wide bound, and ends the moment leverage is no longer above it:
/// the wider bound never covers more than restoring the cap needs, never an
/// order below the cap, and a wide market cannot revert the orders placed above it.
#[test]
fun rebalance_short_emergency_reduction_sells_to_the_cap_and_stops_below_it() {
    let state = rebalance_state(policy::short());
    // 3.2x on a 1_000_000 NAV: the 3x cap is 3_000_000 of notional, 200_000_000 of base above it.
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_200_000, policy::short()), 10, REFERENCE_AT_MS);
    assert!(plan.is_emergency_rebalance());
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 200_000_000);
    assert!(!order.is_increase() && order.is_emergency());
    assert_eq!(order.bound().slippage_bps(), 500);
    order.bound().assert_execution(100, 104);
    // The fill's cost leaves the position a hair above the cap, so a small emergency order follows.
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_099_500, 3_000_000, policy::short()), 200_000_000, REFERENCE_AT_MS);
    let residual = state.next_rebalance_order(&plan);
    assert_eq!(residual.order_base(), 1_500_000);
    assert!(residual.is_emergency());
    state.accept_rebalance_fill(&mut plan, residual, rebalance_observation(1_099_500, 2_998_500, policy::short()), 1_500_000, REFERENCE_AT_MS);
    let next = state.next_rebalance_order(&plan);
    assert_eq!(next.order_base(), 0);
    assert!(!next.is_emergency());
    assert!(plan.is_emergency_rebalance());
    assert_eq!(next.bound().slippage_bps(), 100);
    state.complete_rebalance(plan);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
}

/// A position one lot's notional above the cap sells one lot under the emergency
/// bound, and the plan completes on the restored cap although leverage moved far
/// less than the ordinary minimum improvement.
#[test]
fun an_emergency_plan_barely_above_the_cap_sells_one_lot_and_completes_on_the_restored_cap() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_001, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), LOT_SIZE);
    assert!(order.is_emergency());
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_100_000, 3_000_000, policy::long()), LOT_SIZE, REFERENCE_AT_MS);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);

    let (_, _, before_base, after_base, increased) = state.complete_rebalance(plan);

    assert_eq!(vector[before_base, after_base], vector[3_000_001_000, 3_000_000_000]);
    assert!(!increased);
    state.destroy_for_testing();
}

/// Genuine emergency exposure reduction may commit before restoring the cap,
/// including one partial fill smaller than the ordinary improvement minimum.
#[test]
fun an_emergency_plan_still_above_the_cap_can_keep_a_real_reduction() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_200_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    // One lot of the cap-sized order fills and leaves leverage essentially where it was.
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_100_000, 3_199_999, policy::long()), LOT_SIZE, REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

/// The per-order cap still paces an emergency sale that restoring the cap needs more than one order for.
#[test]
fun an_emergency_order_never_exceeds_the_per_order_cap() {
    let state = rebalance_state(policy::long());
    // 6x on a 1_000_000 NAV: 3_000_000 of notional above the cap against a 2_000_000 order cap.
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 6_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 1_904_761_000);
    assert!(order.is_emergency());
    destroy(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun rebalance_exact_lower_endpoint_rejects() { rebalance_endpoint(1_600_000); }

#[test]
#[expected_failure(abort_code = errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun rebalance_exact_upper_endpoint_rejects() { rebalance_endpoint(2_600_000); }

#[test]
fun rebalance_one_rational_atom_below_lower_is_not_hidden_by_report_rounding() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_001, 1_600_001, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert!(order.order_base() > 0 && order.is_increase() && !order.is_emergency());
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_100_001, 1_600_002, policy::long()), 1_000, REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun rebalance_reduction_without_leverage_improvement_rejects() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_000_000, 2_700_000, policy::long()), 300_000_000, REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun rebalance_increase_rejects_post_cost_target_overshoot() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 1_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_089_225, 1_978_452, policy::long()), 978_452_000, REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun rebalance_hard_threshold_equality_does_not_enable_wide_tolerance() {
    let state = rebalance_state(policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    state.next_rebalance_order(&plan).bound().assert_execution(100, 102);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

#[test]
fun a_flat_short_product_redeems_without_inventing_a_long_position() {
    let mut state = initialized_state(policy::short());
    let flat = standard_observation(policy::long())
        .with_position_base(0);
    let plan = state.prepare_redemption(flat.into_position_observation(), 500_000, 1_000_000, 499_500, REFERENCE_AT_MS);
    assert_eq!(plan.base_to_sell(), 0);
    let (net, admin, fee, _) = state.complete_redemption(plan, flat.into_position_observation(), REFERENCE_AT_MS);
    assert_eq!(vector[net, admin], vector[499_500, 0]);
    assert_eq!(fee, 500);
    state.destroy_for_testing();
}

#[test]
fun redemption_keeps_remaining_nav_and_allocates_its_own_fee() {
    let mut state = initialized_state(policy::short());
    let plan = state.prepare_redemption(
        standard_observation(policy::short()).into_position_observation(),
        500_000, 1_000_000, 497_502, REFERENCE_AT_MS,
    );
    assert_eq!(plan.base_to_sell(), 1_000_000_000);
    let (net, admin, fee, _) = state.complete_redemption(
        plan,
        standard_observation(policy::short())
            .with_venue_equity(1_098_000)
            .with_position_base(1_000_000_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );
    let final_equity = 1_098_000 - net - admin;
    assert_eq!(vector[net, admin, final_equity], vector[497_502, 0, 600_498]);
    assert_eq!(fee, 498);
    assert_eq!(state.maintenance_reserve(), 100_498);
    assert_eq!(final_equity - state.maintenance_reserve(), 500_000);
    state.destroy_for_testing();
}

/// A fill that raises NAV by more than the deposit net of the fee credits exactly
/// `deposit - protocol_fee`; the 2,000-unit excess stays with existing holders.
#[test]
fun mint_credits_at_most_the_deposit_net_of_fee_when_the_fill_is_favorable() {
    let mut state = initialized_state(policy::long());
    let plan = state.prepare_mint(
        standard_observation(policy::long()).into_position_observation(),
        1_000_000,
        1_000_000,
        999_000, 10,
        REFERENCE_AT_MS,
    );
    assert_eq!(plan.base_to_buy(), 1_998_000_000);
    let (shares, contribution, fee, admin, buffer) = state.complete_mint(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(2_102_000)
            .with_position_base(3_998_000_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );
    assert_eq!(vector[shares, contribution, fee, admin, buffer], vector[999_000, 999_000, 1_000, 0, 1_000]);
    assert_eq!(state.maintenance_reserve(), 101_000);
    // Remaining NAV per share rose: 2_001_000 / 1_999_000 > 1_000_000 / 1_000_000.
    let nav_after = 2_102_000 - state.maintenance_reserve();
    assert!((nav_after as u128) * (HEALTH_SHARE_SUPPLY as u128) > (SEED_NAV as u128) * ((HEALTH_SHARE_SUPPLY + shares) as u128));
    state.destroy_for_testing();
}

/// A sell that leaves more NAV than the pre-sell reading pays exactly the
/// proportional claim; the 2,000-unit gain stays with the remaining holders.
#[test]
fun redemption_pays_at_most_the_proportional_claim_when_the_sell_is_favorable() {
    let mut state = initialized_state(policy::long());
    let plan = state.prepare_redemption(
        standard_observation(policy::long()).into_position_observation(),
        500_000, 1_000_000, 499_500, REFERENCE_AT_MS,
    );
    assert_eq!(plan.base_to_sell(), 1_000_000_000);
    let (net, admin, fee, buffer) = state.complete_redemption(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(1_102_000)
            .with_position_base(1_000_000_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );
    let final_equity = 1_102_000 - net - admin;
    assert_eq!(vector[net, admin, fee, buffer], vector[499_500, 0, 500, 500]);
    assert_eq!(state.maintenance_reserve(), 100_500);
    assert_eq!(final_equity, 602_500);
    // Remaining holders keep 502_000 over 500_000 shares, above the 500_000 proportional keep.
    assert_eq!(final_equity - state.maintenance_reserve(), 502_000);
    state.destroy_for_testing();
}

#[test]
fun mint_prices_actual_contribution_after_the_attributable_cost() {
    let mut state = initialized_state(policy::long());
    let plan = state.prepare_mint(
        standard_observation(policy::long()).into_position_observation(),
        1_000_000,
        1_000_000,
        997_000, 10,
        REFERENCE_AT_MS,
    );
    assert_eq!(plan.base_to_buy(), 1_998_000_000);
    let (shares, contribution, _, _, _) = state.complete_mint(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(2_098_000)
            .with_position_base(3_998_000_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );
    assert_eq!(shares, 997_000);
    assert_eq!(contribution, 997_000);
    assert_eq!(state.maintenance_reserve(), 101_000);
    assert!((1_997_000u128) * 1_000_000 >= 1_000_000u128 * (1_000_000 + shares as u128));
    state.destroy_for_testing();
}

#[test]
fun fee_updates_change_future_allocations_without_relabeling_the_buffer() {
    let witness = vault_issuer();
    let issuance: Issuance<Product> = state::issue(
        &witness, fee_capped_vault_policy(100, 100, 3_000), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6,
    );
    let (mut state, _) = issuance.activate_with(standard_observation(policy::long()), SEED_RESERVE);
    let (fee, admin, buffer) = state.fee_allocation_for_testing(1_000_000, true);
    assert_eq!(vector[fee, admin, buffer], vector[1_000, 0, 1_000]);
    let (mint, redeem, allocation) = state.set_fees(30, 40, 3_000);
    assert_eq!(vector[mint, redeem, allocation], vector[10, 10, 0]);
    let (fee, admin, buffer) = state.fee_allocation_for_testing(1_000_000, true);
    assert_eq!(vector[fee, admin, buffer], vector[3_000, 900, 2_100]);
    let (fee, admin, buffer) = state.fee_allocation_for_testing(1_000_000, false);
    assert_eq!(vector[fee, admin, buffer], vector[4_000, 1_200, 2_800]);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
}

#[test]
fun an_issuance_reads_the_frozen_side() {
    let issuance = issued(policy::short());

    assert_eq!(issuance.seed_side(), policy::short());
    destroy(issuance);
}

#[test]
fun flat_seed_preflight_returns_authenticated_order_inputs() {
    let issuance = issued(policy::short());
    let observation = standard_observation(policy::long()).with_position_base(0).into_position_observation();

    let (target_base, max_order_base, seed_position) = issuance.seed_terms(observation, SEED_RESERVE);

    // Prices are 1:1, so base is notional scaled by `10^(9 - 6)`, floored to the lot.
    assert_eq!(target_base, SEED_NOTIONAL * 1_000);
    assert_eq!(max_order_base, 247_000);
    assert_eq!(seed_position.base_price(), 1_000_000_000);
    assert_eq!(seed_position.collateral_price(), 1_000_000_000);
    assert_eq!(seed_position.lot_size(), LOT_SIZE);
    assert_eq!(seed_position.equity(), SEED_VENUE_EQUITY);
    assert_eq!(seed_position.base(), 0);
    assert_eq!(seed_position.notional(), 0);
    destroy(issuance);
}

#[test]
fun initialization_strict_execution_uses_the_frozen_tolerance() {
    let issuance = issued(policy::long());

    issuance.seed_execution_bound().assert_execution(1_000_000, 1_010_000);

    destroy(issuance);
}

#[test]
#[expected_failure(
    abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy,
)]
fun initialization_strict_execution_rejects_one_unit_past_tolerance() {
    let issuance = issued(policy::long());

    issuance.seed_execution_bound().assert_execution(1_000_000, 1_010_001);

    destroy(issuance);
}

#[test]
fun an_authorized_issuance_activates_into_the_issued_terms() {
    let witness = vault_issuer();
    let expected_policy = standard_vault_policy();
    let (state, _) = state::issue<Product>(&witness, expected_policy, MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6).activate_with(standard_observation(policy::long()), SEED_RESERVE);

    assert!(state.is_active_for_testing());
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    assert_eq!(state.vault_policy_for_testing(), expected_policy);
    assert_eq!(state.max_order_notional_for_testing(), MAX_ORDER_NOTIONAL);

    state.destroy_for_testing();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMaxOrderNotional, location = blast_boosts_core::state,
)]
fun max_order_notional_must_be_positive() {
    let witness = vault_issuer();

    destroy(state::issue<Product>(&witness, standard_vault_policy(), 0, NAV_CAP, 9, 6));
}

#[test]
fun max_order_notional_moves_both_directions_and_returns_the_previous_value() {
    let witness = vault_issuer();
    let (mut state, _) = state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6).activate_with(standard_observation(policy::long()), SEED_RESERVE);

    state.set_nav_cap(2_000_000);
    assert_eq!(state.set_test_order_cap(150), MAX_ORDER_NOTIONAL);
    assert_eq!(state.set_test_order_cap(std::u64::max_value!()), 150);
    assert_eq!(state.max_order_notional_for_testing(), std::u64::max_value!());

    state.destroy_for_testing();
}

#[test]
#[expected_failure(
    abort_code = errors::EMaxOrderNotionalUnchanged,
    location = blast_boosts_core::state,
)]
fun max_order_notional_rejects_the_current_value() {
    let witness = vault_issuer();
    let (mut state, _) = state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6).activate_with(standard_observation(policy::long()), SEED_RESERVE);

    state.set_test_order_cap(MAX_ORDER_NOTIONAL);

    state.destroy_for_testing();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMaxOrderNotional, location = blast_boosts_core::state,
)]
fun max_order_notional_rejects_zero() {
    let witness = vault_issuer();
    let (mut state, _) = state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6).activate_with(standard_observation(policy::long()), SEED_RESERVE);

    state.set_test_order_cap(0);

    state.destroy_for_testing();
}

#[test]
fun active_state_begins_shutdown() {
    let witness = vault_issuer();
    let (mut state, _) = state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6).activate_with(standard_observation(policy::long()), SEED_RESERVE);

    state.begin_shutdown(REFERENCE_AT_MS);

    assert!(state.is_unwinding_for_testing());
    state.destroy_for_testing();
}

// --- Initialization ---

#[test]
fun valid_long_seed_activates_and_records_only_the_reserve() {
    let (state, seed_nav) = issued(policy::long()).activate_with(standard_observation(policy::long()), SEED_RESERVE);

    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
}

#[test]
fun valid_short_seed_activates() {
    let (state, seed_nav) = issued(policy::short()).activate_with(standard_observation(policy::short()), SEED_RESERVE);

    assert_eq!(seed_nav, SEED_NAV);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPositionObservation, location = blast_boosts_core::observation,
)]
fun an_observation_with_a_partial_lot_cannot_be_built() {
    destroy(standard_observation(policy::long()).with_position_base(SEED_BASE + 1).into_position_observation());
}

#[test]
fun initialization_admits_nav_cap_equality() {
    let spec = standard_observation(policy::long())
        .with_venue_equity(NAV_CAP + SEED_RESERVE)
        .with_notional(2 * NAV_CAP);

    let (state, seed_nav) = issued(policy::long()).activate_with(spec, SEED_RESERVE);
    assert_eq!(seed_nav, NAV_CAP);

    state.destroy_for_testing();
}

#[test]
fun initialization_admits_both_healthy_leverage_boundaries() {
    let (lower, _) = issued(policy::long()).activate_with(
        standard_observation(policy::long()).with_notional(1_600_000), SEED_RESERVE,
    );
    let (upper, _) = issued(policy::long()).activate_with(
        standard_observation(policy::long()).with_notional(2_600_000), SEED_RESERVE,
    );

    assert!(lower.is_active_for_testing());
    assert!(upper.is_active_for_testing());
    lower.destroy_for_testing();
    upper.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun initialization_rejects_a_reserve_above_equity() {
    standard_observation(policy::long()).with_venue_equity(SEED_RESERVE - 1).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNav, location = blast_boosts_core::state,
)]
fun initialization_rejects_zero_shareholder_nav() {
    standard_observation(policy::long()).with_venue_equity(SEED_RESERVE).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state,
)]
fun initialization_rejects_one_unit_above_the_nav_cap() {
    standard_observation(policy::long())
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1)
            .with_position_base((2 * NAV_CAP + 2) * 1_000).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidInitializationObservation, location = blast_boosts_core::state,
)]
fun initialization_rejects_the_wrong_side() {
    standard_observation(policy::long()).with_observed_side(policy::short()).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_stale_base_price() {
    standard_observation(policy::long()).with_base_price_published_at_ms(69_999).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EFuturePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_future_base_price() {
    standard_observation(policy::long()).with_base_price_published_at_ms(102_001).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_low_confidence_base_price() {
    standard_observation(policy::long()).with_base_confidence(10_000_001).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_stale_collateral_price() {
    standard_observation(policy::long()).with_collateral_price_published_at_ms(69_999).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EFuturePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_future_collateral_price() {
    standard_observation(policy::long()).with_collateral_price_published_at_ms(102_001).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_low_confidence_collateral_price() {
    standard_observation(policy::long()).with_collateral_confidence(10_000_001).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_rejects_mark_divergence() {
    standard_observation(policy::long()).with_mark_price(1_050_000_001).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy, location = blast_boosts_core::state,
)]
fun initialization_rejects_leverage_one_unit_below_healthy() {
    standard_observation(policy::long()).with_position_base(1_599_999_000).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy, location = blast_boosts_core::state,
)]
fun initialization_rejects_leverage_one_unit_above_healthy() {
    standard_observation(policy::long()).with_position_base(2_600_001_000).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationBaseBelowMinOrder, location = blast_boosts_core::state,
)]
fun initialization_rejects_base_below_the_immutable_lot_minimum() {
    // A lot of 0.1 base makes the 100-lot minimum 1e10, above the 2e9 seed position.
    standard_observation(policy::long()).with_lot_size(100_000_000).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNav, location = blast_boosts_core::state,
)]
fun initialization_guard_order_checks_nav_before_base_freshness() {
    standard_observation(policy::long())
            .with_venue_equity(SEED_RESERVE)
            .with_base_price_published_at_ms(69_999).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_base_freshness_before_base_confidence() {
    standard_observation(policy::long())
            .with_base_price_published_at_ms(69_999)
            .with_base_confidence(10_000_001).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_base_before_collateral_valuation() {
    standard_observation(policy::long())
            .with_base_confidence(10_000_001)
            .with_collateral_price_published_at_ms(69_999).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_collateral_freshness_before_confidence() {
    standard_observation(policy::long())
            .with_collateral_price_published_at_ms(69_999)
            .with_collateral_confidence(10_000_001).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_collateral_confidence_before_mark() {
    standard_observation(policy::long())
            .with_collateral_confidence(10_000_001)
            .with_mark_price(1_050_000_001).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_mark_before_side() {
    standard_observation(policy::long())
            .with_mark_price(1_050_000_001)
            .with_observed_side(policy::short()).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state,
)]
fun initialization_guard_order_checks_nav_cap_before_leverage() {
    standard_observation(policy::long())
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1)
            .with_position_base(SEED_BASE * 100).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy, location = blast_boosts_core::state,
)]
fun initialization_guard_order_checks_leverage_before_minimum_exposure() {
    // Equity 700_000 leaves NAV 600_000 against 2_000_000 of notional: 3.33x, outside the band.
    standard_observation(policy::long())
            .with_venue_equity(700_000)
            .with_lot_size(100_000_000).initialize_once(
                policy::long(),
        SEED_RESERVE,
    );
}

// --- Per-Order Notional ---

#[test]
fun an_order_at_the_live_maximum_is_allowed() {
    let state = initialized_state(policy::long());

    state.assert_order_notional_allowed(MAX_ORDER_NOTIONAL, LOT_SIZE, LOT_SIZE, false);

    state.destroy_for_testing();
}

#[test]
#[expected_failure(
    abort_code = errors::EOrderNotionalExceedsMaximum, location = blast_boosts_core::state,
)]
fun an_order_one_unit_above_the_live_maximum_is_rejected() {
    let state = initialized_state(policy::long());

    state.assert_order_notional_allowed(MAX_ORDER_NOTIONAL + 1, LOT_SIZE, LOT_SIZE, false);

    state.destroy_for_testing();
}

// --- Funding Settlement ---

#[test]
fun positive_funding_credits_only_the_buffer() {
    assert_funding_settlement(observation::funding_credit(1), 0, 0, SEED_RESERVE + 1);
}

#[test]
fun a_zero_funding_cost_is_an_exact_no_op() {
    assert_funding_settlement(observation::funding_cost(0), 0, 0, SEED_RESERVE);
}

#[test]
fun a_funding_cost_below_the_reserve_is_fully_absorbed() {
    assert_funding_settlement(observation::funding_cost(40_000), 40_000, 0, 60_000);
}

#[test]
fun a_funding_cost_equal_to_the_reserve_exhausts_it_exactly() {
    assert_funding_settlement(
        observation::funding_cost(SEED_RESERVE),
        SEED_RESERVE,
        0,
        0,
    );
}

#[test]
fun a_funding_cost_above_the_reserve_reports_the_uncovered_remainder() {
    assert_funding_settlement(
        observation::funding_cost(150_000),
        SEED_RESERVE,
        50_000,
        0,
    );
}

#[test]
fun the_maximum_funding_cost_cannot_wrap() {
    assert_funding_settlement(
        observation::funding_cost(std::u64::max_value!()),
        SEED_RESERVE,
        std::u64::max_value!() - SEED_RESERVE,
        0,
    );
}

/// A credit repays the deficit holders carried before it rebuilds the reserve:
/// -150_000 then +300_000 leaves NAV whole and the reserve at 250_000, not
/// 300_000.
#[test]
fun a_credit_repays_the_uncovered_deficit_before_rebuilding_the_reserve() {
    let mut state = initialized_state(policy::long());

    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_cost(150_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[SEED_RESERVE, 50_000, 0]);
    assert_eq!(state.uncovered_deficit(), 50_000);

    // Partial repayment: the whole credit stays in NAV.
    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_credit(20_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 0, 20_000]);
    assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[0, 30_000]);

    // Exact repayment clears the deficit and still adds nothing to the reserve.
    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_credit(30_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 0, 30_000]);
    assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[0, 0]);

    // With no deficit the next credit rebuilds the reserve in full.
    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_credit(250_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 0, 0]);
    assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[250_000, 0]);

    state.destroy_for_testing();
}

/// Two exhausting costs accumulate one deficit, and an over-repaying credit
/// splits between NAV and the reserve.
#[test]
fun deficits_accumulate_and_an_over_repaying_credit_splits() {
    let mut state = initialized_state(policy::long());

    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_cost(120_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[SEED_RESERVE, 20_000, 0]);
    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_cost(5_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 5_000, 0]);
    assert_eq!(state.uncovered_deficit(), 25_000);

    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_credit(40_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 0, 25_000]);
    assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[15_000, 0]);

    state.destroy_for_testing();
}

// --- Reserve Ceiling ---

/// The seed reserve may not exceed the ceiling for the opening notional.
#[test]
#[expected_failure(abort_code = errors::ESeedReserveAboveCap, location = blast_boosts_core::state)]
fun a_seed_reserve_above_the_ceiling_cannot_activate() {
    let (state, _) = capped_issuance(400).activate_with(standard_observation(policy::long()), SEED_RESERVE);
    state.destroy_for_testing();
}

/// A seed reserve exactly at the ceiling activates; the ceiling is inclusive.
#[test]
fun a_seed_reserve_at_the_ceiling_activates() {
    let (state, seed_nav) = capped_issuance(500).activate_with(standard_observation(policy::long()), SEED_RESERVE);
    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
}

/// A redemption that shrinks notional below what the reserve needs releases the
/// excess to holders: the stored reserve drops to the ceiling, the required venue
/// equity is unchanged because nothing moved, and NAV per share rises.
#[test]
fun redemption_releases_reserve_above_the_ceiling_for_the_smaller_position() {
    let mut state = capped_initialized_state(500);
    let plan = state.prepare_redemption(
        standard_observation(policy::long()).into_position_observation(),
        500_000, 1_000_000, 499_500, REFERENCE_AT_MS,
    );
    let (net, admin, fee, buffer) = state.complete_redemption(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(1_102_000)
            .with_position_base(1_000_000_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );
    let final_equity = 1_102_000 - net - admin;
    // Same payout and physical equity as with a wide ceiling.
    assert_eq!(vector[net, admin, fee, buffer, final_equity], vector[499_500, 0, 500, 500, 602_500]);
    // The ceiling for 1_000_000 of notional at 5% is 50_000; the other 50_500 is NAV now.
    assert_eq!(state.maintenance_reserve(), 50_000);
    assert_eq!(final_equity - state.maintenance_reserve(), 552_500);
    state.destroy_for_testing();
}

/// A reserve left above the ceiling by a funding credit is priced as released
/// before a mint, so the newcomer pays the higher NAV per share and the release
/// stays with the holders at the checkpoint.
#[test]
fun a_mint_prices_shares_after_releasing_reserve_above_the_ceiling() {
    let mut state = capped_initialized_state(500);
    // Funding credits carry no observation, so the reserve grows past the 100_000 ceiling.
    state.settle_funding(observation::funding_credit(50_000));
    assert_eq!(state.maintenance_reserve(), 150_000);

    let before = standard_observation(policy::long()).with_venue_equity(1_150_000);
    let plan = state.prepare_mint(before.into_position_observation(), 1_000_000, 1_000_000, 1, 10, REFERENCE_AT_MS);
    // Sized against NAV 1_050_000, not 1_000_000: 200_000 * 999_000 / 1_050_000 floored to the lot.
    // 2e9 * 999_000 / 1_050_000 floored to the lot.
    assert_eq!(plan.base_to_buy(), 1_902_857_000);
    let (shares, contribution, _, _, _) = state.complete_mint(
        plan,
        before
            .with_venue_equity(2_150_000)
            .with_position_base(SEED_BASE + 1_902_857_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );
    // 1_000_000 * 999_000 / 1_050_000, not the 999_000 a pre-release price would mint.
    assert_eq!(vector[shares, contribution], vector[951_428, 999_000]);
    // The fee rebuilds the reserve from the ceiling, not from the stale 150_000.
    assert_eq!(state.maintenance_reserve(), 101_000);
    state.destroy_for_testing();
}

/// A donation is never rejected: the part above the ceiling counts as NAV.
#[test]
fun a_donation_above_the_ceiling_is_accepted_and_the_excess_is_nav() {
    let mut state = capped_initialized_state(500);
    state.donate(
        standard_observation(policy::long()).with_venue_equity(SEED_VENUE_EQUITY + 70_000).into_position_observation(),
        70_000, REFERENCE_AT_MS,
    );
    assert_eq!(state.maintenance_reserve(), 100_000);
    state.destroy_for_testing();
}

/// A flat position has nothing to size the ceiling against and keeps its reserve.
#[test]
fun a_flat_position_keeps_the_reserve_for_the_position_that_reopens() {
    let mut state = capped_initialized_state(500);
    let flat = standard_observation(policy::long()).with_position_base(0);
    state.donate(flat.with_venue_equity(SEED_VENUE_EQUITY + 70_000).into_position_observation(), 70_000, REFERENCE_AT_MS);
    assert_eq!(state.maintenance_reserve(), 170_000);
    state.destroy_for_testing();
}

// --- Invariant ---

/// The one guard no production path can trip by construction still refuses a
/// transition that lowers NAV per share for the holders who stay.
#[test]
#[expected_failure(abort_code = errors::EInvariantViolated, location = blast_boosts_core::state)]
fun a_diluting_transition_trips_the_invariant() {
    state::assert_holders_not_diluted_for_testing(1_000, 100, 999, 100);
}

// --- Issuance ---

#[test]
#[expected_failure(abort_code = errors::EInvalidAssetDecimals, location = blast_boosts_core::state)]
fun issuance_rejects_collateral_decimals_above_the_maximum() {
    let witness = vault_issuer();
    destroy(state::issue<Product>(&witness, vault_policy(policy::long()), 2_000_000, NAV_CAP, 9, 19));
    abort
}

/// At 18 decimals on both sides the unit ratio is one, so a 1:1 pair sizes base
/// atom for atom with notional and the 250-atom order cap rounds below one lot.
#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun seed_rejects_a_cap_below_one_lot_at_maximum_decimals() {
    let witness = vault_issuer();
    let issuance = state::issue<Product>(&witness, vault_policy(policy::long()), MAX_ORDER_NOTIONAL, NAV_CAP, 18, 18);
    let flat = standard_observation(policy::long()).with_position_base(0).into_position_observation();

    let (target_base, max_order_base, _) = issuance.seed_terms(flat, SEED_RESERVE);

    assert_eq!(target_base, SEED_NOTIONAL);
    assert_eq!(max_order_base, 0);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::accounting_math)]
fun seed_terms_reject_a_reserve_that_consumes_the_seed() {
    let issuance = issued(policy::long());
    let flat = standard_observation(policy::long()).with_position_base(0).with_venue_equity(SEED_RESERVE);
    issuance.seed_terms(flat.into_position_observation(), SEED_RESERVE);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EMaintenanceReserveExceedsEquity, location = blast_boosts_core::accounting_math)]
fun seed_terms_reject_a_reserve_above_the_seed() {
    let issuance = issued(policy::long());
    let flat = standard_observation(policy::long()).with_position_base(0).with_venue_equity(SEED_RESERVE - 1);
    issuance.seed_terms(flat.into_position_observation(), SEED_RESERVE);
    abort
}

/// At a base price of 3 the target and the cap both leave a sub-lot remainder unopened.
#[test]
fun flat_seed_preflight_floors_the_order_cap_to_whole_lots() {
    let issuance = state::issue<Product>(&vault_issuer(), standard_vault_policy(), 500, NAV_CAP, 9, 6);
    let flat = standard_observation(policy::long())
        .with_position_base(0)
        .with_base_price(3_000_000_000)
        .with_mark_price(3_000_000_000);

    let (target_base, max_order_base, seed_position) = issuance.seed_terms(flat.into_position_observation(), SEED_RESERVE);

    // 2_000_000 of notional buys 666_666_666 base at 3; 250 buys 83_333. Both floor to the lot.
    assert_eq!(target_base, 666_666_000);
    assert_eq!(max_order_base, 165_000);
    assert_eq!(seed_position.equity(), SEED_VENUE_EQUITY);
    assert_eq!(seed_position.base_price(), 3_000_000_000);
    destroy(issuance);
}

#[test]
fun a_seed_order_at_the_maximum_is_allowed() {
    let issuance = issued(policy::long());

    issuance.assert_seed_order_notional_allowed(MAX_ORDER_NOTIONAL);

    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EOrderNotionalExceedsMaximum, location = blast_boosts_core::state)]
fun a_seed_order_one_unit_above_the_maximum_is_rejected() {
    let issuance = issued(policy::long());
    issuance.assert_seed_order_notional_allowed(MAX_ORDER_NOTIONAL + 1);
    abort
}

// --- Activation ---

/// The minimum is strict: a position of exactly `min_order_lots` lots cannot open.
#[test]
#[expected_failure(abort_code = errors::EInitializationBaseBelowMinOrder, location = blast_boosts_core::state)]
fun initialization_rejects_base_equal_to_the_lot_minimum() {
    standard_observation(policy::long()).with_lot_size(SEED_BASE / MIN_EXPOSURE_LOTS).initialize_once(
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(abort_code = errors::EInitializationLeverageUnhealthy, location = blast_boosts_core::state)]
fun a_flat_seed_cannot_activate() {
    standard_observation(policy::long()).with_position_base(0).initialize_once(policy::long(), SEED_RESERVE);
}

#[test]
fun activation_returns_the_priced_seed_position() {
    let (state, seed_nav, seeded) = issued(policy::long())
        .activate(standard_observation(policy::long()).into_position_observation(), SEED_RESERVE, REFERENCE_AT_MS);

    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(seeded.equity(), SEED_VENUE_EQUITY);
    assert_eq!(seeded.base(), SEED_BASE);
    assert_eq!(seeded.notional(), SEED_NOTIONAL);
    assert_eq!(seeded.lot_size(), LOT_SIZE);
    assert_eq!(seeded.base_price(), 1_000_000_000);
    assert_eq!(seeded.collateral_price(), 1_000_000_000);
    state.destroy_for_testing();
}

#[test]
fun an_active_state_reads_the_frozen_side() {
    let state = initialized_state(policy::short());

    assert_eq!(state.side(), policy::short());
    state.destroy_for_testing();
}

// --- Live Order Cap ---

#[test]
fun max_order_base_floors_the_live_cap_to_whole_lots() {
    let (state, _, seeded) = issued(policy::long()).activate(
        standard_observation(policy::long()).with_lot_size(4_000).into_position_observation(), SEED_RESERVE, REFERENCE_AT_MS,
    );

    // 250 of notional is 250_000 base at 1:1, floored to the 4_000 lot.
    assert_eq!(state.max_order_base(&seeded, false), 244_000);
    state.destroy_for_testing();
}

// --- Execution Bounds ---

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun emergency_execution_rejects_one_unit_past_the_wide_bound() {
    let state = rebalance_state(policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_200_000, policy::long()), 10, REFERENCE_AT_MS);
    state.next_rebalance_order(&plan).bound().assert_execution(1_000_000_000, 1_050_000_001);
    abort
}

#[test]
fun ordinary_execution_admits_the_exact_bound() {
    let state = initialized_state(policy::long());

    assert_eq!(state.execution_bound().slippage_bps(), 100);
    state.execution_bound().assert_execution(1_000_000_000, 1_010_000_000);

    state.destroy_for_testing();
}

/// The seed opens a position, so its orders run under the ordinary bound.
#[test]
fun seed_orders_run_under_the_ordinary_bound() {
    let issuance = issued(policy::long());

    assert_eq!(issuance.seed_execution_bound().slippage_bps(), 100);

    let (state, _) = issuance.activate_with(standard_observation(policy::long()), SEED_RESERVE);
    state.destroy_for_testing();
}

// --- Mint Preparation ---

#[test]
#[expected_failure(abort_code = errors::EInvalidShareSupply, location = blast_boosts_core::state)]
fun mint_rejects_a_zero_share_supply() {
    let state = initialized_state(policy::long());
    destroy(state.prepare_mint(standard_observation(policy::long()).into_position_observation(), 1_000_000, 0, 1, 10, REFERENCE_AT_MS));
    abort
}

/// Both band edges admit a mint, and the order scales with the position at each.
#[test]
fun mint_admits_both_band_endpoints() {
    let state = initialized_state(policy::long());

    let lower = state.prepare_mint(
        standard_observation(policy::long()).with_notional(1_600_000).into_position_observation(),
        1_000_000, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS,
    );
    let upper = state.prepare_mint(
        standard_observation(policy::long()).with_notional(2_600_000).into_position_observation(),
        1_000_000, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS,
    );

    // 999_000 of contribution against 1_000_000 of NAV buys 99.9% of the position.
    assert_eq!(lower.base_to_buy(), 1_598_400_000);
    assert_eq!(upper.base_to_buy(), 2_597_400_000);
    destroy(lower);
    destroy(upper);
    state.destroy_for_testing();
}

/// A zero deposit dies in the fee allocation, before the contribution is sized.
#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_boosts_core::accounting_math)]
fun a_zero_deposit_mint_is_refused() {
    let state = initialized_state(policy::long());
    destroy(state.prepare_mint(standard_observation(policy::long()).into_position_observation(), 0, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS));
    abort
}

// --- Mint Completion ---

#[test]
fun completed_mints_preserve_both_exact_band_edges_for_both_sides() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[1_600_000, 2_600_000].do!(|notional| {
            let mut state = initialized_state(side);
            let before = standard_observation(side).with_notional(notional);
            let plan = state.prepare_mint(before.into_position_observation(), 101, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS);
            let base_after = before.position_base + plan.base_to_buy();
            let (shares, contribution, fee, _, _) = state.complete_mint(
                plan, before.with_venue_equity(SEED_VENUE_EQUITY + 101).with_position_base(base_after).into_position_observation(),
                REFERENCE_AT_MS,
            );
            assert_eq!(vector[shares, contribution, fee], vector[100, 100, 1]);
            // Using the old reserve instead would wrongly refuse the lower edge.
            assert_eq!(state.maintenance_reserve(), SEED_RESERVE + 1);
            state.destroy_for_testing();
        });
    });
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_rounded_long_mint_cannot_cross_the_lower_band_edge() {
    mint_at_band_edge(policy::long(), 1_600_000, 102, 102);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_rounded_short_mint_cannot_cross_the_lower_band_edge() {
    mint_at_band_edge(policy::short(), 1_600_000, 102, 102);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_long_mint_cannot_cross_the_upper_band_edge_after_costs() {
    // The final reserve credit matters: using the old reserve admits this fill.
    mint_at_band_edge(policy::long(), 2_600_000, 101, 100);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_short_mint_cannot_cross_the_upper_band_edge_after_costs() {
    mint_at_band_edge(policy::short(), 2_600_000, 101, 100);
}

/// Credited contribution is capped at 100, but leverage must use the actual NAV gain of 101.
#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_favorable_long_mint_cannot_cross_the_lower_band_edge() {
    mint_at_band_edge(policy::long(), 1_600_000, 101, 102);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_favorable_short_mint_cannot_cross_the_lower_band_edge() {
    mint_at_band_edge(policy::short(), 1_600_000, 101, 102);
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun mint_completion_is_refused_once_shutdown_began() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_mint_plan();
    state.begin_shutdown(REFERENCE_AT_MS);
    state.complete_mint(plan, standard_mint_fill().into_position_observation(), REFERENCE_AT_MS);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun mint_completion_rejects_a_collateral_price_move() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_mint_plan();
    state.complete_mint(
        plan, standard_mint_fill().with_collateral_price(1_000_000_001).into_position_observation(), REFERENCE_AT_MS,
    );
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun mint_completion_rejects_a_lot_size_change() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_mint_plan();
    state.complete_mint(plan, standard_mint_fill().with_lot_size(2_000).into_position_observation(), REFERENCE_AT_MS);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun mint_completion_rejects_a_position_that_shrank() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_mint_plan();
    state.complete_mint(
        plan, standard_mint_fill().with_position_base(1_000_000_000).into_position_observation(), REFERENCE_AT_MS,
    );
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun mint_completion_rejects_an_over_fill() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_mint_plan();
    state.complete_mint(
        plan, standard_mint_fill().with_position_base(3_999_000_000).into_position_observation(), REFERENCE_AT_MS,
    );
    abort
}

/// The standard fill leaves 2_098_000 of equity over a 101_000 reserve: NAV 1_997_000.
#[test]
fun a_mint_landing_exactly_on_the_nav_cap_is_accepted() {
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(1_997_000);
    let plan = state.standard_mint_plan();

    let (shares, _, _, _, _) = state.complete_mint(plan, standard_mint_fill().into_position_observation(), REFERENCE_AT_MS);

    assert_eq!(shares, 997_000);
    assert_eq!(state.maintenance_reserve(), 101_000);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state)]
fun a_mint_landing_one_atom_over_the_nav_cap_is_refused() {
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(1_996_999);
    let plan = state.standard_mint_plan();
    state.complete_mint(plan, standard_mint_fill().into_position_observation(), REFERENCE_AT_MS);
    abort
}

/// A costly fill from the upper band edge lands at 30_591 bps: the fill
/// attribution, share quote, order bounds and NAV cap all pass. The final
/// band guard also covers positions beyond the wider hard cap.
#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun mint_completion_rejects_post_fill_leverage_above_the_cap() {
    let mut state = initialized_state(policy::long());
    let before = standard_observation(policy::long()).with_notional(2_600_000);
    let plan = state.prepare_mint(before.into_position_observation(), 1_000_000, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS);
    assert_eq!(plan.base_to_buy(), 2_597_400_000);
    state.complete_mint(
        plan,
        before.with_venue_equity(1_800_000).with_position_base(5_197_400_000).into_position_observation(),
        REFERENCE_AT_MS,
    );
    abort
}

/// With a 1 bps ceiling the seed reserve is 200 and the mint fee of 1_000 would
/// lift it to 1_200; the ceiling for the post-mint notional admits only 381 and
/// the rest is NAV, priced into the shares the newcomer receives.
#[test]
fun a_mint_fee_above_the_ceiling_is_released_to_holders() {
    let (mut state, seed_nav) = capped_issuance(1).activate_with(standard_observation(policy::long()), 200);
    assert_eq!(seed_nav, 1_099_800);
    let plan = state.prepare_mint(
        standard_observation(policy::long()).into_position_observation(), 1_000_000, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS,
    );
    // 2e9 * 999_000 / 1_099_800 floored to the lot.
    assert_eq!(plan.base_to_buy(), 1_816_693_000);

    let (shares, contribution, fee, admin, reserve_fee) = state.complete_mint(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(2_100_000)
            .with_position_base(SEED_BASE + 1_816_693_000)
            .into_position_observation(),
        REFERENCE_AT_MS,
    );

    // 1 bps of the 3_816_693 post-mint notional, not 200 + 1_000.
    assert_eq!(state.maintenance_reserve(), 381);
    // 1_000_000 * 999_000 / 1_099_800: the newcomer pays the pre-release NAV per share.
    assert_eq!(vector[shares, contribution, fee, admin, reserve_fee], vector[908_346, 999_000, 1_000, 0, 1_000]);
    let nav_after = 2_100_000 - state.maintenance_reserve();
    assert!((nav_after as u128) * (HEALTH_SHARE_SUPPLY as u128) >= (seed_nav as u128) * ((HEALTH_SHARE_SUPPLY + shares) as u128));
    state.destroy_for_testing();
}

// --- Redemption Preparation ---

/// One share of a million needs a 2_000-base sell, under the 100_000 minimum order.
#[test]
#[expected_failure(abort_code = errors::EOrderBelowMinLots, location = blast_boosts_core::accounting_math)]
fun a_dust_redemption_below_the_minimum_order_is_refused() {
    let state = initialized_state(policy::long());
    destroy(state.prepare_redemption(standard_observation(policy::long()).into_position_observation(), 1, HEALTH_SHARE_SUPPLY, 0, REFERENCE_AT_MS));
    abort
}

// --- Redemption Completion ---

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun redemption_completion_is_refused_once_shutdown_began() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_redemption_plan();
    state.begin_shutdown(REFERENCE_AT_MS);
    state.complete_redemption(plan, standard_redemption_fill().into_position_observation(), REFERENCE_AT_MS);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun redemption_completion_rejects_a_price_move() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_redemption_plan();
    state.complete_redemption(
        plan, standard_redemption_fill().with_base_price(1_000_000_001).into_position_observation(), REFERENCE_AT_MS,
    );
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun redemption_completion_rejects_a_partial_sell() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_redemption_plan();
    state.complete_redemption(
        plan, standard_redemption_fill().with_position_base(1_500_000_000).into_position_observation(), REFERENCE_AT_MS,
    );
    abort
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun redemption_completion_rejects_a_position_that_grew() {
    let mut state = initialized_state(policy::long());
    let plan = state.standard_redemption_plan();
    state.complete_redemption(
        plan, standard_redemption_fill().with_position_base(3_000_000_000).into_position_observation(), REFERENCE_AT_MS,
    );
    abort
}

/// Half of the 498 fee is admin cash, rounded down; the rest joins the reserve.
#[test]
fun a_redemption_with_an_admin_share_splits_the_fee() {
    let witness = vault_issuer();
    let issuance: Issuance<Product> = state::issue(
        &witness, fee_capped_vault_policy(10, 10, 5_000), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6,
    );
    let (mut state, _) = issuance.activate_with(standard_observation(policy::long()), SEED_RESERVE);
    state.set_fees(10, 10, 5_000);
    let plan = state.standard_redemption_plan();

    let (net, admin, fee, reserve_fee) = state.complete_redemption(
        plan, standard_redemption_fill().into_position_observation(), REFERENCE_AT_MS,
    );

    assert_eq!(vector[net, admin, fee, reserve_fee], vector[497_502, 249, 498, 249]);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE + 249);
    state.destroy_for_testing();
}

// --- Rebalance Preparation ---

/// A venue fee of the whole denominator is admitted; a reduction never sizes against it.
#[test]
fun a_venue_fee_of_exactly_the_denominator_is_usable() {
    let state = rebalance_state(policy::long());

    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10_000, REFERENCE_AT_MS);

    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 1_000_000_000);
    assert!(!order.is_increase() && !order.is_emergency());
    destroy(plan);
    state.destroy_for_testing();
}

// --- Rebalance Orders ---

/// A reduction that opens exactly at the cap is ordinary and stays ordinary:
/// when equity falls after its first fill the position is above the cap, but
/// the plan's own fills cannot widen its bound. Only a fresh plan, judged
/// against a fresh observation, may carry the emergency bound.
#[test]
fun a_reduction_that_crosses_the_cap_mid_plan_keeps_the_ordinary_bound() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert!(!order.is_emergency());
    assert!(!plan.is_emergency_rebalance());

    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_050_000, 2_900_000, policy::long()), 100_000_000, REFERENCE_AT_MS);

    let next = state.next_rebalance_order(&plan);
    assert!(!next.is_emergency());
    assert!(!plan.is_emergency_rebalance());
    assert!(next.order_base() > 0);
    destroy(plan);

    // A fresh plan against the same observation is emergency from its first order.
    let fresh = state.prepare_rebalance(rebalance_observation(1_050_000, 2_900_000, policy::long()), 10, REFERENCE_AT_MS);
    assert!(state.next_rebalance_order(&fresh).is_emergency());
    assert!(fresh.is_emergency_rebalance());
    destroy(fresh);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun a_zero_rebalance_fill_is_refused() {
    accept_increase_fill_once(rebalance_observation(1_089_226, 1_978_452, policy::long()), 0);
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun a_rebalance_fill_above_the_order_is_refused() {
    accept_increase_fill_once(rebalance_observation(1_089_226, 1_978_452, policy::long()), 978_453_000);
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun a_rebalance_fill_of_a_partial_lot_is_refused() {
    accept_increase_fill_once(rebalance_observation(1_089_226, 1_978_452, policy::long()), 1_500);
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun a_rebalance_fill_after_a_price_move_is_refused() {
    accept_increase_fill_once(
        standard_observation(policy::long())
            .with_venue_equity(1_089_226)
            .with_notional(1_978_452)
            .with_base_price(1_000_000_001)
            .into_position_observation(),
        978_452_000,
    );
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun a_rebalance_fill_the_observation_disagrees_with_is_refused() {
    accept_increase_fill_once(
        standard_observation(policy::long())
            .with_venue_equity(1_089_226)
            .with_position_base(1_978_451_000)
            .into_position_observation(),
        978_452_000,
    );
}

// --- Rebalance Completion ---

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun rebalance_completion_without_a_fill_is_refused() {
    let state = rebalance_state(policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    abort
}

/// One accepted lot whose equity jump lowers leverage is a fill, not progress.
#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun rebalance_increase_whose_leverage_did_not_rise_is_refused() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_001, 1_600_001, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_200_000, 1_600_002, policy::long()), 1_000, REFERENCE_AT_MS);
    assert_eq!(plan.rebalance_position().base(), 1_600_001_000);
    state.complete_rebalance(plan);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun rebalance_completion_is_refused_once_shutdown_began() {
    let mut state = rebalance_state(policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    state.begin_shutdown(REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    abort
}

#[test]
fun a_reduction_reaching_target_ends_the_plan() {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 1_000_000_000);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_100_000, 2_000_000, policy::long()), 1_000_000_000, REFERENCE_AT_MS);

    let next = state.next_rebalance_order(&plan);
    assert_eq!(next.order_base(), 0);
    assert!(!next.is_emergency());
    let (before_equity, after_equity, before_base, after_base, increased) = state.complete_rebalance(plan);

    assert_eq!(vector[before_equity, after_equity, before_base, after_base], vector[1_100_000, 1_100_000, 3_000_000_000, 2_000_000_000]);
    assert!(!increased);
    state.destroy_for_testing();
}

// --- Funding Overflow ---

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::state)]
fun an_uncovered_deficit_cannot_wrap() {
    let mut state = initialized_state(policy::long());
    state.settle_funding(observation::funding_cost(std::u64::max_value!()));
    assert_eq!(state.uncovered_deficit(), std::u64::max_value!() - SEED_RESERVE);
    state.settle_funding(observation::funding_cost(SEED_RESERVE + 1));
    abort
}

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::state)]
fun the_maximum_funding_credit_cannot_wrap() {
    let mut state = initialized_state(policy::long());
    state.settle_funding(observation::funding_credit(std::u64::max_value!()));
    abort
}

/// The conservation totals can exceed u64 even though the resulting reserve fits.
#[test]
fun a_funding_credit_can_fit_when_its_conservation_total_exceeds_u64() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[std::u64::max_value!() - 1, std::u64::max_value!()].do!(|credit| {
            let mut state = initialized_state(side);
            state.settle_funding(observation::funding_cost(SEED_RESERVE + 1));
            assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[0, 1]);
            // A real donation rebuilds reserve without repaying the holder deficit.
            state.donate(standard_observation(side).with_venue_equity(SEED_NAV).into_position_observation(), 1, REFERENCE_AT_MS);
            assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[1, 1]);

            let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_credit(credit));

            assert_eq!(vector[absorbed, uncovered, restored], vector[0, 0, 1]);
            assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[credit, 0]);
            assert!(state.is_active_for_testing());
            state.destroy_for_testing();
        });
    });
}

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::state)]
fun a_funding_credit_still_rejects_a_post_reserve_above_u64() {
    let mut state = initialized_state(policy::long());
    state.settle_funding(observation::funding_cost(SEED_RESERVE + 1));
    state.donate(standard_observation(policy::long()).with_venue_equity(SEED_NAV + 1).into_position_observation(), 2, REFERENCE_AT_MS);
    assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[2, 1]);

    // Repaying one atom still leaves a reserve of MAX + 1, which must fail.
    state.settle_funding(observation::funding_credit(std::u64::max_value!()));
    abort
}

#[test]
fun a_zero_funding_credit_is_an_exact_no_op() {
    assert_funding_settlement(observation::funding_credit(0), 0, 0, SEED_RESERVE);
}

// --- Donation ---

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_boosts_core::state)]
fun a_zero_donation_is_refused() {
    let mut state = initialized_state(policy::long());
    state.donate(standard_observation(policy::long()).into_position_observation(), 0, REFERENCE_AT_MS);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::state)]
fun the_maximum_donation_cannot_wrap() {
    let mut state = initialized_state(policy::long());
    state.donate(standard_observation(policy::long()).into_position_observation(), std::u64::max_value!(), REFERENCE_AT_MS);
    abort
}

#[test]
fun a_donation_under_the_ceiling_is_credited_in_full() {
    let mut state = initialized_state(policy::long());

    state.donate(
        standard_observation(policy::long()).with_venue_equity(SEED_VENUE_EQUITY + 70_000).into_position_observation(),
        70_000, REFERENCE_AT_MS,
    );

    assert_eq!(state.maintenance_reserve(), 170_000);
    state.destroy_for_testing();
}

// --- Unwind ---

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun an_ordinary_operation_is_refused_once_unwinding() {
    let mut state = initialized_state(policy::long());
    state.set_unwinding_for_testing();
    state.assert_active();
    abort
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun unwind_is_refused_while_active() {
    let state = initialized_state(policy::long());
    state.assert_unwinding();
    abort
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun unwind_constraints_are_refused_while_active() {
    let state = initialized_state(policy::long());
    state.unwind_constraints(fresh_price(1_000_000_000), fresh_price(1_000_000_000), LOT_SIZE, REFERENCE_AT_MS);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun unwind_rejects_a_stale_collateral_price() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.unwind_constraints(
        fresh_price(1_000_000_000), observation::new_price(1_000_000_000, 0, 0), LOT_SIZE, REFERENCE_AT_MS,
    );
    abort
}

#[test]
#[expected_failure(abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy)]
fun unwind_rejects_a_low_confidence_base_price() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.unwind_constraints(
        observation::new_price(1_000_000_000, 10_000_001, REFERENCE_AT_MS), fresh_price(1_000_000_000), LOT_SIZE, REFERENCE_AT_MS,
    );
    abort
}

#[test]
fun unwind_floors_the_order_cap_to_whole_lots() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);

    let (_, max_order_base, _, _, _) = state.unwind_constraints(
        fresh_price(1_000_000_000), fresh_price(1_000_000_000), 4_000, REFERENCE_AT_MS,
    );

    assert_eq!(max_order_base, 244_000);
    state.destroy_for_testing();
}

// --- Settlement ---

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun finalize_shutdown_is_refused_while_active() {
    let mut state = initialized_state(policy::long());
    state.finalize_shutdown(7, 2, 0);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::state)]
fun finalize_shutdown_with_only_the_seed_leaves_no_eligible_shares() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    let (eligible, reserve_cash, seed_cash) = state.finalize_shutdown(7, 7, 13);
    assert_eq!(vector[eligible, reserve_cash, seed_cash], vector[0, 0, 0]);
    state.shutdown_claim_quote(13, 7, 7, 1, 0);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::state)]
fun terminal_claim_of_zero_shares_is_refused() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(7, 2, 0);
    state.shutdown_claim_quote(13, 7, 2, 0, 0);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareSupply, location = blast_boosts_core::state)]
fun terminal_claim_against_a_supply_below_the_locked_seed_is_refused() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.finalize_shutdown(7, 2, 0);
    state.shutdown_claim_quote(13, 1, 2, 1, 0);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun terminal_claim_before_settlement_is_refused() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.shutdown_claim_quote(13, 7, 2, 2, 0);
    abort
}

// --- Administration ---

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun fee_updates_are_refused_after_shutdown_began() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    state.set_fees(5, 5, 0);
    abort
}

#[test]
fun a_fee_update_that_changes_only_the_admin_share_is_accepted() {
    let witness = vault_issuer();
    let issuance: Issuance<Product> = state::issue(
        &witness, fee_capped_vault_policy(10, 10, 3_000), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6,
    );
    let (mut state, _) = issuance.activate_with(standard_observation(policy::long()), SEED_RESERVE);

    let (previous_mint, previous_redeem, previous_admin) = state.set_fees(10, 10, 3_000);

    assert_eq!(vector[previous_mint, previous_redeem, previous_admin], vector[10, 10, 0]);
    let (mint, redeem, admin) = state.fee_settings();
    assert_eq!(vector[mint, redeem, admin], vector[10, 10, 3_000]);
    state.destroy_for_testing();
}

#[test]
fun max_order_notional_updates_in_every_lifecycle_state() {
    let mut state = initialized_state(policy::long());
    state.begin_shutdown(REFERENCE_AT_MS);
    assert_eq!(state.set_test_order_cap(500), MAX_ORDER_NOTIONAL);
    state.finalize_shutdown(7, 2, 0);
    assert_eq!(state.set_test_order_cap(750), 500);
    assert_eq!(state.max_order_notional_for_testing(), 750);
    state.destroy_for_testing();
}

/// Lowering the cap under the live NAV is allowed and only blocks the next mint.
#[test]
#[expected_failure(abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state)]
fun nav_cap_may_be_lowered_below_the_live_nav() {
    let mut state = initialized_state(policy::long());
    assert_eq!(state.set_nav_cap(1), NAV_CAP);
    let plan = state.standard_mint_plan();
    state.complete_mint(plan, standard_mint_fill().into_position_observation(), REFERENCE_AT_MS);
    abort
}

// --- Active Observation ---

#[test]
#[expected_failure(abort_code = errors::EInvalidPositionObservation, location = blast_boosts_core::state)]
fun an_active_operation_rejects_a_non_flat_observation_on_the_wrong_side() {
    let state = initialized_state(policy::long());
    state.needs_rebalance(standard_observation(policy::long()).with_observed_side(policy::short()).into_position_observation(), observation::funding_credit(0), true, 10, REFERENCE_AT_MS);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun an_active_operation_rejects_equity_equal_to_the_reserve() {
    let state = initialized_state(policy::long());
    state.needs_rebalance(standard_observation(policy::long()).with_venue_equity(SEED_RESERVE).into_position_observation(), observation::funding_credit(0), true, 10, REFERENCE_AT_MS);
    abort
}

/// The admitted reserve gates priced operations, not the stored one: a credit
/// lifts the book to 150_000 over a 100_000 ceiling, and equity of 140_000
/// still prices, leaving 40_000 of NAV; the redemption that follows releases
/// the excess back to the ceiling instead of locking holders out.
#[test]
fun a_priced_operation_admits_equity_that_covers_the_admitted_reserve() {
    let mut state = capped_initialized_state(500);
    state.settle_funding(observation::funding_credit(50_000));
    assert_eq!(state.maintenance_reserve(), 150_000);
    let observation = standard_observation(policy::long()).with_venue_equity(140_000).into_position_observation();

    let plan = state.prepare_redemption(observation, 500_000, 1_000_000, 0, REFERENCE_AT_MS);
    let after = standard_observation(policy::long()).with_venue_equity(140_000).with_position_base(1_000_000_000).into_position_observation();
    let (net, _, _, _) = state.complete_redemption(plan, after, REFERENCE_AT_MS);
    assert!(net > 0);
    assert!(state.maintenance_reserve() <= 100_000);
    state.destroy_for_testing();
}

/// Equity at or below the admitted reserve is still refused.
#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun a_priced_operation_is_refused_when_equity_only_covers_the_admitted_reserve() {
    let mut state = capped_initialized_state(500);
    state.settle_funding(observation::funding_credit(50_000));
    state.needs_rebalance(standard_observation(policy::long()).with_venue_equity(100_000).into_position_observation(), observation::funding_credit(0), true, 10, REFERENCE_AT_MS);
    abort
}

#[test]
fun seed_and_admin_accept_the_first_cap_covering_the_live_minimum() {
    // 100 lots at $1 with 1% headroom and the extra price atom cost 102 atoms.
    let issuance = state::issue<Product>(&vault_issuer(), standard_vault_policy(), 102, 1_600_000, 9, 6);
    let flat = standard_observation(policy::long()).with_position_base(0).into_position_observation();
    let (_, capacity, _) = issuance.seed_terms(flat, SEED_RESERVE);
    assert!(capacity >= MIN_EXPOSURE_LOTS * LOT_SIZE);
    destroy(issuance);
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(1_600_000);
    state.set_test_order_cap(102);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun seed_rejects_one_atom_below_minimum_order_capacity() {
    let issuance = state::issue<Product>(&vault_issuer(), standard_vault_policy(), 101, 1_600_000, 9, 6);
    let flat = standard_observation(policy::long()).with_position_base(0).into_position_observation();
    issuance.seed_terms(flat, SEED_RESERVE);
    destroy(issuance);
}

#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun admin_rejects_one_atom_below_minimum_order_capacity() {
    let mut state = initialized_state(policy::long());
    state.set_nav_cap(1_600_000);
    state.set_test_order_cap(101);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun order_cap_update_requires_fresh_prices() {
    let mut state = initialized_state(policy::long());
    state.set_max_order_notional(500, fresh_price(1_000_000_000), fresh_price(1_000_000_000), LOT_SIZE, REFERENCE_AT_MS + 100_000);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxOrderNotional, location = blast_boosts_core::state)]
fun invalid_cap_is_rejected_before_stale_prices() {
    let mut state = initialized_state(policy::long());
    state.set_max_order_notional(0, fresh_price(1_000_000_000), fresh_price(1_000_000_000), LOT_SIZE, REFERENCE_AT_MS + 100_000);
    state.destroy_for_testing();
}

// === Test Helpers ===

fun mint_at_band_edge(side: PositionSide, notional: u64, deposit: u64, equity_increase: u64) {
    let mut state = initialized_state(side);
    let before = standard_observation(side).with_notional(notional);
    let plan = state.prepare_mint(before.into_position_observation(), deposit, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS);
    let base_after = before.position_base + plan.base_to_buy();
    state.complete_mint(
        plan, before.with_venue_equity(SEED_VENUE_EQUITY + equity_increase).with_position_base(base_after).into_position_observation(),
        REFERENCE_AT_MS,
    );
    state.destroy_for_testing();
}

fun set_test_order_cap(self: &mut State<Product>, cap: u64): u64 {
    self.set_max_order_notional(cap, fresh_price(1_000_000_000), fresh_price(1_000_000_000), LOT_SIZE, REFERENCE_AT_MS)
}


fun rebalance_state(side: PositionSide): State<Product> {
    let witness = vault_issuer();
    let (state, _, _) = state::issue<Product>(&witness, vault_policy(side), 2_000_000, NAV_CAP, 9, 6)
        .activate(rebalance_observation(SEED_VENUE_EQUITY, SEED_NOTIONAL, side), SEED_RESERVE, REFERENCE_AT_MS);
    state
}

fun rebalance_observation(equity: u64, notional: u64, side: PositionSide): PositionObservation {
    let mut spec = standard_observation(side);
    spec.venue_equity = equity;
    spec.position_base = notional * 1_000;
    spec.into_position_observation()
}

/// The close-only bound, in basis points, an unwind step at `now_at_ms` would price under.
fun unwind_bound_bps_at(state: &State<Product>, now_at_ms: u64): u64 {
    let (_, _, _, _, bound) = state.unwind_constraints(
        observation::new_price(1_000_000_000, 0, now_at_ms),
        observation::new_price(1_000_000_000, 0, now_at_ms), LOT_SIZE, now_at_ms,
    );
    bound.slippage_bps()
}

fun rebalance_endpoint(notional: u64) {
    let state = rebalance_state(policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, notional, policy::long()), 10, REFERENCE_AT_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
}

fun vault_issuer(): AdminWitness<VaultIssuer> {
    blast_acl::witness_for_testing()
}

fun standard_vault_policy(): VaultPolicy {
    vault_policy(policy::long())
}

fun vault_policy(side: PositionSide): VaultPolicy {
    policy::new_vault_policy(
        side,
        policy::new_rebalance_policy(
            16_000,
            20_000,
            26_000,
            30_000,
            100,
            500,
            10,
        ),
        policy::new_price_policy(30_000, 2_000, 100, 500),
        10,
        10,
        10,
        10,
        0,
        MIN_EXPOSURE_LOTS,
        MAX_RESERVE_BPS,
    )
}

/// The standard long policy with fee caps the admin may move up to.
fun fee_capped_vault_policy(mint_fee_cap_bps: u64, redeem_fee_cap_bps: u64, admin_share_cap_bps: u64): VaultPolicy {
    policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(16_000, 20_000, 26_000, 30_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500),
        10,
        10,
        mint_fee_cap_bps,
        redeem_fee_cap_bps,
        admin_share_cap_bps,
        MIN_EXPOSURE_LOTS,
        MAX_RESERVE_BPS,
    )
}

/// A long issuance whose reserve ceiling is `max_reserve_bps` of notional.
fun capped_issuance(max_reserve_bps: u64): Issuance<Product> {
    let witness = vault_issuer();
    let vault_policy = policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(16_000, 20_000, 26_000, 30_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500),
        10,
        10,
        10,
        10,
        0,
        MIN_EXPOSURE_LOTS,
        max_reserve_bps,
    );

    state::issue<Product>(&witness, vault_policy, MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6)
}

fun capped_initialized_state(max_reserve_bps: u64): State<Product> {
    let (state, _) = capped_issuance(max_reserve_bps).activate_with(standard_observation(policy::long()), SEED_RESERVE);
    state
}

fun issued(side: PositionSide): Issuance<Product> {
    let witness = vault_issuer();

    state::issue<Product>(&witness, vault_policy(side), MAX_ORDER_NOTIONAL, NAV_CAP, 9, 6)
}

/// Activates the issuance on `spec`, at the fixture's decimals and clock; returns the state and seed NAV.
fun activate_with(self: Issuance<Product>, spec: ObservationSpec, seed_reserve: u64): (State<Product>, u64) {
    let (state, seed_nav, _) = self.activate(spec.into_position_observation(), seed_reserve, REFERENCE_AT_MS);
    (state, seed_nav)
}

fun initialized_state(side: PositionSide): State<Product> {
    let (state, seed_nav) = issued(side).activate_with(standard_observation(side), SEED_RESERVE);
    assert_eq!(seed_nav, SEED_NAV);

    state
}

fun initialize_once(spec: ObservationSpec, side: PositionSide, seed_reserve: u64) {
    let (state, _) = issued(side).activate_with(spec, seed_reserve);

    state.destroy_for_testing();
}

/// The standard 1_000_000 deposit against the seed: 999_000 of contribution buys 1_998_000_000 of base.
fun standard_mint_plan(state: &State<Product>): MintPlan<Product> {
    let plan = state.prepare_mint(
        standard_observation(policy::long()).into_position_observation(), 1_000_000, HEALTH_SHARE_SUPPLY, 1, 10, REFERENCE_AT_MS,
    );
    assert_eq!(plan.base_to_buy(), 1_998_000_000);

    plan
}

/// The position after the standard mint's order filled with 2_000 of execution cost.
fun standard_mint_fill(): ObservationSpec {
    standard_observation(policy::long()).with_venue_equity(2_098_000).with_position_base(3_998_000_000)
}

/// Half the supply redeemed against the seed: a 1_000_000_000 sell.
fun standard_redemption_plan(state: &State<Product>): RedemptionPlan<Product> {
    let plan = state.prepare_redemption(
        standard_observation(policy::long()).into_position_observation(), 500_000, HEALTH_SHARE_SUPPLY, 1, REFERENCE_AT_MS,
    );
    assert_eq!(plan.base_to_sell(), 1_000_000_000);

    plan
}

/// The position after the standard redemption's sell filled with 2_000 of execution cost.
fun standard_redemption_fill(): ObservationSpec {
    standard_observation(policy::long()).with_venue_equity(1_098_000).with_position_base(1_000_000_000)
}

fun fresh_price(price: u64): PriceObservation {
    observation::new_price(price, 0, REFERENCE_AT_MS)
}

/// Opens the standard increase plan, whose first order is 978_452_000, and presents one fill.
fun accept_increase_fill_once(after: PositionObservation, filled_base: u64) {
    let state = rebalance_state(policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 1_000_000, policy::long()), 10, REFERENCE_AT_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 978_452_000);

    state.accept_rebalance_fill(&mut plan, order, after, filled_base, REFERENCE_AT_MS);

    destroy(plan);
    state.destroy_for_testing();
}

fun assert_funding_settlement(
    settlement: FundingSettlement,
    expected_absorbed: u64,
    expected_uncovered: u64,
    expected_reserve: u64,
) {
    let mut state = initialized_state(policy::long());

    let (absorbed, uncovered, restored) = state.settle_funding(settlement);

    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, expected_uncovered);
    assert_eq!(restored, 0);
    assert_eq!(state.uncovered_deficit(), expected_uncovered);
    assert_eq!(state.maintenance_reserve(), expected_reserve);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
}

fun standard_observation(side: PositionSide): ObservationSpec {
    ObservationSpec {
        venue_equity: SEED_VENUE_EQUITY,
        position_base: SEED_BASE,
        lot_size: LOT_SIZE,
        observed_side: side,
        base_price: 1_000_000_000,
        base_confidence: 1_000_000,
        base_publish_time_ms: 95_000,
        collateral_price: 1_000_000_000,
        collateral_confidence: 1_000_000,
        collateral_publish_time_ms: 95_000,
        mark_price: 1_000_000_000,
    }
}

fun into_position_observation(self: ObservationSpec): PositionObservation {
    let ObservationSpec {
        venue_equity,
        position_base,
        lot_size,
        observed_side,
        base_price,
        base_confidence,
        base_publish_time_ms: base_price_published_at_ms,
        collateral_price,
        collateral_confidence,
        collateral_publish_time_ms: collateral_price_published_at_ms,
        mark_price,
    } = self;

    observation::new_position(
        venue_equity,
        position_base,
        lot_size,
        observed_side,
        observation::new_price(base_price, base_confidence, base_price_published_at_ms),
        observation::new_price(
            collateral_price,
            collateral_confidence,
            collateral_price_published_at_ms,
        ),
        mark_price,
    )
}

/// Sets the notional and the base that values to it at the fixture's unit price.
fun with_notional(mut self: ObservationSpec, notional: u64): ObservationSpec {
    self.position_base = notional * 1_000;
    self
}

fun with_lot_size(mut self: ObservationSpec, lot_size: u64): ObservationSpec {
    self.lot_size = lot_size;
    self
}

fun with_venue_equity(mut self: ObservationSpec, venue_equity: u64): ObservationSpec {
    self.venue_equity = venue_equity;
    self
}

fun with_position_base(mut self: ObservationSpec, position_base: u64): ObservationSpec {
    self.position_base = position_base;
    self
}

fun with_base_price(mut self: ObservationSpec, base_price: u64): ObservationSpec {
    self.base_price = base_price;
    self
}

fun with_collateral_price(mut self: ObservationSpec, collateral_price: u64): ObservationSpec {
    self.collateral_price = collateral_price;
    self
}

fun with_observed_side(mut self: ObservationSpec, observed_side: PositionSide): ObservationSpec {
    self.observed_side = observed_side;
    self
}

fun with_base_confidence(mut self: ObservationSpec, base_confidence: u64): ObservationSpec {
    self.base_confidence = base_confidence;
    self
}

fun with_base_price_published_at_ms(
    mut self: ObservationSpec,
    base_price_published_at_ms: u64,
): ObservationSpec {
    self.base_publish_time_ms = base_price_published_at_ms;
    self
}

fun with_collateral_confidence(
    mut self: ObservationSpec,
    collateral_confidence: u64,
): ObservationSpec {
    self.collateral_confidence = collateral_confidence;
    self
}

fun with_collateral_price_published_at_ms(
    mut self: ObservationSpec,
    collateral_price_published_at_ms: u64,
): ObservationSpec {
    self.collateral_publish_time_ms = collateral_price_published_at_ms;
    self
}

fun with_mark_price(mut self: ObservationSpec, mark_price: u64): ObservationSpec {
    self.mark_price = mark_price;
    self
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_boosts_core::{
    accounting_math,
    errors,
    lifecycle,
    observation::{Self, FundingSettlement, PositionObservation, PriceObservation},
    policy::{Self, PositionSide, VaultPolicy},
    blast_boosts_core::VaultIssuer,
    state::{Self, Issuance, MintPlan, RedemptionPlan, State},
};

use std::unit_test::{assert_eq, destroy};

use fun set_test_order_cap as State.set_test_order_cap;

use fun activate_with as Issuance.activate_with;

use fun standard_mint_plan as State.standard_mint_plan;

use fun standard_redemption_plan as State.standard_redemption_plan;

use fun unwind_bound_bps_at as State.unwind_bound_bps_at;
