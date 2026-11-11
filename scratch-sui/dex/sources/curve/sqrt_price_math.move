// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Concentrated liquidity deltas and exact-input price rounding in Q96.
module blast_fun_dex::sqrt_price_math;

// === Constants ===

const Q96: u256 = 1 << 96;

// === Package Functions ===

/// Asset delta is L * Q96 * (upper - lower) / upper / lower. The same
/// rounding direction can be applied at both divisions without changing it.
public(package) fun asset_delta(lower: u256, upper: u256, liquidity: u128, round_up: bool): u256 {
    let scaled = (liquidity as u256) << 96;
    let first = mul_div(scaled, upper - lower, upper, round_up);
    divide(first, lower, round_up)
}

/// Quote delta is L * (upper - lower) / Q96.
public(package) fun quote_delta(lower: u256, upper: u256, liquidity: u128, round_up: bool): u256 {
    mul_div(liquidity as u256, upper - lower, Q96, round_up)
}

public(package) fun input_delta(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    if (up) quote_delta(start, end, liquidity, true)
    else asset_delta(end, start, liquidity, true)
}

/// Round output down in Q64 atoms and carry it until the swap settles.
/// The asset leg's first division loses less than 1/start atom.
public(package) fun output_delta_x64(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    if (!up) return mul_div(liquidity as u256, start - end, 1 << 32, false);
    let scaled = (liquidity as u256) << 96;
    let first = mul_div(scaled, end - start, end, false);
    mul_div(first, 1 << 64, start, false)
}

/// Farthest representable endpoint affordable with the integer net budget.
/// Round toward the starting price in both directions.
public(package) fun next_price(start: u256, liquidity: u128, net: u64, up: bool): u256 {
    if (up) return start + ((net as u256) << 96) / (liquidity as u256);
    let scaled = (liquidity as u256) << 96;
    let denominator = scaled + (net as u256) * start;
    mul_div(scaled, start, denominator, true)
}

// === Private Functions ===

fun divide(numerator: u256, denominator: u256, round_up: bool): u256 {
    if (round_up) numerator.div_ceil(denominator) else numerator / denominator
}

/// Here a < 2^224, b < 2^160, d < 2^225 and the quotient fits. The
/// remainder stays below d. Two 80-bit limbs suffice when a and d both fit
/// in 175 bits. Otherwise, at most six 30-bit limbs keep each dividend below
/// 2^256.
fun mul_div(a: u256, b: u256, d: u256, round_up: bool): u256 {
    let product = a.checked_mul(b);
    if (product.is_some()) return divide(product.destroy_some(), d, round_up);

    assert!(a < (1u256 << 224) && b < (1u256 << 160) && d < (1u256 << 225));
    if ((a | d) < (1u256 << 175)) {
        let high_product = a * (b >> 80);
        let low_dividend = ((high_product % d) << 80) + a * (b & ((1u256 << 80) - 1));
        return ((high_product / d) << 80) + divide(low_dividend, d, round_up)
    };

    let mut shift = if (b < (1u256 << 120)) 90u8 else 150u8;
    let mut quotient = 0;
    let mut remainder = 0;
    loop {
        let digit = (b >> shift) & 0x3fff_ffff;
        let dividend = (remainder << 30) + a * digit;
        quotient = (quotient << 30) + dividend / d;
        remainder = dividend % d;
        if (shift == 0) break;
        shift = shift - 30;
    };
    quotient + if (round_up && remainder > 0) 1 else 0
}
