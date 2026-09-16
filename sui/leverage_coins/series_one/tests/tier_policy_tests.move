#[test_only]
/// Composition and validation tests for one immutable Vault tier policy.
module blast_leverage_series_one::tier_policy_tests;

use std::unit_test::assert_eq;

use blast_leverage_series_one::{policy};

// === Tests ===

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_leverage_series_one::policy)]
fun fee_limits_reject_mint_cap_below_initial_rate() {
    new_tier(true, 10, 20, 1, 1).with_fee_limits(9, 20, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_leverage_series_one::policy)]
fun fee_limits_reject_redeem_cap_below_initial_rate() {
    new_tier(true, 10, 20, 1, 1).with_fee_limits(10, 19, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_leverage_series_one::policy)]
fun fee_limits_reject_mint_cap_at_full_principal() {
    new_tier(true, 10, 20, 1, 1).with_fee_limits(10_000, 20, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_leverage_series_one::policy)]
fun fee_limits_reject_redeem_cap_at_full_principal() {
    new_tier(true, 10, 20, 1, 1).with_fee_limits(10, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_leverage_series_one::policy)]
fun fee_limits_reject_allocation_cap_above_full_fee() {
    new_tier(true, 10, 20, 1, 1).with_fee_limits(10, 20, 10_001, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_leverage_series_one::policy)]
fun fee_limits_reject_initial_allocation_above_cap() {
    new_tier(true, 10, 20, 1, 1).with_fee_limits(10, 20, 2_000, 2_001);
}

#[test]
fun fee_limits_accept_zero_exact_initial_and_largest_legal_caps() {
    new_tier(true, 0, 0, 1, 1).with_fee_limits(0, 0, 0, 0).assert_fee_limits(0, 0, 0);
    new_tier(true, 10, 20, 1, 1).with_fee_limits(10, 20, 2_000, 2_000).assert_fee_limits(10, 20, 2_000);
    new_tier(true, 9_999, 9_999, 1, 1).with_fee_limits(9_999, 9_999, 10_000, 10_000).assert_fee_limits(9_999, 9_999, 10_000);
}


#[test]
fun a_complete_long_policy_is_composed_and_preserved() {
    let tier = new_tier(true, 0, 0, 1, 1);
    let rebalance = tier.rebalance_policy();
    let valuation = tier.valuation_policy();

    assert_eq!(tier.side(), policy::long());
    assert_eq!(rebalance.target_bps(), 3);
    assert_eq!(valuation.max_price_age_ms(), 1);
    assert_eq!(tier.mint_fee_bps(), 0);
    assert_eq!(tier.redeem_fee_bps(), 0);
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
        1_000_000,
        max / 100,
    );

    assert_eq!(tier.side(), policy::short());
    assert_eq!(tier.rebalance_policy().hard_cap_bps(), 1_000_000);
    assert_eq!(tier.valuation_policy().max_price_age_ms(), max);
    assert_eq!(tier.mint_fee_bps(), 9_999);
    assert_eq!(tier.redeem_fee_bps(), 9_999);
    assert_eq!(tier.min_exposure_lots(), 1_000_000);
    assert_eq!(tier.nav_cap(), max / 100);
}

#[test]
fun copied_tier_preserves_every_composed_field() {
    let tier = new_tier(true, 1, 2, 4, 5);
    let copied = tier;

    assert_eq!(copied.side(), tier.side());
    assert_eq!(copied.rebalance_policy(), tier.rebalance_policy());
    assert_eq!(copied.valuation_policy(), tier.valuation_policy());
    assert_eq!(copied.mint_fee_bps(), tier.mint_fee_bps());
    assert_eq!(copied.redeem_fee_bps(), tier.redeem_fee_bps());
    assert_eq!(copied.min_exposure_lots(), tier.min_exposure_lots());
    assert_eq!(copied.nav_cap(), tier.nav_cap());
}

