#[test_only]
/// Independent boundary vectors for per-session cost-aware rebalance sizing.
module blast_leverage_series_one::rebalance_math_tests;

use blast_leverage_series_one::rebalance_math;
use std::unit_test::assert_eq;

// === Tests ===

#[test]
fun maximum_width_cost_and_conversion_keep_wide_intermediates() {
    let max = std::u64::max_value!();
    assert_eq!(rebalance_math::execution_cost_up(max, 10_000, 9_999), 55_336_542_872_313_912_935);
    assert_eq!(rebalance_math::index_notional_up(max, 1_000, 1), max);
    assert_eq!(rebalance_math::base_for_notional_down(max, 1_000, 1, 1), max);
    assert_eq!(rebalance_math::increase_base_down(max, max - 1, 10_000, 1_000, 1, 1, max, 0, 0), 1);
    assert!(!rebalance_math::reduction_is_sufficient(max, max, max - 1, max, 20_000, max, max));
}

#[test]
fun whole_lot_increase_matches_exhaustive_small_domain_reference() {
    // Price ratio makes one base atom one collateral atom. Enumerate every
    // candidate, independently of production's binary search and sizing helpers.
    let mut nav = 1u64;
    while (nav <= 6) {
        let mut notional = 0u64;
        while (notional <= 12) {
            let mut lot = 1u64;
            while (lot <= 3) {
                vector[0u64, 1_000].do!(|fee| {
                    vector[0u64, 1_000].do!(|tolerance| {
                        let mut expected = 0u64;
                        let mut candidate = lot;
                        while (candidate <= 8) {
                            let adverse = (candidate * tolerance + 9_999) / 10_000;
                            let charge = ((candidate + adverse) * fee + 9_999) / 10_000;
                            if (adverse + charge < nav && notional + candidate <= 2 * (nav - adverse - charge)) {
                                expected = candidate;
                            };
                            candidate = candidate + lot;
                        };
                        assert_eq!(rebalance_math::increase_base_down(nav, notional, 20_000, 1_000, 1, lot, 8, fee, tolerance), expected);
                    });
                });
                lot = lot + 1;
            };
            notional = notional + 1;
        };
        nav = nav + 1;
    };
}

#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EVenueFeeUnusable, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_fee_first_above_full_rate() {
    rebalance_math::execution_cost_up(1, 10_001, 0);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EVenueFeeUnusable, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_tolerance_at_full_rate() {
    rebalance_math::execution_cost_up(1, 0, 10_000);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EArithmeticOverflow, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_target_width_overflow() {
    rebalance_math::increase_base_down(std::u64::max_value!(), 0, 20_000, 1_000, 1, 1, 1, 0, 0);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EArithmeticOverflow, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_base_width_overflow() {
    rebalance_math::base_for_notional_down(std::u64::max_value!(), 1, 1, 1);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EArithmeticOverflow, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_notional_width_overflow() {
    rebalance_math::index_notional_up(std::u64::max_value!(), 1_001, 1);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EInvalidNav, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_zero_nav_before_invalid_target() {
    rebalance_math::increase_base_down(0, 0, 0, 0, 0, 0, 0, 0, 0);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EInvalidTargetLeverageBps, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_zero_target_before_invalid_price() {
    rebalance_math::increase_base_down(1, 0, 0, 0, 0, 0, 0, 0, 0);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EInvalidValuationPrice, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_invalid_price_before_zero_lot() {
    rebalance_math::base_for_notional_down(1, 0, 1, 0);
}


#[test]
#[expected_failure(abort_code = blast_leverage_series_one::errors::EInvalidLotSize, location = blast_leverage_series_one::rebalance_math)]
fun sizing_rejects_zero_lot_at_valid_prices() {
    rebalance_math::base_for_notional_down(1, 1, 1, 0);
}


#[test]
fun reduction_improvement_uses_exact_ratios_and_one_lot_tolerance() {
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 250, 100, 20_000, 500, 1));
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 299, 100, 20_000, 101, 1));
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 201, 100, 20_000, 20_000, 1));
    // A 300-atom position has not improved if its NAV fell in the same proportion.
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 270, 90, 20_000, 1, 1));
}

