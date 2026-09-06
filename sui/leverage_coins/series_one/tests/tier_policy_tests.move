#[test_only]
/// Composition and validation tests for one immutable Vault tier policy.
module blast_leverage_series_one::tier_policy_tests;

use std::unit_test::assert_eq;

use blast_leverage_series_one::{errors, policy};

// === Tests ===

#[test]
fun a_complete_long_policy_is_composed_and_preserved() {
    let tier = new_tier(true, 0, 0, 0, 1, 1);
    let rebalance = tier.rebalance_policy();
    let valuation = tier.valuation_policy();

    assert_eq!(tier.side(), policy::long());
    assert_eq!(rebalance.target_bps(), 3);
    assert_eq!(valuation.max_price_age_ms(), 1);
    assert_eq!(tier.mint_fee_bps(), 0);
    assert_eq!(tier.redeem_fee_bps(), 0);
    assert_eq!(tier.max_mint_contribution_divergence_bps(), 0);
    assert_eq!(tier.min_exposure_lots(), 1);
    assert_eq!(tier.nav_cap(), 1);
}

#[test]
fun the_largest_locally_valid_short_policy_is_preserved() {
    let max = std::u64::max_value!();
    let tier = policy::new_tier_policy(
        policy::short(),
        policy::new_rebalance_policy(
            0,
            2,
            999_999,
            1_000_000,
            9_999,
            9_999,
            max,
        ),
        policy::new_valuation(max, max, 9_999, 9_999),
        9_999,
        9_999,
        9_999,
        9_999,
        1_000_000,
        max / 100,
    );

    assert_eq!(tier.side(), policy::short());
    assert_eq!(tier.rebalance_policy().hard_cap_bps(), 1_000_000);
    assert_eq!(tier.valuation_policy().max_price_age_ms(), max);
    assert_eq!(tier.mint_fee_bps(), 9_999);
    assert_eq!(tier.redeem_fee_bps(), 9_999);
    assert_eq!(tier.max_mint_contribution_divergence_bps(), 9_999);
    assert_eq!(tier.max_redemption_gross_divergence_bps(), 9_999);
    assert_eq!(tier.min_exposure_lots(), 1_000_000);
    assert_eq!(tier.nav_cap(), max / 100);
}

#[test]
fun copied_tier_preserves_every_composed_field() {
    let tier = new_tier(true, 1, 2, 3, 4, 5);
    let copied = tier;

    assert_eq!(copied.side(), tier.side());
    assert_eq!(copied.rebalance_policy(), tier.rebalance_policy());
    assert_eq!(copied.valuation_policy(), tier.valuation_policy());
    assert_eq!(copied.mint_fee_bps(), tier.mint_fee_bps());
    assert_eq!(copied.redeem_fee_bps(), tier.redeem_fee_bps());
    assert_eq!(
        copied.max_mint_contribution_divergence_bps(),
        tier.max_mint_contribution_divergence_bps(),
    );
    assert_eq!(
        copied.max_redemption_gross_divergence_bps(),
        tier.max_redemption_gross_divergence_bps(),
    );
    assert_eq!(copied.min_exposure_lots(), tier.min_exposure_lots());
    assert_eq!(copied.nav_cap(), tier.nav_cap());
}

#[test]
fun every_small_valid_domain_tuple_is_accepted_and_preserved() {
    vector[false, true].do!(|is_long| {
        0u64.range_do!(3, |mint_fee_bps| {
            0u64.range_do!(3, |redeem_fee_bps| {
                0u64.range_do!(3, |mint_divergence_bps| {
                    1u64.range_do!(3, |min_exposure_lots| {
                        1u64.range_do!(3, |nav_cap| {
                            let tier = new_tier(
                                is_long,
                                mint_fee_bps,
                                redeem_fee_bps,
                                mint_divergence_bps,
                                min_exposure_lots,
                                nav_cap,
                            );

                            assert_eq!(tier.mint_fee_bps(), mint_fee_bps);
                            assert_eq!(tier.redeem_fee_bps(), redeem_fee_bps);
                            assert_eq!(
                                tier.max_mint_contribution_divergence_bps(),
                                mint_divergence_bps,
                            );
                            assert_eq!(tier.min_exposure_lots(), min_exposure_lots);
                            assert_eq!(tier.nav_cap(), nav_cap);
                        });
                    });
                });
            });
        });
    });
}

