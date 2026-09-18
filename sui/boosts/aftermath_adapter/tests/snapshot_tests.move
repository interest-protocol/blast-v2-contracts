#[test_only]
/// Literal-vector tests for authenticated Aftermath snapshot normalization.
module blast_boosts_aftermath::snapshot_tests;

// === Tests ===

#[test]
fun signed_funding_cost_crosses_allocated_zero_without_becoming_unresolved() {
    let before = checkpoint(10, 5, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 3, 7, 8, 7, 8, 9);
    let change = snapshot::classify_signed_funding_for_testing(&before, &after, false, 5, true, 3);
    let (has, cost, raw, _, clean) = change.funding_change_fields();
    assert!(has && cost && clean);
    assert_eq!(raw, 8);
}

#[test]
fun signed_funding_credit_crosses_allocated_zero_without_becoming_unresolved() {
    let before = checkpoint(10, 5, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 3, 7, 8, 7, 8, 9);
    let change = snapshot::classify_signed_funding_for_testing(&before, &after, true, 5, false, 3);
    let (has, cost, raw, _, clean) = change.funding_change_fields();
    assert!(has && !cost && clean);
    assert_eq!(raw, 8);
}

#[test]
fun signed_funding_less_negative_allocation_is_a_credit() {
    let before = checkpoint(10, 5, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 3, 7, 8, 7, 8, 9);
    let change = snapshot::classify_signed_funding_for_testing(&before, &after, true, 5, true, 3);
    let (has, cost, raw, _, clean) = change.funding_change_fields();
    assert!(has && !cost && clean);
    assert_eq!(raw, 2);
}

#[test]
fun zero_net_funding_refresh_is_clean_but_not_an_identical_checkpoint() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 1_000, 7, 8, 7, 8, 9);
    assert!(!snapshot::checkpoint_unchanged(&before, &after));
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 0).is_unchanged_for_testing());
    assert!(snapshot::classify_preexisting_funding_for_testing(&before, &after).is_unchanged_for_testing());
}

#[test]
fun unchanged_checkpoint_is_not_funding() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = before;

    assert!(snapshot::classify_change_for_testing(&before, &after).is_unchanged_for_testing());
}

#[test]
fun exact_positive_funding_transition_is_credit() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 2_000, 7, 8, 7, 8, 9);

    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 1_000).is_credit_for_testing());
}

#[test]
fun funding_settlement_keeps_the_exact_raw_candidate_amount() {
    let before = checkpoint(10, 4_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 5_337, 7, 8, 7, 8, 9);
    let change = snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 1_337);

    assert_eq!(change.funding_amount_for_testing(), 1_337);
}

#[test]
fun exact_negative_funding_transition_is_cost() {
    let before = checkpoint(10, 2_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 1_000, 7, 8, 7, 8, 9);

    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &after, true, 1_000).is_cost_for_testing());
}

#[test]
fun funding_settlement_refreshes_both_snapshots_for_short_positions() {
    let before = checkpoint(10, 2_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 3_000, 7, 8, 7, 8, 9);

    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 1_000).is_credit_for_testing());
}

#[test]
fun wrong_funding_delta_and_inactive_snapshot_transition_are_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let wrong_delta = checkpoint(10, 2_000, 7, 6, 7, 8, 9);
    let wrong_side = checkpoint(10, 2_000, 5, 8, 7, 8, 9);

    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &wrong_delta, false, 999).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &wrong_side, false, 1_000).is_unexpected_for_testing());
}

#[test]
fun collateral_delta_without_a_funding_snapshot_transition_is_unexpected() {
    let before = checkpoint(10, 1_000, 7, 8, 7, 8, 9);
    let after = checkpoint(10, 2_000, 7, 8, 7, 8, 9);

    assert!(snapshot::classify_change_for_testing(&before, &after).is_unexpected_for_testing());
}

