#[test_only]
/// Literal-vector tests for authenticated Aftermath snapshot normalization.
module blast_boosts_aftermath::snapshot_tests;

// === Tests ===

#[test]
fun signed_funding_cost_crosses_allocated_zero_without_becoming_unresolved() {
    let before = checkpoint(10, 5, 5, 6, 7, 8, 9);
    let after = checkpoint(10, neg(3), 7, 8, 7, 8, 9);
    let change = preexisting(&before, &after);
    let (has, cost, raw, amount, clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());
    assert!(has && cost && clean);
    assert_eq!(raw, 8);
    // A cost of 8 raw IFixed units rounds up to one collateral atom.
    assert_eq!(amount, 1);
}

#[test]
fun signed_funding_credit_crosses_allocated_zero_without_becoming_unresolved() {
    let before = checkpoint(10, neg(5), 5, 6, 7, 8, 9);
    let after = checkpoint(10, 3, 7, 8, 7, 8, 9);
    let change = preexisting(&before, &after);
    let (has, cost, raw, amount, clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());
    assert!(has && !cost && clean);
    assert_eq!(raw, 8);
    // A credit of 8 raw IFixed units floors to nothing.
    assert_eq!(amount, 0);
}

#[test]
fun signed_funding_less_negative_allocation_is_a_credit() {
    let before = checkpoint(10, neg(5), 5, 6, 7, 8, 9);
    let after = checkpoint(10, neg(3), 7, 8, 7, 8, 9);
    let change = preexisting(&before, &after);
    let (has, cost, raw, amount, clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());
    assert!(has && !cost && clean);
    assert_eq!(raw, 2);
    assert_eq!(amount, 0);
}

#[test]
fun signed_funding_deeper_negative_allocation_is_a_cost() {
    let before = checkpoint(10, neg(3), 5, 6, 7, 8, 9);
    let after = checkpoint(10, neg(5), 7, 8, 7, 8, 9);
    let change = preexisting(&before, &after);
    let (has, cost, raw, amount, clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());
    assert!(has && cost && clean);
    assert_eq!(raw, 2);
    // A cost of 2 raw IFixed units rounds up to one collateral atom.
    assert_eq!(amount, 1);
}

// The fixtures below hold one raw unit of base at a raw unit collateral
// price, so the venue settles exactly the raw rate move on the held side: a
// rise costs a long, a fall credits it.

#[test]
fun a_flat_position_refreshes_its_snapshots_without_settling() {
    let before = flat_checkpoint(1_000, 5, 6, 7, 8, 9);
    let after = flat_checkpoint(1_000, 7, 8, 7, 8, 9);
    assert!(before != after);
    assert!(before.classify_change(&after, 1).is_unchanged_for_testing());
    assert!(preexisting(&before, &after).is_unchanged_for_testing());
}

#[test]
fun unchanged_checkpoint_is_not_funding() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let after = before;

    assert!(before.classify_change(&after, 1).is_unchanged_for_testing());
}

#[test]
fun a_rate_fall_on_the_held_side_is_a_credit_of_the_venue_amount() {
    let before = checkpoint(10, 1_000, 1_005, 6, 5, 8, 9);
    let after = checkpoint(10, 2_000, 5, 8, 5, 8, 9);
    let change = before.classify_change(&after, 1);

    assert_eq!(change.raw_amount(), 1_000);
    assert!(change.is_credit_for_testing());
}

#[test]
fun a_rate_rise_on_the_held_side_is_a_cost_of_the_venue_amount() {
    let before = checkpoint(10, 2_000, 5, 6, 1_005, 8, 9);
    let after = checkpoint(10, 1_000, 1_005, 8, 1_005, 8, 9);

    assert!(before.classify_change(&after, 1).is_cost());
}