#[test]
fun a_mint_contribution_at_the_exact_bound_is_accepted() {
    mint_contribution_tier(20_000, 250)
        .assert_mint_contribution_within_bound(10_000, 10_500);
}

#[test]
#[expected_failure(
    abort_code = errors::EMintContributionExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun a_mint_contribution_one_unit_past_the_bound_is_rejected() {
    mint_contribution_tier(20_000, 250)
        .assert_mint_contribution_within_bound(10_000, 10_501);
}

#[test]
fun maximum_width_mint_contribution_comparison_does_not_wrap() {
    let max = std::u64::max_value!();
    let tier = policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(
            0,
            999_997,
            999_999,
            1_000_000,
            0,
            0,
            1,
        ),
        standard_valuation(),
        0,
        0,
        9_999,
        9_999,
        1,
        max / 100,
    );

    tier.assert_mint_contribution_within_bound(max - 1, max);
    tier.assert_redemption_gross_within_bound(max - 1, max);
}

#[test]
fun mint_contribution_bound_matches_the_small_domain_reference() {
    vector[3u64, 20_000].do!(|target_bps| {
        vector[0u64, 250, 9_999].do!(|divergence_bps| {
            let tier = mint_contribution_tier(target_bps, divergence_bps);

            0u64.range_do!(16, |deposit| {
                0u64.range_do!(21, |contribution| {
                    let allowance = (deposit as u256)
                        * (divergence_bps as u256)
                        * (target_bps as u256)
                        / 100_000_000;
                    let expected = (contribution as u256)
                        <= (deposit as u256) + allowance;

                    assert_eq!(
                        tier.is_mint_contribution_within_bound_for_testing(
                            deposit,
                            contribution,
                        ),
                        expected,
                    );
                });
            });
        });
    });
}

#[test]
fun a_redemption_gross_at_the_exact_bound_is_accepted() {
    mint_contribution_tier(20_000, 250)
        .assert_redemption_gross_within_bound(10_000, 10_500);
}

#[test]
#[expected_failure(
    abort_code = errors::ERedemptionGrossExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun a_redemption_gross_one_unit_past_the_bound_is_rejected() {
    mint_contribution_tier(20_000, 250)
        .assert_redemption_gross_within_bound(10_000, 10_501);
}

#[test]
fun a_redemption_gross_at_or_below_its_claim_always_passes() {
    let tier = mint_contribution_tier(20_000, 0);

    tier.assert_redemption_gross_within_bound(10_000, 10_000);
    tier.assert_redemption_gross_within_bound(10_000, 1);
}

/// The audit case: one share of a million burned against a 100-unit equity gain.
/// The proportional claim is 1 and the leveraged allowance floors to zero, so a
/// gross of 101 is rejected however small the redeemer's stake.
#[test]
#[expected_failure(
    abort_code = errors::ERedemptionGrossExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun a_dust_redeemer_cannot_capture_a_pool_wide_gain() {
    mint_contribution_tier(20_000, 250)
        .assert_redemption_gross_within_bound(1, 101);
}

#[test]
#[expected_failure(
    abort_code = errors::ERedemptionGrossExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun a_zero_claim_admits_no_positive_gross_even_at_the_widest_bound() {
    mint_contribution_tier(20_000, 9_999)
        .assert_redemption_gross_within_bound(0, 1);
}

#[test]
fun redemption_gross_bound_matches_the_small_domain_reference() {
    vector[3u64, 20_000].do!(|target_bps| {
        vector[0u64, 250, 9_999].do!(|divergence_bps| {
            let tier = mint_contribution_tier(target_bps, divergence_bps);

            0u64.range_do!(16, |claim| {
                0u64.range_do!(21, |gross| {
                    let allowance = (claim as u256)
                        * (divergence_bps as u256)
                        * (target_bps as u256)
                        / 100_000_000;
                    let expected = (gross as u256) <= (claim as u256) + allowance;

                    assert_eq!(
                        tier.is_redemption_gross_within_bound_for_testing(claim, gross),
                        expected,
                    );
                });
            });
        });
    });
}