#[test]
fun free_collateral_change_is_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = checkpoint(11, 1_000, 5, 6, 7, 8, 9);

    assert!(snapshot::classify_change_for_testing(&before, &after).is_unexpected_for_testing());
}

#[test]
fun base_quote_and_pending_order_changes_are_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let base_changed = venue_account::checkpoint_for_testing(10, 1_000, 12, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let quote_changed = venue_account::checkpoint_for_testing(10, 1_000, 1, 13, 3, 4, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let order_changed = venue_account::checkpoint_for_testing(10, 1_000, 1, 2, 3, 4, 7, 8, 9, 10, 11, 13, 13, false, 14, 15, 16);

    assert!(snapshot::classify_change_for_testing(&before, &base_changed).is_unexpected_for_testing());
    assert!(snapshot::classify_change_for_testing(&before, &quote_changed).is_unexpected_for_testing());
    assert!(snapshot::classify_change_for_testing(&before, &order_changed).is_unexpected_for_testing());
}

#[test]
fun every_checkpoint_guard_field_blocks_an_otherwise_matching_funding_delta() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let base_funding_after = checkpoint(10, 2_000, 7, 8, 7, 8, 9);
    let pending_ask_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 99, 11, 12, 13, false, 14, 15, 16);
    let pending_bid_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 99, 12, 13, false, 14, 15, 16);
    let pause_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 99, false, 14, 15, 16);
    let frozen_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, true, 14, 15, 16);
    let position_imr_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, false, 99, 15, 16);
    let market_imr_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 99, 16);
    let market_mmr_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 99);

    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &base_funding_after, false, 1_000).is_credit_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &pending_ask_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &pending_bid_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &pause_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &frozen_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &position_imr_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &market_imr_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &market_mmr_changed, false, 1_000).is_unexpected_for_testing());
}

#[test]
fun market_rate_or_lot_change_blocks_funding_even_when_the_delta_matches() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let market_rate_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 99, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let lot_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 99, 10, 11, 12, 13, false, 14, 15, 16);

    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &market_rate_changed, false, 1_000).is_unexpected_for_testing());
    assert!(snapshot::classify_change_with_candidate_for_testing(&before, &lot_changed, false, 1_000).is_unexpected_for_testing());
}

#[test]
fun fixed_normalization_keeps_base_at_nine_and_quote_at_six_decimals() {
    // 1.234567890123 fixed units becomes 1.234567890 base units but
    // 1.234567 collateral/quote units: the scales differ by exactly 1,000.
    let raw = 1_234_567_890_123_000_000u256;
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(raw, 9, false), 1_234_567_890);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(raw, 6, false), 1_234_567);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(raw, 6, true), 1_234_568);
}

#[test]
fun fixed_negative_liability_and_absolute_risk_round_against_the_vault() {
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000_000u256, 6, false), 1);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000_000u256, 6, true), 1);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000_001u256, 6, false), 1);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000_001u256, 6, true), 2);
}

#[test]
fun pyth_price_rounds_down_and_confidence_rounds_up_at_a_remainder() {
    // 12345 × 10^-13 normalizes to 1.2345 at 9 decimals.
    let (value_1, ok_1) = snapshot::normalize_pyth_for_testing(12_345, true, 13, false);
    assert_eq!(value_1, 1);
    assert!(ok_1);
    let (value_2, ok_2) = snapshot::normalize_pyth_for_testing(12_345, true, 13, true);
    assert_eq!(value_2, 2);
    assert!(ok_2);
    let (value_3, ok_3) = snapshot::normalize_pyth_for_testing(1, true, 13, true);
    assert_eq!(value_3, 1);
    assert!(ok_3);
}

#[test]
fun pyth_positive_exponent_and_seconds_conversion_are_literal() {
    let (value_4, ok_4) = snapshot::normalize_pyth_for_testing(42, false, 2, false);
    assert_eq!(value_4, 4_200_000_000_000);
    assert!(ok_4);
    let (value_5, ok_5) = snapshot::seconds_to_millis_for_testing(1_700_000_000);
    assert_eq!(value_5, 1_700_000_000_000);
    assert!(ok_5);
}

