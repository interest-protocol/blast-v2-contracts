// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::math_tests;

// === Tests ===

/// Catches assigning a later depositor any blast value earned before its deposit.
#[test]
fun later_blast_deposit_uses_current_assets_per_share() {
    assert_eq!(math::blast_shares_out_down(10, 30, 20), 6);
}

/// Catches paying a redeemer more than its floor-rounded pro-rata claim.
#[test]
fun blast_redemption_rounds_gross_sui_down() {
    assert_eq!(math::blast_gross_sui_out_down(7, 31, 20), 10);
}

/// Catches a zero-fee result for any positive redemption below one fee quantum.
#[test]
fun redemption_fee_rounds_up_to_one_mist_at_every_rate() {
    assert_eq!(math::blast_redeem_fee_up(1, constants::default_redeem_fee_bps!()), 1);
    assert_eq!(math::blast_redeem_fee_up(5_000, constants::default_redeem_fee_bps!()), 1);
    assert_eq!(math::blast_redeem_fee_up(5_001, constants::default_redeem_fee_bps!()), 2);
    assert_eq!(math::blast_redeem_fee_up(10_000, constants::max_redeem_fee_bps!()), 100);
    assert_eq!(math::blast_redeem_fee_up(10_001, constants::max_redeem_fee_bps!()), 101);
    assert_eq!(math::blast_redeem_fee_up(10_000, 0), 0);
}

/// Catches an off-by-one on operands where the floor equals the exact quotient.
#[test]
fun share_math_is_exact_when_division_has_no_remainder() {
    assert_eq!(math::blast_shares_out_down(10, 40, 20), 5);
    assert_eq!(math::blast_gross_sui_out_down(10, 40, 20), 20);
    assert_eq!(math::blast_redeem_fee_up(10_000, constants::default_redeem_fee_bps!()), 2);
    assert_eq!(math::sui_at_rate_down(6, 30, 20), 9);
    assert_eq!(math::pool_tokens_at_rate_down(9, 30, 20), 6);
    assert_eq!(math::pool_tokens_for_sui_up(33, 100, 165), 20);
}

/// Catches intermediate multiplication overflow at the maximum supported coin amount.
#[test]
fun share_math_supports_maximum_u64_inputs() {
    let max = std::u64::max_value!();

    assert_eq!(math::blast_shares_out_down(max, max, max), max);
    assert_eq!(math::blast_gross_sui_out_down(max, max, max), max);
    assert_eq!(math::blast_redeem_fee_up(max, constants::max_redeem_fee_bps!()), max / 100 + 1);
    assert_eq!(math::sui_at_rate_down(max, max, max), max);
    assert_eq!(math::pool_tokens_at_rate_down(max, max, max), max);
    assert_eq!(math::pool_tokens_for_sui_up(max, max, max), max);
}

/// Catches a fee that ignores the live rate or any fee-free redemption other than a zero rate.
#[test]
fun redemption_quote_always_retains_the_live_fee() {
    let (gross, fee, net) = math::blast_redemption_quote(10, 150, 40, 2);
    assert_eq!(gross, 37);
    assert_eq!(fee, 1);
    assert_eq!(net, 36);

    let (gross, fee, net) = math::blast_redemption_quote(10, 150, 40, 100);
    assert_eq!(gross, 37);
    assert_eq!(fee, 1);
    assert_eq!(net, 36);

    let (gross, fee, net) = math::blast_redemption_quote(10, 1_500_000, 40, 100);
    assert_eq!(gross, 375_000);
    assert_eq!(fee, 3_750);
    assert_eq!(net, 371_250);

    // Presenting the whole supply is unreachable in production, and even that
    // quote pays the fee: there is no final-share exemption.
    let (gross, fee, net) = math::blast_redemption_quote(40, 123, 40, 100);
    assert_eq!(gross, 123);
    assert_eq!(fee, 2);
    assert_eq!(net, 121);

    // A zero rate is the only fee-free redemption.
    let (gross, fee, net) = math::blast_redemption_quote(10, 150, 40, 0);
    assert_eq!(gross, 37);
    assert_eq!(fee, 0);
    assert_eq!(net, 37);
}

