#[test_only]
/// Validation tests for immutable Series policy facts.
module blast_leverage_coins::series_policy_tests;

use std::unit_test::assert_eq;

use blast_leverage_coins::{errors, series};

// === Tests ===

#[test]
fun the_smallest_valid_long_policy_is_accepted_and_preserved() {
    let policy = new_policy(true, 0, 0, 1, 1);
    let bounds = policy.leverage_bounds();

    assert_eq!(policy.side(), series::long());
    assert_eq!(bounds.lower_bps(), 1);
    assert_eq!(bounds.target_bps(), 2);
    assert_eq!(bounds.upper_bps(), 3);
    assert_eq!(bounds.hard_cap_bps(), 4);
    assert_eq!(policy.mint_fee_bps(), 0);
    assert_eq!(policy.redeem_fee_bps(), 0);
    assert_eq!(policy.min_exposure_lots(), 1);
    assert_eq!(policy.nav_cap(), 1);
}

#[test]
fun the_largest_locally_valid_short_policy_is_accepted_and_preserved() {
    let max = std::u64::max_value!();
    let policy = series::new_policy(
        series::short(),
        1,
        2,
        max - 1,
        max,
        9_999,
        9_999,
        max,
        max,
    );
    let bounds = policy.leverage_bounds();

    assert_eq!(policy.side(), series::short());
    assert_eq!(bounds.hard_cap_bps(), max);
    assert_eq!(policy.mint_fee_bps(), 9_999);
    assert_eq!(policy.redeem_fee_bps(), 9_999);
    assert_eq!(policy.min_exposure_lots(), max);
    assert_eq!(policy.nav_cap(), max);
}

#[test]
fun every_small_valid_policy_tuple_is_accepted_and_preserved() {
    vector[false, true].do!(|is_long| {
        0u64.range_do!(4, |mint_fee_bps| {
            0u64.range_do!(4, |redeem_fee_bps| {
                1u64.range_do!(4, |min_exposure_lots| {
                    1u64.range_do!(4, |nav_cap| {
                        let expected_side = if (is_long) {
                            series::long()
                        } else {
                            series::short()
                        };
                        let policy = new_policy(
                            is_long,
                            mint_fee_bps,
                            redeem_fee_bps,
                            min_exposure_lots,
                            nav_cap,
                        );

                        assert_eq!(policy.side(), expected_side);
                        assert_eq!(policy.mint_fee_bps(), mint_fee_bps);
                        assert_eq!(policy.redeem_fee_bps(), redeem_fee_bps);
                        assert_eq!(policy.min_exposure_lots(), min_exposure_lots);
                        assert_eq!(policy.nav_cap(), nav_cap);
                    });
                });
            });
        });
    });
}

#[test]
fun a_policy_is_a_copyable_immutable_value() {
    let policy = new_policy(true, 1, 2, 3, 4);
    let copied_policy = policy;

    assert_eq!(policy.side(), copied_policy.side());
    assert_eq!(policy.leverage_bounds(), copied_policy.leverage_bounds());
    assert_eq!(policy.mint_fee_bps(), copied_policy.mint_fee_bps());
    assert_eq!(policy.redeem_fee_bps(), copied_policy.redeem_fee_bps());
    assert_eq!(policy.min_exposure_lots(), copied_policy.min_exposure_lots());
    assert_eq!(policy.nav_cap(), copied_policy.nav_cap());
}

#[test]
fun the_smallest_strictly_ordered_bounds_are_accepted() {
    let bounds = new_policy_with_bounds(1, 2, 3, 4).leverage_bounds();

    assert_eq!(bounds.lower_bps(), 1);
    assert_eq!(bounds.target_bps(), 2);
    assert_eq!(bounds.upper_bps(), 3);
    assert_eq!(bounds.hard_cap_bps(), 4);
}

#[test]
fun bounds_support_the_maximum_hard_cap() {
    let max = std::u64::max_value!();
    let bounds = new_policy_with_bounds(1, 2, max - 1, max).leverage_bounds();

    assert_eq!(bounds.lower_bps(), 1);
    assert_eq!(bounds.target_bps(), 2);
    assert_eq!(bounds.upper_bps(), max - 1);
    assert_eq!(bounds.hard_cap_bps(), max);
}

