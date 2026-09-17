#[test_only]
/// Leverage, target notional, and the two-sided proportional-exposure bounds.
module blast_leverage_core::exposure_math_tests;

use blast_leverage_core::{accounting_math, errors};
use std::unit_test::assert_eq;

// === Tests ===

/// Catches reporting an unsafe position as safer than it is.
#[test]
fun leverage_rounds_up_and_reports_a_flat_position_as_zero() {
    assert_eq!(accounting_math::leverage_bps_up_for_testing(0, 100), 0);
    assert_eq!(accounting_math::leverage_bps_up_for_testing(100, 100), 10_000);
    assert_eq!(accounting_math::leverage_bps_up_for_testing(200, 100), 20_000);
    assert_eq!(accounting_math::leverage_bps_up_for_testing(200_000_001, 100_000_000), 20_001);
    assert_eq!(accounting_math::leverage_bps_up_for_testing(1, 10_000), 1);
    assert_eq!(accounting_math::leverage_bps_up_for_testing(1, 10_001), 1);
}

/// Catches an intermediate `notional * 10_000` that wraps instead of widening.
#[test]
fun leverage_supports_its_maximum_representable_ratio() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::leverage_bps_up_for_testing(max, max), 10_000);
    assert_eq!(accounting_math::leverage_bps_up_for_testing(max, 10_000), max);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun leverage_against_zero_nav_is_rejected() {
    accounting_math::leverage_bps_up_for_testing(100, 0);
}

/// Pins the first ratio above the supported `u64` range.
#[test]
#[expected_failure(
    abort_code = errors::EArithmeticOverflow,
    location = blast_leverage_core::accounting_math,
)]
fun leverage_above_the_supported_bound_is_rejected() {
    accounting_math::leverage_bps_up_for_testing(std::u64::max_value!(), 9_999);
}

/// Catches targeting more notional than the requested leverage allows.
#[test]
fun target_notional_rounds_down() {
    assert_eq!(accounting_math::target_notional_down_for_testing(100, 20_000), 200);
    assert_eq!(accounting_math::target_notional_down_for_testing(1, 20_000), 2);
    assert_eq!(accounting_math::target_notional_down_for_testing(10_000, 1), 1);
    assert_eq!(accounting_math::target_notional_down_for_testing(9_999, 1), 0);
    assert_eq!(accounting_math::target_notional_down_for_testing(1, 1), 0);
}

/// Catches an intermediate `nav * target_leverage_bps` that wraps instead of widening.
#[test]
fun target_notional_supports_its_maximum_representable_value() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::target_notional_down_for_testing(max, 10_000), max);
    assert_eq!(accounting_math::target_notional_down_for_testing(max, 9_999), 18_444_899_399_302_180_659);
}

/// Proves target-notional floor and reported-leverage ceiling are conservative duals.
#[test]
fun target_and_reported_leverage_are_dual_across_the_operating_band() {
    let max = std::u64::max_value!();

    vector[1u64, 9_999, 10_000, 1_000_000, max / 3].do!(|nav| {
        vector[1u64, 9_999, 10_000, 18_000, 20_000, 22_000].do!(|target_leverage_bps| {
            assert_target_round_trip_is_conservative(nav, target_leverage_bps);
        });
    });
    assert_target_round_trip_is_conservative(1, max);

    let notional_at_lower = accounting_math::target_notional_down_for_testing(1_000_000, 18_000);
    let notional_at_target = accounting_math::target_notional_down_for_testing(1_000_000, 20_000);
    let notional_at_upper = accounting_math::target_notional_down_for_testing(1_000_000, 22_000);

    assert_eq!(notional_at_lower, 1_800_000);
    assert_eq!(notional_at_target, 2_000_000);
    assert_eq!(notional_at_upper, 2_200_000);
    assert!(notional_at_lower < notional_at_target);
    assert!(notional_at_target < notional_at_upper);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun a_target_notional_against_zero_nav_is_rejected() {
    accounting_math::target_notional_down_for_testing(0, 20_000);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidTargetLeverageBps,
    location = blast_leverage_core::accounting_math,
)]
fun a_zero_target_leverage_is_rejected() {
    accounting_math::target_notional_down_for_testing(100, 0);
}

/// Pins the NAV guard ahead of the target guard when both are zero.
#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun zero_nav_is_rejected_before_a_zero_target_leverage() {
    accounting_math::target_notional_down_for_testing(0, 0);
}

