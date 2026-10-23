// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Structural and boundary tests for immutable rebalance policy.
module blast_boosts_core::rebalance_policy_tests;

// === Tests ===

#[test]
fun one_public_band_accepts_adjacent_thresholds_and_has_inclusive_endpoints() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1);
    // Leverage 0 bps: notional 0 against NAV 10_000.
    assert!(!value.is_leverage_below_band(0, 10_000));
    assert!(!value.is_leverage_above_band_for_testing(0, 10_000));
    // Leverage 2 bps sits exactly on the upper edge.
    assert!(!value.is_leverage_below_band(2, 10_000));
    assert!(!value.is_leverage_above_band_for_testing(2, 10_000));
    assert!(!value.is_leverage_above_max(3, 10_000));
    assert!(value.is_leverage_above_max(4, 10_000));
}

#[test]
fun the_smallest_strictly_ordered_policy_is_preserved() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1);

    assert_eq!(value.rebalance_below_bps(), 0);
    assert_eq!(value.target_leverage_bps(), 1);
    assert_eq!(value.rebalance_above_bps(), 2);
    assert_eq!(value.max_leverage_bps(), 3);
    assert_eq!(value.max_slippage_bps(), 0);
    assert_eq!(value.emergency_max_slippage_bps(), 0);
    assert_eq!(value.min_leverage_improvement_bps(), 1);
}

#[test]
fun maximum_width_policy_values_are_supported() {
    let max = std::u64::max_value!();
    let value = policy::new_rebalance_policy(
        0,
        2,
        999_999,
        1_000_000,
        9_999,
        9_999,
        max,
    );

    assert_eq!(value.max_leverage_bps(), 1_000_000);
    assert_eq!(value.min_leverage_improvement_bps(), max);
}

#[test]
fun copied_policy_preserves_every_field() {
    let value = policy::new_rebalance_policy(1, 3, 5, 6, 7, 8, 9);
    let copied = value;

    assert_eq!(copied.rebalance_below_bps(), value.rebalance_below_bps());
    assert_eq!(copied.target_leverage_bps(), value.target_leverage_bps());
    assert_eq!(copied.rebalance_above_bps(), value.rebalance_above_bps());
    assert_eq!(copied.max_leverage_bps(), value.max_leverage_bps());
    assert_eq!(copied.max_slippage_bps(), value.max_slippage_bps());
    assert_eq!(copied.emergency_max_slippage_bps(), value.emergency_max_slippage_bps());
    assert_eq!(copied.min_leverage_improvement_bps(), value.min_leverage_improvement_bps());
}

#[test]
fun every_strictly_ordered_small_tuple_is_accepted_and_preserved() {
    0u64.range_do!(8, |rebalance_below| {
        (rebalance_below + 1).range_do!(8, |target| {
            (target + 1).range_do!(8, |rebalance_above| {
                (rebalance_above + 1).range_do!(8, |max_leverage| {
                    let value = policy::new_rebalance_policy(rebalance_below, target, rebalance_above, max_leverage, 0, 0, 1);
                    assert_eq!(value.rebalance_below_bps(), rebalance_below);
                    assert_eq!(value.target_leverage_bps(), target);
                    assert_eq!(value.rebalance_above_bps(), rebalance_above);
                    assert_eq!(value.max_leverage_bps(), max_leverage);
                });
            });
        });
    });
}

