// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Shared concentrated-liquidity seed price for migrator venues.
module blast_fun_migrators::migration_math;

// === Constants ===

const Q128_SHIFT: u8 = 128;
const SQRT_UPPER_BOUND_SHIFT: u8 = 96;

// === Errors ===

#[error(code = 0)]
const EInvalidMigrationSeedBalance: vector<u8> = b"Migration seed balances must both be greater than zero.";

// === Package Functions ===

/// Derives floor(sqrt(coin_b / coin_a) * 2^64) from migration atomic units.
///
/// When Meme is coin A, the ratio is Quote/Meme. When Meme is coin B, it is
/// Meme/Quote. Display decimals never enter this calculation.
public(package) fun sqrt_price_x64(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u128 {
    integer_sqrt(ratio_q128(meme_amount, quote_amount, meme_is_coin_a))
}

// === Private Functions ===

fun ratio_q128(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u256 {
    assert!(
        meme_amount > 0 && quote_amount > 0,
        EInvalidMigrationSeedBalance,
    );

    let (numerator, denominator) = if (meme_is_coin_a) {
        (quote_amount, meme_amount)
    } else {
        (meme_amount, quote_amount)
    };

    ((numerator as u256) << Q128_SHIFT) / (denominator as u256)
}

/// Uses a fixed 96-step upper bound because a positive u64/u64 Q128 ratio is below 2^192.
fun integer_sqrt(value: u256): u128 {
    let mut low = 0u256;
    let mut high = 1u256 << SQRT_UPPER_BOUND_SHIFT;

    while (low + 1 < high) {
        let middle = (low + high) / 2;

        if (middle * middle <= value) {
            low = middle;
        } else {
            high = middle;
        };
    };

    low as u128
}