#[test]
#[expected_failure(
    abort_code = errors::EArithmeticOverflow,
    location = blast_leverage_core::accounting_math,
)]
fun a_target_notional_above_the_supported_bound_is_rejected() {
    accounting_math::target_notional_down_for_testing(std::u64::max_value!(), 10_001);
}

/// Catches a mint opening more exposure than its contribution funds.
#[test]
fun the_mint_base_delta_rounds_down_to_the_live_lot() {
    assert_eq!(
        accounting_math::mint_base_delta_down_for_testing(990_000, 1_000_000, 1_000_000_000, 1, 1),
        990,
    );
    assert_eq!(
        accounting_math::mint_base_delta_down_for_testing(990_000, 1_000_000, 1_000_000_000, 100, 1),
        900,
    );
    // An exact multiple of the lot keeps the complete proportional target.
    assert_eq!(
        accounting_math::mint_base_delta_down_for_testing(1_000, 1_000_000_000, 1_000_000_000, 1_000, 1),
        1_000,
    );
}

/// Catches an intermediate `base_before * contribution` that wraps instead of widening.
#[test]
fun the_mint_base_delta_supports_maximum_supported_values() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::mint_base_delta_down_for_testing(2, max, 2, 1, 1), max);
    assert_eq!(accounting_math::mint_base_delta_down_for_testing(2, max, 2, 1, max), max);
}

/// Catches a rounded delta that exceeds its proportional target or falls a lot short.
#[test]
fun the_mint_base_delta_never_exceeds_its_proportional_target() {
    assert_mint_base_delta_is_proportional(990_000, 1_000_000, 1_000_000_000, 1, 1);
    assert_mint_base_delta_is_proportional(990_000, 1_000_000, 1_000_000_000, 100, 1);
    assert_mint_base_delta_is_proportional(990_000, 1_000_000, 1_000_000_000, 7, 1);
    assert_mint_base_delta_is_proportional(990_000, 1_000_000, 1_000_000_000, 7, 100);
    assert_mint_base_delta_is_proportional(1_000, 1_000_000_000, 1_000_000_000, 1_000, 1);
    assert_mint_base_delta_is_proportional(1, 1_000_000_000, 1_000_000_000, 1, 1);
    assert_mint_base_delta_is_proportional(2, std::u64::max_value!(), 2, 1, 1);
}

/// Exhausts a bounded domain around proportional-floor and minimum-lot boundaries.
#[test]
fun mint_base_delta_matches_its_definition_across_the_small_domain() {
    1u64.range_do!(13, |nav_before| {
        1u64.range_do!(13, |base_before| {
            0u64.range_do!(13, |contribution| {
                1u64.range_do!(9, |lot_size| {
                    1u64.range_do!(4, |min_exposure_lots| {
                        let proportional_base = base_before * contribution / nav_before;

                        if (proportional_base >= lot_size * min_exposure_lots) {
                            assert_mint_base_delta_is_proportional(
                                contribution,
                                base_before,
                                nav_before,
                                lot_size,
                                min_exposure_lots,
                            );
                        };
                    });
                });
            });
        });
    });
}

/// Proves every contribution below the operation's lot has a sub-lot proportional target.
///
/// A one-unit lot exposes the raw proportional target. The production operation
/// instead uses the captured 1,000-unit lot and rejects each target below it;
/// the endpoint and midpoint abort tests pin that guard.
#[test]
fun every_dust_contribution_has_a_sub_lot_proportional_target() {
    1u64.range_do!(1_000, |contribution| {
        let proportional_base = accounting_math::mint_base_delta_down_for_testing(
            contribution,
            1_000_000_000,
            1_000_000_000,
            1,
            1,
        );

        assert_eq!(proportional_base, contribution);
        assert!(proportional_base < 1_000);
    });

    assert_eq!(
        accounting_math::mint_base_delta_down_for_testing(1_000, 1_000_000_000, 1_000_000_000, 1_000, 1),
        1_000,
    );
}

/// Pins the first proportional target the minimum lot multiple admits and its rounding.
#[test]
fun a_mint_at_the_minimum_lot_multiple_is_accepted() {
    assert_eq!(
        accounting_math::mint_base_delta_down_for_testing(100_000, 1_000_000_000, 1_000_000_000, 1_000, 100),
        100_000,
    );
    assert_eq!(
        accounting_math::mint_base_delta_down_for_testing(100_999, 1_000_000_000, 1_000_000_000, 1_000, 100),
        100_000,
    );
}

