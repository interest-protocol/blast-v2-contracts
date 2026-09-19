#[test_only]
/// Tests for construction of adapter-custodied Series1 state.
module blast_boosts_core::state_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const ISSUER: address = @0x1;
const MAX_ORDER_NOTIONAL: u64 = 250;
const REFERENCE_TIME_MS: u64 = 100_000;
const SEED_RESERVE: u64 = 100_000;
const SEED_VENUE_EQUITY: u64 = 1_100_000;
const SEED_NAV: u64 = 1_000_000;
const SEED_BASE: u64 = 2_000_000_000;
const SEED_NOTIONAL: u64 = 2_000_000;
const LOT_SIZE: u64 = 1_000;
const MIN_EXPOSURE_LOTS: u64 = 100;
const NAV_CAP: u64 = 1_000_000_000;
/// Half of notional: wide enough that ordinary fixtures never touch the ceiling.
const MAX_RESERVE_BPS: u64 = 5_000;
const HEALTH_SHARE_SUPPLY: u64 = 1_000_000;

// === Test-Only Types ===

public struct Product {}

public struct Fixture {
    scenario: Scenario,
    authority: Authority<BLAST_BOOSTS_CORE>,
    super_admin_cap: SuperAdminCap<BLAST_BOOSTS_CORE>,
    admin_cap: AdminCap<BLAST_BOOSTS_CORE>,
}

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
fun terminal_claim_quote_conserves_zero_dust_and_maximum_cash_for_both_sides() {
    let fixture = start(domain::vault_issuer_role());
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = initialized_state(&fixture, side);
        state.begin_shutdown();
        assert_eq!(state.finalize_shutdown(7, 2), 5);
        assert_eq!(state.shutdown_claim_quote(13, 7, 2, 2, 5), 5);
        assert_eq!(state.shutdown_claim_quote(8, 5, 2, 3, 8), 8);
        assert_eq!(state.shutdown_claim_quote(0, 7, 2, 5, 0), 0);
        let maximum = std::u64::max_value!();
        assert_eq!(state.shutdown_claim_quote(maximum, maximum, 0, maximum, maximum), maximum);
        state.destroy_for_testing();
    });
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EZeroNetPayout, location = blast_boosts_core::state)]
fun terminal_partial_dust_requires_combining_native_shares() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.begin_shutdown();
    state.finalize_shutdown(7, 2);
    state.shutdown_claim_quote(1, 7, 2, 1, 0);
    destroy(state);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ERedemptionOutputBelowMinimum, location = blast_boosts_core::state)]
fun terminal_zero_pool_requires_explicit_zero_minimum() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::short());
    state.begin_shutdown();
    state.finalize_shutdown(7, 2);
    state.shutdown_claim_quote(0, 7, 2, 5, 1);
    destroy(state);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::state)]
fun terminal_claim_cannot_include_locked_seed() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.begin_shutdown();
    state.finalize_shutdown(7, 2);
    state.shutdown_claim_quote(13, 7, 2, 6, 0);
    destroy(state);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareSupply, location = blast_boosts_core::state)]
fun terminal_supply_below_locked_seed_fails_closed() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.begin_shutdown();
    state.finalize_shutdown(1, 2);
    destroy(state);
    destroy(fixture);
}

#[test]
fun unwind_uses_the_frozen_emergency_bound_without_a_nav_input_for_both_sides() {
    let fixture = start(domain::vault_issuer_role());
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = initialized_state(&fixture, side);
        state.begin_shutdown();
        let (actual_side, cap, base_price, collateral_price) = state.unwind_constraints(
            observation::new_price(1_000_000_000, 0, REFERENCE_TIME_MS),
            observation::new_price(1_000_000_000, 0, REFERENCE_TIME_MS), REFERENCE_TIME_MS,
        );
        assert_eq!(actual_side, side);
        assert_eq!(cap, 250);
        assert_eq!(base_price, 1_000_000_000);
        assert_eq!(collateral_price, 1_000_000_000);
        state.assert_execution(true, 1_000_000_000, 1_050_000_000);
        state.assert_execution(true, 1_000_000_000, 950_000_000);
        state.destroy_for_testing();
    });
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun ordinary_unwind_never_falls_back_to_a_stale_price() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::short());
    state.begin_shutdown();
    state.unwind_constraints(observation::new_price(1_000_000_000, 0, 0),
        observation::new_price(1_000_000_000, 0, 0), REFERENCE_TIME_MS);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun settled_cash_cannot_reopen_a_funding_buffer() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.begin_shutdown();
    state.finalize_shutdown(5, 2);
    state.settle_funding(observation::funding_credit(1));
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EVenueFeeUnusable, location = blast_boosts_core::state)]
fun invalid_rebalance_fee_precedes_invalid_observation() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::long());
    let invalid = standard_observation(policy::long()).with_observed_side(policy::short());
    destroy(state.prepare_rebalance(invalid.into_position_observation(), 10_001, REFERENCE_TIME_MS));
    destroy(state);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun mint_outside_band_precedes_deposit_arithmetic() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::long());
    let plan = state.prepare_mint(standard_observation(policy::long()).with_notional(1_000_000).into_position_observation(), 0, 1_000_000, 1, REFERENCE_TIME_MS);
    destroy(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun mint_completion_rejects_missing_attributable_fill() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    let plan = state.prepare_mint(standard_observation(policy::long()).into_position_observation(), 1_000_000, 1_000_000, 1, REFERENCE_TIME_MS);
    state.complete_mint(plan, standard_observation(policy::long()).into_position_observation(), REFERENCE_TIME_MS);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ERedemptionOutputBelowMinimum, location = blast_boosts_core::state)]
