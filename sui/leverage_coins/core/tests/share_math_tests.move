#[test_only]
/// Fee, mint, and redemption share accounting.
module blast_leverage_core::share_math_tests;

use blast_leverage_core::{accounting_math};
use std::unit_test::assert_eq;

// === Tests ===

/// Catches a fee that truncates below one atomic unit or ignores the live rate.
#[test]
fun fee_rounds_up_and_a_zero_rate_is_the_only_fee_free_result() {
    assert_eq!(accounting_math::fee_up(10_000, 0), 0);
    assert_eq!(accounting_math::fee_up(1, 1), 1);
    assert_eq!(accounting_math::fee_up(10_000, 1), 1);
    assert_eq!(accounting_math::fee_up(10_001, 1), 2);
    assert_eq!(accounting_math::fee_up(1, 9_999), 1);
    assert_eq!(accounting_math::fee_up(20_000, 9_999), 19_998);
    assert_eq!(accounting_math::fee_up(20_001, 9_999), 19_999);
}

/// Catches an intermediate `amount * fee_bps` that wraps instead of widening.
#[test]
fun fee_supports_maximum_u64_amounts() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::fee_up(max, 0), 0);
    assert_eq!(accounting_math::fee_up(max, 1), 1_844_674_407_370_956);
    assert_eq!(accounting_math::fee_up(max, 9_999), 18_444_899_399_302_180_660);
}

/// Proves the returned fee is the least integer not below the exact rational fee.
#[test]
fun fee_matches_the_exact_ceiling_across_boundary_values() {
    let max = std::u64::max_value!();

    vector[1u64, 2, 9_999, 10_000, 10_001, 1_000_000_000, max].do!(|amount| {
        vector[0u64, 1, 2, 5_000, 9_998, 9_999].do!(|fee_bps| {
            assert_fee_is_exact_ceiling(amount, fee_bps);
        });
    });
}

/// Catches a fee that could exceed the amount it is subtracted from.
#[test]
fun fee_never_exceeds_the_amount_at_the_highest_rate() {
    let max = std::u64::max_value!();

    vector[1u64, 2, 3, 9_999, 10_000, 10_001, 1_000_000_000, max].do!(
        |amount| assert!(accounting_math::fee_up(amount, 9_999) <= amount),
    );
}

#[test]
#[expected_failure(abort_code = accounting_math::EZeroAmount, location = blast_leverage_core::accounting_math)]
fun zero_fee_amount_is_rejected() {
    accounting_math::fee_up(0, 1);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidFeeBps,
    location = blast_leverage_core::accounting_math,
)]
fun a_fee_rate_at_the_denominator_is_rejected() {
    accounting_math::fee_up(10_000, 10_000);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidFeeBps,
    location = blast_leverage_core::accounting_math,
)]
fun the_maximum_u64_fee_rate_is_rejected() {
    accounting_math::fee_up(1, std::u64::max_value!());
}

/// Pins the amount guard ahead of the rate guard when both inputs are invalid.
#[test]
#[expected_failure(abort_code = accounting_math::EZeroAmount, location = blast_leverage_core::accounting_math)]
fun a_zero_amount_is_rejected_before_an_invalid_fee_rate() {
    accounting_math::fee_up(0, 10_000);
}

/// Catches rounding minted shares up, which would take value from existing holders.
#[test]
fun mint_shares_floor_and_leave_the_remainder_with_existing_holders() {
    // Exact division mints the whole quotient.
    let (shares_out, shares_after) = accounting_math::mint_quote(10, 100, 100);

    assert_eq!(shares_out, 10);
    assert_eq!(shares_after, 110);

    // A one-unit remainder stays with the Series.
    let (shares_out, shares_after) = accounting_math::mint_quote(10, 300, 100);

    assert_eq!(shares_out, 3);
    assert_eq!(shares_after, 103);
}

/// Catches an intermediate `shares_before * contribution` that wraps instead of widening.
#[test]
fun mint_supports_maximum_supported_values() {
    let max = std::u64::max_value!();
    let (shares_out, shares_after) = accounting_math::mint_quote(100, max - 100, max - 1_000);

    assert_eq!(shares_out, 99);
    assert_eq!(shares_after, max - 901);
}