/// Proves the minimum lot multiple caps under-exposure at `1 / min_exposure_lots` of the target.
#[test]
fun the_minimum_lot_multiple_bounds_relative_under_exposure() {
    vector[1u64, 10, 100].do!(|min_exposure_lots| {
        vector[1u64, 7, 1_000].do!(|lot_size| {
            let first_target = lot_size * min_exposure_lots;

            first_target.range_do!(first_target + 3 * lot_size, |contribution| {
                assert_mint_base_delta_is_proportional(
                    contribution,
                    1_000_000_000,
                    1_000_000_000,
                    lot_size,
                    min_exposure_lots,
                );
            });
        });
    });
}

/// Regression for cumulative drift: a one-lot minimum lets worst-case mints leave the band.
///
/// The exact figures are pinned so `docs/accounting.md` cannot drift from the
/// harness: the pool first drops below 1.8x on mint 2,229 and ends 3,000 mints
/// at 1.7397x with NAV up 32 percent.
#[test]
fun repeated_worst_case_mints_leave_the_band_with_a_one_lot_minimum() {
    let (leverage_after_drift, lowest, first_breach, nav) =
        drift_after_worst_case_mints(3_000, 1_000, 1);

    assert_eq!(first_breach, 2_229);
    assert_eq!(leverage_after_drift, 17_397);
    assert_eq!(lowest, 17_397);
    assert_eq!(nav, 13_221_338);
}

/// Proves a hundred-lot minimum keeps the same worst-case sequence inside the band.
#[test]
fun repeated_worst_case_mints_stay_in_band_with_a_hundred_lot_minimum() {
    let (leverage_after_drift, lowest, first_breach, nav) =
        drift_after_worst_case_mints(3_000, 1_000, 100);

    assert_eq!(first_breach, 0);
    assert_eq!(leverage_after_drift, 19_455);
    assert_eq!(lowest, 19_455);
    assert_eq!(nav, 164_485_245);
}

#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun the_smallest_dust_mint_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(1, 1_000_000_000, 1_000_000_000, 1_000, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun the_largest_sub_lot_mint_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(999, 1_000_000_000, 1_000_000_000, 1_000, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_mid_range_sub_lot_mint_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(500, 1_000_000_000, 1_000_000_000, 1_000, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_zero_contribution_mint_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(0, 1_000_000_000, 1_000_000_000, 1_000, 1);
}

/// Pins the last proportional target below a hundred-lot minimum.
#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_below_the_minimum_lot_multiple_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(99_999, 1_000_000_000, 1_000_000_000, 1_000, 100);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun a_mint_base_delta_against_zero_nav_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(10, 100, 0, 1, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidBaseExposure,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_base_delta_from_flat_exposure_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(10, 0, 100, 1, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLotSize,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_base_delta_with_a_zero_lot_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(10, 100, 100, 0, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMinExposureLots,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_base_delta_with_a_zero_minimum_lot_multiple_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(10, 100, 100, 1, 0);
}

/// Pins the NAV guard ahead of the exposure and lot guards.
#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun zero_nav_is_rejected_before_flat_exposure_and_a_zero_lot() {
    accounting_math::mint_base_delta_down_for_testing(10, 0, 0, 0, 0);
}

/// Pins the exposure guard ahead of the lot guard.
#[test]
#[expected_failure(
    abort_code = errors::EInvalidBaseExposure,
    location = blast_leverage_core::accounting_math,
)]
fun flat_exposure_is_rejected_before_a_zero_lot() {
    accounting_math::mint_base_delta_down_for_testing(10, 0, 100, 0, 0);
}

