#[test_only]
/// Composition and validation tests for one immutable Vault policy.
module blast_boosts_core::vault_policy_tests;

// === Tests ===

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_mint_cap_below_initial_rate() {
    new_policy(true, 10, 20, 1, 1).with_fee_limits(9, 20, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_redeem_cap_below_initial_rate() {
    new_policy(true, 10, 20, 1, 1).with_fee_limits(10, 19, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_mint_cap_at_full_principal() {
    new_policy(true, 10, 20, 1, 1).with_fee_limits(10_000, 20, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_redeem_cap_at_full_principal() {
    new_policy(true, 10, 20, 1, 1).with_fee_limits(10, 10_000, 0);
}

#[test]
#[expected_failure(abort_code = policy::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_allocation_cap_above_full_fee() {
    new_policy(true, 10, 20, 1, 1).with_fee_limits(10, 20, 10_001);
}

#[test]
fun fee_limits_accept_zero_exact_and_largest_legal_caps() {
    new_policy(true, 0, 0, 1, 1).with_fee_limits(0, 0, 0).assert_fee_limits(0, 0, 0);
    new_policy(true, 10, 20, 1, 1).with_fee_limits(10, 20, 2_000).assert_fee_limits(10, 20, 2_000);
    new_policy(true, 9_999, 9_999, 1, 1).with_fee_limits(9_999, 9_999, 10_000).assert_fee_limits(9_999, 9_999, 10_000);
}

#[test]
fun a_complete_long_policy_is_composed_and_preserved() {
    let vault_policy = new_policy(true, 0, 0, 1, 1);
    let rebalance = vault_policy.rebalance_policy();
    let price_policy = vault_policy.price_policy();

    assert_eq!(vault_policy.side(), policy::long());
    assert_eq!(rebalance.target_bps(), 3);
    assert_eq!(price_policy.max_price_age_ms(), 1);
    assert_eq!(vault_policy.mint_fee_bps(), 0);
    assert_eq!(vault_policy.redeem_fee_bps(), 0);
    assert_eq!(vault_policy.min_exposure_lots(), 1);
    assert_eq!(vault_policy.nav_cap(), 1);
}

#[test]
fun the_largest_locally_valid_short_policy_is_preserved() {
    let max = std::u64::max_value!();
    let vault_policy = policy::new_vault_policy(
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
        policy::new_price_policy(max, max, 9_999, 9_999),
        9_999,
        9_999,
        1_000_000,
        max / 100,
    );

    assert_eq!(vault_policy.side(), policy::short());
    assert_eq!(vault_policy.rebalance_policy().max_leverage_bps(), 1_000_000);
    assert_eq!(vault_policy.price_policy().max_price_age_ms(), max);
    assert_eq!(vault_policy.mint_fee_bps(), 9_999);
    assert_eq!(vault_policy.redeem_fee_bps(), 9_999);
    assert_eq!(vault_policy.min_exposure_lots(), 1_000_000);
    assert_eq!(vault_policy.nav_cap(), max / 100);
}

#[test]
fun copied_policy_preserves_every_composed_field() {
    let vault_policy = new_policy(true, 1, 2, 4, 5);
    let copied = vault_policy;

    assert_eq!(copied.side(), vault_policy.side());
    assert_eq!(copied.rebalance_policy(), vault_policy.rebalance_policy());
    assert_eq!(copied.price_policy(), vault_policy.price_policy());
    assert_eq!(copied.mint_fee_bps(), vault_policy.mint_fee_bps());
    assert_eq!(copied.redeem_fee_bps(), vault_policy.redeem_fee_bps());
    assert_eq!(copied.min_exposure_lots(), vault_policy.min_exposure_lots());
    assert_eq!(copied.nav_cap(), vault_policy.nav_cap());
}

#[test]
fun every_small_valid_domain_tuple_is_accepted_and_preserved() {
    vector[false, true].do!(|is_long| {
        0u64.range_do!(3, |mint_fee_bps| {
            0u64.range_do!(3, |redeem_fee_bps| {
                1u64.range_do!(3, |min_exposure_lots| {
                    1u64.range_do!(3, |nav_cap| {
                        let vault_policy = new_policy(
                            is_long,
                            mint_fee_bps,
                            redeem_fee_bps,
                            min_exposure_lots,
                            nav_cap,
                        );

                        assert_eq!(vault_policy.mint_fee_bps(), mint_fee_bps);
                        assert_eq!(vault_policy.redeem_fee_bps(), redeem_fee_bps);
                        assert_eq!(vault_policy.min_exposure_lots(), min_exposure_lots);
                        assert_eq!(vault_policy.nav_cap(), nav_cap);
                    });
                });
            });
        });
    });
}

#[test]
fun rebalance_policy_accepts_the_largest_nav_cap_that_fits_max_leverage() {
    let max = std::u64::max_value!();
    policy::new_rebalance_policy(0, 2, 999_999, 1_000_000, 0, 0, 1).assert_valid_nav_cap(max / 100);
}

#[test]
fun minimum_exposure_lots_at_the_ceiling_are_accepted() {
    assert_eq!(new_policy(true, 0, 0, 1_000_000, 1).min_exposure_lots(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_boosts_core::policy)]
fun minimum_exposure_lots_above_the_ceiling_are_rejected() {
    new_policy(true, 0, 0, 1_000_001, 1);
}

/// A policy whose lot multiple and NAV cap were swapped is rejected instead of
/// deploying an immutable Vault that can never mint.
#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_boosts_core::policy)]
fun a_transposed_lot_multiple_and_nav_cap_is_rejected() {
    new_policy(true, 0, 0, 5_000_000_000_000, 100);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidNavCap, location = blast_boosts_core::policy)]
fun a_nav_cap_whose_max_leverage_notional_overflows_is_rejected() {
    let max = std::u64::max_value!();

    policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 2, 999_999, 1_000_000, 0, 0, 1),
        standard_price_policy(),
        0,
        0,
        1,
        max / 100 + 1,
    );
}

#[test]
#[expected_failure(abort_code = policy::EInvalidFeeBps, location = blast_boosts_core::policy)]
fun mint_fee_at_the_denominator_is_rejected() {
    new_policy(true, 10_000, 0, 1, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidFeeBps, location = blast_boosts_core::policy)]
fun redeem_fee_at_the_denominator_is_rejected() {
    new_policy(true, 0, 10_000, 1, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_boosts_core::policy)]
fun zero_minimum_exposure_lots_are_rejected() {
    new_policy(true, 0, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidNavCap, location = blast_boosts_core::policy)]
fun zero_nav_cap_is_rejected() {
    new_policy(true, 0, 0, 1, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidFeeBps, location = blast_boosts_core::policy)]
fun fee_validation_precedes_other_policy_validation() {
    new_policy(true, 10_000, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = policy::EInvalidMinExposureLots, location = blast_boosts_core::policy)]
fun lot_validation_precedes_nav_validation() {
    new_policy(true, 0, 0, 0, 0);
}

// === Private Functions ===

fun new_policy(
    is_long: bool,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
): policy::VaultPolicy {
    policy::new_vault_policy(
        if (is_long) policy::long() else policy::short(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_price_policy(),
        mint_fee_bps,
        redeem_fee_bps,
        min_exposure_lots,
        nav_cap,
    )
}

fun standard_price_policy(): policy::PricePolicy {
    policy::new_price_policy(1, 0, 0, 0)
}

// === Imports ===

use std::unit_test::assert_eq;

use blast_boosts_core::{policy};
