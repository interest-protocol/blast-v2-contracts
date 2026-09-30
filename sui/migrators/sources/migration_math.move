// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Shared concentrated-liquidity seed price and auto-LP side selection for migrator venues.
module blast_fun_migrators::migration_math;

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
    if (sqrt_price <= sqrt_lower || sqrt_price >= sqrt_upper) return (true, 0);

    let (lower, price, upper) = (sqrt_lower as u256, sqrt_price as u256, sqrt_upper as u256);
    if (can_fix_a(lower, price, upper, amount_a, amount_b)) (true, amount_a)
    else if (can_fix_b(lower, price, upper, amount_a, amount_b)) (false, amount_b)
    else (true, 0)
}

// === Private Functions ===

/// Whether fixing all of `amount_a` gives positive liquidity whose B need, plus the margin,
/// `amount_b` covers: L = a * P * U / (U - P), then B = ceil(L * (P - lower)).
fun can_fix_a(lower: u256, price: u256, upper: u256, amount_a: u64, amount_b: u64): bool {
    let one = 1u256 << constants::q64_shift!();
    let liquidity = (amount_a as u256) * (price * upper / one) / (upper - price);
    if (liquidity == 0 || liquidity >= (1u256 << constants::q128_shift!())) return false;

    let needed_b = (liquidity * (price - lower)).div_ceil(one);
    needed_b + constants::auto_lp_margin!() <= (amount_b as u256)
}

/// Whether fixing all of `amount_b` gives positive liquidity whose A need, plus the margin,
/// `amount_a` covers: L = b / (P - lower), then A = ceil(L / P) - floor(L / U).
fun can_fix_b(lower: u256, price: u256, upper: u256, amount_a: u64, amount_b: u64): bool {
    let liquidity = ((amount_b as u256) << constants::q64_shift!()) / (price - lower);
    if (liquidity == 0) return false;

    let needed_a =
        (liquidity << constants::q64_shift!()).div_ceil(price)
            - (liquidity << constants::q64_shift!()) / upper;
    needed_a + constants::auto_lp_margin!() <= (amount_a as u256)
}

fun ratio_q128(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u256 {
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