#[test]
fun eligibility_predicates_pin_every_threshold_equality() {
    let value = standard_policy();

    // Notional in collateral atoms against NAV 10_000, so notional reads as leverage bps.
    assert!(value.is_leverage_below_band(15_999, 10_000));
    assert!(!value.is_leverage_below_band(16_000, 10_000));
    assert!(!value.is_leverage_above_band_for_testing(16_000, 10_000));
    assert!(!value.is_leverage_above_band_for_testing(26_000, 10_000));
    assert!(!value.is_leverage_below_band(26_000, 10_000));
    assert!(value.is_leverage_above_band_for_testing(26_001, 10_000));
    assert!(!value.is_leverage_within_band(15_999, 10_000));
    assert!(value.is_leverage_within_band(16_000, 10_000));
    assert!(value.is_leverage_within_band(26_000, 10_000));
    assert!(!value.is_leverage_within_band(26_001, 10_000));
    assert!(!value.is_leverage_above_max(29_999, 10_000));
    assert!(!value.is_leverage_above_max(30_000, 10_000));
    assert!(value.is_leverage_above_max(30_001, 10_000));
    // The comparison is exact: one atom over the edge on a large NAV still counts.
    let nav = std::u64::max_value!() / 3;
    let edge = ((nav as u128) * 26_000 / 10_000) as u64;
    assert!(!value.is_leverage_above_band_for_testing(edge, nav));
    assert!(value.is_leverage_above_band_for_testing(edge + 1, nav));
}