/// Catches diverging from the native floor conversions between pool tokens and SUI.
#[test]
fun rate_conversions_mirror_native_floors_and_empty_rate() {
    assert_eq!(math::sui_at_rate_down(500_000_000, 3_000_000_001, 1_500_000_000), 1_000_000_000);
    assert_eq!(math::sui_at_rate_down(7, 0, 0), 7);
    assert_eq!(math::sui_at_rate_down(7, 10, 0), 7);
    assert_eq!(
        math::pool_tokens_at_rate_down(1_000_000_001, 3_000_000_001, 1_500_000_000),
        500_000_000,
    );
    assert_eq!(math::pool_tokens_at_rate_down(7, 0, 5), 7);
}

#[test]
fun fun_conversion_loss_bound_is_zero_at_the_native_empty_rate_and_rounds_up() {
    assert_eq!(math::fun_conversion_loss_bound_up(0, 0), 0);
    assert_eq!(math::fun_conversion_loss_bound_up(1, 1), 1);
    assert_eq!(math::fun_conversion_loss_bound_up(3, 2), 2);
    assert_eq!(
        math::fun_conversion_loss_bound_up(
            std::u64::max_value!(),
            std::u64::max_value!(),
        ),
        1,
    );
}

/// Catches requesting too few pool tokens for an exact native redemption.
#[test]
fun pool_tokens_for_sui_rounds_up_and_caps_at_held() {
    assert_eq!(math::pool_tokens_for_sui_up(10, 100, 165), 7);
    assert_eq!(math::pool_tokens_for_sui_up(165, 100, 165), 100);
    assert_eq!(math::pool_tokens_for_sui_up(1_000, 100, 165), 100);
    assert_eq!(math::pool_tokens_for_sui_up(1, 100, 0), 100);
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::math)]
fun zero_deposit_is_rejected() {
    math::blast_shares_out_down(0, 10, 10);
}

#[test]
#[expected_failure(abort_code = errors::EBlastAssetsDepleted, location = blast_sui::math)]
fun deposit_against_depleted_blast_custody_is_rejected() {
    math::blast_shares_out_down(1, 0, 1);
}

#[test]
#[expected_failure(abort_code = errors::EZeroBlastShares, location = blast_sui::math)]
fun zero_share_mint_is_rejected() {
    math::blast_shares_out_down(1, 10, 1);
}

/// Catches reintroducing a one-share-per-MIST issue against an empty supply.
#[test]
#[expected_failure(abort_code = errors::EZeroBlastShares, location = blast_sui::math)]
fun zero_supply_never_mints_shares() {
    math::blast_shares_out_down(7, 5, 0);
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::math)]
fun zero_share_redemption_is_rejected() {
    math::blast_gross_sui_out_down(0, 10, 10);
}

#[test]
#[expected_failure(abort_code = errors::EBlastAssetsDepleted, location = blast_sui::math)]
fun redemption_against_depleted_blast_custody_is_rejected() {
    math::blast_gross_sui_out_down(1, 0, 10);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_sui::math)]
fun redemption_above_supply_is_rejected() {
    math::blast_gross_sui_out_down(11, 10, 10);
}

#[test]
#[expected_failure(abort_code = errors::EZeroSuiRedemption, location = blast_sui::math)]
fun zero_gross_redemption_is_rejected() {
    math::blast_gross_sui_out_down(1, 1, 10);
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::math)]
fun zero_gross_fee_is_rejected() {
    math::blast_redeem_fee_up(0, 2);
}

// === Imports ===

use blast_sui::{constants, errors, math};

use std::unit_test::assert_eq;