#[test]
fun nav_at_the_cap_is_within_it() {
    let tier = new_tier(true, 0, 0, 0, 1, 5_000);

    assert!(tier.is_within_nav_cap(5_000));
    assert!(!tier.is_within_nav_cap(5_001));
    tier.assert_within_nav_cap(0);
    tier.assert_within_nav_cap(5_000);
}

#[test]
#[expected_failure(
    abort_code = errors::ESeriesNavCapExceeded,
    location = blast_leverage_series_one::policy,
)]
fun nav_one_unit_above_the_cap_is_rejected() {
    new_tier(true, 0, 0, 0, 1, 5_000).assert_within_nav_cap(5_001);
}

#[test]
fun minimum_exposure_lots_at_the_ceiling_are_accepted() {
    assert_eq!(new_tier(true, 0, 0, 0, 1_000_000, 1).min_exposure_lots(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun minimum_exposure_lots_above_the_ceiling_are_rejected() {
    new_tier(true, 0, 0, 0, 1_000_001, 1);
}

/// A policy whose lot multiple and NAV cap were swapped is rejected instead of
/// deploying an immutable Vault that can never mint.
#[test]
#[expected_failure(abort_code = errors::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun a_transposed_lot_multiple_and_nav_cap_is_rejected() {
    new_tier(true, 0, 0, 0, 5_000_000_000_000, 100);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSeriesNavCap, location = blast_leverage_series_one::policy)]
fun a_nav_cap_whose_hard_cap_notional_overflows_is_rejected() {
    let max = std::u64::max_value!();

    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 2, 999_999, 1_000_000, 0, 0, 1),
        standard_valuation(),
        0,
        0,
        0,
        0,
        1,
        max / 100 + 1,
    );
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxRedemptionGrossDivergenceBps, location = blast_leverage_series_one::policy)]
fun redemption_gross_divergence_at_the_denominator_is_rejected() {
    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_valuation(),
        0,
        0,
        0,
        10_000,
        1,
        1,
    );
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxRedemptionGrossDivergenceBps, location = blast_leverage_series_one::policy)]
fun redemption_divergence_validation_precedes_lot_and_nav_validation() {
    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_valuation(),
        0,
        0,
        0,
        10_000,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = errors::EInvalidFeeBps, location = blast_leverage_series_one::policy)]
fun mint_fee_at_the_denominator_is_rejected() {
    new_tier(true, 10_000, 0, 0, 1, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidFeeBps, location = blast_leverage_series_one::policy)]
fun redeem_fee_at_the_denominator_is_rejected() {
    new_tier(true, 0, 10_000, 0, 1, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxMintContributionDivergenceBps, location = blast_leverage_series_one::policy)]
fun mint_contribution_divergence_at_the_denominator_is_rejected() {
    new_tier(true, 0, 0, 10_000, 1, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun zero_minimum_exposure_lots_are_rejected() {
    new_tier(true, 0, 0, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSeriesNavCap, location = blast_leverage_series_one::policy)]
fun zero_nav_cap_is_rejected() {
    new_tier(true, 0, 0, 0, 1, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidFeeBps, location = blast_leverage_series_one::policy)]
fun fee_validation_precedes_other_tier_validation() {
    new_tier(true, 10_000, 10_000, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxMintContributionDivergenceBps, location = blast_leverage_series_one::policy)]
fun mint_divergence_validation_precedes_lot_and_nav_validation() {
    new_tier(true, 0, 0, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun lot_validation_precedes_nav_validation() {
    new_tier(true, 0, 0, 0, 0, 0);
}

// === Private Functions ===

fun new_tier(
    is_long: bool,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    mint_divergence_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
): policy::TierPolicy {
    policy::new_tier_policy(
        if (is_long) policy::long() else policy::short(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_valuation(),
        mint_fee_bps,
        redeem_fee_bps,
        mint_divergence_bps,
        mint_divergence_bps,
        min_exposure_lots,
        nav_cap,
    )
}

fun standard_valuation(): policy::ValuationPolicy {
    policy::new_valuation(1, 0, 0, 0)
}

fun mint_contribution_tier(
    target_bps: u64,
    mint_divergence_bps: u64,
): policy::TierPolicy {
    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(
            0,
            target_bps,
            target_bps + 2,
            target_bps + 3,
            0,
            0,
            1,
        ),
        standard_valuation(),
        0,
        0,
        mint_divergence_bps,
        mint_divergence_bps,
        1,
        1,
    )
}