fun redemption_rejects_output_one_above_net() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_redemption(before.into_position_observation(), 500_000, 1_000_000, 499_501, REFERENCE_TIME_MS);
    state.complete_redemption(plan, before.with_position_base(1_000_000_000).into_position_observation(), REFERENCE_TIME_MS);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ESharesOutBelowMinimum, location = blast_boosts_core::accounting_math)]
fun mint_amount_supply_swap_cannot_satisfy_the_original_minimum() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    let before = standard_observation(policy::long());
    let plan = state.prepare_mint(before.into_position_observation(), 1_000_000, 500_000, 600_000, REFERENCE_TIME_MS);
    state.complete_mint(plan, before.with_venue_equity(2_098_000).with_position_base(3_998_000_000).into_position_observation(), REFERENCE_TIME_MS);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::accounting_math)]
fun redemption_shares_supply_swap_is_rejected() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::long());
    let plan = state.prepare_redemption(standard_observation(policy::long()).into_position_observation(), 1_000_000, 500_000, 1, REFERENCE_TIME_MS);
    destroy(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun issuance_rejects_a_zero_nav_cap() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    destroy(state::issue<Product>(&witness, vault_policy(policy::long()), 2_000_000, 0));
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun issuance_rejects_a_nav_cap_whose_max_leverage_notional_overflows() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    destroy(state::issue<Product>(&witness, vault_policy(policy::long()), 2_000_000, std::u64::max_value!()));
    abort
}

#[test]
fun nav_cap_setter_replaces_the_initial_cap_and_returns_the_previous_one() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    assert_eq!(state.nav_cap_for_testing(), NAV_CAP);
    assert!(state.is_within_nav_cap_for_testing(NAV_CAP));
    assert!(!state.is_within_nav_cap_for_testing(NAV_CAP + 1));

    assert_eq!(state.set_nav_cap(NAV_CAP / 2), NAV_CAP);

    assert_eq!(state.nav_cap_for_testing(), NAV_CAP / 2);
    assert!(!state.is_within_nav_cap_for_testing(NAV_CAP / 2 + 1));
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ENavCapUnchanged, location = blast_boosts_core::state)]
fun nav_cap_setter_rejects_an_unchanged_cap() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_nav_cap(NAV_CAP);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun nav_cap_setter_rejects_zero() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_nav_cap(0);
    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun nav_cap_setter_rejects_a_cap_whose_max_leverage_notional_overflows() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_nav_cap(std::u64::max_value!());
    abort
}

#[test]
fun live_fee_setter_accepts_each_exact_immutable_cap() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let issuance: Issuance<Product> = state::issue(
        &witness, vault_policy(policy::long()).with_fee_limits(100, 200, 3_000), MAX_ORDER_NOTIONAL, NAV_CAP,
    );
    let (mut state, _) = activate_with(issuance, standard_observation(policy::long()), SEED_RESERVE);
    state.set_fees(100, 200, 3_000);
    let (mint, redeem, admin) = state.fee_settings();
    assert_eq!(vector[mint, redeem, admin], vector[100, 200, 3_000]);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun active_mint_and_redemption_are_generic_for_long_and_short_2x_4x_6x() {
    let fixture = start(domain::vault_issuer_role());
    vector[20_000, 40_000, 60_000].do!(|target| {
        vector[policy::long(), policy::short()].do!(|side| {
            let witness = fixture.authority.sign_in(&fixture.admin_cap);
            let vault_policy = policy::new_vault_policy(
                side, policy::new_rebalance_policy(target - 2_000, target, target + 2_000, target + 10_000, 100, 500, 10),
                policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, MAX_RESERVE_BPS,
            );
            let notional = target * 100;
            let (mut state, _, _) = state::issue<Product>(&witness, vault_policy, 2_000_000, NAV_CAP)
                .activate(rebalance_observation(1_100_000, notional, side), 100_000, 9, 6, REFERENCE_TIME_MS);
            let plan = state.prepare_mint(rebalance_observation(1_100_000, notional, side), 1_000_000, 1_000_000, 1_000_000, REFERENCE_TIME_MS);
            assert_eq!(plan.base_to_buy(), notional * 1_000);
            let (shares, contribution, _, _, _) = state.complete_mint(plan, rebalance_observation(2_100_000, notional * 2, side), REFERENCE_TIME_MS);
            assert_eq!(vector[shares, contribution, state.maintenance_reserve()], vector[1_000_000, 1_000_000, 100_000]);
            let plan = state.prepare_redemption(rebalance_observation(2_100_000, notional * 2, side), 500_000, 2_000_000, 500_000, REFERENCE_TIME_MS);
            assert_eq!(plan.base_to_sell(), notional * 500);
            let (net, admin, fee, _) = state.complete_redemption(plan, rebalance_observation(2_100_000, notional * 3 / 2, side), REFERENCE_TIME_MS);
            assert_eq!(vector[net, admin, fee], vector[500_000, 0, 0]);
            state.destroy_for_testing();
        });
    });
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun active_redemption_rejects_a_stale_price() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::short());
    let mut invalid = standard_observation(policy::short());
    invalid.base_publish_time_ms = 0;
    destroy(state.prepare_redemption(invalid.into_position_observation(), 500_000, HEALTH_SHARE_SUPPLY, 1, REFERENCE_TIME_MS));
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_update_cannot_raise_the_immutable_cap() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_fees(11, 10, 0);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EFeeSettingsUnchanged, location = blast_boosts_core::state)]
fun fee_update_rejects_an_unchanged_tuple() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_fees(10, 10, 0);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ENonpositiveContribution, location = blast_boosts_core::state)]
fun mint_rejects_input_consumed_by_rounded_fee_before_sizing_exposure() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::long());
    destroy(state.prepare_mint(standard_observation(policy::long()).into_position_observation(), 1, HEALTH_SHARE_SUPPLY, 0, REFERENCE_TIME_MS));
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun rebalance_increase_reserves_cost_and_keeps_buffer_unchanged() {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 1_000_000, policy::long()), 10, REFERENCE_TIME_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 978_452_000);
    assert!(order.is_increase() && !order.is_wide());
    let filled = order.order_base();
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_089_226, 1_978_452, policy::long()), filled, REFERENCE_TIME_MS);
    assert_eq!(state.next_rebalance_order(&plan).order_base(), 0);
    let (before_equity, after_equity, before_base, after_base, increased) = state.complete_rebalance(plan);
    assert_eq!(before_equity, 1_100_000);
    assert_eq!(after_equity, 1_089_226);
    assert_eq!(before_base, 1_000_000_000);
    assert_eq!(after_base, 1_978_452_000);
    assert!(increased);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
    destroy(fixture);
}

