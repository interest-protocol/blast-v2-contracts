#[test_only]
/// Structural and boundary tests for immutable rebalance policy.
module blast_boosts_core::rebalance_policy_tests;

// === Tests ===

#[test]
fun one_public_band_accepts_adjacent_thresholds_and_has_inclusive_endpoints() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1);
    // Leverage 0 bps: notional 0 against NAV 10_000.
    assert!(!value.is_leverage_below_band(0, 10_000));
    assert!(!value.is_leverage_above_band(0, 10_000));
    // Leverage 2 bps sits exactly on the upper edge.
    assert!(!value.is_leverage_below_band(2, 10_000));
    assert!(!value.is_leverage_above_band(2, 10_000));
    assert!(!value.is_leverage_above_max(3, 10_000));
    assert!(value.is_leverage_above_max(4, 10_000));
}

#[test]
fun the_smallest_strictly_ordered_policy_is_preserved() {
    let value = policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1);

    assert_eq!(value.rebalance_below_bps(), 0);
    assert_eq!(value.target_bps(), 1);
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
    assert_eq!(copied.target_bps(), value.target_bps());
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
                    assert_eq!(value.target_bps(), target);
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
    assert!(!value.is_leverage_above_band(16_000, 10_000));
    assert!(!value.is_leverage_above_band(26_000, 10_000));
    assert!(!value.is_leverage_below_band(26_000, 10_000));
    assert!(value.is_leverage_above_band(26_001, 10_000));
    assert!(!value.is_leverage_above_max(29_999, 10_000));
    assert!(!value.is_leverage_above_max(30_000, 10_000));
    assert!(value.is_leverage_above_max(30_001, 10_000));
    // The comparison is exact: one atom over the edge on a large NAV still counts.
    let nav = std::u64::max_value!() / 3;
    let edge = ((nav as u128) * 26_000 / 10_000) as u64;
    assert!(!value.is_leverage_above_band(edge, nav));
    assert!(value.is_leverage_above_band(edge + 1, nav));
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
    assert!(!value.is_leverage_above_band(0, 10_000));
}

#[test]
fun execution_slippage_bounds_are_inclusive_and_symmetric() {
    let value = standard_policy();

    assert!(value.is_execution_within_max_slippage(1_000_000, 1_010_000));
    assert!(!value.is_execution_within_max_slippage(1_000_000, 1_010_001));
    assert!(value.is_execution_within_max_slippage(1_000_000, 990_000));
    assert!(!value.is_execution_within_max_slippage(1_000_000, 989_999));
    assert!(value.is_execution_within_emergency_max_slippage(1_000_000, 1_010_001));
    assert!(value.is_execution_within_emergency_max_slippage(1_000_000, 1_050_000));
    assert!(!value.is_execution_within_emergency_max_slippage(1_000_000, 1_050_001));
    assert!(value.is_execution_within_emergency_max_slippage(1_000_000, 950_000));
    assert!(!value.is_execution_within_emergency_max_slippage(1_000_000, 949_999));
    assert!(!value.is_execution_within_max_slippage(0, 0));
    assert!(!value.is_execution_within_emergency_max_slippage(0, 0));
    value.assert_execution_within_max_slippage(1_000_000, 1_010_000);
    value.assert_execution_within_emergency_max_slippage(1_000_000, 1_050_000);
}

#[test]
fun maximum_width_execution_tolerance_does_not_wrap() {
    let max = std::u64::max_value!();
    let value = policy::new_rebalance_policy(0, 2, 4, 5, 9_999, 9_999, 1);

    assert!(value.is_execution_within_max_slippage(max, max));
    assert!(!value.is_execution_within_max_slippage(max, 0));
    assert!(!value.is_execution_within_max_slippage(1, max));
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_execution_one_unit_past_max_slippage_is_rejected() {
    standard_policy().assert_execution_within_max_slippage(1_000_000, 1_010_001);
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_execution_one_unit_past_emergency_max_slippage_is_rejected() {
    standard_policy().assert_execution_within_emergency_max_slippage(1_000_000, 1_050_001);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPrice, location = blast_boosts_core::policy)]
fun a_zero_reference_is_rejected_before_the_max_slippage() {
    standard_policy().assert_execution_within_max_slippage(0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPrice, location = blast_boosts_core::policy)]
fun a_zero_reference_is_rejected_before_the_emergency_max_slippage() {
    standard_policy().assert_execution_within_emergency_max_slippage(0, 0);
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
    rebalance_below: u64,
    target: u64,
    rebalance_above: u64,
    max_leverage: u64,
): policy::RebalancePolicy {
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

use blast_boosts_core::{errors, policy};