/// Pins the lot guard ahead of the minimum-lot-multiple guard.
#[test]
#[expected_failure(
    abort_code = errors::EInvalidLotSize,
    location = blast_leverage_core::accounting_math,
)]
fun a_zero_lot_is_rejected_before_a_zero_minimum_lot_multiple() {
    accounting_math::mint_base_delta_down_for_testing(10, 100, 100, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = errors::EArithmeticOverflow,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_base_delta_beyond_u64_is_rejected() {
    accounting_math::mint_base_delta_down_for_testing(3, std::u64::max_value!(), 2, 1, 1);
}

/// Catches a mint range that admits a fill beyond the plan or below the actual contribution.
#[test]
fun mint_bounds_span_the_actual_contribution_and_the_planned_fill() {
    let (min_delta, max_delta) = accounting_math::mint_base_bounds_for_testing(
        1_000_500,
        999_000,
        1_000_000,
        1_000_000_000,
        100,
        1,
    );

    assert_eq!(min_delta, 900);
    assert_eq!(max_delta, 1_000);

    // The full planned fill, the actual-contribution floor, and a point between are admitted.
    accounting_math::assert_mint_base_within_bounds_for_testing(1_001_000, 1_000_500, 999_000, 1_000_000, 1_000_000_000, 100, 1);
    accounting_math::assert_mint_base_within_bounds_for_testing(1_000_900, 1_000_500, 999_000, 1_000_000, 1_000_000_000, 100, 1);
    accounting_math::assert_mint_base_within_bounds_for_testing(1_000_950, 1_000_500, 999_000, 1_000_000, 1_000_000_000, 100, 1);
}

/// Pins the range the capped contribution produces: `[delta(actual), delta(expected)]`
/// with `actual <= expected`, collapsing to the planned fill when the cap binds.
#[test]
fun a_capped_contribution_never_widens_the_planned_fill() {
    vector[999_000u64, 1_000_000, 1_000_500].do!(|expected| {
        let planned = accounting_math::mint_base_delta_down_for_testing(
            expected, 1_000_000, 1_000_000_000, 100, 1,
        );

        vector[100_000u64, 500_000, expected - 1, expected].do!(|actual| {
            let (min_delta, max_delta) = accounting_math::mint_base_bounds_for_testing(
                expected, actual, 1_000_000, 1_000_000_000, 100, 1,
            );
            let actual_delta = accounting_math::mint_base_delta_down_for_testing(
                actual, 1_000_000, 1_000_000_000, 100, 1,
            );

            assert_eq!(max_delta, planned);
            assert_eq!(min_delta, actual_delta);
            assert!(min_delta <= max_delta);
            if (actual == expected) {
                assert_eq!(min_delta, max_delta);
            };
        });
    });
}

/// Catches an empty range when a favorable fill credits more than the plan expected.
#[test]
fun a_favorable_fill_demands_the_complete_planned_fill() {
    let (min_delta, max_delta) = accounting_math::mint_base_bounds_for_testing(
        999_000,
        1_000_500,
        1_000_000,
        1_000_000_000,
        100,
        1,
    );

    assert_eq!(min_delta, 900);
    assert_eq!(max_delta, 900);

    accounting_math::assert_mint_base_within_bounds_for_testing(1_000_900, 999_000, 1_000_500, 1_000_000, 1_000_000_000, 100, 1);
}

/// Exhausts small contributions, bases, lots, and minimums against the exact independent formula.
#[test]
fun mint_bounds_match_their_definition_across_the_small_domain() {
    1u64.range_do!(5, |nav_before| {
        1u64.range_do!(5, |base_before| {
            0u64.range_do!(9, |expected_contribution| {
                0u64.range_do!(9, |actual_contribution| {
                    1u64.range_do!(4, |lot_size| {
                        1u64.range_do!(3, |min_exposure_lots| {
                            let expected_target = base_before * expected_contribution / nav_before;
                            let actual_target = base_before * actual_contribution / nav_before;
                            let minimum = lot_size * min_exposure_lots;

                            if (expected_target >= minimum && actual_target >= minimum) {
                                assert_mint_bounds_hold(
                                    expected_contribution,
                                    actual_contribution,
                                    base_before,
                                    nav_before,
                                    lot_size,
                                    min_exposure_lots,
                                );
                            };
                        });
                    });
                });
            });
        });
    });
}

/// Catches a fill that opened more than the sealed plan.
#[test]
#[expected_failure(
    abort_code = errors::EMintOverExposed,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_fill_above_the_plan_is_rejected() {
    accounting_math::assert_mint_base_within_bounds_for_testing(1_001_001, 1_000_500, 999_000, 1_000_000, 1_000_000_000, 100, 1);
}

/// Catches a partial fill below the exposure the actual contribution funds.
#[test]
#[expected_failure(
    abort_code = errors::EMintUnderExposed,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_fill_below_the_actual_contribution_is_rejected() {
    accounting_math::assert_mint_base_within_bounds_for_testing(1_000_899, 1_000_500, 999_000, 1_000_000, 1_000_000_000, 100, 1);
}

/// Catches a mint whose actual credited contribution is dust even though its plan was not.
#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_whose_actual_contribution_is_dust_is_rejected() {
    accounting_math::mint_base_bounds_for_testing(1_000_500, 99, 1_000_000, 1_000_000_000, 100, 1);
}

/// Catches an upper bound that wraps past the maximum base.
#[test]
#[expected_failure(
    abort_code = errors::EArithmeticOverflow,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_bound_beyond_the_maximum_base_is_rejected() {
    let max = std::u64::max_value!();

    accounting_math::assert_mint_base_within_bounds_for_testing(max, 2, 2, max, 2, 1, 1);
}

/// Catches a remaining base above the proportional keep of ADR 0064 I11.
#[test]
fun redemption_bounds_keep_the_proportional_remaining_base() {
    // A one-unit lot admits exactly the proportional target.
    assert_redemption_bounds_eq(10, 1_000, 100, 1, 1, 900, 900);
    // An exact multiple of the lot also admits exactly that target.
    assert_redemption_bounds_eq(10, 1_000, 100, 100, 1, 900, 900);
    // A remainder opens a sub-lot tolerance below the target.
    assert_redemption_bounds_eq(10, 1_000, 100, 7, 1, 895, 900);
    assert_redemption_bounds_eq(10, 1_000, 100, 3, 1, 898, 900);
}

/// Catches an off-by-one at the first and last presentable share count.
#[test]
fun redemption_bounds_at_the_first_and_last_presentable_share_count() {
    assert_redemption_bounds_eq(1, 1_000, 100, 7, 1, 986, 990);
    assert_redemption_bounds_eq(99, 1_000, 100, 7, 1, 6, 10);
}

/// Catches a rounded reduction that cannot be capped at flat.
#[test]
fun redemption_bounds_cap_the_planned_reduction_at_flat() {
    // The kept base is below one lot: rounding up crosses the position, so the cap is flat.
    assert_redemption_bounds_eq(75, 20, 100, 7, 1, 0, 5);
    assert_redemption_bounds_eq(90, 20, 100, 7, 1, 0, 2);
    // Exactly one lot of reduction plans exactly that lot.
    assert_redemption_bounds_eq(35, 20, 100, 7, 1, 13, 13);
    // Above one lot: the tolerance is the lot remainder.
    assert_redemption_bounds_eq(10, 1_000, 100, 7, 1, 895, 900);
}

/// Catches treating a flat Series as free to reopen exposure during a redemption.
#[test]
fun a_flat_series_must_stay_flat_through_a_redemption() {
    assert_redemption_bounds_eq(1, 0, 100, 7, 1, 0, 0);

    accounting_math::assert_redemption_base_within_bounds(0, 1, 0, 100, 7, 1);
}

/// Proves a redemption that closes the complete position is not gated by the minimum.
#[test]
fun a_redemption_that_reaches_flat_bypasses_the_minimum_lot_multiple() {
    assert_redemption_bounds_eq(99, 50, 100, 1_000, 100, 0, 0);

    accounting_math::assert_redemption_base_within_bounds(0, 99, 50, 100, 1_000, 100);
}

/// Pins the first required reduction a minimum lot multiple admits.
#[test]
fun a_redemption_at_the_minimum_lot_multiple_is_accepted() {
    assert_redemption_bounds_eq(10, 1_000, 100, 7, 14, 895, 900);
    assert_redemption_bounds_eq(10, 1_000, 100, 100, 1, 900, 900);
}

/// Catches any admitted final base above the keep or more than one lot below it.
#[test]
fun redemption_bounds_hold_the_two_sided_lot_tolerance() {
    let max = std::u64::max_value!();

    assert_redemption_bounds_hold(10, 1_000, 100, 1, 1);
    assert_redemption_bounds_hold(10, 1_000, 100, 3, 1);
    assert_redemption_bounds_hold(10, 1_000, 100, 7, 1);
    assert_redemption_bounds_hold(10, 1_000, 100, 7, 14);
    assert_redemption_bounds_hold(10, 1_000, 100, 100, 1);
    assert_redemption_bounds_hold(1, 1_000, 100, 7, 1);
    assert_redemption_bounds_hold(99, 1_000, 100, 7, 1);
    assert_redemption_bounds_hold(75, 20, 100, 7, 1);
    assert_redemption_bounds_hold(90, 20, 100, 7, 1);
    assert_redemption_bounds_hold(35, 20, 100, 7, 1);
    assert_redemption_bounds_hold(50, 2_000, 100, 1_000, 1);
    assert_redemption_bounds_hold(1, 0, 100, 7, 1);
    assert_redemption_bounds_hold(1, max, max, 1, 1);
    assert_redemption_bounds_hold(max - 1, max, max, 1, 1);
}

/// Exhausts small share, base, lot, and minimum values against the exact independent formula.
#[test]
fun redemption_bounds_match_their_definition_across_the_small_domain() {
    2u64.range_do!(13, |shares_before| {
        1u64.range_do!(shares_before, |shares_burned| {
            0u64.range_do!(17, |base_before| {
                1u64.range_do!(9, |lot_size| {
                    1u64.range_do!(4, |min_exposure_lots| {
                        let max_final_base =
                            base_before * (shares_before - shares_burned) / shares_before;
                        let required_reduction = base_before - max_final_base;

                        if (
                            max_final_base == 0
                                || required_reduction >= lot_size * min_exposure_lots
                        ) {
                            assert_redemption_bounds_hold(
                                shares_burned,
                                base_before,
                                shares_before,
                                lot_size,
                                min_exposure_lots,
                            );
                        };
                    });
                });
            });
        });
    });
}

/// Catches overflow or an off-by-one when base, supply, and the live lot are maximum `u64`.
#[test]
fun proportional_exposure_math_supports_the_maximum_live_lot() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::mint_base_delta_down_for_testing(max, max, max, max, 1), max);
    assert_eq!(accounting_math::mint_base_delta_down_for_testing(max, max, max, 1, max), max);
    assert_redemption_bounds_eq(max - 1, max, max, 1, 1, 1, 1);
    accounting_math::assert_redemption_base_within_bounds(1, max - 1, max, max, 1, 1);
}

