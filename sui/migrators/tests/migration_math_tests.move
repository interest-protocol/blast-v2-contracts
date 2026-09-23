// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::migration_math_tests;

// === Tests ===

#[test]
fun one_to_one_atomic_price_is_one_in_q64_64_for_both_orders() {
    let one_x64 = 18_446_744_073_709_551_616u128;

    assert_eq!(migration_math::sqrt_price_x64(1, 1, true), one_x64);
    assert_eq!(migration_math::sqrt_price_x64(1, 1, false), one_x64);
    assert_eq!(
        migration_math::sqrt_price_x64(
            std::u64::max_value!(),
            std::u64::max_value!(),
            true,
        ),
        one_x64,
    );
}

#[test]
fun committed_quote_decimal_vectors_match_both_pair_orientations() {
    assert_eq!(
        migration_math::sqrt_price_x64(
            196_608_503_317_768_494,
            3_038_310_000_000,
            true,
        ),
        72_516_129_429_223_843,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            196_608_503_317_768_494,
            3_038_310_000_000,
            false,
        ),
        4_692_505_923_844_928_806_099u128,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            196_608_503_317_768_494,
            3_038_310_000,
            true,
        ),
        2_293_161_360_959_133,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            196_608_503_317_768_494,
            303_831_000_000,
            true,
        ),
        22_931_613_609_591_333,
    );
}

#[test]
fun integer_square_root_rounds_down() {
    let sqrt_price = migration_math::sqrt_price_x64(3, 2, true);
    let ratio_q128 = (2u256 << 128) / 3u256;
    let square = (sqrt_price as u256) * (sqrt_price as u256);
    let next_square = ((sqrt_price + 1) as u256) * ((sqrt_price + 1) as u256);

    assert!(square <= ratio_q128);
    assert!(next_square > ratio_q128);
}

#[test]
#[expected_failure(
    abort_code = migration_math::EInvalidMigrationSeedBalance,
    location = blast_fun_migrators::migration_math,
)]
fun zero_meme_seed_is_rejected() {
    migration_math::sqrt_price_x64(0, 1, true);
}

#[test]
#[expected_failure(
    abort_code = migration_math::EInvalidMigrationSeedBalance,
    location = blast_fun_migrators::migration_math,
)]
fun zero_quote_seed_is_rejected() {
    migration_math::sqrt_price_x64(1, 0, true);
}

// === Imports ===

use blast_fun_migrators::migration_math;

use std::unit_test::assert_eq;