/// An emergency reduction ends the moment leverage is no longer above the hard
/// cap: the wider bound never covers an order below it, and a wide market cannot
/// revert the orders placed above it.
#[test]
fun rebalance_short_emergency_reduction_stops_once_leverage_is_below_the_cap() {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::short());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_200_000, policy::short()), 10, REFERENCE_TIME_MS);
    let order = state.next_rebalance_order(&plan);
    assert_eq!(order.order_base(), 1_200_000_000);
    assert!(!order.is_increase() && order.is_wide());
    state.assert_execution(order.is_wide(), 100, 104);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_099_500, 2_900_000, policy::short()), 300_000_000, REFERENCE_TIME_MS);
    let next = state.next_rebalance_order(&plan);
    assert_eq!(next.order_base(), 0);
    assert!(!next.is_wide());
    state.complete_rebalance(plan);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun rebalance_exact_lower_endpoint_rejects() { rebalance_endpoint(1_600_000); }

#[test]
#[expected_failure(abort_code = errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun rebalance_exact_upper_endpoint_rejects() { rebalance_endpoint(2_600_000); }

#[test]
fun rebalance_one_rational_atom_below_lower_is_not_hidden_by_report_rounding() {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_001, 1_600_001, policy::long()), 10, REFERENCE_TIME_MS);
    let order = state.next_rebalance_order(&plan);
    assert!(order.order_base() > 0 && order.is_increase() && !order.is_wide());
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_100_001, 1_600_002, policy::long()), 1_000, REFERENCE_TIME_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun rebalance_reduction_without_leverage_improvement_rejects() {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_TIME_MS);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_000_000, 2_700_000, policy::long()), 300_000_000, REFERENCE_TIME_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EActiveLeverageAboveCap, location = blast_boosts_core::state)]
fun rebalance_increase_rejects_post_cost_target_overshoot() {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::long());
    let mut plan = state.prepare_rebalance(rebalance_observation(1_100_000, 1_000_000, policy::long()), 10, REFERENCE_TIME_MS);
    let order = state.next_rebalance_order(&plan);
    state.accept_rebalance_fill(&mut plan, order, rebalance_observation(1_089_225, 1_978_452, policy::long()), 978_452_000, REFERENCE_TIME_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun rebalance_hard_threshold_equality_does_not_enable_wide_tolerance() {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, 3_000_000, policy::long()), 10, REFERENCE_TIME_MS);
    state.assert_execution(state.next_rebalance_order(&plan).is_wide(), 100, 102);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun a_flat_short_product_redeems_without_inventing_a_long_position() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::short());
    let flat = standard_observation(policy::long())
        .with_position_base(0);
    let plan = state.prepare_redemption(flat.into_position_observation(), 500_000, 1_000_000, 499_500, REFERENCE_TIME_MS);
    assert_eq!(plan.base_to_sell(), 0);
    let (net, admin, fee, _) = state.complete_redemption(plan, flat.into_position_observation(), REFERENCE_TIME_MS);
    assert_eq!(vector[net, admin], vector[499_500, 0]);
    assert_eq!(fee, 500);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun redemption_keeps_remaining_nav_and_allocates_its_own_fee() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::short());
    let plan = state.prepare_redemption(
        standard_observation(policy::short()).into_position_observation(),
        500_000, 1_000_000, 497_502, REFERENCE_TIME_MS,
    );
    assert_eq!(plan.base_to_sell(), 1_000_000_000);
    let (net, admin, fee, _) = state.complete_redemption(
        plan,
        standard_observation(policy::short())
            .with_venue_equity(1_098_000)
            .with_position_base(1_000_000_000)
            .into_position_observation(),
        REFERENCE_TIME_MS,
    );
    let final_equity = 1_098_000 - net - admin;
    assert_eq!(vector[net, admin, final_equity], vector[497_502, 0, 600_498]);
    assert_eq!(fee, 498);
    assert_eq!(state.maintenance_reserve(), 100_498);
    assert_eq!(final_equity - state.maintenance_reserve(), 500_000);
    state.destroy_for_testing();
    destroy(fixture);
}

