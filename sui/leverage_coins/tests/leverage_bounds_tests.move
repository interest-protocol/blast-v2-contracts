#[test_only]
/// Validation tests for immutable Series leverage bounds.
module blast_leverage_coins::leverage_bounds_tests;

use std::unit_test::assert_eq;

use blast_leverage_coins::{errors, leverage_bounds};

// === Tests ===

#[test]
fun the_smallest_strictly_ordered_bounds_are_accepted() {
    let bounds = leverage_bounds::new(1, 2, 3, 4);

    assert_eq!(bounds.lower_bps(), 1);
    assert_eq!(bounds.target_bps(), 2);
    assert_eq!(bounds.upper_bps(), 3);
    assert_eq!(bounds.hard_cap_bps(), 4);
}

#[test]
fun bounds_support_the_maximum_hard_cap() {
    let max = std::u64::max_value!();
    let bounds = leverage_bounds::new(1, 2, max - 1, max);

    assert_eq!(bounds.lower_bps(), 1);
    assert_eq!(bounds.target_bps(), 2);
    assert_eq!(bounds.upper_bps(), max - 1);
    assert_eq!(bounds.hard_cap_bps(), max);
}

#[test]
fun every_strictly_ordered_small_tuple_is_accepted_and_preserved() {
    1u64.range_do!(7, |lower_bps| {
        1u64.range_do!(7, |target_bps| {
            1u64.range_do!(7, |upper_bps| {
                1u64.range_do!(7, |hard_cap_bps| {
                    if (
                        lower_bps < target_bps
                            && target_bps < upper_bps
                            && upper_bps < hard_cap_bps
                    ) {
                        let bounds = leverage_bounds::new(
                            lower_bps,
                            target_bps,
                            upper_bps,
                            hard_cap_bps,
                        );

                        assert_eq!(bounds.lower_bps(), lower_bps);
                        assert_eq!(bounds.target_bps(), target_bps);
                        assert_eq!(bounds.upper_bps(), upper_bps);
                        assert_eq!(bounds.hard_cap_bps(), hard_cap_bps);
                    };
                });
            });
        });
    });
}

#[test]
fun bounds_are_copyable_immutable_values() {
    let bounds = leverage_bounds::new(1, 2, 3, 4);
    let copied_bounds = bounds;

    assert_eq!(bounds.target_bps(), copied_bounds.target_bps());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun a_zero_lower_bound_is_rejected() {
    leverage_bounds::new(0, 2, 3, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun a_lower_bound_equal_to_the_target_is_rejected() {
    leverage_bounds::new(2, 2, 3, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun a_lower_bound_above_the_target_is_rejected() {
    leverage_bounds::new(3, 2, 4, 5);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun a_target_equal_to_the_upper_bound_is_rejected() {
    leverage_bounds::new(1, 3, 3, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun a_target_above_the_upper_bound_is_rejected() {
    leverage_bounds::new(1, 4, 3, 5);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun an_upper_bound_equal_to_the_hard_cap_is_rejected() {
    leverage_bounds::new(1, 2, 4, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::leverage_bounds,
)]
fun an_upper_bound_above_the_hard_cap_is_rejected() {
    leverage_bounds::new(1, 2, 5, 4);
}