/// The improvement clause is inclusive at exactly the minimum and exclusive one
/// basis point below it: 3.00x to 2.99x is a 100 bps improvement.
#[test]
fun reduction_improvement_is_inclusive_at_exactly_the_minimum() {
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 299, 100, 20_000, 100, 1));
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 299, 100, 20_000, 101, 1));
}

/// The one-lot clause is inclusive at exactly one lot's notional from target and
/// exclusive one atom farther when the improvement clause cannot rescue it.
#[test]
fun one_lot_tolerance_is_inclusive_at_exactly_one_lot() {
    // Target notional 200 at 2x on 100 NAV; lot notional 1.
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 201, 100, 20_000, 20_000, 1));
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 202, 100, 20_000, 20_000, 1));
    // Landing exactly on target passes with any minimum.
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 200, 100, 20_000, 20_000, 1));
}

/// A reduction whose NAV rose is measured in leverage terms, not notional terms.
#[test]
fun reduction_improvement_credits_a_nav_gain() {
    // 3.00x to 2.636x although notional fell only 10: a 3_636 bps improvement.
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 290, 110, 20_000, 3_636, 1));
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 290, 110, 20_000, 3_637, 1));
}

/// Crossing the target is admitted only while the landing is closer than the
/// start; production sizing floors every reduction at the target, so this is a
/// property of the predicate alone.
#[test]
fun a_crossing_reduction_passes_only_while_it_is_closer_than_the_start() {
    // 3.0x to 1.5x with target 2x: 10_000 bps away became 5_000 bps away.
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 150, 100, 20_000, 5_000, 1));
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 150, 100, 20_000, 5_001, 1));
    // 3.0x to 0.5x: 10_000 bps away became 15_000 bps away.
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 50, 100, 20_000, 1, 1));
}

/// A lot larger than the distance to target cannot excuse a landing farther
/// from target than the start, even within one lot.
#[test]
fun one_lot_tolerance_never_admits_moving_away_from_target() {
    // Target notional 1_000 at 2x on 500 NAV; lot notional 600.
    assert!(!rebalance_math::reduction_is_sufficient(1_150, 500, 550, 500, 20_000, 1, 600));
    assert!(rebalance_math::reduction_is_sufficient(1_150, 500, 950, 500, 20_000, 1, 600));
    assert!(rebalance_math::reduction_is_sufficient(1_150, 500, 1_000, 500, 20_000, 1, 600));
}

/// Exhausts small positions against an independent rational reference and the
/// invariant that a sufficient reduction never ends farther from target.
#[test]
fun reduction_predicate_matches_the_small_domain_reference() {
    vector[10_000u64, 20_000].do!(|target_bps| {
        vector[1u64, 5_000].do!(|minimum_improvement_bps| {
            vector[1u64, 3].do!(|lot| {
                1u64.range_do!(5, |before_nav| {
                    1u64.range_do!(5, |after_nav| {
                        0u64.range_do!(8, |before_notional| {
                            0u64.range_do!(8, |after_notional| {
                                let observed = rebalance_math::reduction_is_sufficient(
                                    before_notional, before_nav, after_notional, after_nav,
                                    target_bps, minimum_improvement_bps, lot,
                                );
                                let before_bps = leverage_distance_bps(before_notional, before_nav, target_bps);
                                let after_bps = leverage_distance_bps(after_notional, after_nav, target_bps);
                                let not_farther = ratio_le(after_bps, before_bps);
                                let improved = ratio_le(
                                    Ratio {
                                        numerator: after_bps.numerator * before_bps.denominator
                                            + (minimum_improvement_bps as u128) * after_bps.denominator * before_bps.denominator,
                                        denominator: after_bps.denominator * before_bps.denominator,
                                    },
                                    before_bps,
                                );
                                let within_lot = ratio_le(
                                    after_bps,
                                    Ratio { numerator: (lot as u128) * 10_000, denominator: after_nav as u128 },
                                );
                                assert_eq!(observed, (within_lot && not_farther) || improved);
                                if (observed) { assert!(not_farther) };
                            });
                        });
                    });
                });
            });
        });
    });
}