/// A fill that raises NAV by more than the deposit net of the fee credits exactly
/// `deposit - protocol_fee`; the 2,000-unit excess stays with existing holders.
#[test]
fun mint_credits_at_most_the_deposit_net_of_fee_when_the_fill_is_favorable() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    let plan = state.prepare_mint(
        standard_observation(policy::long()).into_position_observation(),
        1_000_000,
        1_000_000,
        999_000,
        REFERENCE_TIME_MS,
    );
    assert_eq!(plan.base_to_buy(), 1_998_000_000);
    let (shares, contribution, fee, admin, buffer) = state.complete_mint(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(2_102_000)
            .with_position_base(3_998_000_000)
            .into_position_observation(),
        REFERENCE_TIME_MS,
    );
    assert_eq!(vector[shares, contribution, fee, admin, buffer], vector[999_000, 999_000, 1_000, 0, 1_000]);
    assert_eq!(state.maintenance_reserve(), 101_000);
    // Remaining NAV per share rose: 2_001_000 / 1_999_000 > 1_000_000 / 1_000_000.
    assert!((2_001_000u128) * 1_000_000 > 1_000_000u128 * 1_999_000);
    state.destroy_for_testing();
    destroy(fixture);
}

/// An unwind that leaves more NAV than the pre-unwind reading pays exactly the
/// proportional claim; the 2,000-unit gain stays with the remaining holders.
#[test]
fun redemption_pays_at_most_the_proportional_claim_when_the_unwind_is_favorable() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    let plan = state.prepare_redemption(
        standard_observation(policy::long()).into_position_observation(),
        500_000, 1_000_000, 499_500, REFERENCE_TIME_MS,
    );
    assert_eq!(plan.base_to_sell(), 1_000_000_000);
    let (net, admin, fee, buffer) = state.complete_redemption(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(1_102_000)
            .with_position_base(1_000_000_000)
            .into_position_observation(),
        REFERENCE_TIME_MS,
    );
    let final_equity = 1_102_000 - net - admin;
    assert_eq!(vector[net, admin, fee, buffer], vector[499_500, 0, 500, 500]);
    assert_eq!(state.maintenance_reserve(), 100_500);
    assert_eq!(final_equity, 602_500);
    // Remaining holders keep 502_000 over 500_000 shares, above the 500_000 proportional keep.
    assert_eq!(final_equity - state.maintenance_reserve(), 502_000);
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun mint_prices_actual_contribution_after_the_attributable_cost() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());
    let plan = state.prepare_mint(
        standard_observation(policy::long()).into_position_observation(),
        1_000_000,
        1_000_000,
        997_000,
        REFERENCE_TIME_MS,
    );
    assert_eq!(plan.base_to_buy(), 1_998_000_000);
    let (shares, contribution, _, _, _) = state.complete_mint(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(2_098_000)
            .with_position_base(3_998_000_000)
            .into_position_observation(),
        REFERENCE_TIME_MS,
    );
    assert_eq!(shares, 997_000);
    assert_eq!(contribution, 997_000);
    assert_eq!(state.maintenance_reserve(), 101_000);
    assert!((1_997_000u128) * 1_000_000 >= 1_000_000u128 * (1_000_000 + shares as u128));
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun fee_updates_change_future_allocations_without_relabeling_the_buffer() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let issuance: Issuance<Product> = state::issue(
        &witness, vault_policy(policy::long()).with_fee_limits(100, 100, 3_000), MAX_ORDER_NOTIONAL, NAV_CAP,
    );
    let (mut state, _) = activate_with(issuance, standard_observation(policy::long()), SEED_RESERVE);
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
    destroy(fixture);
}

#[test]
fun an_issuance_reads_the_frozen_side_and_live_order_cap() {
    let fixture = start(domain::vault_issuer_role());
    let issuance = issued(&fixture, policy::short());

    assert_eq!(issuance.side(), policy::short());
    assert_eq!(issuance.max_order_notional(), MAX_ORDER_NOTIONAL);
    destroy(issuance);
    destroy(fixture);
}