/// Catches a partial fill that pays out without reaching the proportional keep.
#[test]
#[expected_failure(
    abort_code = errors::ERedemptionUnderReduced,
    location = blast_leverage_core::accounting_math,
)]
fun a_final_base_above_the_proportional_keep_is_rejected() {
    accounting_math::assert_redemption_base_within_bounds(901, 10, 1_000, 100, 7, 1);
}

/// Catches a reduction beyond the lot tolerance that is not the flat cap.
#[test]
#[expected_failure(
    abort_code = errors::ERedemptionOverReduced,
    location = blast_leverage_core::accounting_math,
)]
fun a_final_base_more_than_one_lot_below_the_keep_is_rejected() {
    accounting_math::assert_redemption_base_within_bounds(894, 10, 1_000, 100, 7, 1);
}

/// Catches reopening exposure on a flat Series through the bounds check.
#[test]
#[expected_failure(
    abort_code = errors::ERedemptionUnderReduced,
    location = blast_leverage_core::accounting_math,
)]
fun any_exposure_on_a_flat_series_is_rejected() {
    accounting_math::assert_redemption_base_within_bounds(1, 1, 0, 100, 7, 1);
}

/// Regression for cumulative drift: a dust redemption may not close a whole lot.
#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_dust_redemption_below_one_lot_is_rejected() {
    accounting_math::redemption_base_bounds(1, 100, 1_000_000, 7, 1);
}