#[test]
fun max_leverage_at_the_leverage_ceiling_is_accepted() {
    assert_eq!(new_with_thresholds(0, 2, 4, 1_000_000).max_leverage_bps(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun max_leverage_above_the_leverage_ceiling_is_rejected() {
    new_with_thresholds(0, 2, 4, 1_000_001);
}

#[test]
fun a_zero_rebalance_below_threshold_disables_the_lower_public_trigger() {
    let value = new_with_thresholds(0, 2, 4, 5);

    assert!(!value.is_leverage_below_band(0, 10_000));
    assert!(!value.is_leverage_above_band_for_testing(0, 10_000));
}

// --- Execution Bounds ---

#[test]
fun execution_bounds_are_inclusive_and_symmetric() {
    let value = standard_policy();
    let ordinary = value.execution_bound(false);
    let emergency = value.execution_bound(true);

    assert_eq!(ordinary.slippage_bps(), 100);
    assert_eq!(emergency.slippage_bps(), 500);
    assert!(ordinary.is_within_for_testing(1_000_000, 1_010_000));
    assert!(!ordinary.is_within_for_testing(1_000_000, 1_010_001));
    assert!(ordinary.is_within_for_testing(1_000_000, 990_000));
    assert!(!ordinary.is_within_for_testing(1_000_000, 989_999));
    assert!(emergency.is_within_for_testing(1_000_000, 1_010_001));
    assert!(emergency.is_within_for_testing(1_000_000, 1_050_000));
    assert!(!emergency.is_within_for_testing(1_000_000, 1_050_001));
    assert!(emergency.is_within_for_testing(1_000_000, 950_000));
    assert!(!emergency.is_within_for_testing(1_000_000, 949_999));
    assert!(!ordinary.is_within_for_testing(0, 0));
    assert!(!emergency.is_within_for_testing(0, 0));
    ordinary.assert_execution(1_000_000, 1_010_000);
    emergency.assert_execution(1_000_000, 1_050_000);
}

#[test]
fun maximum_width_execution_tolerance_does_not_wrap() {
    let max = std::u64::max_value!();
    let bound = policy::new_rebalance_policy(0, 2, 4, 5, 9_999, 9_999, 1).execution_bound(false);

    assert!(bound.is_within_for_testing(max, max));
    assert!(!bound.is_within_for_testing(max, 0));
    assert!(!bound.is_within_for_testing(1, max));
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_execution_one_unit_past_the_ordinary_bound_is_rejected() {
    standard_policy().execution_bound(false).assert_execution(1_000_000, 1_010_001);
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_execution_one_unit_past_the_emergency_bound_is_rejected() {
    standard_policy().execution_bound(true).assert_execution(1_000_000, 1_050_001);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPrice, location = blast_boosts_core::policy)]
fun a_zero_reference_is_rejected_before_the_bound() {
    standard_policy().execution_bound(false).assert_execution(0, 0);
}

// --- Limit Price ---

/// A bid may pay at most the bound above the reference, rounded down to the tick.
#[test]
fun a_bid_limit_is_the_bound_above_the_reference_floored_to_the_tick() {
    let bound = standard_policy().execution_bound(false);

    assert_eq!(bound.limit_price(1_000_000, false, 1), 1_010_000);
    assert_eq!(bound.limit_price(1_000_000, false, 7), 1_009_995);
    assert_eq!(bound.limit_price(1_000_000, false, 20_000), 1_000_000);
    bound.assert_execution(1_000_000, bound.limit_price(1_000_000, false, 7));
}

/// An ask must receive at least the bound below the reference, rounded up to the tick.
#[test]
fun an_ask_limit_is_the_bound_below_the_reference_ceiled_to_the_tick() {
    let bound = standard_policy().execution_bound(false);

    assert_eq!(bound.limit_price(1_000_000, true, 1), 990_000);
    assert_eq!(bound.limit_price(1_000_000, true, 7), 990_003);
    assert_eq!(bound.limit_price(1_000_000, true, 20_000), 1_000_000);
    bound.assert_execution(1_000_000, bound.limit_price(1_000_000, true, 7));
}

#[test]
fun the_emergency_bound_prices_its_own_wider_limit() {
    let bound = standard_policy().execution_bound(true);

    assert_eq!(bound.limit_price(1_000_000, false, 1), 1_050_000);
    assert_eq!(bound.limit_price(1_000_000, true, 1), 950_000);
}

#[test]
fun a_zero_bound_limits_at_the_reference_itself() {
    let bound = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1).execution_bound(false);

    assert_eq!(bound.limit_price(1_000_000, false, 1_000), 1_000_000);
    assert_eq!(bound.limit_price(1_000_000, true, 1_000), 1_000_000);
}

/// The widest admissible bound still prices an ask above zero and a bid at the
/// largest reference it can widen without leaving `u64`.
#[test]
fun the_widest_bound_keeps_every_limit_positive_and_representable() {
    let bound = policy::new_rebalance_policy(0, 2, 4, 5, 9_999, 9_999, 1).execution_bound(false);
    let max = std::u64::max_value!();

    assert_eq!(bound.limit_price(1, true, 1), 1);
    assert_eq!(bound.limit_price(1, false, 1), 1);
    assert_eq!(bound.limit_price(max, true, 1), 1_844_674_407_370_956);
    assert_eq!(bound.limit_price(max / 2, false, 1), (max / 2) / 10_000 * 19_999 + ((max / 2) % 10_000) * 19_999 / 10_000);
}

/// Every limit the production formula prices lands inside its bound and equals an
/// independent rounding of the same rule, over every small reference, tick and side.
#[test]
fun every_limit_price_matches_the_rounding_reference_and_stays_inside_its_bound() {
    vector[0u64, 1, 250, 5_000, 9_999].do!(|slippage_bps| {
        let bound = policy::new_rebalance_policy(0, 1, 2, 3, slippage_bps, slippage_bps, 1).execution_bound(false);
        let mut reference = 1u64;
        while (reference <= 40) {
            let mut tick = 1u64;
            while (tick <= 9) {
                vector[false, true].do!(|is_ask| {
                    let expected = if (is_ask) {
                        (reference * (10_000 - slippage_bps)).div_ceil(10_000).div_ceil(tick) * tick
                    } else {
                        reference * (10_000 + slippage_bps) / 10_000 / tick * tick
                    };
                    // A tick wider than the bound leaves no admissible price; production aborts there.
                    if (expected.diff(reference) * 10_000 <= slippage_bps * reference) {
                        let limit = bound.limit_price(reference, is_ask, tick);
                        assert_eq!(limit, expected);
                        assert!(limit % tick == 0 && limit > 0);
                        bound.assert_execution(reference, limit);
                    };
                });
                tick = tick + 1;
            };
            reference = reference + 1;
        };
    });
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPrice, location = blast_boosts_core::policy)]
fun a_limit_rejects_a_zero_reference_before_the_tick() {
    standard_policy().execution_bound(false).limit_price(0, false, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidTickSize, location = blast_boosts_core::policy)]
fun a_limit_rejects_a_zero_tick() {
    standard_policy().execution_bound(false).limit_price(1_000_000, false, 0);
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun a_bid_limit_rejects_a_tick_wider_than_its_bound() {
    standard_policy().execution_bound(false).limit_price(1_000_000, false, 3_000_000);
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_ask_limit_rejects_a_tick_wider_than_its_bound() {
    standard_policy().execution_bound(false).limit_price(1_000_000, true, 3_000_000);
}

#[test]
#[expected_failure(abort_code = errors::EArithmeticOverflow, location = blast_boosts_core::policy)]
fun a_bid_limit_rejects_a_reference_it_cannot_widen_within_u64() {
    standard_policy().execution_bound(false).limit_price(std::u64::max_value!(), false, 1);
}

// --- Unwind Bound ---

/// The close-only bound opens at the ordinary bound and widens linearly to the
/// emergency bound over one day, where it stays.
#[test]
fun the_unwind_bound_widens_from_the_ordinary_to_the_emergency_bound_over_a_day() {
    let value = standard_policy();
    let day_ms = 86_400_000;

    assert_eq!(value.unwind_execution_bound(0).slippage_bps(), 100);
    assert_eq!(value.unwind_execution_bound(day_ms / 4).slippage_bps(), 200);
    assert_eq!(value.unwind_execution_bound(day_ms / 2).slippage_bps(), 300);
    assert_eq!(value.unwind_execution_bound(day_ms - 1).slippage_bps(), 499);
    assert_eq!(value.unwind_execution_bound(day_ms).slippage_bps(), 500);
    assert_eq!(value.unwind_execution_bound(day_ms + 1).slippage_bps(), 500);
    assert_eq!(value.unwind_execution_bound(std::u64::max_value!()).slippage_bps(), 500);
}

/// Widening rounds down to whole basis points: 400 bps over a day opens its
/// first basis point after exactly 216 seconds, and never narrows afterwards.
#[test]
fun the_unwind_bound_rounds_down_and_never_narrows() {
    let value = standard_policy();

    assert_eq!(value.unwind_execution_bound(215_999).slippage_bps(), 100);
    assert_eq!(value.unwind_execution_bound(216_000).slippage_bps(), 101);
    let mut elapsed_duration_ms = 0;
    let mut previous = 100;
    while (elapsed_duration_ms <= 90_000_000) {
        let current = value.unwind_execution_bound(elapsed_duration_ms).slippage_bps();
        assert!(current >= previous && current <= 500);
        previous = current;
        elapsed_duration_ms = elapsed_duration_ms + 1_234_567;
    };
}

#[test]
fun equal_bounds_leave_the_unwind_bound_constant() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 30, 30, 1);

    assert_eq!(value.unwind_execution_bound(0).slippage_bps(), 30);
    assert_eq!(value.unwind_execution_bound(1_000_000_000).slippage_bps(), 30);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun rebalance_below_equal_to_target_is_rejected() {
    new_with_thresholds(1, 1, 2, 3);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun rebalance_below_above_target_is_rejected() {
    new_with_thresholds(2, 1, 3, 4);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun target_equal_to_rebalance_above_is_rejected() {
    new_with_thresholds(0, 2, 2, 3);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun target_above_rebalance_above_is_rejected() {
    new_with_thresholds(0, 3, 2, 4);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun rebalance_above_equal_to_max_leverage_is_rejected() {
    new_with_thresholds(0, 2, 5, 5);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun rebalance_above_past_max_leverage_is_rejected() {
    new_with_thresholds(0, 2, 6, 5);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxSlippageBps, location = blast_boosts_core::policy)]
fun max_slippage_at_the_denominator_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 10_000, 10_000, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidEmergencyMaxSlippageBps, location = blast_boosts_core::policy)]
fun emergency_max_slippage_at_the_denominator_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 0, 10_000, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidEmergencyMaxSlippageBps, location = blast_boosts_core::policy)]
fun emergency_max_slippage_below_max_slippage_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 2, 1, 1);
}

#[test]
fun equal_strict_and_emergency_max_slippages_are_accepted() {
    let value = policy::new_rebalance_policy(0, 2, 4, 5, 9_999, 9_999, 1);

    assert_eq!(value.max_slippage_bps(), value.emergency_max_slippage_bps());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinLeverageImprovementBps, location = blast_boosts_core::policy)]