#[test]
fun a_short_settles_against_the_short_rate_with_the_opposite_sign() {
    // Short rate rises by 1_000: the short is paid; the long rate is not consulted.
    let before = short_checkpoint(10, 1_000, 5, 6, 7, 1_006, 9);
    let credited = short_checkpoint(10, 2_000, 7, 1_006, 7, 1_006, 9);
    let change = before.classify_change(&credited, 1);
    assert_eq!(change.raw_amount(), 1_000);
    assert!(change.is_credit_for_testing());

    // The same move on a long looks at the long side's +2 and expects a cost of 2.
    let long_before = checkpoint(10, 1_000, 5, 6, 7, 1_006, 9);
    let costed = checkpoint(10, 998, 7, 1_006, 7, 1_006, 9);
    assert!(long_before.classify_change(&costed, 1).is_cost());
    assert!(long_before.classify_change(&checkpoint(10, 2_000, 7, 1_006, 7, 1_006, 9), 1).is_unexpected_for_testing());
}

#[test]
fun a_credit_rounds_down_and_a_cost_rounds_up_at_the_collateral_price() {
    // 1_001 raw USD at a price of 2 raw: the venue credits 500 and charges 501.
    let before = checkpoint(10, 1_000, 1_006, 6, 5, 8, 9);
    let credited = checkpoint(10, 1_500, 5, 8, 5, 8, 9);
    let credit = before.classify_change(&credited, 2);
    assert_eq!(credit.raw_amount(), 500);
    assert!(credit.is_credit_for_testing());
    assert!(before.classify_change(&checkpoint(10, 1_501, 5, 8, 5, 8, 9), 2).is_unexpected_for_testing());

    let rising = checkpoint(10, 1_000, 5, 6, 1_006, 8, 9);
    let costed = checkpoint(10, 499, 1_006, 8, 1_006, 8, 9);
    let cost = rising.classify_change(&costed, 2);
    assert!(cost.is_cost());
    assert_eq!(cost.raw_amount(), 501);
    assert!(rising.classify_change(&checkpoint(10, 500, 1_006, 8, 1_006, 8, 9), 2).is_unexpected_for_testing());
}

#[test]
fun a_credit_that_rounds_to_zero_leaves_the_collateral_untouched() {
    // One raw USD at a price of 2 raw floors to nothing; the venue still refreshes the snapshots.
    let before = checkpoint(10, 1_000, 6, 6, 5, 8, 9);
    let refreshed = checkpoint(10, 1_000, 5, 8, 5, 8, 9);
    assert!(before.classify_change(&refreshed, 2).is_unchanged_for_testing());
    assert!(before.classify_change(&checkpoint(10, 1_001, 5, 8, 5, 8, 9), 2).is_unexpected_for_testing());
}

#[test]
fun a_rate_crossing_zero_settles_the_sum_of_both_magnitudes() {
    // Snapshot -3, market +4 on the long side: the rate rose by 7, a cost of 7 for the long.
    let before = checkpoint(10, 1_000, neg(3), 6, 4, 8, 9);
    let after = checkpoint(10, 993, 4, 8, 4, 8, 9);
    let change = before.classify_change(&after, 1);
    assert!(change.is_cost());
    assert_eq!(change.raw_amount(), 7);

    // Snapshot +3, market -4: the rate fell by 7, a credit of 7.
    let rising = checkpoint(10, 1_000, 3, 6, neg(4), 8, 9);
    let falling = checkpoint(10, 1_007, neg(4), 8, neg(4), 8, 9);
    let credit = rising.classify_change(&falling, 1);
    assert_eq!(credit.raw_amount(), 7);
    assert!(credit.is_credit_for_testing());
}

#[test]
fun funding_settlement_keeps_the_exact_raw_amount() {
    let before = checkpoint(10, 4_000, 1_342, 6, 5, 8, 9);
    let after = checkpoint(10, 5_337, 5, 8, 5, 8, 9);
    let change = before.classify_change(&after, 1);

    assert_eq!(change.raw_amount(), 1_337);
}

#[test]
fun wrong_funding_delta_and_inactive_snapshot_transition_are_unexpected() {
    let before = checkpoint(10, 1_000, 1_005, 6, 5, 8, 9);
    let wrong_delta = checkpoint(10, 1_999, 5, 8, 5, 8, 9);
    let wrong_side = checkpoint(10, 2_000, 1_005, 8, 5, 8, 9);
    let wrong_short = checkpoint(10, 2_000, 5, 9, 5, 8, 9);

    assert!(before.classify_change(&wrong_delta, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&wrong_side, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&wrong_short, 1).is_unexpected_for_testing());
}