#[test]
fun health_pyth_normalization_preserves_unrepresentable_values_as_invalid() {
    let (exponent_value, exponent_valid) =
        snapshot::normalize_pyth_for_testing(1, false, 19, false);
    let (width_value, width_valid) = snapshot::normalize_pyth_for_testing(
        std::u64::max_value!(),
        false,
        9,
        false,
    );

    assert_eq!(exponent_value, 0);
    assert!(!exponent_valid);
    assert_eq!(width_value, 0);
    assert!(!width_valid);
}

#[test]
fun health_feed_and_timestamp_width_failures_are_invalid_not_aborts() {
    let (feed, feed_valid) = snapshot::normalize_feed_for_testing(
        (std::u64::max_value!() as u128) + 1,
    );
    let (timestamp, timestamp_valid) = snapshot::seconds_to_millis_for_testing(
        std::u64::max_value!() / 1_000 + 1,
    );

    assert_eq!(feed, 0);
    assert!(!feed_valid);
    assert_eq!(timestamp, 0);
    assert!(!timestamp_valid);
}

#[test]
fun stablecoin_depeg_and_minimum_lot_vectors_keep_the_venue_scales() {
    // Pyth -9 inputs are already in adapter price units: $0.95 remains exact.
    let (value_6, ok_6) = snapshot::normalize_pyth_for_testing(950_000_000, true, 9, false);
    assert_eq!(value_6, 950_000_000);
    assert!(ok_6);
    // One minimum base lot and one quote micro-unit remain distinct scales.
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000, 9, false), 1);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000_000, 6, false), 1);
}

#[test]
fun usd_values_convert_to_collateral_units_at_the_authenticated_depeg_price() {
    // $1 converts to 1.052631578947368421 collateral at $0.95; credits floor
    // and costs ceil at the raw IFixed unit.
    let (value_7, ok_7) = snapshot::usd_fixed_to_collateral_for_testing(1_000_000_000_000_000_000, 950_000_000_000_000_000, false);
    assert_eq!(value_7, 1_052_631_578_947_368_421);
    assert!(ok_7);
    let (value_8, ok_8) = snapshot::usd_fixed_to_collateral_for_testing(1_000_000_000_000_000_000, 950_000_000_000_000_000, true);
    assert_eq!(value_8, 1_052_631_578_947_368_422);
    assert!(ok_8);
    // $1.50 notional at $1.20 collateral is exactly 1.25 collateral.
    let (value_9, ok_9) = snapshot::usd_fixed_to_collateral_for_testing(1_500_000_000_000_000_000, 1_200_000_000_000_000_000, true);
    assert_eq!(value_9, 1_250_000_000_000_000_000);
    assert!(ok_9);
}

#[test]
fun margin_safety_is_below_equal_and_above_the_named_requirement() {
    assert!(!snapshot::margin_safe_for_testing(true, 999, 1));
    assert!(snapshot::margin_safe_for_testing(false, 0, 0));
    assert!(!snapshot::margin_safe_for_testing(false, 0, 1));
    assert!(!snapshot::margin_safe_for_testing(false, 99, 100));
    assert!(snapshot::margin_safe_for_testing(false, 100, 100));
    assert!(snapshot::margin_safe_for_testing(false, 101, 100));
}

#[test]
fun sign_coherence_covers_long_short_flat_and_all_bad_combinations() {
    assert!(snapshot::position_signs_coherent_for_testing(false, true, false, false, true));
    assert!(snapshot::position_signs_coherent_for_testing(true, false, false, false, false));
    assert!(snapshot::position_signs_coherent_for_testing(false, false, true, true, true));
    assert!(!snapshot::position_signs_coherent_for_testing(false, false, false, false, true));
    assert!(!snapshot::position_signs_coherent_for_testing(true, true, false, false, false));
    assert!(!snapshot::position_signs_coherent_for_testing(false, true, true, false, true));
    assert!(!snapshot::position_signs_coherent_for_testing(true, false, false, false, true));
}