/// Pins the last required reduction below a fourteen-lot minimum.
#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_sub_minimum_redemption_reduction_is_rejected() {
    accounting_math::redemption_base_bounds(10, 1_000, 100, 7, 15);
}

/// A position that is itself a single live lot cannot be redeemed at any size.
#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_one_lot_position_cannot_be_redeemed_at_any_size() {
    let max = std::u64::max_value!();

    accounting_math::redemption_base_bounds(1, max, max, max, 1);
}

/// The largest legal reduction burns all but one share; when even that is below
/// the minimum, every burn count aborts and the position is locked.
#[test]
#[expected_failure(
    abort_code = errors::ESubLotExposureDelta,
    location = blast_leverage_core::accounting_math,
)]
fun a_position_at_the_minimum_operation_size_locks_the_largest_redemption() {
    accounting_math::redemption_base_bounds(999, 100_000, 1_000, 1_000, 100);
}

/// Sufficient exposure leaves the exact proportional keep of the last share.
#[test]
fun sufficient_exposure_gives_exact_bounds_for_the_largest_redemption() {
    let (min_final_base, max_final_base) =
        accounting_math::redemption_base_bounds(999, 100_100, 1_000, 1_000, 100);

    assert_eq!(max_final_base, 100);
    assert_eq!(min_final_base, 100);
}