#[test]
fun collateral_delta_without_a_funding_snapshot_transition_is_unexpected() {
    let before = checkpoint(10, 1_000, 7, 8, 7, 8, 9);
    let after = checkpoint(10, 2_000, 7, 8, 7, 8, 9);

    assert!(before.classify_change(&after, 1).is_unexpected_for_testing());
}

#[test]
fun free_collateral_change_is_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 5, 6, 9);
    let after = checkpoint(11, 1_000, 5, 6, 5, 6, 9);

    assert!(before.classify_change(&after, 1).is_unexpected_for_testing());
}

#[test]
fun base_quote_and_pending_order_changes_are_unexpected() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let base_changed = checkpoint::checkpoint_for_testing(10, 1_000, 12, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let quote_changed = checkpoint::checkpoint_for_testing(10, 1_000, 1, 13, 3, 4, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let order_changed = checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 3, 4, 7, 8, 9, 10, 11, 13, 13, false, 14, 15, 16);

    assert!(before.classify_change(&base_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&quote_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&order_changed, 1).is_unexpected_for_testing());
}

#[test]
fun every_checkpoint_guard_field_blocks_an_otherwise_matching_funding_delta() {
    let before = checkpoint(10, 1_000, 1_007, 6, 7, 8, 9);
    let base_funding_after = checkpoint(10, 2_000, 7, 8, 7, 8, 9);
    let pending_ask_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 99, 11, 12, 13, false, 14, 15, 16);
    let pending_bid_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 99, 12, 13, false, 14, 15, 16);
    let pause_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 11, 12, 99, false, 14, 15, 16);
    let frozen_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 11, 12, 13, true, 14, 15, 16);
    let position_imr_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 11, 12, 13, false, 99, 15, 16);
    let market_imr_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 11, 12, 13, false, 14, 99, 16);
    let market_mmr_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 11, 12, 13, false, 14, 15, 99);

    assert!(before.classify_change(&base_funding_after, 1).is_credit_for_testing());
    assert!(before.classify_change(&pending_ask_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&pending_bid_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&pause_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&frozen_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&position_imr_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&market_imr_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&market_mmr_changed, 1).is_unexpected_for_testing());
}

#[test]
fun market_rate_or_lot_change_blocks_funding_even_when_the_delta_matches() {
    let before = checkpoint(10, 1_000, 1_007, 6, 7, 8, 9);
    let market_rate_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 99, 8, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let short_rate_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 99, 9, 10, 11, 12, 13, false, 14, 15, 16);
    let lot_changed = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 99, 10, 11, 12, 13, false, 14, 15, 16);

    assert!(before.classify_change(&market_rate_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&short_rate_changed, 1).is_unexpected_for_testing());
    assert!(before.classify_change(&lot_changed, 1).is_unexpected_for_testing());
}

#[test]
fun a_funding_cost_too_wide_for_collateral_atoms_is_carried_raw_but_not_clean() {
    // One raw unit above the widest cost that rounds up into a u64 atom count.
    let d = (std::u64::max_value!() as u256) * 1_000_000_000_000 + 1;
    let before = checkpoint(10, d, 5, 6, 5 + d, 8, 9);
    let after = checkpoint(10, 0, 5 + d, 8, 5 + d, 8, 9);
    let change = before.classify_change(&after, 1);

    assert!(change.is_cost());
    assert_eq!(change.raw_amount(), d);
    assert!(!change.has_funding());
    assert_eq!(change.amount(), 0);
    assert!(!change.is_clean());
}

