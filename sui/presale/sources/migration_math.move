// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Concentrated-liquidity seed price derived from the configured migration assets.
module blast_presale::migration_math;

// === Package Functions ===

/// Derives floor(sqrt(coin_b / coin_a) * 2^64) from migration atomic units.
public(package) fun sqrt_price_x64(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u128 {
    let (numerator, denominator) = if (meme_is_coin_a) {
        (quote_amount, meme_amount)
    } else {
        (meme_amount, quote_amount)
    };
    let ratio = ((numerator as u256) << 128) / (denominator as u256);
    let mut low = 0u256;
    let mut high = 1u256 << 96;

    while (low + 1 < high) {
        let middle = (low + high) / 2;
        if (middle * middle <= ratio) low = middle else high = middle;
    };

    low as u128
}