#[test]
fun health_usd_conversion_keeps_the_same_max_width_input_as_an_invalid_fact() {
    let (value, valid) = snapshot::usd_fixed_to_collateral_for_testing(
        57896044618658097595993403267027758503064007324132374166459015334359435960541,
        499_999_999_999_999_999,
        false,
    );
    assert_eq!(value, 0);
    assert!(!valid);
}

#[test]
fun health_mark_normalization_preserves_an_unrepresentable_mark_as_invalid() {
    let raw = ((std::u64::max_value!() as u256) + 1) * 1_000_000_000;
    let (mark, valid) = snapshot::normalize_mark_for_testing(raw);

    assert_eq!(mark, 0);
    assert!(!valid);
}

#[test]
fun negative_allocated_collateral_is_a_liability_not_an_invalid_observation() {
    let (equity, valid) = snapshot::signed_equity_for_testing(
        10, true, 2_000_000_000_001, false, 5_000_000_000_000,
        1_000_000_000_000_000_000,
    );
    assert!(valid);
    // Round the liability up and the favorable PnL down.
    assert_eq!(equity, 12);
    let (value_10, ok_10) = snapshot::signed_equity_for_testing(
        0, true, 2_000_000_000_000, false, 5_000_000_000_000,
        1_000_000_000_000_000_000,
    );
    assert_eq!(value_10, 3);
    assert!(ok_10);
}

#[test]
fun negative_allocated_collateral_and_negative_pnl_cannot_create_equity() {
    let (equity, valid) = snapshot::signed_equity_for_testing(
        4, true, 2_000_000_000_000, true, 3_000_000_000_000,
        1_000_000_000_000_000_000,
    );
    assert!(!valid);
    assert_eq!(equity, 0);
}

#[test]
fun negative_pnl_equity_accepts_the_largest_u64_net_value() {
    let (equity, valid) = snapshot::signed_equity_for_testing(
        std::u64::max_value!(),
        false,
        1_000_000_000_000,
        true,
        1_000_000_000_000,
        1_000_000_000_000_000_000,
    );

    assert_eq!(equity, std::u64::max_value!());
    assert!(valid);
}

#[test]
fun health_negative_pnl_equity_rejects_the_first_net_value_above_u64() {
    let (equity, valid) = snapshot::signed_equity_for_testing(
        std::u64::max_value!(),
        false,
        2_000_000_000_000,
        true,
        1_000_000_000_000,
        1_000_000_000_000_000_000,
    );

    assert_eq!(equity, 0);
    assert!(!valid);
}

#[test]
fun usd_round_up_accepts_the_largest_representable_result_and_refuses_one_more() {
    let (value_11, ok_11) = snapshot::usd_fixed_to_collateral_for_testing(
            115792089237316195307778895771371712429698999656952656186187599342272565600477,
            999_999_999_999_999_999,
            true,
        );
    assert_eq!(value_11, std::u256::max_value!());
    assert!(ok_11);
    let (value_12, ok_12) = snapshot::usd_fixed_to_collateral_for_testing(
            115792089237316195307778895771371712429698999656952656186187599342272565600478,
            999_999_999_999_999_999,
            true,
        );
    assert_eq!(value_12, 0);
    assert!(!ok_12);
}

// === Test Helpers ===

fun checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
): Checkpoint {
    venue_account::checkpoint_for_testing(
        free_collateral,
        allocated_collateral,
        1,
        2,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        10,
        11,
        12,
        13,
        false,
        14,
        15,
        16,
    )
}

// === Imports ===

use blast_boosts_aftermath::{snapshot, venue_account::{Self, Checkpoint}};

use blast_boosts_core::policy;

use std::unit_test::assert_eq;