/// Catches any mint that lowers NAV per share for holders that entered earlier.
#[test]
fun mint_is_never_dilutive_across_the_table() {
    let max = std::u64::max_value!();

    assert_mint_is_non_dilutive(990_000, 1_000_000_000, 2_000_000_000);
    assert_mint_is_non_dilutive(490_000, 1_000_000_000, 2_000_000_000);
    assert_mint_is_non_dilutive(10, 100, 100);
    assert_mint_is_non_dilutive(10, 300, 100);
    assert_mint_is_non_dilutive(2, 1_000, 1_000);
    assert_mint_is_non_dilutive(1, 100_000, 100_000);
    assert_mint_is_non_dilutive(2, 1, 1);
    assert_mint_is_non_dilutive(100, max - 100, max - 1_000);
}

/// Exhausts a bounded domain around low NAV, low supply, and share-rounding cliffs.
#[test]
fun mint_formula_and_non_dilution_hold_across_the_small_domain() {
    1u64.range_do!(17, |nav_before| {
        1u64.range_do!(17, |shares_before| {
            1u64.range_do!(17, |contribution| {
                if (shares_before * contribution / nav_before > 0) {
                    assert_mint_matches_reference(contribution, nav_before, shares_before);
                };
            });
        });
    });
}

/// Pins the largest successful share result and the largest successful final supply.
#[test]
fun mint_reaches_the_maximum_representable_share_boundary() {
    let max = std::u64::max_value!();
    let (shares_out, shares_after) = accounting_math::mint_quote(max - 1, 1, 1);

    assert_eq!(shares_out, max - 1);
    assert_eq!(shares_after, max);
}

/// Pins the smallest positive contribution that still buys one atomic share.
#[test]
fun a_one_unit_contribution_can_mint_exactly_one_atomic_share() {
    let (shares_out, shares_after) = accounting_math::mint_quote(1, 100_000, 100_000);

    assert_eq!(shares_out, 1);
    assert_eq!(shares_after, 100_001);
}

#[test]
#[expected_failure(abort_code = accounting_math::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun a_mint_against_zero_nav_is_rejected() {
    accounting_math::mint_quote(10, 0, 100);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareSupply,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_against_zero_supply_is_rejected() {
    accounting_math::mint_quote(10, 100, 0);
}

/// Catches accepting a mint that creates no shareholder NAV contribution.
#[test]
#[expected_failure(
    abort_code = accounting_math::ENonpositiveContribution,
    location = blast_leverage_core::accounting_math,
)]
fun a_zero_contribution_mint_is_rejected() {
    accounting_math::mint_quote(0, 100, 100);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EZeroSharesOut,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_below_one_atomic_share_is_rejected() {
    accounting_math::mint_quote(999, 1_000, 1);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_of_more_shares_than_u64_is_rejected() {
    accounting_math::mint_quote(2, 1, std::u64::max_value!());
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_leverage_core::accounting_math,
)]
fun a_mint_that_overflows_the_supply_is_rejected() {
    accounting_math::mint_quote(1, 2, std::u64::max_value!());
}

/// Pins the NAV guard ahead of the supply guard when both are zero.
#[test]
#[expected_failure(abort_code = accounting_math::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun zero_nav_is_rejected_before_zero_supply() {
    accounting_math::mint_quote(10, 0, 0);
}

/// Pins the supply guard ahead of the contribution guard when both are zero.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareSupply,
    location = blast_leverage_core::accounting_math,
)]
fun zero_supply_is_rejected_before_a_zero_contribution() {
    accounting_math::mint_quote(0, 100, 0);
}

/// Catches paying a redeemer more than the excess over the equity kept for others.
#[test]
fun redemption_pays_only_the_excess_over_the_kept_equity() {
    let (shares_after, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        10,
        1_000,
        1_000,
        100,
        100,
    );

    assert_eq!(shares_after, 90);
    assert_eq!(equity_keep, 900);
    assert_eq!(gross, 100);
    assert_eq!(fee, 1);
    assert_eq!(net, 99);

    // An unwind that costs the Series 50 units pays the redeemer 50 less.
    let (_, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        10,
        1_000,
        950,
        100,
        0,
    );

    assert_eq!(equity_keep, 900);
    assert_eq!(gross, 50);
    assert_eq!(fee, 0);
    assert_eq!(net, 50);
}