#[test]
fun funding_width_is_exact_at_the_u64_atom_boundary_per_rounding_direction() {
    // A cost of exactly u64::max atoms rounds up to itself.
    let cost_raw = (std::u64::max_value!() as u256) * 1_000_000_000_000;
    let cost = checkpoint(10, cost_raw, 5, 6, 5 + cost_raw, 8, 9)
        .classify_change(&checkpoint(10, 0, 5 + cost_raw, 8, 5 + cost_raw, 8, 9), 1);
    assert!(cost.is_cost() && cost.has_funding());
    assert_eq!(cost.amount(), std::u64::max_value!());

    // A credit just below the next atom floors to u64::max.
    let credit_raw = cost_raw + 999_999_999_999;
    let credit = checkpoint(10, 0, 5 + credit_raw, 6, 5, 8, 9)
        .classify_change(&checkpoint(10, credit_raw, 5, 8, 5, 8, 9), 1);
    assert!(!credit.is_cost() && credit.has_funding());
    assert_eq!(credit.amount(), std::u64::max_value!());

    // The first whole atom above u64::max is unrepresentable as a credit.
    let wide_raw = ((std::u64::max_value!() as u256) + 1) * 1_000_000_000_000;
    let wide = checkpoint(10, 0, 5 + wide_raw, 6, 5, 8, 9)
        .classify_change(&checkpoint(10, wide_raw, 5, 8, 5, 8, 9), 1);
    assert!(!wide.is_cost() && !wide.has_funding());
}

#[test]
fun a_credit_floors_its_sub_atom_remainder() {
    let before = checkpoint(10, 0, 5 + 1_999_999_999_999, 6, 5, 8, 9);
    let after = checkpoint(10, 1_999_999_999_999, 5, 8, 5, 8, 9);
    let change = before.classify_change(&after, 1);

    assert!(change.has_funding());
    assert_eq!(change.amount(), 1);
    assert!(change.is_credit_for_testing());
}

#[test]
fun an_allocated_move_without_refreshed_snapshots_is_not_preexisting_funding() {
    let stored = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let before = checkpoint(10, 1_500, 5, 6, 7, 8, 9);

    assert!(preexisting(&stored, &before).is_unexpected_for_testing());
    assert!(sync_change(&stored, &before, &before, 1).is_unexpected_for_testing());
}

#[test]
fun an_unchanged_held_side_rate_settles_nothing_even_when_the_other_side_refreshes() {
    let before = checkpoint(10, 1_000, 5, 6, 5, 8, 9);
    let refreshed = checkpoint(10, 1_000, 5, 8, 5, 8, 9);
    let moved = checkpoint(10, 1_001, 5, 8, 5, 8, 9);

    assert!(before.classify_change(&refreshed, 1).is_unchanged_for_testing());
    assert!(before.classify_change(&moved, 1).is_unexpected_for_testing());
}

#[test]
fun a_short_pays_when_the_short_rate_falls() {
    let before = short_checkpoint(10, 2_000, 5, 1_006, 7, 6, 9);
    let after = short_checkpoint(10, 1_000, 7, 6, 7, 6, 9);
    let change = before.classify_change(&after, 1);

    assert!(change.is_cost());
    assert_eq!(change.raw_amount(), 1_000);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_boosts_aftermath::checkpoint)]
fun settlement_replay_aborts_where_the_venue_product_overflows() {
    let rate_delta = 1u256 << 60;
    let before = checkpoint::checkpoint_for_testing(
        10, 1_000, 1u256 << 200, 2, 5, 6, 5 + rate_delta, 8, 9, 10, 11, 12, 13, false, 14, 15, 16,
    );
    let after = checkpoint::checkpoint_for_testing(
        10, 999, 1u256 << 200, 2, 5 + rate_delta, 8, 5 + rate_delta, 8, 9, 10, 11, 12, 13, false, 14, 15, 16,
    );

    before.classify_change(&after, 1);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_boosts_aftermath::checkpoint)]
fun settlement_replay_divides_by_the_collateral_price_the_venue_divided_by() {
    // A zero price never reaches the classifier: the venue's own settlement
    // divides by the same price first and aborts. The replay aborts the same way.
    let before = checkpoint(10, 1_000, 5, 6, 1_005, 8, 9);
    let after = checkpoint(10, 0, 1_005, 8, 1_005, 8, 9);
    before.classify_change(&after, 0);
}

