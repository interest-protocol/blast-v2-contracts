// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Exact atomic-unit seed prices from docs/vectors/quote-decimals.json.
module blast_presale::migration_math_tests;

// === Tests ===

#[test]
fun sui_like_9dec_quote_matches_both_pair_orientations() {
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            2_970_000_000_000,
            true,
        ),
        71_085_815_383_773_548u128,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            2_970_000_000_000,
            false,
        ),
        4_786_923_594_866_905_679_395u128,
    );
}

#[test]
fun usdc_like_6dec_quote_matches_both_pair_orientations() {
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            2_970_000_000,
            true,
        ),
        2_247_930_859_429_608u128,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            2_970_000_000,
            false,
        ),
        151_375_815_449_805_255_005_138u128,
    );
}

#[test]
fun lst_like_8dec_quote_matches_both_pair_orientations() {
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            297_000_000_000,
            true,
        ),
        22_479_308_594_296_080u128,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            297_000_000_000,
            false,
        ),
        15_137_581_544_980_525_500_513u128,
    );
}

#[test]
fun meme_6dec_quote_9dec_matches_both_pair_orientations() {
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000,
            2_970_000_000_000,
            true,
        ),
        2_247_930_859_429_608_031u128,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000,
            2_970_000_000_000,
            false,
        ),
        151_375_815_449_805_254_626u128,
    );
}

#[test]
fun equal_atomic_amounts_are_one_in_both_pair_orientations() {
    let one_x64 = 1u128 << 64;

    assert_eq!(migration_math::sqrt_price_x64(1, 1, true), one_x64);
    assert_eq!(migration_math::sqrt_price_x64(1, 1, false), one_x64);
    assert_eq!(
        migration_math::sqrt_price_x64(std::u64::max_value!(), std::u64::max_value!(), true),
        one_x64,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(std::u64::max_value!(), std::u64::max_value!(), false),
        one_x64,
    );
}

#[test]
fun integer_square_root_rounds_down_in_both_pair_orientations() {
    vector[true, false].do!(|meme_is_a| {
        let sqrt_price = migration_math::sqrt_price_x64(3, 2, meme_is_a);
        let ratio_q128 = if (meme_is_a) (2u256 << 128) / 3 else (3u256 << 128) / 2;
        let square = (sqrt_price as u256) * (sqrt_price as u256);
        let next_square = ((sqrt_price + 1) as u256) * ((sqrt_price + 1) as u256);

        assert!(square <= ratio_q128);
        assert!(next_square > ratio_q128);
    });
}

// === Imports ===

use blast_presale::migration_math;

use std::unit_test::assert_eq;