/// A favorable unwind pays exactly the proportional claim; the gain stays with holders.
#[test]
fun a_favorable_unwind_pays_exactly_the_proportional_claim() {
    let (shares_after, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        10,
        1_000,
        1_050,
        100,
        100,
    );

    assert_eq!(shares_after, 90);
    assert_eq!(equity_keep, 900);
    assert_eq!(gross, 100);
    assert_eq!(fee, 1);
    assert_eq!(net, 99);

    // The audit case: one share of a million against a 100-unit pool-wide gain pays one unit.
    let (_, equity_keep, gross, _, net) = accounting_math::redemption_quote(
        1,
        1_000_000,
        1_000_100,
        1_000_000,
        0,
    );

    assert_eq!(equity_keep, 999_999);
    assert_eq!(gross, 1);
    assert_eq!(net, 1);
}

/// Catches a cap that widens instead of narrowing when the unwind loses value.
#[test]
fun a_costly_unwind_still_pays_the_reduced_gross() {
    assert_redemption_matches_reference(10, 1_000, 950, 100, 0);
    assert_redemption_matches_reference(10, 1_000, 901, 100, 0);
}

/// Catches a favorable unwind rescuing a claim the rounded-up kept equity consumed.
#[test]
#[expected_failure(abort_code = accounting_math::ENonpositiveGross, location = blast_leverage_core::accounting_math)]
fun a_favorable_unwind_cannot_rescue_a_claim_the_kept_equity_consumes() {
    accounting_math::redemption_quote(10, 1, 1_000, 100, 0);
}

/// Catches a maximum-width favorable unwind that wraps or escapes the cap.
#[test]
fun a_maximum_width_favorable_unwind_is_capped_at_the_claim() {
    let max = std::u64::max_value!();
    let (shares_after, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        1,
        max - 1,
        max,
        max - 1,
        0,
    );

    assert_eq!(shares_after, max - 2);
    assert_eq!(equity_keep, max - 2);
    assert_eq!(gross, 1);
    assert_eq!(fee, 0);
    assert_eq!(net, 1);
}

/// Catches flooring the kept equity, which would pay the redeemer one extra unit.
#[test]
fun redemption_rounds_the_kept_equity_up() {
    let (shares_after, equity_keep, gross, _, net) = accounting_math::redemption_quote(
        10,
        1_001,
        1_001,
        100,
        0,
    );

    assert_eq!(shares_after, 90);
    assert_eq!(equity_keep, 901);
    assert_eq!(gross, 100);
    assert_eq!(net, 100);
}

/// Catches an off-by-one at the first and last presentable share count.
#[test]
fun redemption_supports_the_first_and_last_presentable_share_count() {
    let (shares_after, equity_keep, gross, _, net) = accounting_math::redemption_quote(
        1,
        1_000,
        1_000,
        100,
        0,
    );

    assert_eq!(shares_after, 99);
    assert_eq!(equity_keep, 990);
    assert_eq!(gross, 10);
    assert_eq!(net, 10);

    let (shares_after, equity_keep, gross, _, net) = accounting_math::redemption_quote(
        99,
        1_000,
        1_000,
        100,
        0,
    );

    assert_eq!(shares_after, 1);
    assert_eq!(equity_keep, 10);
    assert_eq!(gross, 990);
    assert_eq!(net, 990);
}

/// Catches an intermediate `nav_before * shares_after` that wraps instead of widening.
#[test]
fun redemption_supports_maximum_supported_values() {
    let max = std::u64::max_value!();
    let (shares_after, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        1,
        max,
        max,
        max,
        0,
    );

    assert_eq!(shares_after, max - 1);
    assert_eq!(equity_keep, max - 1);
    assert_eq!(gross, 1);
    assert_eq!(fee, 0);
    assert_eq!(net, 1);
}

/// Catches a redemption fee that leaves the redeemer nothing but still burns shares.
#[test]
fun the_highest_fee_rate_still_leaves_a_positive_payout() {
    let (_, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        10,
        100_000,
        100_000,
        100,
        9_999,
    );

    assert_eq!(equity_keep, 90_000);
    assert_eq!(gross, 10_000);
    assert_eq!(fee, 9_999);
    assert_eq!(net, 1);
}