#[test]
fun every_small_valid_domain_tuple_is_accepted_and_preserved() {
    vector[false, true].do!(|is_long| {
        0u64.range_do!(3, |mint_fee_bps| {
            0u64.range_do!(3, |redeem_fee_bps| {
                1u64.range_do!(3, |min_exposure_lots| {
                    1u64.range_do!(3, |nav_cap| {
                        let tier = new_tier(
                            is_long,
                            mint_fee_bps,
                            redeem_fee_bps,
                            min_exposure_lots,
                            nav_cap,
                        );

                        assert_eq!(tier.mint_fee_bps(), mint_fee_bps);
                        assert_eq!(tier.redeem_fee_bps(), redeem_fee_bps);
                        assert_eq!(tier.min_exposure_lots(), min_exposure_lots);
                        assert_eq!(tier.nav_cap(), nav_cap);
                    });
                });
            });
        });
    });
}

#[test]
fun nav_at_the_cap_is_within_it() {
    let tier = new_tier(true, 0, 0, 1, 5_000);

    assert!(tier.is_within_nav_cap(5_000));
    assert!(!tier.is_within_nav_cap(5_001));
    tier.assert_within_nav_cap(0);
    tier.assert_within_nav_cap(5_000);
}

#[test]
#[expected_failure(
    abort_code = policy::ESeriesNavCapExceeded,
    location = blast_leverage_series_one::policy,
)]
fun nav_one_unit_above_the_cap_is_rejected() {
    new_tier(true, 0, 0, 1, 5_000).assert_within_nav_cap(5_001);
}

#[test]
fun minimum_exposure_lots_at_the_ceiling_are_accepted() {
    assert_eq!(new_tier(true, 0, 0, 1_000_000, 1).min_exposure_lots(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun minimum_exposure_lots_above_the_ceiling_are_rejected() {
    new_tier(true, 0, 0, 1_000_001, 1);
}

/// A policy whose lot multiple and NAV cap were swapped is rejected instead of
/// deploying an immutable Vault that can never mint.
#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun a_transposed_lot_multiple_and_nav_cap_is_rejected() {
    new_tier(true, 0, 0, 5_000_000_000_000, 100);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidSeriesNavCap, location = blast_leverage_series_one::policy)]
fun a_nav_cap_whose_hard_cap_notional_overflows_is_rejected() {
    let max = std::u64::max_value!();

    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 2, 999_999, 1_000_000, 0, 0, 1),
        standard_valuation(),
        0,
        0,
        1,
        max / 100 + 1,
    );
}

#[test]
#[expected_failure(abort_code = policy::EInvalidFeeBps, location = blast_leverage_series_one::policy)]
fun mint_fee_at_the_denominator_is_rejected() {
    new_tier(true, 10_000, 0, 1, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidFeeBps, location = blast_leverage_series_one::policy)]
fun redeem_fee_at_the_denominator_is_rejected() {
    new_tier(true, 0, 10_000, 1, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun zero_minimum_exposure_lots_are_rejected() {
    new_tier(true, 0, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidSeriesNavCap, location = blast_leverage_series_one::policy)]
fun zero_nav_cap_is_rejected() {
    new_tier(true, 0, 0, 1, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidFeeBps, location = blast_leverage_series_one::policy)]
fun fee_validation_precedes_other_tier_validation() {
    new_tier(true, 10_000, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_leverage_series_one::policy)]
fun lot_validation_precedes_nav_validation() {
    new_tier(true, 0, 0, 0, 0);
}

// === Private Functions ===

fun new_tier(
    is_long: bool,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
): policy::TierPolicy {
    policy::new_tier_policy(
        if (is_long) policy::long() else policy::short(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_valuation(),
        mint_fee_bps,
        redeem_fee_bps,
        min_exposure_lots,
        nav_cap,
    )
}

fun standard_valuation(): policy::ValuationPolicy {
    policy::new_valuation(1, 0, 0, 0)
}
