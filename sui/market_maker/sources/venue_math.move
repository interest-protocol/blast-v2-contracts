// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Shared concentrated-liquidity seed price and auto-LP side selection for migrator venues.
module blast_market_maker::venue_math;

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

/// The Q128 price ratio of coin B to coin A: Quote/Meme when Meme is coin A, else Meme/Quote.
fun ratio_q128(meme_amount: u64, quote_amount: u64, meme_is_coin_a: bool): u256 {
    let (numerator, denominator) = if (meme_is_coin_a) {
        (quote_amount, meme_amount)
    } else {
        (meme_amount, quote_amount)
    };

    ((numerator as u256) << 128) / (denominator as u256)
}

/// Uses a fixed 96-step upper bound because a positive u64/u64 Q128 ratio is below 2^192.
fun integer_sqrt(value: u256): u128 {
    let mut low = 0u256;
    let mut high = 1u256 << 96;

    while (low + 1 < high) {
        let middle = (low + high) / 2;
        if (middle * middle <= value) low = middle else high = middle;
    };

    low as u128
}