#[test]
fun flat_seed_preflight_returns_authenticated_order_inputs() {
    let fixture = start(domain::vault_issuer_role());
    let issuance = issued(&fixture, policy::short());
    let observation = standard_observation(policy::long()).with_position_base(0).into_position_observation();

    let (target_notional, seed_position) = issuance.seed_terms(observation, SEED_RESERVE);

    assert_eq!(target_notional, SEED_NOTIONAL);
    assert_eq!(seed_position.base_price(), 1_000_000_000);
    assert_eq!(seed_position.collateral_price(), 1_000_000_000);
    assert_eq!(seed_position.lot_size(), LOT_SIZE);
    assert_eq!(seed_position.base(), 0);
    assert_eq!(seed_position.notional(), 0);
    destroy(issuance);
    destroy(fixture);
}

#[test]
fun initialization_strict_execution_uses_the_frozen_tolerance() {
    let fixture = start(domain::vault_issuer_role());
    let issuance = issued(&fixture, policy::long());

    issuance.assert_execution(1_000_000, 1_010_000);

    destroy(issuance);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy,
)]
fun initialization_strict_execution_rejects_one_unit_past_tolerance() {
    let fixture = start(domain::vault_issuer_role());
    let issuance = issued(&fixture, policy::long());

    issuance.assert_execution(1_000_000, 1_010_001);

    destroy(issuance);
    destroy(fixture);
}

#[test]
fun an_authorized_issuance_activates_into_the_issued_terms() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let expected_policy = standard_vault_policy();
    let (state, _) = activate_with(state::issue<Product>(&witness, expected_policy, MAX_ORDER_NOTIONAL, NAV_CAP), standard_observation(policy::long()), SEED_RESERVE);

    assert!(state.is_active_for_testing());
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    assert_eq!(state.vault_policy_for_testing(), expected_policy);
    assert_eq!(state.max_order_notional(), MAX_ORDER_NOTIONAL);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun issuance_requires_the_vault_issuer_role() {
    let fixture = start(domain::risk_admin_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);

    destroy(state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP));
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMaxOrderNotional, location = blast_boosts_core::state,
)]
fun max_order_notional_must_be_positive() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);

    destroy(state::issue<Product>(&witness, standard_vault_policy(), 0, NAV_CAP));
    destroy(fixture);
}