/// Catches any redemption that lowers NAV per share for the remaining holders.
#[test]
fun redemption_is_never_dilutive_across_the_table() {
    let max = std::u64::max_value!();

    assert_redemption_is_non_dilutive(10, 1_000, 1_000, 100, 100);
    assert_redemption_is_non_dilutive(10, 1_001, 1_001, 100, 0);
    assert_redemption_is_non_dilutive(10, 1_000, 950, 100, 0);
    assert_redemption_is_non_dilutive(1, 1_000, 1_000, 100, 0);
    assert_redemption_is_non_dilutive(99, 1_000, 1_000, 100, 0);
    assert_redemption_is_non_dilutive(10, 100_000, 100_000, 100, 9_999);
    assert_redemption_is_non_dilutive(1, 4, 5, 4, 0);
    assert_redemption_is_non_dilutive(10, 1_000, 1_050, 100, 100);
    assert_redemption_is_non_dilutive(1, max - 1, max, max - 1, 0);
    assert_redemption_is_non_dilutive(1, max, max, max, 0);
}

/// Exhausts a bounded domain around share-count, kept-equity, fee, and payout cliffs.
#[test]
fun redemption_formula_and_non_dilution_hold_across_the_small_domain() {
    1u64.range_do!(33, |nav_before| {
        2u64.range_do!(17, |shares_before| {
            1u64.range_do!(shares_before, |shares_burned| {
                vector[0u64, 1, 5_000].do!(|redeem_fee_bps| {
                    let shares_after = shares_before - shares_burned;
                    let equity_keep = ((nav_before as u128) * (shares_after as u128))
                        .div_ceil(shares_before as u128) as u64;
                    let gross = nav_before - equity_keep;
                    let fee = if (gross == 0) {
                        0
                    } else {
                        reference_fee_up(gross, redeem_fee_bps)
                    };

                    if (gross > fee) {
                        assert_redemption_matches_reference(
                            shares_burned,
                            nav_before,
                            nav_before,
                            shares_before,
                            redeem_fee_bps,
                        );
                    };
                });
            });
        });
    });
}

/// Exhausts unwound readings below, at, and above the pre-unwind NAV against the cap.
#[test]
fun capped_redemption_formula_and_non_dilution_hold_across_the_small_domain() {
    1u64.range_do!(9, |nav_before| {
        2u64.range_do!(7, |shares_before| {
            1u64.range_do!(shares_before, |shares_burned| {
                0u64.range_do!(16, |nav_unwound| {
                    let shares_after = shares_before - shares_burned;
                    let equity_keep = ((nav_before as u128) * (shares_after as u128))
                        .div_ceil(shares_before as u128) as u64;
                    let claimable = nav_unwound.min(nav_before);

                    if (claimable > equity_keep) {
                        assert_redemption_matches_reference(
                            shares_burned,
                            nav_before,
                            nav_unwound,
                            shares_before,
                            0,
                        );
                        assert_redemption_is_non_dilutive(
                            shares_burned,
                            nav_before,
                            nav_unwound,
                            shares_before,
                            0,
                        );
                    };
                });
            });
        });
    });
}

/// Catches a maximum-width fee, kept-equity, and payout calculation that wraps.
#[test]
fun redemption_with_the_highest_fee_supports_maximum_u64_values() {
    let max = std::u64::max_value!();

    assert_redemption_matches_reference(max - 1, max, max, max, 9_999);
}

/// Proves an immediate mint and redemption cannot return more collateral than was deposited.
#[test]
fun immediate_round_trips_cannot_profit_from_share_or_fee_rounding() {
    assert_round_trip_cannot_profit(1, 1, 1, 0, 0);
    assert_round_trip_cannot_profit(300, 100, 10, 0, 0);
    assert_round_trip_cannot_profit(1_000, 333, 200, 100, 100);
    assert_round_trip_cannot_profit(1_000_000, 2_000_000, 1_000_000, 100, 100);
    assert_round_trip_cannot_profit(100_000, 100_000, 10_000, 9_999, 0);
    assert_round_trip_cannot_profit(
        std::u64::max_value!() / 2,
        std::u64::max_value!() / 3,
        1_000_000,
        1,
        1,
    );
}

/// Catches gaining shares by splitting one contribution around downward share rounding.
#[test]
fun splitting_a_mint_does_not_create_extra_shares() {
    let (combined_shares, _) = accounting_math::mint_quote(198, 1_000, 333);
    let (first_shares, shares_after_first) = accounting_math::mint_quote(99, 1_000, 333);
    let (second_shares, _) = accounting_math::mint_quote(99, 1_099, shares_after_first);

    assert_eq!(combined_shares, 65);
    assert_eq!(first_shares + second_shares, 64);
    assert!(first_shares + second_shares <= combined_shares);
}

