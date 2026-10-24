// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::errors_tests;

// === Tests ===

// Every code is pinned so a renumbering is a deliberate, reviewed edit.

#[test]
/// The registry runs from zero without gaps, in source order.
fun error_codes_run_from_zero_without_gaps() {
    let codes = vector[
        errors::zero_amount!(),
        errors::invalid_fee_bps!(),
        errors::invalid_nav!(),
        errors::invalid_share_supply!(),
        errors::invalid_share_amount!(),
        errors::nonpositive_contribution!(),
        errors::zero_shares_out!(),
        errors::nonpositive_gross!(),
        errors::zero_net_payout!(),
        errors::invalid_target_leverage_bps!(),
        errors::invalid_lot_size!(),
        errors::invalid_base!(),
        errors::order_below_min_lots!(),
        errors::redemption_under_reduced!(),
        errors::redemption_over_reduced!(),
        errors::arithmetic_overflow!(),
        errors::maintenance_reserve_exceeds_equity!(),
        errors::invalid_lifecycle_transition!(),
        errors::operation_not_permitted_in_lifecycle!(),
        errors::mint_base_above_bound!(),
        errors::mint_base_below_bound!(),
        errors::invalid_min_order_lots!(),
        errors::invalid_rebalance_policy!(),
        errors::invalid_nav_cap!(),
        errors::invalid_max_price_age!(),
        errors::invalid_max_confidence_bps!(),
        errors::invalid_max_mark_divergence_bps!(),
        errors::stale_price!(),
        errors::future_price!(),
        errors::invalid_price!(),
        errors::confidence_exceeds_bound!(),
        errors::mark_oracle_divergence_exceeds_bound!(),
        errors::invalid_max_slippage_bps!(),
        errors::invalid_emergency_max_slippage_bps!(),
        errors::invalid_min_leverage_improvement_bps!(),
        errors::shares_out_below_minimum!(),
        errors::nav_cap_exceeded!(),
        errors::execution_outside_max_slippage!(),
        errors::invalid_freshness_window!(),
        errors::invalid_max_order_notional!(),
        errors::max_order_notional_unchanged!(),
        errors::invalid_observation_lot_size!(),
        errors::invalid_position_observation!(),
        errors::order_notional_exceeds_maximum!(),
        errors::invalid_initialization_observation!(),
        errors::initialization_leverage_unhealthy!(),
        errors::initialization_base_below_min_order!(),
        errors::fee_cap_exceeded!(),
        errors::fee_settings_unchanged!(),
        errors::mint_outside_rebalance_band!(),
        errors::active_checkpoint_changed!(),
        errors::active_fill_incomplete!(),
        errors::active_leverage_above_cap!(),
        errors::redemption_output_below_minimum!(),
        errors::rebalance_inside_band!(),
        errors::rebalance_no_progress!(),
        errors::venue_fee_unusable!(),
        errors::invalid_asset_decimals!(),
        errors::nav_cap_unchanged!(),
        errors::invalid_max_reserve_bps!(),
        errors::seed_reserve_above_cap!(),
        errors::invariant_violated!(),
        errors::invalid_tick_size!(),
        errors::order_cap_below_minimum!(),
        errors::profit_realization_not_needed!(),
        errors::profit_realization_uneconomic!(),
        errors::initial_margin_headroom!(),
        errors::rebalance_not_actionable!(),
        errors::rebalance_outside_band!(),
    ];

    assert_eq!(codes.length(), 69);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_boosts_core::errors;

use std::unit_test::assert_eq;