#[test]
fun a_sub_supply_position_can_always_close_flat() {
    assert!(!accounting_math::is_exposure_above_minimum_operation(999, 1_000, 100));

    let (min_final_base, max_final_base) =
        accounting_math::redemption_base_bounds(999, 999, 1_000, 1_000, 100);

    assert_eq!(max_final_base, 0);
    assert_eq!(min_final_base, 0);
}

#[test]
fun exposure_predicates_never_abort_on_degenerate_inputs() {
    let max = std::u64::max_value!();

    assert!(!accounting_math::is_exposure_above_minimum_operation(max, 0, 1));
    assert!(!accounting_math::is_exposure_above_minimum_operation(max, 1, 0));
    assert!(!accounting_math::is_exposure_above_minimum_operation(max, max, max));
    assert!(accounting_math::is_exposure_above_minimum_operation(max, max, 1) == false);
    assert!(accounting_math::is_exposure_above_minimum_operation(max, max - 1, 1));
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun redemption_bounds_reject_a_zero_share_burn() {
    accounting_math::redemption_base_bounds(0, 1_000, 100, 7, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun redemption_bounds_reject_burning_the_complete_supply() {
    accounting_math::redemption_base_bounds(100, 1_000, 100, 7, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLotSize,
    location = blast_leverage_core::accounting_math,
)]
fun redemption_bounds_reject_a_zero_lot() {
    accounting_math::redemption_base_bounds(10, 1_000, 100, 0, 1);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMinExposureLots,
    location = blast_leverage_core::accounting_math,
)]
fun redemption_bounds_reject_a_zero_minimum_lot_multiple() {
    accounting_math::redemption_base_bounds(10, 1_000, 100, 7, 0);
}

/// Pins the share-bound guard ahead of the lot guard when both are invalid.
#[test]
#[expected_failure(
    abort_code = errors::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun an_invalid_share_amount_is_rejected_before_a_zero_lot() {
    accounting_math::redemption_base_bounds(0, 1_000, 100, 0, 0);
}

/// Pins the lot guard ahead of the minimum-lot-multiple guard in redemption.
#[test]
#[expected_failure(
    abort_code = errors::EInvalidLotSize,
    location = blast_leverage_core::accounting_math,
)]
fun a_zero_lot_is_rejected_before_a_zero_minimum_lot_multiple_in_redemption() {
    accounting_math::redemption_base_bounds(10, 1_000, 100, 0, 0);
}

// === Private Test Helpers ===

/// Proves floor targeting followed by ceiling reporting cannot exceed the requested leverage.
fun assert_target_round_trip_is_conservative(nav: u64, target_leverage_bps: u64) {
    let target_numerator = (nav as u128) * (target_leverage_bps as u128);
    let target_notional = accounting_math::target_notional_down_for_testing(nav, target_leverage_bps);
    let reported_leverage_bps = accounting_math::leverage_bps_up_for_testing(target_notional, nav);

    assert_eq!(
        target_notional as u128,
        target_numerator / 10_000,
    );
    assert!((target_notional as u128) * 10_000 <= target_numerator);
    assert!(((target_notional as u128) + 1) * 10_000 > target_numerator);
    assert!(reported_leverage_bps <= target_leverage_bps);

    let reported_numerator = (target_notional as u128) * 10_000;
    assert!((reported_leverage_bps as u128) * (nav as u128) >= reported_numerator);
    if (reported_leverage_bps > 0) {
        assert!(
            ((reported_leverage_bps - 1) as u128) * (nav as u128)
                < reported_numerator,
        );
    } else {
        assert_eq!(target_notional, 0);
    };
}

/// Asserts the returned range equals the expected minimum and maximum final base.
fun assert_redemption_bounds_eq(
    shares_burned: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
    expected_min_final_base: u64,
    expected_max_final_base: u64,
) {
    let (min_final_base, max_final_base) = accounting_math::redemption_base_bounds(
        shares_burned,
        base_before,
        shares_before,
        lot_size,
        min_exposure_lots,
    );

    assert_eq!(min_final_base, expected_min_final_base);
    assert_eq!(max_final_base, expected_max_final_base);
}