#[test]
#[expected_failure(abort_code = accounting_math::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun a_redemption_against_zero_nav_is_rejected() {
    accounting_math::redemption_quote(10, 0, 1_000, 100, 0);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun a_zero_share_redemption_is_rejected() {
    accounting_math::redemption_quote(0, 1_000, 1_000, 100, 0);
}

/// Catches a final-holder drain that the permanently locked seed shares must prevent.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun redeeming_the_complete_supply_is_rejected() {
    accounting_math::redemption_quote(100, 1_000, 1_000, 100, 0);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun a_redemption_against_zero_supply_is_rejected() {
    accounting_math::redemption_quote(1, 1_000, 1_000, 0, 0);
}

/// Catches paying a redeemer when the unwind left exactly the equity others keep.
#[test]
#[expected_failure(
    abort_code = accounting_math::ENonpositiveGross,
    location = blast_leverage_core::accounting_math,
)]
fun a_redemption_without_excess_equity_is_rejected() {
    accounting_math::redemption_quote(10, 1_000, 900, 100, 0);
}

/// Pins fee validation ahead of the gross-claim guard, before the kept equity is computed.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidFeeBps,
    location = blast_leverage_core::accounting_math,
)]
fun an_invalid_redemption_fee_is_rejected_before_a_nonpositive_gross() {
    accounting_math::redemption_quote(10, 1_000, 900, 100, 10_000);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::ENonpositiveGross,
    location = blast_leverage_core::accounting_math,
)]
fun a_redemption_below_the_kept_equity_is_rejected() {
    accounting_math::redemption_quote(10, 1_000, 899, 100, 0);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidFeeBps,
    location = blast_leverage_core::accounting_math,
)]
fun a_redeem_fee_rate_at_the_denominator_is_rejected() {
    accounting_math::redemption_quote(10, 1_000, 1_000, 100, 10_000);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EZeroNetPayout,
    location = blast_leverage_core::accounting_math,
)]
fun a_redemption_consumed_by_its_fee_is_rejected() {
    accounting_math::redemption_quote(10, 1_000, 901, 100, 9_999);
}

/// Pins the last gross amount below the 9,999-bps positive-payout threshold.
#[test]
#[expected_failure(
    abort_code = accounting_math::EZeroNetPayout,
    location = blast_leverage_core::accounting_math,
)]
fun a_9_999_unit_gross_is_completely_consumed_at_the_highest_fee() {
    accounting_math::redemption_quote(9_999, 10_000, 10_000, 10_000, 9_999);
}

/// Pins the NAV guard ahead of the share-bound guard when both are invalid.
#[test]
#[expected_failure(abort_code = accounting_math::EInvalidNav, location = blast_leverage_core::accounting_math)]
fun zero_nav_is_rejected_before_an_invalid_share_amount() {
    accounting_math::redemption_quote(0, 0, 1_000, 100, 0);
}

/// Pins the share-bound guard ahead of the fee-rate guard when both are invalid.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareAmount,
    location = blast_leverage_core::accounting_math,
)]
fun an_invalid_share_amount_is_rejected_before_an_invalid_fee_rate() {
    accounting_math::redemption_quote(100, 1_000, 1_000, 100, 10_000);
}

// === Private Test Helpers ===

/// Computes the independent ceiling reference for a valid positive fee input.
fun reference_fee_up(amount: u64, fee_bps: u64): u64 {
    ((amount as u128) * (fee_bps as u128))
        .div_ceil(10_000)
        as u64
}

/// Asserts the fee is the exact ceiling and remains bounded by its source amount.
fun assert_fee_is_exact_ceiling(amount: u64, fee_bps: u64) {
    let fee = accounting_math::fee_up(amount, fee_bps);
    let numerator = (amount as u128) * (fee_bps as u128);

    assert_eq!(fee, reference_fee_up(amount, fee_bps));
    assert!(fee <= amount);
    assert!((fee as u128) * 10_000 >= numerator);
    if (fee > 0) {
        assert!(((fee - 1) as u128) * 10_000 < numerator);
    } else {
        assert_eq!(fee_bps, 0);
    };
}

