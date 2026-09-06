#[test_only]
module blast_leverage_series_one::errors_tests;

use std::unit_test::assert_eq;

// === Tests ===

/// Pins every published abort code so a later module cannot renumber the registry.
#[test]
fun package_error_registry_is_stable() {
    assert_eq!(blast_leverage_series_one::errors::zero_amount!(), 0);
    assert_eq!(blast_leverage_series_one::errors::invalid_fee_bps!(), 1);
    assert_eq!(blast_leverage_series_one::errors::invalid_nav!(), 2);
    assert_eq!(blast_leverage_series_one::errors::invalid_share_supply!(), 3);
    assert_eq!(blast_leverage_series_one::errors::invalid_share_amount!(), 4);
    assert_eq!(blast_leverage_series_one::errors::nonpositive_contribution!(), 5);
    assert_eq!(blast_leverage_series_one::errors::zero_shares_out!(), 6);
    assert_eq!(blast_leverage_series_one::errors::nonpositive_gross!(), 7);
    assert_eq!(blast_leverage_series_one::errors::zero_net_payout!(), 8);
    assert_eq!(
        blast_leverage_series_one::errors::invalid_target_leverage_bps!(),
        9,
    );
    assert_eq!(blast_leverage_series_one::errors::invalid_lot_size!(), 10);
    assert_eq!(blast_leverage_series_one::errors::invalid_base_exposure!(), 11);
    assert_eq!(blast_leverage_series_one::errors::sub_lot_exposure_delta!(), 12);
    assert_eq!(
        blast_leverage_series_one::errors::redemption_under_reduced!(),
        13,
    );
    assert_eq!(blast_leverage_series_one::errors::redemption_over_reduced!(), 14);
    assert_eq!(blast_leverage_series_one::errors::arithmetic_overflow!(), 15);
    assert_eq!(
        blast_leverage_series_one::errors::maintenance_reserve_exceeds_equity!(),
        16,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
        17,
    );
    assert_eq!(
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
        18,
    );
    assert_eq!(blast_leverage_series_one::errors::mint_over_exposed!(), 19);
    assert_eq!(blast_leverage_series_one::errors::mint_under_exposed!(), 20);
    assert_eq!(
        blast_leverage_series_one::errors::invalid_min_exposure_lots!(),
        21,
    );
    assert_eq!(blast_leverage_series_one::errors::invalid_rebalance_policy!(), 22);
    assert_eq!(blast_leverage_series_one::errors::invalid_series_nav_cap!(), 23);
    assert_eq!(blast_leverage_series_one::errors::invalid_max_price_age!(), 24);
    assert_eq!(
        blast_leverage_series_one::errors::invalid_max_confidence_bps!(),
        25,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_max_mark_divergence_bps!(),
        26,
    );
    assert_eq!(blast_leverage_series_one::errors::stale_valuation!(), 27);
    assert_eq!(blast_leverage_series_one::errors::future_valuation!(), 28);
    assert_eq!(blast_leverage_series_one::errors::invalid_valuation_price!(), 29);
    assert_eq!(
        blast_leverage_series_one::errors::confidence_exceeds_bound!(),
        30,
    );
    assert_eq!(
        blast_leverage_series_one::errors::mark_index_divergence_exceeds_bound!(),
        31,
    );
    assert_eq!(
        blast_leverage_series_one::errors::mint_contribution_exceeds_bound!(),
        32,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_max_mint_contribution_divergence_bps!(),
        33,
    );
    assert_eq!(blast_leverage_series_one::errors::invalid_bounded_value!(), 34);
    assert_eq!(
        blast_leverage_series_one::errors::invalid_strict_tolerance_bps!(),
        35,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_emergency_tolerance_bps!(),
        36,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_minimum_improvement_bps!(),
        37,
    );
}

/// Pins the Series gate codes added by the 2026-09-03 remediation.
#[test]
fun series_gate_error_registry_is_stable() {
    assert_eq!(
        blast_leverage_series_one::errors::redemption_gross_exceeds_bound!(),
        55,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_max_redemption_gross_divergence_bps!(),
        56,
    );
    assert_eq!(blast_leverage_series_one::errors::shares_out_below_minimum!(), 57);
    assert_eq!(
        blast_leverage_series_one::errors::insufficient_leverage_improvement!(),
        58,
    );
    assert_eq!(blast_leverage_series_one::errors::series_nav_cap_exceeded!(), 59);
    assert_eq!(
        blast_leverage_series_one::errors::execution_outside_tolerance!(),
        60,
    );
    assert_eq!(blast_leverage_series_one::errors::invalid_freshness_window!(), 61);
}

/// Pins the Series state-construction error in its reserved range.
#[test]
fun state_error_registry_is_stable() {
    assert_eq!(blast_leverage_series_one::errors::invalid_max_order_notional!(), 64);
    assert_eq!(blast_leverage_series_one::errors::max_order_notional_unchanged!(), 74);
}

/// Pins the operation-observation codes appended after the state range.
#[test]
fun observation_error_registry_is_stable() {
    assert_eq!(blast_leverage_series_one::errors::invalid_observation_price!(), 75);
    assert_eq!(blast_leverage_series_one::errors::invalid_observation_lot_size!(), 76);
    assert_eq!(blast_leverage_series_one::errors::invalid_position_observation!(), 77);
}

/// Pins the activation and per-order State diagnostics appended after observations.
#[test]
fun state_kernel_error_registry_is_stable() {
    assert_eq!(
        blast_leverage_series_one::errors::order_notional_exceeds_maximum!(),
        78,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_initialization_observation!(),
        79,
    );
    assert_eq!(
        blast_leverage_series_one::errors::initialization_orders_not_empty!(),
        80,
    );
    assert_eq!(
        blast_leverage_series_one::errors::initialization_venue_not_operational!(),
        81,
    );
    assert_eq!(
        blast_leverage_series_one::errors::initialization_checkpoint_dirty!(),
        82,
    );
    assert_eq!(
        blast_leverage_series_one::errors::initialization_margin_unsafe!(),
        83,
    );
    assert_eq!(
        blast_leverage_series_one::errors::initialization_leverage_unhealthy!(),
        84,
    );
    assert_eq!(
        blast_leverage_series_one::errors::initialization_exposure_below_minimum!(),
        85,
    );
    assert_eq!(blast_leverage_series_one::errors::fee_cap_exceeded!(), 86);
    assert_eq!(blast_leverage_series_one::errors::fee_settings_unchanged!(), 87);
    assert_eq!(blast_leverage_series_one::errors::user_fee_limit_exceeded!(), 88);
    assert_eq!(blast_leverage_series_one::errors::mint_outside_public_band!(), 89);
    assert_eq!(blast_leverage_series_one::errors::active_checkpoint_changed!(), 90);
    assert_eq!(blast_leverage_series_one::errors::active_fill_incomplete!(), 91);
    assert_eq!(blast_leverage_series_one::errors::active_leverage_above_cap!(), 92);
    assert_eq!(blast_leverage_series_one::errors::active_observation_unusable!(), 93);
    assert_eq!(blast_leverage_series_one::errors::redemption_output_below_minimum!(), 94);
    assert_eq!(blast_leverage_series_one::errors::buffer_release_exceeds_balance!(), 95);
    assert_eq!(blast_leverage_series_one::errors::rebalance_inside_public_band!(), 96);
    assert_eq!(blast_leverage_series_one::errors::rebalance_no_progress!(), 97);
    assert_eq!(blast_leverage_series_one::errors::venue_fee_unusable!(), 98);
}