#[test]
fun net_funding_refuses_an_overflowing_gross_sum() {
    let half = (1u256 << 255) - 1;
    let preexisting = preexisting(&checkpoint(10, half, 5, 6, 7, 8, 9), &checkpoint(10, neg(half), 7, 8, 7, 8, 9));
    assert!(preexisting.is_cost());
    assert_eq!(preexisting.raw_amount(), std::u256::max_value!() - 1);
    let settled = checkpoint(10, 2_000, 5, 6, 1_005, 8, 9)
        .classify_change(&checkpoint(10, 1_000, 1_005, 8, 1_005, 8, 9), 1);
    assert!(settled.is_cost());

    assert!(preexisting.net_funding(settled).is_unexpected_for_testing());
}

#[test]
fun fixed_normalization_keeps_base_at_nine_and_quote_at_six_decimals() {
    // 1.234567890123 fixed units becomes 1.234567890 base units but
    // 1.234567 collateral/quote units: the scales differ by exactly 1,000.
    let raw = 1_234_567_890_123_000_000u256;
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(raw, 9, false), 1_234_567_890);
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(raw, 6, false), 1_234_567);
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(raw, 6, true), 1_234_568);
}

#[test]
fun fixed_negative_liability_and_absolute_risk_round_against_the_vault() {
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(1_000_000_000_000u256, 6, false), 1);
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(1_000_000_000_000u256, 6, true), 1);
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(1_000_000_000_001u256, 6, false), 1);
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(1_000_000_000_001u256, 6, true), 2);
}

#[test]
fun venue_feed_prices_normalize_from_eighteen_to_nine_decimals() {
    // The live SUI feed read on 2026-09-20: 0.82152064 USD as an 18-decimal IFixed.
    let (sui, sui_ok) = snapshot::normalize_price_for_testing(821_520_640_000_000_000);
    assert_eq!(sui, 821_520_640);
    assert!(sui_ok);
    // A feed too wide for the 9-decimal unit is invalid, not an abort.
    let (wide, wide_ok) = snapshot::normalize_price_for_testing((std::u64::max_value!() as u256 + 1) * 1_000_000_000);
    assert_eq!(wide, 0);
    assert!(!wide_ok);
}

#[test]
fun stablecoin_depeg_and_minimum_lot_vectors_keep_the_venue_scales() {
    // A depegged $0.95 feed remains exact in adapter price units.
    let (value_6, ok_6) = snapshot::normalize_price_for_testing(950_000_000_000_000_000);
    assert_eq!(value_6, 950_000_000);
    assert!(ok_6);
    // One minimum base lot and one quote micro-unit remain distinct scales.
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(1_000_000_000, 9, false), 1);
    assert_eq!(ifixed_math::normalize_raw_fixed_for_testing(1_000_000_000_000, 6, false), 1);
}

#[test]
fun usd_values_convert_to_collateral_units_at_the_authenticated_depeg_price() {
    // $1 converts to 1.052631578947368421 collateral at $0.95; credits floor
    // and costs ceil at the raw IFixed unit.
    let (value_7, ok_7) = ifixed_math::usd_fixed_to_collateral_for_testing(1_000_000_000_000_000_000, 950_000_000_000_000_000, false);
    assert_eq!(value_7, 1_052_631_578_947_368_421);
    assert!(ok_7);
    let (value_8, ok_8) = ifixed_math::usd_fixed_to_collateral_for_testing(1_000_000_000_000_000_000, 950_000_000_000_000_000, true);
    assert_eq!(value_8, 1_052_631_578_947_368_422);
    assert!(ok_8);
    // $1.50 notional at $1.20 collateral is exactly 1.25 collateral.
    let (value_9, ok_9) = ifixed_math::usd_fixed_to_collateral_for_testing(1_500_000_000_000_000_000, 1_200_000_000_000_000_000, true);
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
    // (base_negative, quote_negative, base_zero, quote_zero, is_long_or_flat)
    assert!(snapshot::position_signs_coherent_for_testing(false, false, false, false, true));
    assert!(snapshot::position_signs_coherent_for_testing(true, true, false, false, false));
    assert!(snapshot::position_signs_coherent_for_testing(false, false, true, true, true));
    assert!(!snapshot::position_signs_coherent_for_testing(false, true, false, false, true));
    assert!(!snapshot::position_signs_coherent_for_testing(true, false, false, false, false));
    assert!(!snapshot::position_signs_coherent_for_testing(false, false, true, false, true));
    assert!(!snapshot::position_signs_coherent_for_testing(true, true, false, false, true));
}

