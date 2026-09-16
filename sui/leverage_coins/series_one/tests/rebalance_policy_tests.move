#[test_only]
/// Structural and boundary tests for immutable rebalance policy.
module blast_leverage_series_one::rebalance_policy_tests;

use std::unit_test::assert_eq;

use blast_leverage_series_one::{policy};

// === Tests ===

#[test]
fun one_public_band_accepts_adjacent_thresholds_and_has_inclusive_endpoints() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1);
    assert!(value.is_healthy(0));
    assert!(value.is_healthy(2));
    assert!(!value.is_public_allowed(0));
    assert!(!value.is_public_allowed(2));
    assert!(!value.is_hard_emergency(3));
    assert!(value.is_hard_emergency(4));
}

#[test]
fun the_smallest_strictly_ordered_policy_is_preserved() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1);

    assert_eq!(value.public_lower_bps(), 0);
    assert_eq!(value.target_bps(), 1);
    assert_eq!(value.public_upper_bps(), 2);
    assert_eq!(value.hard_cap_bps(), 3);
    assert_eq!(value.strict_tolerance_bps(), 0);
    assert_eq!(value.emergency_tolerance_bps(), 0);
    assert_eq!(value.minimum_improvement_bps(), 1);
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

    assert_eq!(value.hard_cap_bps(), 1_000_000);
    assert_eq!(value.minimum_improvement_bps(), max);
}

#[test]
fun copied_policy_preserves_every_field() {
    let value = policy::new_rebalance_policy(1, 3, 5, 6, 7, 8, 9);
    let copied = value;

    assert_eq!(copied.public_lower_bps(), value.public_lower_bps());
    assert_eq!(copied.target_bps(), value.target_bps());
    assert_eq!(copied.public_upper_bps(), value.public_upper_bps());
    assert_eq!(copied.hard_cap_bps(), value.hard_cap_bps());
    assert_eq!(copied.strict_tolerance_bps(), value.strict_tolerance_bps());
    assert_eq!(copied.emergency_tolerance_bps(), value.emergency_tolerance_bps());
    assert_eq!(copied.minimum_improvement_bps(), value.minimum_improvement_bps());
}

#[test]
fun every_strictly_ordered_small_tuple_is_accepted_and_preserved() {
    0u64.range_do!(8, |public_lower| {
        (public_lower + 1).range_do!(8, |target| {
            (target + 1).range_do!(8, |public_upper| {
                (public_upper + 1).range_do!(8, |hard_cap| {
                    let value = policy::new_rebalance_policy(public_lower, target, public_upper, hard_cap, 0, 0, 1);
                    assert_eq!(value.public_lower_bps(), public_lower);
                    assert_eq!(value.target_bps(), target);
                    assert_eq!(value.public_upper_bps(), public_upper);
                    assert_eq!(value.hard_cap_bps(), hard_cap);
                });
            });
        });
    });
}

#[test]
fun eligibility_predicates_pin_every_threshold_equality() {
    let value = standard_policy();

    assert!(value.is_public_allowed(15_999));
    assert!(!value.is_public_allowed(16_000));
    assert!(!value.is_healthy(15_999));
    assert!(value.is_healthy(16_000));
    assert!(value.is_healthy(17_999));
    assert!(value.is_healthy(22_000));
    assert!(value.is_healthy(26_000));
    assert!(!value.is_public_allowed(26_000));
    assert!(value.is_public_allowed(26_001));
    assert!(!value.is_hard_emergency(29_999));
    assert!(!value.is_hard_emergency(30_000));
    assert!(value.is_hard_emergency(30_001));
}