fun zero_min_leverage_improvement_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebalancePolicy, location = blast_boosts_core::policy)]
fun threshold_validation_precedes_tolerance_and_improvement_validation() {
    policy::new_rebalance_policy(0, 0, 0, 0, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxSlippageBps, location = blast_boosts_core::policy)]
fun max_slippage_validation_precedes_improvement_validation() {
    policy::new_rebalance_policy(0, 2, 4, 5, 10_000, 9_999, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidEmergencyMaxSlippageBps, location = blast_boosts_core::policy)]
fun emergency_validation_precedes_improvement_validation() {
    policy::new_rebalance_policy(0, 2, 4, 5, 0, 10_000, 0);
}

/// Every comparison cross-multiplies, so a zero NAV never divides and reads as infinite leverage.
#[test]
fun leverage_predicates_against_zero_nav_do_not_wrap() {
    let value = standard_policy();

    assert!(!value.is_leverage_below_band(0, 0));
    assert!(!value.is_leverage_below_band(1, 0));
    assert!(value.is_leverage_above_band_for_testing(1, 0));
    assert!(!value.is_leverage_above_band_for_testing(0, 0));
    assert!(value.is_leverage_within_band(0, 0));
    assert!(value.is_leverage_at_most_target(0, 0));
    assert!(!value.is_leverage_below_max(0, 0));
    assert!(value.is_leverage_above_max(1, 0));
}

