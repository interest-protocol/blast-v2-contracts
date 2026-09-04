#[test_only]
/// Literal-vector tests for authenticated Aftermath snapshot normalization.
module blast_leverage_aftermath::snapshot_tests;

use blast_leverage_aftermath::snapshot;
use blast_leverage_aftermath::venue_account;
use std::unit_test::assert_eq;

// === Tests ===

#[test]
fun normalization_module_is_available() {
    snapshot::assert_test_seam_for_testing();
}

#[test]
fun unchanged_checkpoint_is_not_funding() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = before;

    assert!(snapshot::is_unchanged_for_testing(snapshot::classify_change_for_testing(&before, &after)));
}

#[test]
fun exact_positive_funding_transition_is_credit() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 2_000, 7, 6, 7, 8, 9);

    assert!(snapshot::is_credit_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 1_000, true)));
}

#[test]
fun funding_settlement_keeps_the_exact_raw_candidate_amount() {
    let before = checkpoint(10, 4_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 5_337, 7, 6, 7, 8, 9);
    let change = snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 1_337, true);

    assert_eq!(snapshot::funding_amount_for_testing(change), 1_337);
}

#[test]
fun exact_negative_funding_transition_is_cost() {
    let before = checkpoint(10, 2_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 1_000, 7, 6, 7, 8, 9);

    assert!(snapshot::is_cost_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &after, true, 1_000, true)));
}

#[test]
fun short_funding_changes_only_the_short_snapshot() {
    let before = checkpoint(10, 2_000, 5, 6, 7, 8, 9);
    let after = checkpoint(10, 3_000, 5, 8, 7, 8, 9);

    assert!(snapshot::is_credit_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &after, false, 1_000, false)));
}

#[test]
fun wrong_funding_delta_and_inactive_snapshot_transition_are_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let wrong_delta = checkpoint(10, 2_000, 7, 6, 7, 8, 9);
    let wrong_side = checkpoint(10, 2_000, 5, 8, 7, 8, 9);

    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &wrong_delta, false, 999, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &wrong_side, false, 1_000, true)));
}

#[test]
fun collateral_delta_without_a_funding_snapshot_transition_is_unexpected() {
    let before = checkpoint(10, 1_000, 7, 8, 7, 8, 9);
    let after = checkpoint(10, 2_000, 7, 8, 7, 8, 9);

    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_for_testing(&before, &after)));
}

#[test]
fun free_collateral_change_is_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = checkpoint(11, 1_000, 5, 6, 7, 8, 9);

    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_for_testing(&before, &after)));
}

#[test]
fun base_quote_and_pending_order_changes_are_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let base_changed = venue_account::checkpoint_for_testing(10, 1_000, 12, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let quote_changed = venue_account::checkpoint_for_testing(10, 1_000, 1, 13, 3, 4, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let order_changed = venue_account::checkpoint_for_testing(10, 1_000, 1, 2, 3, 4, 7, 8, 9, 10, 11, 13, 13, false, 14, 15, 16);

    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_for_testing(&before, &base_changed)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_for_testing(&before, &quote_changed)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_for_testing(&before, &order_changed)));
}

#[test]
fun every_checkpoint_guard_field_blocks_an_otherwise_matching_funding_delta() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let base_funding_after = checkpoint(10, 2_000, 7, 6, 7, 8, 9);
    let pending_ask_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 99, 11, 12, 13, false, 14, 15, 16);
    let pending_bid_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 99, 12, 13, false, 14, 15, 16);
    let pause_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 99, false, 14, 15, 16);
    let frozen_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, true, 14, 15, 16);
    let position_imr_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, false, 99, 15, 16);
    let market_imr_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 99, 16);
    let market_mmr_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 99);

    assert!(snapshot::is_credit_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &base_funding_after, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &pending_ask_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &pending_bid_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &pause_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &frozen_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &position_imr_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &market_imr_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &market_mmr_changed, false, 1_000, true)));
}

#[test]
fun market_rate_or_lot_change_blocks_funding_even_when_the_delta_matches() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let market_rate_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 99, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let lot_changed = venue_account::checkpoint_for_testing(10, 2_000, 1, 2, 7, 6, 7, 8, 99, 10, 11, 12, 13, false, 14, 15, 16);

    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &market_rate_changed, false, 1_000, true)));
    assert!(snapshot::is_unexpected_for_testing(snapshot::classify_change_with_candidate_for_testing(&before, &lot_changed, false, 1_000, true)));
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
    assert_eq!(snapshot::normalize_pyth_for_testing(12_345, true, 13, false), 1);
    assert_eq!(snapshot::normalize_pyth_for_testing(12_345, true, 13, true), 2);
    assert_eq!(snapshot::normalize_pyth_for_testing(1, true, 13, true), 1);
}

#[test]
fun pyth_positive_exponent_and_seconds_conversion_are_literal() {
    assert_eq!(snapshot::normalize_pyth_for_testing(42, false, 2, false), 4_200_000_000_000);
    assert_eq!(snapshot::seconds_to_millis_for_testing(1_700_000_000), 1_700_000_000_000);
}

#[test]
fun stablecoin_depeg_and_minimum_lot_vectors_keep_the_venue_scales() {
    // Pyth -9 inputs are already in adapter price units: $0.95 remains exact.
    assert_eq!(snapshot::normalize_pyth_for_testing(950_000_000, true, 9, false), 950_000_000);
    // One minimum base lot and one quote micro-unit remain distinct scales.
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000, 9, false), 1);
    assert_eq!(snapshot::normalize_raw_fixed_for_testing(1_000_000_000_000, 6, false), 1);
}

#[test]
#[expected_failure(abort_code = 24, location = blast_leverage_aftermath::snapshot)]
fun pyth_normalization_rejects_a_component_that_cannot_fit_u64() {
    snapshot::normalize_pyth_for_testing(std::u64::max_value!(), false, 9, false);
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
): venue_account::Checkpoint {
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