#[test]
fun health_usd_conversion_keeps_the_same_max_width_input_as_an_invalid_fact() {
    let (value, valid) = ifixed_math::usd_fixed_to_collateral_for_testing(
        57896044618658097595993403267027758503064007324132374166459015334359435960541,
        499_999_999_999_999_999,
        false,
    );
    assert_eq!(value, 0);
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
    let (value_11, ok_11) = ifixed_math::usd_fixed_to_collateral_for_testing(
            115792089237316195307778895771371712429698999656952656186187599342272565600477,
            999_999_999_999_999_999,
            true,
        );
    assert_eq!(value_11, std::u256::max_value!());
    assert!(ok_11);
    let (value_12, ok_12) = ifixed_math::usd_fixed_to_collateral_for_testing(
            115792089237316195307778895771371712429698999656952656186187599342272565600478,
            999_999_999_999_999_999,
            true,
        );
    assert_eq!(value_12, 0);
    assert!(!ok_12);
}

#[test]
fun a_ready_capture_becomes_the_core_observation_and_its_checkpoint() {
    let checkpoint = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let captured = snapshot::captured_health_for_testing(checkpoint, 2_500, true, 0, true, true);
    assert_eq!(captured.checkpoint(), checkpoint);
    assert_eq!(captured.collateral_fixed(), 1_000_000_000_000_000_000);

    let (observation, read_with) = captured.into_observation();
    let expected = observation::new_position(
        2_500,
        1_800,
        1,
        policy::long(),
        observation::new_price(1_000_000_000, 0, 1_000),
        observation::new_price(1_000_000_000, 0, 1_000),
        1_000_000_000,
    );
    assert_eq!(observation, expected);
    assert_eq!(read_with, checkpoint);
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun a_capture_under_margin_is_refused_for_a_priced_operation() {
    snapshot::captured_health_for_testing(checkpoint(10, 1_000, 5, 6, 7, 8, 9), 2_500, false, 0, true, true)
        .into_observation();
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun a_capture_with_an_open_order_is_refused_for_a_priced_operation() {
    snapshot::captured_health_for_testing(checkpoint(10, 1_000, 5, 6, 7, 8, 9), 2_500, true, 1, true, true)
        .into_observation();
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun a_capture_of_a_paused_or_frozen_market_is_refused_for_a_priced_operation() {
    snapshot::captured_health_for_testing(checkpoint(10, 1_000, 5, 6, 7, 8, 9), 2_500, true, 0, false, true)
        .into_observation();
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::snapshot)]
fun unrepresentable_economics_are_refused_before_venue_readiness() {
    snapshot::captured_health_for_testing(checkpoint(10, 1_000, 5, 6, 7, 8, 9), 2_500, false, 1, false, false)
        .into_observation();
}

#[test]
fun an_oracle_leg_is_the_bound_feed_price_in_nine_decimals_with_its_timestamp() {
    let (price, timestamp, representable) =
        snapshot::oracle_leg_for_testing(821_520_640_000_000_000, 1_000, 821_520_640_000_000_000);

    assert_eq!(price, 821_520_640);
    assert_eq!(timestamp, 1_000);
    assert!(representable);
}

#[test]
#[expected_failure(abort_code = errors::EOracleObservationMismatch, location = blast_boosts_aftermath::snapshot)]
fun an_oracle_leg_refuses_a_venue_price_the_bound_feed_does_not_show() {
    snapshot::oracle_leg_for_testing(821_520_640_000_000_000, 1_000, 821_520_640_000_000_001);
}

#[test]
fun an_oracle_leg_too_wide_for_nine_decimals_is_an_invalid_fact_not_an_abort() {
    let wide = ((std::u64::max_value!() as u256) + 1) * 1_000_000_000;
    let (price, timestamp, representable) = snapshot::oracle_leg_for_testing(wide as u128, 1_000, wide);

    assert_eq!(price, 0);
    assert_eq!(timestamp, 1_000);
    assert!(!representable);
}

#[test]
fun signed_equity_is_invalid_at_a_zero_collateral_price() {
    let (equity, valid) = snapshot::signed_equity_for_testing(10, false, 0, false, 0, 0);

    assert_eq!(equity, 0);
    assert!(!valid);
}

#[test]
fun signed_equity_is_invalid_when_allocated_collateral_does_not_fit_u64_atoms() {
    let wide = ((std::u64::max_value!() as u256) + 1) * 1_000_000_000_000;
    let (equity, valid) = snapshot::signed_equity_for_testing(0, false, wide, false, 0, 1_000_000_000_000_000_000);

    assert_eq!(equity, 0);
    assert!(!valid);
}

#[test]
fun signed_equity_is_invalid_when_a_liability_rounds_up_past_u64_atoms() {
    let crossing = (std::u64::max_value!() as u256) * 1_000_000_000_000 + 1;
    let (equity, valid) =
        snapshot::signed_equity_for_testing(0, true, crossing, false, 0, 1_000_000_000_000_000_000);

    assert_eq!(equity, 0);
    assert!(!valid);
}

#[test]
fun signed_equity_is_invalid_when_pnl_does_not_fit_u64_atoms() {
    let wide = ((std::u64::max_value!() as u256) + 1) * 1_000_000_000_000;
    let (equity, valid) = snapshot::signed_equity_for_testing(0, false, 0, false, wide, 1_000_000_000_000_000_000);

    assert_eq!(equity, 0);
    assert!(!valid);
}

#[test]
fun signed_equity_is_invalid_when_the_pnl_usd_conversion_overflows() {
    let (equity, valid) =
        snapshot::signed_equity_for_testing(0, false, 0, false, std::u256::max_value!(), 1);

    assert_eq!(equity, 0);
    assert!(!valid);
}

#[test]
fun equity_exactly_consumed_by_liabilities_is_a_valid_zero() {
    let (equity, valid) = snapshot::signed_equity_for_testing(
        4, true, 2_000_000_000_000, true, 2_000_000_000_000, 1_000_000_000_000_000_000,
    );

    assert_eq!(equity, 0);
    assert!(valid);
}

#[test]
fun signed_equity_rounds_pnl_against_the_vault_at_a_depegged_collateral_price() {
    // A $1 loss at $0.95 is 1.052631578947368422 collateral, charged as 1_052_632 atoms.
    let (loss_equity, loss_valid) = snapshot::signed_equity_for_testing(
        2_000_000, false, 0, true, 1_000_000_000_000_000_000, 950_000_000_000_000_000,
    );
    assert_eq!(loss_equity, 947_368);
    assert!(loss_valid);

    // A $1 gain at $0.95 is 1.052631578947368421 collateral, credited as 1_052_631 atoms.
    let (gain_equity, gain_valid) = snapshot::signed_equity_for_testing(
        0, false, 0, false, 1_000_000_000_000_000_000, 950_000_000_000_000_000,
    );
    assert_eq!(gain_equity, 1_052_631);
    assert!(gain_valid);
}

#[test]
fun sign_coherence_rejects_half_flat_and_wrong_side_positions() {
    // (base_negative, quote_negative, base_zero, quote_zero, is_long_or_flat)
    assert!(!snapshot::position_signs_coherent_for_testing(false, false, false, true, true));
    assert!(snapshot::position_signs_coherent_for_testing(false, false, true, true, false));
    assert!(!snapshot::position_signs_coherent_for_testing(true, false, false, false, true));
    assert!(!snapshot::position_signs_coherent_for_testing(false, false, false, false, false));
    assert!(!snapshot::position_signs_coherent_for_testing(false, true, false, false, false));
}

#[test]
fun price_normalization_accepts_the_largest_u64_price() {
    let (price, valid) = snapshot::normalize_price_for_testing(18_446_744_073_709_551_615_000_000_000);

    assert_eq!(price, std::u64::max_value!());
    assert!(valid);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::ifixed_math)]
fun raw_normalization_round_up_refuses_the_first_value_past_u64() {
    ifixed_math::normalize_raw_fixed_for_testing(18_446_744_073_709_551_615_000_000_000_001, 6, true);
}

#[test]
fun usd_conversion_at_a_zero_collateral_price_is_invalid_in_both_rounding_directions() {
    let (down, down_ok) = ifixed_math::usd_fixed_to_collateral_for_testing(1_000_000_000_000_000_000, 0, false);
    assert_eq!(down, 0);
    assert!(!down_ok);
    let (up, up_ok) = ifixed_math::usd_fixed_to_collateral_for_testing(1_000_000_000_000_000_000, 0, true);
    assert_eq!(up, 0);
    assert!(!up_ok);
}

#[test]
fun usd_conversion_is_invalid_when_either_scaled_part_overflows() {
    // The whole part times one IFixed overflows.
    let (whole, whole_ok) = ifixed_math::usd_fixed_to_collateral_for_testing(std::u256::max_value!(), 1, false);
    assert_eq!(whole, 0);
    assert!(!whole_ok);
    // The fractional part times one IFixed overflows.
    let (fraction, fraction_ok) = ifixed_math::usd_fixed_to_collateral_for_testing(
        std::u256::max_value!() - 1, std::u256::max_value!(), false,
    );
    assert_eq!(fraction, 0);
    assert!(!fraction_ok);
}

#[test]
fun repeated_market_margin_updates_are_clean_without_changing_account_guards() {
    let original = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let lowered = checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 10, 8);
    let raised = checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 30, 20);
    assert!(original.classify_preexisting(&lowered).is_unchanged_for_testing());
    assert!(lowered.classify_preexisting(&raised).is_unchanged_for_testing());
    assert!(raised.classify_preexisting(&original).is_unchanged_for_testing());

    let settled = checkpoint::checkpoint_for_testing(10, 2_000, 1, 2, 7, 8, 7, 8, 9, 10, 11, 12, 13, false, 14, 30, 20);
    let old_rates = checkpoint(10, 1_000, 1_007, 6, 7, 8, 9);
    assert!(old_rates.classify_preexisting(&settled).is_credit_for_testing());
    // During our own atomic settlement the market settings must remain exact.
    assert!(old_rates.classify_change(&settled, 1).is_unexpected_for_testing());
}