/// Asserts every mint field against an independently evaluated floor formula.
fun assert_mint_matches_reference(contribution: u64, nav_before: u64, shares_before: u64) {
    let (shares_out, shares_after) = accounting_math::mint_quote(
        contribution,
        nav_before,
        shares_before,
    );
    let share_numerator = (shares_before as u128) * (contribution as u128);
    let nav_after = (nav_before as u128) + (contribution as u128);

    assert_eq!(shares_out as u128, share_numerator / (nav_before as u128));
    assert_eq!(shares_after, shares_before + shares_out);
    assert!((shares_out as u128) * (nav_before as u128) <= share_numerator);
    assert!(((shares_out as u128) + 1) * (nav_before as u128) > share_numerator);
    assert!(nav_after * (shares_before as u128) >= (nav_before as u128) * (shares_after as u128));
}

/// Asserts every redemption field against independent ceiling and conservation formulas.
fun assert_redemption_matches_reference(
    shares_burned: u64,
    nav_before: u64,
    nav_unwound: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
) {
    let (shares_after, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        shares_burned,
        nav_before,
        nav_unwound,
        shares_before,
        redeem_fee_bps,
    );
    let equity_numerator = (nav_before as u128) * (shares_after as u128);
    let expected_equity_keep = equity_numerator.div_ceil(shares_before as u128) as u64;
    let expected_gross = nav_unwound.min(nav_before) - expected_equity_keep;
    let expected_fee = reference_fee_up(expected_gross, redeem_fee_bps);

    assert_eq!(shares_after, shares_before - shares_burned);
    assert_eq!(equity_keep, expected_equity_keep);
    assert_eq!(gross, expected_gross);
    assert_eq!(fee, expected_fee);
    assert_eq!(net, expected_gross - expected_fee);
    assert!((equity_keep as u128) * (shares_before as u128) >= equity_numerator);
    assert!(((equity_keep - 1) as u128) * (shares_before as u128) < equity_numerator);
    assert_eq!(nav_unwound.min(nav_before), equity_keep + fee + net);
    assert!(gross <= nav_before - equity_keep);
    assert!(
        (equity_keep as u128) * (shares_before as u128)
            >= (nav_before as u128) * (shares_after as u128),
    );
}

/// Mints from an actual deposit, immediately redeems those shares, and proves no profit.
fun assert_round_trip_cannot_profit(
    nav_before: u64,
    shares_before: u64,
    deposit: u64,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
) {
    let mint_fee = reference_fee_up(deposit, mint_fee_bps);
    let contribution = deposit - mint_fee;
    let nav_after_mint = nav_before + contribution;
    let (shares_out, shares_after) = accounting_math::mint_quote(
        contribution,
        nav_before,
        shares_before,
    );
    let (_, equity_keep, _, redemption_fee, net) = accounting_math::redemption_quote(
        shares_out,
        nav_after_mint,
        nav_after_mint,
        shares_after,
        redeem_fee_bps,
    );

    assert!(net <= deposit);
    assert_eq!(nav_after_mint - net - redemption_fee, equity_keep);
    assert!(equity_keep >= nav_before);
}

/// Asserts the quote fields reconcile and `nav_after / S1 >= nav_before / S0`.
fun assert_mint_is_non_dilutive(contribution: u64, nav_before: u64, shares_before: u64) {
    let (shares_out, shares_after) = accounting_math::mint_quote(
        contribution,
        nav_before,
        shares_before,
    );
    let nav_after = (nav_before as u128) + (contribution as u128);

    assert_eq!(shares_after, shares_before + shares_out);
    assert!(nav_after * (shares_before as u128) >= (nav_before as u128) * (shares_after as u128));
}

/// Asserts the quote fields reconcile and `equity_keep / S1 >= nav_before / S0`.
fun assert_redemption_is_non_dilutive(
    shares_burned: u64,
    nav_before: u64,
    nav_unwound: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
) {
    let (shares_after, equity_keep, gross, fee, net) = accounting_math::redemption_quote(
        shares_burned,
        nav_before,
        nav_unwound,
        shares_before,
        redeem_fee_bps,
    );

    assert!(fee <= gross);
    assert_eq!(shares_after, shares_before - shares_burned);
    assert_eq!(gross, nav_unwound.min(nav_before) - equity_keep);
    assert_eq!(net, gross - fee);
    assert!(
        (equity_keep as u128) * (shares_before as u128)
            >= (nav_before as u128) * (shares_after as u128),
    );
    // The NAV that actually remains never prices below the pre-unwind share price.
    assert!(
        ((nav_unwound - gross) as u128) * (shares_before as u128)
            >= (nav_before as u128) * (shares_after as u128),
    );
}
