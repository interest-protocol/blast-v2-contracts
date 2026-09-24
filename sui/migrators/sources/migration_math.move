// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Shared concentrated-liquidity seed price and auto-LP side selection for migrator venues.
module blast_fun_migrators::migration_math;

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

/// Chooses the side a fixed-amount liquidity add fixes so the venue never needs more of the other
/// asset than is available, from the pool's and the position's bound sqrt prices (Q64.64).
///
/// Returns `(fix_a, amount)`; a zero amount means nothing can be added now (an empty side, a price
/// outside the range, or too little for positive liquidity), and the balances wait for later.
public(package) fun auto_lp_fixed_side(
    sqrt_lower: u128,
    sqrt_price: u128,
    sqrt_upper: u128,
    amount_a: u64,
    amount_b: u64,
): (bool, u64) {
    if (amount_a == 0 || amount_b == 0) return (true, 0);
    if (sqrt_price <= sqrt_lower || sqrt_price >= sqrt_upper) return (true, 0);
    let lower = sqrt_lower as u256;
    let price = sqrt_price as u256;
    let upper = sqrt_upper as u256;
    let one = 1u256 << constants::q64_shift!();

    // Fixing A: L = a * P * U / (U - P), then B = ceil(L * (P - lower)).
    let liquidity = (amount_a as u256) * (price * upper / one) / (upper - price);
    if (liquidity > 0 && liquidity < (1u256 << constants::q128_shift!())) {
        let needed_b = (liquidity * (price - lower)).div_ceil(one);
        if (needed_b + constants::auto_lp_margin!() <= (amount_b as u256)) return (true, amount_a);
    };

    // Fixing B: L = b / (P - lower), then A = ceil(L / P) - floor(L / U).
    let liquidity = ((amount_b as u256) << constants::q64_shift!()) / (price - lower);
    if (liquidity > 0) {
        let needed_a =
            (liquidity << constants::q64_shift!()).div_ceil(price)
                - (liquidity << constants::q64_shift!()) / upper;
        if (needed_a + constants::auto_lp_margin!() <= (amount_a as u256)) return (false, amount_b);
    };

    (true, 0)
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

    ((numerator as u256) << constants::q128_shift!()) / (denominator as u256)
}

/// Uses a fixed 96-step upper bound because a positive u64/u64 Q128 ratio is below 2^192.
fun integer_sqrt(value: u256): u128 {
    let mut low = 0u256;
    let mut high = 1u256 << constants::sqrt_upper_bound_shift!();

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

// === Imports ===

use blast_fun_migrators::constants;