#[test]
fun market_margin_updates_cannot_hide_unexplained_account_changes() {
    let before = checkpoint(10, 1_000, 5, 6, 7, 8, 9);
    let variants = vector[
        checkpoint::checkpoint_for_testing(11, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_001, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 2, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 10, 10, 11, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 11, 11, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 12, 12, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 13, 13, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 14, false, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, true, 14, 30, 20),
        checkpoint::checkpoint_for_testing(10, 1_000, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, false, 15, 30, 20),
    ];
    variants.do_ref!(|after| assert!(before.classify_preexisting(after).is_unexpected_for_testing()));
}

// === Test Helpers ===

/// `-magnitude` in the venue's two's-complement carrier.
fun neg(magnitude: u256): u256 {
    std::u256::max_value!() - magnitude + 1
}

/// The stored → before edge alone: what another caller settled since `stored`.
fun preexisting(stored: &Checkpoint, before: &Checkpoint): CheckpointChange {
    stored.classify_preexisting(before)
}

/// Both edges of one synchronization netted, as `synchronize` applies them.
fun sync_change(stored: &Checkpoint, before: &Checkpoint, after: &Checkpoint, collateral_price: u256): CheckpointChange {
    let (preexisting_change, local_change) = stored.classify_sync_changes(before, after, collateral_price);
    preexisting_change.net_funding(local_change)
}

/// One raw unit long; the quote carries the base's sign.
fun checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
): Checkpoint {
    checkpoint::checkpoint_for_testing(
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

/// One raw unit short: base and quote carry the negative sign.
fun short_checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
): Checkpoint {
    checkpoint::checkpoint_for_testing(
        free_collateral,
        allocated_collateral,
        neg(1),
        neg(2),
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

fun flat_checkpoint(
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
): Checkpoint {
    checkpoint::checkpoint_for_testing(
        10,
        allocated_collateral,
        0,
        0,
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

use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint, CheckpointChange}, errors, ifixed_math, snapshot};

use blast_boosts_core::{observation, policy};

use std::unit_test::assert_eq;