#[test]
fun max_order_notional_moves_both_directions_and_returns_the_previous_value() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let (mut state, _) = activate_with(state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP), standard_observation(policy::long()), SEED_RESERVE);

    assert_eq!(state.set_max_order_notional(1), MAX_ORDER_NOTIONAL);
    assert_eq!(state.set_max_order_notional(std::u64::max_value!()), 1);
    assert_eq!(state.max_order_notional(), std::u64::max_value!());

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EMaxOrderNotionalUnchanged,
    location = blast_boosts_core::state,
)]
fun max_order_notional_rejects_the_current_value() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let (mut state, _) = activate_with(state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP), standard_observation(policy::long()), SEED_RESERVE);

    state.set_max_order_notional(MAX_ORDER_NOTIONAL);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMaxOrderNotional, location = blast_boosts_core::state,
)]
fun max_order_notional_rejects_zero() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let (mut state, _) = activate_with(state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP), standard_observation(policy::long()), SEED_RESERVE);

    state.set_max_order_notional(0);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun active_state_begins_shutdown() {
    let fixture = start(domain::vault_issuer_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let (mut state, _) = activate_with(state::issue<Product>(&witness, standard_vault_policy(), MAX_ORDER_NOTIONAL, NAV_CAP), standard_observation(policy::long()), SEED_RESERVE);

    state.begin_shutdown();

    assert!(state.is_unwinding_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

// --- Initialization ---

#[test]
fun valid_long_seed_activates_and_records_only_the_reserve() {
    let fixture = start(domain::vault_issuer_role());
    let (state, seed_nav) = activate_with(issued(&fixture, policy::long()), standard_observation(policy::long()), SEED_RESERVE);

    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun valid_short_seed_activates() {
    let fixture = start(domain::vault_issuer_role());
    let (state, seed_nav) = activate_with(issued(&fixture, policy::short()), standard_observation(policy::short()), SEED_RESERVE);

    assert_eq!(seed_nav, SEED_NAV);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
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
    let fixture = start(domain::vault_issuer_role());
    let spec = standard_observation(policy::long())
        .with_venue_equity(NAV_CAP + SEED_RESERVE)
        .with_notional(2 * NAV_CAP);

    let (state, seed_nav) = activate_with(issued(&fixture, policy::long()), spec, SEED_RESERVE);
    assert_eq!(seed_nav, NAV_CAP);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun initialization_admits_both_healthy_leverage_boundaries() {
    let fixture = start(domain::vault_issuer_role());
    let (lower, _) = activate_with(
        issued(&fixture, policy::long()), standard_observation(policy::long()).with_notional(1_600_000), SEED_RESERVE,
    );
    let (upper, _) = activate_with(
        issued(&fixture, policy::long()), standard_observation(policy::long()).with_notional(2_600_000), SEED_RESERVE,
    );

    assert!(lower.is_active_for_testing());
    assert!(upper.is_active_for_testing());
    lower.destroy_for_testing();
    upper.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun initialization_rejects_a_reserve_above_equity() {
    initialize_once(
        standard_observation(policy::long()).with_venue_equity(SEED_RESERVE - 1),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNav, location = blast_boosts_core::state,
)]
fun initialization_rejects_zero_shareholder_nav() {
    initialize_once(
        standard_observation(policy::long()).with_venue_equity(SEED_RESERVE),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state,
)]
fun initialization_rejects_one_unit_above_the_nav_cap() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1)
            .with_position_base((2 * NAV_CAP + 2) * 1_000),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidInitializationObservation, location = blast_boosts_core::state,
)]
fun initialization_rejects_the_wrong_side() {
    initialize_once(
        standard_observation(policy::long()).with_observed_side(policy::short()),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_stale_base_price() {
    initialize_once(
        standard_observation(policy::long()).with_base_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EFuturePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_future_base_price() {
    initialize_once(
        standard_observation(policy::long()).with_base_publish_time_ms(102_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_low_confidence_base_price() {
    initialize_once(
        standard_observation(policy::long()).with_base_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_stale_collateral_price() {
    initialize_once(
        standard_observation(policy::long()).with_collateral_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EFuturePrice, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_future_collateral_price() {
    initialize_once(
        standard_observation(policy::long()).with_collateral_publish_time_ms(102_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_rejects_a_low_confidence_collateral_price() {
    initialize_once(
        standard_observation(policy::long()).with_collateral_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_rejects_mark_divergence() {
    initialize_once(
        standard_observation(policy::long()).with_mark_price(1_050_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy, location = blast_boosts_core::state,
)]
fun initialization_rejects_leverage_one_unit_below_healthy() {
    initialize_once(
        standard_observation(policy::long()).with_position_base(1_599_999_000),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy, location = blast_boosts_core::state,
)]
fun initialization_rejects_leverage_one_unit_above_healthy() {
    initialize_once(
        standard_observation(policy::long()).with_position_base(2_600_001_000),
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
    initialize_once(
        standard_observation(policy::long()).with_lot_size(100_000_000),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNav, location = blast_boosts_core::state,
)]
fun initialization_guard_order_checks_nav_before_base_freshness() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(SEED_RESERVE)
            .with_base_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_base_freshness_before_base_confidence() {
    initialize_once(
        standard_observation(policy::long())
            .with_base_publish_time_ms(69_999)
            .with_base_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_base_before_collateral_valuation() {
    initialize_once(
        standard_observation(policy::long())
            .with_base_confidence(10_000_001)
            .with_collateral_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStalePrice, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_collateral_freshness_before_confidence() {
    initialize_once(
        standard_observation(policy::long())
            .with_collateral_publish_time_ms(69_999)
            .with_collateral_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_collateral_confidence_before_mark() {
    initialize_once(
        standard_observation(policy::long())
            .with_collateral_confidence(10_000_001)
            .with_mark_price(1_050_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EMarkOracleDivergenceExceedsBound, location = blast_boosts_core::policy,
)]
fun initialization_guard_order_checks_mark_before_side() {
    initialize_once(
        standard_observation(policy::long())
            .with_mark_price(1_050_000_001)
            .with_observed_side(policy::short()),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state,
)]
fun initialization_guard_order_checks_nav_cap_before_leverage() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1)
            .with_position_base(SEED_BASE * 100),
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
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(700_000)
            .with_lot_size(100_000_000),
        policy::long(),
        SEED_RESERVE,
    );
}

// --- Per-Order Notional ---

#[test]
fun an_order_at_the_live_maximum_is_allowed() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::long());

    state.assert_order_notional_allowed(MAX_ORDER_NOTIONAL);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EOrderNotionalExceedsMaximum, location = blast_boosts_core::state,
)]
fun an_order_one_unit_above_the_live_maximum_is_rejected() {
    let fixture = start(domain::vault_issuer_role());
    let state = initialized_state(&fixture, policy::long());

    state.assert_order_notional_allowed(MAX_ORDER_NOTIONAL + 1);

    state.destroy_for_testing();
    destroy(fixture);
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
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());

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
    destroy(fixture);
}

/// Two exhausting costs accumulate one deficit, and an over-repaying credit
/// splits between NAV and the reserve.
#[test]
fun deficits_accumulate_and_an_over_repaying_credit_splits() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());

    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_cost(120_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[SEED_RESERVE, 20_000, 0]);
    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_cost(5_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 5_000, 0]);
    assert_eq!(state.uncovered_deficit(), 25_000);

    let (absorbed, uncovered, restored) = state.settle_funding(observation::funding_credit(40_000));
    assert_eq!(vector[absorbed, uncovered, restored], vector[0, 0, 25_000]);
    assert_eq!(vector[state.maintenance_reserve(), state.uncovered_deficit()], vector[15_000, 0]);

    state.destroy_for_testing();
    destroy(fixture);
}

// --- Reserve Ceiling ---

/// The seed reserve may not exceed the ceiling for the opening notional.
#[test]
#[expected_failure(abort_code = errors::ESeedReserveAboveCap, location = blast_boosts_core::state)]
fun a_seed_reserve_above_the_ceiling_cannot_activate() {
    let fixture = start(domain::vault_issuer_role());
    let (state, _) = activate_with(capped_issuance(&fixture, 400), standard_observation(policy::long()), SEED_RESERVE);
    state.destroy_for_testing();
    destroy(fixture);
}

/// A seed reserve exactly at the ceiling activates; the ceiling is inclusive.
#[test]
fun a_seed_reserve_at_the_ceiling_activates() {
    let fixture = start(domain::vault_issuer_role());
    let (state, seed_nav) = activate_with(capped_issuance(&fixture, 500), standard_observation(policy::long()), SEED_RESERVE);
    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(state.maintenance_reserve(), SEED_RESERVE);
    state.destroy_for_testing();
    destroy(fixture);
}

/// A redemption that shrinks notional below what the reserve needs releases the
/// excess to holders: the stored reserve drops to the ceiling, the required venue
/// equity is unchanged because nothing moved, and NAV per share rises.
#[test]
fun redemption_releases_reserve_above_the_ceiling_for_the_smaller_position() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = capped_initialized_state(&fixture, 500);
    let plan = state.prepare_redemption(
        standard_observation(policy::long()).into_position_observation(),
        500_000, 1_000_000, 499_500, REFERENCE_TIME_MS,
    );
    let (net, admin, fee, buffer) = state.complete_redemption(
        plan,
        standard_observation(policy::long())
            .with_venue_equity(1_102_000)
            .with_position_base(1_000_000_000)
            .into_position_observation(),
        REFERENCE_TIME_MS,
    );
    let final_equity = 1_102_000 - net - admin;
    // Same payout and physical equity as with a wide ceiling.
    assert_eq!(vector[net, admin, fee, buffer, final_equity], vector[499_500, 0, 500, 500, 602_500]);
    // The ceiling for 1_000_000 of notional at 5% is 50_000; the other 50_500 is NAV now.
    assert_eq!(state.maintenance_reserve(), 50_000);
    assert_eq!(final_equity - state.maintenance_reserve(), 552_500);
    state.destroy_for_testing();
    destroy(fixture);
}

/// A reserve left above the ceiling by a funding credit is priced as released
/// before a mint, so the newcomer pays the higher NAV per share and the release
/// stays with the holders at the checkpoint.
#[test]
fun a_mint_prices_shares_after_releasing_reserve_above_the_ceiling() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = capped_initialized_state(&fixture, 500);
    // Funding credits carry no observation, so the reserve grows past the 100_000 ceiling.
    state.settle_funding(observation::funding_credit(50_000));
    assert_eq!(state.maintenance_reserve(), 150_000);

    let before = standard_observation(policy::long()).with_venue_equity(1_150_000);
    let plan = state.prepare_mint(before.into_position_observation(), 1_000_000, 1_000_000, 1, REFERENCE_TIME_MS);
    // Sized against NAV 1_050_000, not 1_000_000: 200_000 * 999_000 / 1_050_000 floored to the lot.
    // 2e9 * 999_000 / 1_050_000 floored to the lot.
    assert_eq!(plan.base_to_buy(), 1_902_857_000);
    let (shares, contribution, _, _, _) = state.complete_mint(
        plan,
        before
            .with_venue_equity(2_150_000)
            .with_position_base(SEED_BASE + 1_902_857_000)
            .into_position_observation(),
        REFERENCE_TIME_MS,
    );
    // 1_000_000 * 999_000 / 1_050_000, not the 999_000 a pre-release price would mint.
    assert_eq!(vector[shares, contribution], vector[951_428, 999_000]);
    // The fee rebuilds the reserve from the ceiling, not from the stale 150_000.
    assert_eq!(state.maintenance_reserve(), 101_000);
    state.destroy_for_testing();
    destroy(fixture);
}

/// A donation is never rejected: the part above the ceiling counts as NAV.
#[test]
fun a_donation_above_the_ceiling_is_accepted_and_the_excess_is_nav() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = capped_initialized_state(&fixture, 500);
    state.donate(
        standard_observation(policy::long()).with_venue_equity(SEED_VENUE_EQUITY + 70_000).into_position_observation(),
        70_000, REFERENCE_TIME_MS,
    );
    assert_eq!(state.maintenance_reserve(), 100_000);
    state.destroy_for_testing();
    destroy(fixture);
}

/// A flat position has nothing to size the ceiling against and keeps its reserve.
#[test]
fun a_flat_position_keeps_the_reserve_for_the_position_that_reopens() {
    let fixture = start(domain::vault_issuer_role());
    let mut state = capped_initialized_state(&fixture, 500);
    let flat = standard_observation(policy::long()).with_position_base(0);
    state.donate(flat.with_venue_equity(SEED_VENUE_EQUITY + 70_000).into_position_observation(), 70_000, REFERENCE_TIME_MS);
    assert_eq!(state.maintenance_reserve(), 170_000);
    state.destroy_for_testing();
    destroy(fixture);
}

// === Fixture Setup ===

fun rebalance_state(fixture: &Fixture, side: PositionSide): State<Product> {
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let (state, _, _) = state::issue<Product>(&witness, vault_policy(side), 2_000_000, NAV_CAP)
        .activate(rebalance_observation(SEED_VENUE_EQUITY, SEED_NOTIONAL, side), SEED_RESERVE, 9, 6, REFERENCE_TIME_MS);
    state
}

fun rebalance_observation(equity: u64, notional: u64, side: PositionSide): PositionObservation {
    let mut spec = standard_observation(side);
    spec.venue_equity = equity;
    spec.position_base = notional * 1_000;
    spec.into_position_observation()
}

fun rebalance_endpoint(notional: u64) {
    let fixture = start(domain::vault_issuer_role());
    let state = rebalance_state(&fixture, policy::long());
    let plan = state.prepare_rebalance(rebalance_observation(1_100_000, notional, policy::long()), 10, REFERENCE_TIME_MS);
    state.complete_rebalance(plan);
    state.destroy_for_testing();
    destroy(fixture);
}

fun start(roles: u64): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (super_admin_cap, mut authority) =
        domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        roles,
        ISSUER,
        scenario.ctx(),
    );

    scenario.next_tx(ISSUER);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_BOOSTS_CORE>>();

    Fixture { scenario, authority, super_admin_cap, admin_cap }
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
        MIN_EXPOSURE_LOTS,
        MAX_RESERVE_BPS,
    )
}

/// A long issuance whose reserve ceiling is `max_reserve_bps` of notional.
fun capped_issuance(fixture: &Fixture, max_reserve_bps: u64): Issuance<Product> {
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let vault_policy = policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(16_000, 20_000, 26_000, 30_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500),
        10,
        10,
        MIN_EXPOSURE_LOTS,
        max_reserve_bps,
    );

    state::issue<Product>(&witness, vault_policy, MAX_ORDER_NOTIONAL, NAV_CAP)
}

fun capped_initialized_state(fixture: &Fixture, max_reserve_bps: u64): State<Product> {
    let (state, _) = activate_with(capped_issuance(fixture, max_reserve_bps), standard_observation(policy::long()), SEED_RESERVE);
    state
}

fun issued(fixture: &Fixture, side: PositionSide): Issuance<Product> {
    let witness = fixture.authority.sign_in(&fixture.admin_cap);

    state::issue<Product>(&witness, vault_policy(side), MAX_ORDER_NOTIONAL, NAV_CAP)
}

/// Activates the issuance on `spec`, at the fixture's decimals and clock; returns the state and seed NAV.
fun activate_with(self: Issuance<Product>, spec: ObservationSpec, seed_reserve: u64): (State<Product>, u64) {
    let (state, seed_nav, _) = self.activate(spec.into_position_observation(), seed_reserve, 9, 6, REFERENCE_TIME_MS);
    (state, seed_nav)
}

fun initialized_state(fixture: &Fixture, side: PositionSide): State<Product> {
    let (state, seed_nav) = activate_with(issued(fixture, side), standard_observation(side), SEED_RESERVE);
    assert_eq!(seed_nav, SEED_NAV);

    state
}

fun initialize_once(spec: ObservationSpec, side: PositionSide, seed_reserve: u64) {
    let fixture = start(domain::vault_issuer_role());
    let (state, _) = activate_with(issued(&fixture, side), spec, seed_reserve);

    state.destroy_for_testing();
    destroy(fixture);
}

fun assert_funding_settlement(
    settlement: FundingSettlement,
    expected_absorbed: u64,
    expected_uncovered: u64,
    expected_reserve: u64,
) {
    let fixture = start(domain::vault_issuer_role());
    let mut state = initialized_state(&fixture, policy::long());

    let (absorbed, uncovered, restored) = state.settle_funding(settlement);

    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, expected_uncovered);
    assert_eq!(restored, 0);
    assert_eq!(state.uncovered_deficit(), expected_uncovered);
    assert_eq!(state.maintenance_reserve(), expected_reserve);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
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
        base_publish_time_ms,
        collateral_price,
        collateral_confidence,
        collateral_publish_time_ms,
        mark_price,
    } = self;

    observation::new_position(
        venue_equity,
        position_base,
        lot_size,
        observed_side,
        observation::new_price(base_price, base_confidence, base_publish_time_ms),
        observation::new_price(
            collateral_price,
            collateral_confidence,
            collateral_publish_time_ms,
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

fun with_observed_side(mut self: ObservationSpec, observed_side: PositionSide): ObservationSpec {
    self.observed_side = observed_side;
    self
}

fun with_base_confidence(mut self: ObservationSpec, base_confidence: u64): ObservationSpec {
    self.base_confidence = base_confidence;
    self
}

fun with_base_publish_time_ms(
    mut self: ObservationSpec,
    base_publish_time_ms: u64,
): ObservationSpec {
    self.base_publish_time_ms = base_publish_time_ms;
    self
}

fun with_collateral_confidence(
    mut self: ObservationSpec,
    collateral_confidence: u64,
): ObservationSpec {
    self.collateral_confidence = collateral_confidence;
    self
}

fun with_collateral_publish_time_ms(
    mut self: ObservationSpec,
    collateral_publish_time_ms: u64,
): ObservationSpec {
    self.collateral_publish_time_ms = collateral_publish_time_ms;
    self
}

fun with_mark_price(mut self: ObservationSpec, mark_price: u64): ObservationSpec {
    self.mark_price = mark_price;
    self
}

// === Imports ===

use blast_admin::acl::{Authority, SuperAdminCap, AdminCap};

use blast_boosts_core::{
    accounting_math,
    domain_fixture,
    errors,
    lifecycle,
    observation::{Self, FundingSettlement, PositionObservation},
    policy::{Self, PositionSide, VaultPolicy},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    state::{Self, Issuance, State},
};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};
