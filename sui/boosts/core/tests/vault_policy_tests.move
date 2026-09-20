#[test_only]
/// Composition and validation tests for one immutable Vault policy.
module blast_boosts_core::vault_policy_tests;

// === Constants ===

const MAX_RESERVE_BPS: u64 = 1_000;

// === Tests ===

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun policy_construction_rejects_mint_cap_below_initial_rate() {
    new_policy_with_fee_caps(10, 20, 9, 20, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun policy_construction_rejects_redeem_cap_below_initial_rate() {
    new_policy_with_fee_caps(10, 20, 10, 19, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun policy_construction_rejects_mint_cap_at_full_principal() {
    new_policy_with_fee_caps(10, 20, 10_000, 20, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun policy_construction_rejects_redeem_cap_at_full_principal() {
    new_policy_with_fee_caps(10, 20, 10, 10_000, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun policy_construction_rejects_allocation_cap_above_full_fee() {
    new_policy_with_fee_caps(10, 20, 10, 20, 10_001);
}

#[test]
fun fee_limits_accept_zero_exact_and_largest_legal_caps() {
    new_policy_with_fee_caps(0, 0, 0, 0, 0).assert_fee_limits(0, 0, 0);
    new_policy_with_fee_caps(10, 20, 10, 20, 2_000).assert_fee_limits(10, 20, 2_000);
    new_policy_with_fee_caps(9_999, 9_999, 9_999, 9_999, 10_000).assert_fee_limits(9_999, 9_999, 10_000);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_a_mint_fee_one_unit_above_its_cap() {
    new_policy_with_fee_caps(10, 20, 10, 20, 2_000).assert_fee_limits(11, 20, 2_000);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_a_redeem_fee_one_unit_above_its_cap() {
    new_policy_with_fee_caps(10, 20, 10, 20, 2_000).assert_fee_limits(10, 21, 2_000);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_limits_reject_an_admin_share_one_unit_above_its_cap() {
    new_policy_with_fee_caps(10, 20, 10, 20, 2_000).assert_fee_limits(10, 20, 2_001);
}

#[test]
fun a_complete_long_policy_is_composed_and_preserved() {
    let vault_policy = new_policy(true, 0, 0, 1);
    let rebalance = vault_policy.rebalance_policy();
    let price_policy = vault_policy.price_policy();

    assert_eq!(vault_policy.side(), policy::long());
    assert_eq!(rebalance.target_leverage_bps(), 3);
    assert_eq!(price_policy.max_price_age_ms(), 1);
    assert_eq!(vault_policy.initial_mint_fee_bps(), 0);
    assert_eq!(vault_policy.initial_redeem_fee_bps(), 0);
    assert_eq!(vault_policy.min_order_lots(), 1);
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
        9_999,
        9_999,
        10_000,
        1_000_000,
        10_000,
    );

    assert_eq!(vault_policy.side(), policy::short());
    assert_eq!(vault_policy.rebalance_policy().max_leverage_bps(), 1_000_000);
    assert_eq!(vault_policy.price_policy().max_price_age_ms(), max);
    assert_eq!(vault_policy.initial_mint_fee_bps(), 9_999);
    assert_eq!(vault_policy.initial_redeem_fee_bps(), 9_999);
    assert_eq!(vault_policy.min_order_lots(), 1_000_000);
    assert_eq!(vault_policy.max_reserve_bps(), 10_000);
}

#[test]
fun copied_policy_preserves_every_composed_field() {
    let vault_policy = new_policy(true, 1, 2, 4);
    let copied = vault_policy;

    assert_eq!(copied.side(), vault_policy.side());
    assert_eq!(copied.rebalance_policy(), vault_policy.rebalance_policy());
    assert_eq!(copied.price_policy(), vault_policy.price_policy());
    assert_eq!(copied.initial_mint_fee_bps(), vault_policy.initial_mint_fee_bps());
    assert_eq!(copied.initial_redeem_fee_bps(), vault_policy.initial_redeem_fee_bps());
    assert_eq!(copied.min_order_lots(), vault_policy.min_order_lots());
}

#[test]
fun every_small_valid_domain_tuple_is_accepted_and_preserved() {
    vector[false, true].do!(|is_long| {
        0u64.range_do!(3, |mint_fee_bps| {
            0u64.range_do!(3, |redeem_fee_bps| {
                1u64.range_do!(3, |min_order_lots| {
                    let vault_policy = new_policy(is_long, mint_fee_bps, redeem_fee_bps, min_order_lots);

                    assert_eq!(vault_policy.initial_mint_fee_bps(), mint_fee_bps);
                    assert_eq!(vault_policy.initial_redeem_fee_bps(), redeem_fee_bps);
                    assert_eq!(vault_policy.min_order_lots(), min_order_lots);
                });
            });
        });
    });
}

#[test]
fun rebalance_policy_accepts_the_largest_nav_cap_that_fits_max_leverage() {
    let max = std::u64::max_value!();
    policy::new_rebalance_policy(0, 2, 999_999, 1_000_000, 0, 0, 1).assert_nav_cap_valid(max / 100);
}

/// At or below 1x the target notional never exceeds the cap itself, so the full `u64` range fits.
#[test]
fun a_full_u64_nav_cap_is_accepted_when_max_leverage_is_at_most_one_x() {
    let max = std::u64::max_value!();

    policy::new_rebalance_policy(0, 1, 2, 10_000, 0, 0, 1).assert_nav_cap_valid(max);
    policy::new_rebalance_policy(0, 1, 2, 3, 0, 0, 1).assert_nav_cap_valid(max);
}

#[test]
fun minimum_exposure_lots_at_the_ceiling_are_accepted() {
    assert_eq!(new_policy(true, 0, 0, 1_000_000).min_order_lots(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinOrderLots, location = blast_boosts_core::policy)]
fun minimum_exposure_lots_above_the_ceiling_are_rejected() {
    new_policy(true, 0, 0, 1_000_001);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun a_nav_cap_whose_max_leverage_notional_overflows_is_rejected() {
    let max = std::u64::max_value!();
    policy::new_rebalance_policy(0, 2, 999_999, 1_000_000, 0, 0, 1).assert_nav_cap_valid(max / 100 + 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidFeeBps, location = blast_boosts_core::policy)]
fun mint_fee_at_the_denominator_is_rejected() {
    new_policy(true, 10_000, 0, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidFeeBps, location = blast_boosts_core::policy)]
fun redeem_fee_at_the_denominator_is_rejected() {
    new_policy(true, 0, 10_000, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinOrderLots, location = blast_boosts_core::policy)]
fun zero_minimum_exposure_lots_are_rejected() {
    new_policy(true, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxReserveBps, location = blast_boosts_core::policy)]
fun a_zero_reserve_ceiling_is_rejected() {
    new_policy_with_reserve_ceiling(0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxReserveBps, location = blast_boosts_core::policy)]
fun a_reserve_ceiling_above_the_whole_notional_is_rejected() {
    new_policy_with_reserve_ceiling(10_001);
}

/// The ceiling rounds down against notional, so one atom over it is released.
#[test]
fun the_reserve_cap_is_the_floored_share_of_notional() {
    let vault_policy = new_policy_with_reserve_ceiling(1_000);

    assert_eq!(vault_policy.reserve_cap(0), 0);
    assert_eq!(vault_policy.reserve_cap(9), 0);
    assert_eq!(vault_policy.reserve_cap(10), 1);
    assert_eq!(vault_policy.reserve_cap(2_000_000), 200_000);
    assert_eq!(new_policy_with_reserve_ceiling(10_000).reserve_cap(std::u64::max_value!()), std::u64::max_value!());
    assert_eq!(new_policy_with_reserve_ceiling(1).reserve_cap(std::u64::max_value!()), std::u64::max_value!() / 10_000);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNavCap, location = blast_boosts_core::policy)]
fun zero_nav_cap_is_rejected() {
    policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1).assert_nav_cap_valid(0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidFeeBps, location = blast_boosts_core::policy)]
fun fee_validation_precedes_lot_validation() {
    new_policy(true, 10_000, 10_000, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFeeCapExceeded, location = blast_boosts_core::policy)]
fun fee_cap_validation_precedes_lot_validation() {
    policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_price_policy(),
        10,
        0,
        9,
        0,
        0,
        0,
        MAX_RESERVE_BPS,
    );
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMinOrderLots, location = blast_boosts_core::policy)]
fun lot_validation_precedes_reserve_validation() {
    policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_price_policy(),
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    );
}

// === Private Functions ===

fun new_policy(
    is_long: bool,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    min_order_lots: u64,
): VaultPolicy {
    policy::new_vault_policy(
        if (is_long) policy::long() else policy::short(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_price_policy(),
        mint_fee_bps,
        redeem_fee_bps,
        mint_fee_bps,
        redeem_fee_bps,
        0,
        min_order_lots,
        MAX_RESERVE_BPS,
    )
}

fun new_policy_with_fee_caps(
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    mint_fee_cap_bps: u64,
    redeem_fee_cap_bps: u64,
    admin_share_cap_bps: u64,
): VaultPolicy {
    policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_price_policy(),
        mint_fee_bps,
        redeem_fee_bps,
        mint_fee_cap_bps,
        redeem_fee_cap_bps,
        admin_share_cap_bps,
        1,
        MAX_RESERVE_BPS,
    )
}

fun new_policy_with_reserve_ceiling(max_reserve_bps: u64): VaultPolicy {
    policy::new_vault_policy(
        policy::long(),
        policy::new_rebalance_policy(0, 3, 5, 6, 0, 0, 1),
        standard_price_policy(),
        0,
        0,
        0,
        0,
        0,
        1,
        max_reserve_bps,
    )
}

fun standard_price_policy(): PricePolicy {
    policy::new_price_policy(1, 0, 0, 0)
}

// === Imports ===

use std::unit_test::assert_eq;

use blast_boosts_core::{errors, policy::{Self, PricePolicy, VaultPolicy}};