/// Asserts the rounded delta stays at or below the proportional target within the relative cap.
fun assert_mint_base_delta_is_proportional(
    contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    let proportional_base = (
        (base_before as u128) * (contribution as u128) / (nav_before as u128),
    ) as u64;
    let delta = accounting_math::mint_base_delta_down_for_testing(
        contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
    let under_exposure = proportional_base - delta;

    assert!((delta as u128) >= (lot_size as u128) * (min_exposure_lots as u128));
    assert_eq!(delta % lot_size, 0);
    assert!(delta <= proportional_base);
    assert!(under_exposure < lot_size);
    assert!((under_exposure as u128) * (min_exposure_lots as u128) < (proportional_base as u128));
}

/// Asserts the mint range is `[min(actual, planned), planned]` and admits its own endpoints.
fun assert_mint_bounds_hold(
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    let (min_delta, max_delta) = accounting_math::mint_base_bounds_for_testing(
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
    let planned_delta = accounting_math::mint_base_delta_down_for_testing(
        expected_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
    let actual_delta = accounting_math::mint_base_delta_down_for_testing(
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );

    assert_eq!(max_delta, planned_delta);
    assert_eq!(min_delta, actual_delta.min(planned_delta));
    assert!(min_delta <= max_delta);

    accounting_math::assert_mint_base_within_bounds_for_testing(
        base_before + max_delta,
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
    accounting_math::assert_mint_base_within_bounds_for_testing(
        base_before + min_delta,
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
}

/// Asserts the returned range is the I11 keep with a two-sided tolerance below the relative cap.
fun assert_redemption_bounds_hold(
    shares_burned: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    let (min_final_base, max_final_base) = accounting_math::redemption_base_bounds(
        shares_burned,
        base_before,
        shares_before,
        lot_size,
        min_exposure_lots,
    );
    let expected_max_final_base = (
        (base_before as u128) * ((shares_before - shares_burned) as u128)
            / (shares_before as u128),
    ) as u64;
    let required_reduction = base_before - expected_max_final_base;
    let expected_planned_reduction = (
        (required_reduction as u128).div_ceil(lot_size as u128) * (lot_size as u128),
    ).min(base_before as u128) as u64;
    let expected_min_final_base = base_before - expected_planned_reduction;
    let over_reduction = max_final_base - min_final_base;

    assert_eq!(max_final_base, expected_max_final_base);
    assert_eq!(min_final_base, expected_min_final_base);
    assert!(min_final_base <= max_final_base);
    assert!(over_reduction < lot_size);
    assert!(
        (base_before - min_final_base) % lot_size == 0 || min_final_base == 0,
    );
    if (required_reduction > 0) {
        assert!(
            (over_reduction as u128) * (min_exposure_lots as u128)
                < (required_reduction as u128),
        );
    };

    accounting_math::assert_redemption_base_within_bounds(
        min_final_base,
        shares_burned,
        base_before,
        shares_before,
        lot_size,
        min_exposure_lots,
    );
    accounting_math::assert_redemption_base_within_bounds(
        max_final_base,
        shares_burned,
        base_before,
        shares_before,
        lot_size,
        min_exposure_lots,
    );
    accounting_math::assert_redemption_base_within_bounds(
        min_final_base + over_reduction / 2,
        shares_burned,
        base_before,
        shares_before,
        lot_size,
        min_exposure_lots,
    );
}

/// Runs worst-case legal mints on a 2x pool and returns the final and lowest accounting leverage.
///
/// Every mint targets one unit below the next lot multiple, so it loses the
/// largest sub-lot remainder the minimum admits. The pool starts at NAV
/// 10,000,000 and base 20,000,000 with unit price, so notional equals base.
fun drift_after_worst_case_mints(
    count: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): (u64, u64, u64, u64) {
    let mut nav = 10_000_000u64;
    let mut base = 20_000_000u64;
    let mut lowest = accounting_math::leverage_bps_up_for_testing(base, nav);
    let mut first_breach = 0;
    let worst_target = (min_exposure_lots + 1) * lot_size - 1;

    assert_eq!(lowest, 20_000);
    count.do!(|index| {
        let contribution = ((worst_target as u128) * (nav as u128) / (base as u128)) as u64;
        let delta = accounting_math::mint_base_delta_down_for_testing(
            contribution,
            base,
            nav,
            lot_size,
            min_exposure_lots,
        );

        assert_eq!(delta, min_exposure_lots * lot_size);
        nav = nav + contribution;
        base = base + delta;
        let leverage = accounting_math::leverage_bps_up_for_testing(base, nav);
        if (leverage < 18_000 && first_breach == 0) {
            first_breach = index + 1;
        };
        lowest = lowest.min(leverage);
    });

    (
        accounting_math::leverage_bps_up_for_testing(base, nav),
        lowest,
        first_breach,
        nav,
    )
}