#[test]
fun maximum_width_leverage_comparisons_do_not_wrap() {
    let max = std::u64::max_value!();
    let value = standard_policy();

    assert!(value.is_leverage_below_band(max, max));
    assert!(!value.is_leverage_within_band(max, max));
    assert!(value.is_leverage_above_max(max, 1));
    assert!(!value.is_leverage_above_max(1, max));
    assert!(value.is_leverage_at_most_target(max, max));
}

#[test]
fun at_most_target_is_inclusive_at_the_target_edge() {
    let value = standard_policy();

    assert!(value.is_leverage_at_most_target(19_999, 10_000));
    assert!(value.is_leverage_at_most_target(20_000, 10_000));
    assert!(!value.is_leverage_at_most_target(20_001, 10_000));
    // The comparison is exact: one atom over the edge on a large NAV still counts.
    let nav = std::u64::max_value!() / 3;
    let edge = ((nav as u128) * 20_000 / 10_000) as u64;
    assert!(value.is_leverage_at_most_target(edge, nav));
    assert!(!value.is_leverage_at_most_target(edge + 1, nav));
}

#[test]
fun below_max_is_strict_at_the_max_edge() {
    let value = standard_policy();

    assert!(value.is_leverage_below_max(29_999, 10_000));
    assert!(!value.is_leverage_below_max(30_000, 10_000));
    assert!(!value.is_leverage_below_max(30_001, 10_000));
}

// === Test Helpers ===

fun standard_policy(): RebalancePolicy {
    policy::new_rebalance_policy(
        16_000,
        20_000,
        26_000,
        30_000,
        100,
        500,
        10,
    )
}

fun new_with_thresholds(
    rebalance_below: u64,
    target: u64,
    rebalance_above: u64,
    max_leverage: u64,
): RebalancePolicy {
    policy::new_rebalance_policy(
        rebalance_below,
        target,
        rebalance_above,
        max_leverage,
        0,
        0,
        1,
    )
}

// === Imports ===

use std::unit_test::assert_eq;

use blast_boosts_core::{errors, policy::{Self, RebalancePolicy}};