#[test]
fun increase_reserves_adverse_execution_and_fee_headroom() {
    let base = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 20_000, 10_000_000_000, 1_000_000_000,
        1_000, 2_000_000, 10, 50,
    );
    assert_eq!(base, 98_813_000);
    let notional = rebalance_math::index_notional_up(base, 10_000_000_000, 1_000_000_000);
    let cost = rebalance_math::execution_cost_up(notional, 10, 50);
    assert_eq!(notional, 988_130);
    assert_eq!(cost, 5_935);
    assert!((1_000_000u128 + (notional as u128)) * 10_000 <= 20_000 * (1_000_000 - cost));
    let next = rebalance_math::index_notional_up(base + 1_000, 10_000_000_000, 1_000_000_000);
    let next_cost = rebalance_math::execution_cost_up(next, 10, 50);
    assert!((1_000_000u128 + (next as u128)) * 10_000 > 20_000 * (1_000_000 - next_cost));
}

#[test]
fun increase_recomputes_headroom_after_each_order_cost() {
    let first = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 20_000, 10_000_000_000, 1_000_000_000,
        1_000, 500_000, 10, 50,
    );
    assert_eq!(first, 50_000_000);
    assert_eq!(rebalance_math::execution_cost_up(500_000, 10, 50), 3_003);
    let second = rebalance_math::increase_base_down(
        996_997, 1_500_000, 20_000, 10_000_000_000, 1_000_000_000,
        1_000, 500_000, 10, 50,
    );
    assert_eq!(second, 48_813_000);
}

#[test]
fun execution_cost_rounds_each_order_instead_of_the_aggregate() {
    assert_eq!(rebalance_math::execution_cost_up(1, 10, 50), 2);
    assert_eq!(rebalance_math::execution_cost_up(16, 10, 50), 2);
    assert_eq!(16 * rebalance_math::execution_cost_up(1, 10, 50), 32);
}

#[test]
fun increase_returns_zero_when_a_whole_lot_cannot_leave_positive_nav() {
    assert_eq!(rebalance_math::increase_base_down(
        1, 0, 20_000, 1_000_000_000, 1_000_000_000, 1_000, 100, 10, 50,
    ), 0);
}

#[test]
fun generic_four_and_six_times_use_the_same_maximal_integer_search() {
    let four = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 40_000, 10_000_000_000, 1_000_000_000,
        1_000, 5_000_000, 0, 0,
    );
    let six = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 60_000, 10_000_000_000, 1_000_000_000,
        1_000, 5_000_000, 0, 0,
    );
    assert_eq!(four, 300_000_000);
    assert_eq!(six, 500_000_000);
}

// === Reference Helpers ===

/// One exact positive-denominator rational for the independent reference.
public struct Ratio has copy, drop { numerator: u128, denominator: u128 }

/// Leverage distance from target as an exact rational in basis points.
fun leverage_distance_bps(notional: u64, nav: u64, target_bps: u64): Ratio {
    let scaled = (notional as u128) * 10_000;
    let target = (target_bps as u128) * (nav as u128);
    Ratio {
        numerator: if (scaled >= target) { scaled - target } else { target - scaled },
        denominator: nav as u128,
    }
}

/// Returns whether `left <= right`.
fun ratio_le(left: Ratio, right: Ratio): bool {
    left.numerator * right.denominator <= right.numerator * left.denominator
}