#[test]
fun a_hard_cap_at_the_leverage_ceiling_is_accepted() {
    assert_eq!(new_with_thresholds(0, 2, 4, 1_000_000).hard_cap_bps(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun a_hard_cap_above_the_leverage_ceiling_is_rejected() {
    new_with_thresholds(0, 2, 4, 1_000_001);
}

#[test]
fun a_zero_public_lower_threshold_disables_the_lower_public_trigger() {
    let value = new_with_thresholds(0, 2, 4, 5);

    assert!(!value.is_public_allowed(0));
    assert!(value.is_healthy(0));
}

#[test]
fun improvement_is_the_decrease_in_distance_from_target() {
    let value = standard_policy();

    assert!(value.is_improvement_sufficient(22_000, 21_990));
    assert!(!value.is_improvement_sufficient(22_000, 21_991));
    assert!(value.is_improvement_sufficient(22_000, 20_000));
    assert!(value.is_improvement_sufficient(18_000, 18_010));
    assert!(!value.is_improvement_sufficient(18_000, 18_009));
    assert!(value.is_improvement_sufficient(22_000, 18_010));
    assert!(!value.is_improvement_sufficient(22_000, 17_990));
    assert!(!value.is_improvement_sufficient(20_000, 20_000));
    assert!(!value.is_improvement_sufficient(21_000, 22_000));
    value.assert_improvement_sufficient(22_000, 21_990);
}

#[test]
fun improvement_comparison_does_not_wrap_at_maximum_width() {
    let max = std::u64::max_value!();
    let value = policy::new_rebalance_policy(0, 2, 4, 5, 0, 0, max);

    assert!(!value.is_improvement_sufficient(max, 2));
    assert!(!value.is_improvement_sufficient(max, max));
}

#[test]
#[expected_failure(abort_code = policy::EInsufficientLeverageImprovement, location = blast_leverage_series_one::policy)]
fun a_rebalance_one_basis_point_short_of_the_minimum_improvement_is_rejected() {
    standard_policy().assert_improvement_sufficient(22_000, 21_991);
}

#[test]
fun execution_tolerances_are_inclusive_and_symmetric() {
    let value = standard_policy();

    assert!(value.is_execution_within_strict_tolerance(1_000_000, 1_010_000));
    assert!(!value.is_execution_within_strict_tolerance(1_000_000, 1_010_001));
    assert!(value.is_execution_within_strict_tolerance(1_000_000, 990_000));
    assert!(!value.is_execution_within_strict_tolerance(1_000_000, 989_999));
    assert!(value.is_execution_within_emergency_tolerance(1_000_000, 1_010_001));
    assert!(value.is_execution_within_emergency_tolerance(1_000_000, 1_050_000));
    assert!(!value.is_execution_within_emergency_tolerance(1_000_000, 1_050_001));
    assert!(value.is_execution_within_emergency_tolerance(1_000_000, 950_000));
    assert!(!value.is_execution_within_emergency_tolerance(1_000_000, 949_999));
    assert!(!value.is_execution_within_strict_tolerance(0, 0));
    assert!(!value.is_execution_within_emergency_tolerance(0, 0));
    value.assert_execution_within_strict_tolerance(1_000_000, 1_010_000);
    value.assert_execution_within_emergency_tolerance(1_000_000, 1_050_000);
}

#[test]
fun maximum_width_execution_tolerance_does_not_wrap() {
    let max = std::u64::max_value!();
    let value = policy::new_rebalance_policy(0, 2, 4, 5, 9_999, 9_999, 1);

    assert!(value.is_execution_within_strict_tolerance(max, max));
    assert!(!value.is_execution_within_strict_tolerance(max, 0));
    assert!(!value.is_execution_within_strict_tolerance(1, max));
}

#[test]
#[expected_failure(abort_code = policy::EExecutionOutsideTolerance, location = blast_leverage_series_one::policy)]
fun an_execution_one_unit_past_strict_tolerance_is_rejected() {
    standard_policy().assert_execution_within_strict_tolerance(1_000_000, 1_010_001);
}

#[test]
#[expected_failure(abort_code = policy::EExecutionOutsideTolerance, location = blast_leverage_series_one::policy)]
fun an_execution_one_unit_past_emergency_tolerance_is_rejected() {
    standard_policy().assert_execution_within_emergency_tolerance(1_000_000, 1_050_001);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidValuationPrice, location = blast_leverage_series_one::policy)]
fun a_zero_reference_is_rejected_before_the_strict_tolerance() {
    standard_policy().assert_execution_within_strict_tolerance(0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidValuationPrice, location = blast_leverage_series_one::policy)]
fun a_zero_reference_is_rejected_before_the_emergency_tolerance() {
    standard_policy().assert_execution_within_emergency_tolerance(0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun public_lower_equal_to_target_is_rejected() {
    new_with_thresholds(1, 1, 2, 3);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun public_lower_above_target_is_rejected() {
    new_with_thresholds(2, 1, 3, 4);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun target_equal_to_public_upper_is_rejected() {
    new_with_thresholds(0, 2, 2, 3);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun target_above_public_upper_is_rejected() {
    new_with_thresholds(0, 3, 2, 4);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun public_upper_equal_to_hard_cap_is_rejected() {
    new_with_thresholds(0, 2, 5, 5);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun public_upper_above_hard_cap_is_rejected() {
    new_with_thresholds(0, 2, 6, 5);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidStrictToleranceBps, location = blast_leverage_series_one::policy)]
fun strict_tolerance_at_the_denominator_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 10_000, 10_000, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidEmergencyToleranceBps, location = blast_leverage_series_one::policy)]
fun emergency_tolerance_at_the_denominator_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 0, 10_000, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidEmergencyToleranceBps, location = blast_leverage_series_one::policy)]
fun emergency_tolerance_below_strict_tolerance_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 2, 1, 1);
}

#[test]
fun equal_strict_and_emergency_tolerances_are_accepted() {
    let value = policy::new_rebalance_policy(0, 2, 4, 5, 9_999, 9_999, 1);

    assert_eq!(value.strict_tolerance_bps(), value.emergency_tolerance_bps());
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinimumImprovementBps, location = blast_leverage_series_one::policy)]
fun zero_minimum_improvement_is_rejected() {
    policy::new_rebalance_policy(0, 2, 4, 5, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidRebalancePolicy, location = blast_leverage_series_one::policy)]
fun threshold_validation_precedes_tolerance_and_improvement_validation() {
    policy::new_rebalance_policy(0, 0, 0, 0, 10_000, 0, 0);
}

// === Private Functions ===

fun standard_policy(): policy::RebalancePolicy {
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
    public_lower: u64,
    target: u64,
    public_upper: u64,
    hard_cap: u64,
): policy::RebalancePolicy {
    policy::new_rebalance_policy(
        public_lower,
        target,
        public_upper,
        hard_cap,
        0,
        0,
        1,
    )
}