#[test]
fun every_strictly_ordered_small_bounds_tuple_is_accepted_and_preserved() {
    1u64.range_do!(7, |lower_bps| {
        1u64.range_do!(7, |target_bps| {
            1u64.range_do!(7, |upper_bps| {
                1u64.range_do!(7, |hard_cap_bps| {
                    if (
                        lower_bps < target_bps
                            && target_bps < upper_bps
                            && upper_bps < hard_cap_bps
                    ) {
                        let bounds = new_policy_with_bounds(
                            lower_bps,
                            target_bps,
                            upper_bps,
                            hard_cap_bps,
                        ).leverage_bounds();

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
    let bounds = new_policy_with_bounds(1, 2, 3, 4).leverage_bounds();
    let copied_bounds = bounds;

    assert_eq!(bounds.target_bps(), copied_bounds.target_bps());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun a_zero_lower_bound_is_rejected() {
    new_policy_with_bounds(0, 2, 3, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun a_lower_bound_equal_to_the_target_is_rejected() {
    new_policy_with_bounds(2, 2, 3, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun a_lower_bound_above_the_target_is_rejected() {
    new_policy_with_bounds(3, 2, 4, 5);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun a_target_equal_to_the_upper_bound_is_rejected() {
    new_policy_with_bounds(1, 3, 3, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun a_target_above_the_upper_bound_is_rejected() {
    new_policy_with_bounds(1, 4, 3, 5);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun an_upper_bound_equal_to_the_hard_cap_is_rejected() {
    new_policy_with_bounds(1, 2, 4, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun an_upper_bound_above_the_hard_cap_is_rejected() {
    new_policy_with_bounds(1, 2, 5, 4);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidFeeBps,
    location = blast_leverage_coins::series,
)]
fun a_mint_fee_at_the_denominator_is_rejected() {
    new_policy(true, 10_000, 0, 1, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidFeeBps,
    location = blast_leverage_coins::series,
)]
fun a_redeem_fee_at_the_denominator_is_rejected() {
    new_policy(true, 0, 10_000, 1, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidFeeBps,
    location = blast_leverage_coins::series,
)]
fun a_fee_above_the_denominator_is_rejected() {
    new_policy(true, 0, std::u64::max_value!(), 1, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMinExposureLots,
    location = blast_leverage_coins::series,
)]
fun zero_minimum_exposure_lots_are_rejected() {
    new_policy(true, 0, 0, 0, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidSeriesNavCap,
    location = blast_leverage_coins::series,
)]
fun a_zero_nav_cap_is_rejected() {
    new_policy(true, 0, 0, 1, 0);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidFeeBps,
    location = blast_leverage_coins::series,
)]
fun fee_validation_precedes_minimum_lots_and_nav_cap_validation() {
    new_policy(true, 10_000, 10_000, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLeverageBounds,
    location = blast_leverage_coins::series,
)]
fun leverage_bounds_validation_precedes_other_policy_validation() {
    series::new_policy(
        series::long(),
        0,
        0,
        0,
        0,
        10_000,
        10_000,
        0,
        0,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMinExposureLots,
    location = blast_leverage_coins::series,
)]
fun minimum_lot_validation_precedes_nav_cap_validation() {
    new_policy(true, 0, 0, 0, 0);
}

// === Private Functions ===

fun new_policy(
    is_long: bool,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
): series::SeriesPolicy {
    series::new_policy(
        if (is_long) series::long() else series::short(),
        1,
        2,
        3,
        4,
        mint_fee_bps,
        redeem_fee_bps,
        min_exposure_lots,
        nav_cap,
    )
}

fun new_policy_with_bounds(
    lower_bps: u64,
    target_bps: u64,
    upper_bps: u64,
    hard_cap_bps: u64,
): series::SeriesPolicy {
    series::new_policy(
        series::long(),
        lower_bps,
        target_bps,
        upper_bps,
        hard_cap_bps,
        0,
        0,
        1,
        1,
    )
}
