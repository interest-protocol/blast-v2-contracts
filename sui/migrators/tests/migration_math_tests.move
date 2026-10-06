// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Seed-price derivation and auto-LP side selection, checked against an independent Q64.64 oracle
/// of the Uniswap v3 liquidity formulas.
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
            200_000_000_000_000_001,
            2_970_000_000_000,
            true,
        ),
        71_085_815_383_773_548,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            2_970_000_000_000,
            false,
        ),
        4_786_923_594_866_905_679_395u128,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            2_970_000_000,
            true,
        ),
        2_247_930_859_429_608,
    );
    assert_eq!(
        migration_math::sqrt_price_x64(
            200_000_000_000_000_001,
            297_000_000_000,
            true,
        ),
        22_479_308_594_296_080,
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

// Auto-LP Side Selection

#[test]
fun balanced_amounts_with_room_for_the_margin_fix_coin_a() {
    // Price 1 in [0.25, 4]: each unit of A pairs with exactly one unit of B.
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_000, 1_000_010, true, 1_000_000);
    assert_selects(
        MIN_SQRT_PRICE,
        ONE,
        MAX_SQRT_PRICE,
        1_000_000_000,
        2_000_000_000,
        true,
        1_000_000_000,
    );
}

#[test]
fun scarce_coin_b_is_fixed_instead() {
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_010, 1_000_000, false, 1_000_000);
    assert_selects(
        MIN_SQRT_PRICE,
        ONE,
        MAX_SQRT_PRICE,
        2_000_000_000,
        1_000_000_000,
        false,
        1_000_000_000,
    );
}

#[test]
fun amounts_without_room_for_the_margin_on_either_side_add_nothing() {
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 1, 1, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 2, 2, true, 0);
    assert_selects(MIN_SQRT_PRICE, ONE, MAX_SQRT_PRICE, 1_000_000_000, 1_000_000_000, true, 0);
}

#[test]
fun an_empty_side_adds_nothing() {
    assert_selects(ONE / 2, ONE, ONE * 2, 0, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_000, 0, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 0, 0, true, 0);
}

#[test]
fun a_price_on_or_outside_the_range_adds_nothing() {
    assert_selects(ONE / 2, ONE / 2, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE * 2, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE / 4, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE * 4, ONE * 2, 1_000_000, 1_000_000, true, 0);
}

#[test]
fun extreme_prices_and_u64_max_amounts_never_abort_and_the_other_side_always_fits() {
    let prices = vector[
        MIN_SQRT_PRICE + 1,
        MIN_SQRT_PRICE * 2,
        ONE,
        MAX_SQRT_PRICE / 2,
        MAX_SQRT_PRICE - 1,
    ];
    let amounts = vector[1, 3, 12_345, 1_000_000_000_000, U64_MAX - 2, U64_MAX];
    prices.do!(|price| {
        amounts.do_ref!(|amount_a| amounts.do_ref!(|amount_b| {
            assert_fits(MIN_SQRT_PRICE, price, MAX_SQRT_PRICE, *amount_a, *amount_b);
        }));
    });
    // Just below the upper bound nothing but coin B can be fixed, and all of it is used.
    assert_selects(
        MIN_SQRT_PRICE,
        MAX_SQRT_PRICE - 1,
        MAX_SQRT_PRICE,
        U64_MAX,
        U64_MAX,
        false,
        U64_MAX,
    );
    // Just above the lower bound coin A buys almost no B, so all of A is fixed.
    assert_selects(
        MIN_SQRT_PRICE,
        MIN_SQRT_PRICE + 1,
        MAX_SQRT_PRICE,
        U64_MAX,
        U64_MAX,
        true,
        U64_MAX,
    );
}

#[test]
fun every_selection_on_a_grid_fits_and_prefers_coin_a_whenever_it_fits() {
    let prices = vector[ONE / 2 + 1, ONE * 3 / 4, ONE, ONE * 3 / 2, ONE * 2 - 1];
    let amounts = vector[1, 2, 3, 5, 100, 1_000, 1_000_000, 1_000_000_000_000, U64_MAX];
    prices.do!(|price| {
        amounts.do_ref!(|amount_a| amounts.do_ref!(|amount_b| {
            assert_fits(ONE / 2, price, ONE * 2, *amount_a, *amount_b);
        }));
    });
}

// === Test Helpers ===

/// Asserts the exact selection, then that it fits.
fun assert_selects(
    lower: u128,
    price: u128,
    upper: u128,
    amount_a: u64,
    amount_b: u64,
    expected_fix_a: bool,
    expected_amount: u64,
) {
    let (selected_fix_a, selected_amount) = migration_math::auto_lp_fixed_side(
        lower,
        price,
        upper,
        amount_a,
        amount_b,
    );

    assert_eq!(selected_fix_a, expected_fix_a);
    assert_eq!(selected_amount, expected_amount);
    assert_fits(lower, price, upper, amount_a, amount_b);
}

/// Recomputes the chosen side's liquidity and the other side's rounded-up requirement with the
/// Uniswap v3 formulas and asserts the requirement plus the margin fits the other balance. Coin A
/// must be chosen whenever it fits, and nothing when the price is outside or a side is empty.
fun assert_fits(lower: u128, price: u128, upper: u128, amount_a: u64, amount_b: u64) {
    let (fix_a, fixed_amount) = migration_math::auto_lp_fixed_side(
        lower,
        price,
        upper,
        amount_a,
        amount_b,
    );
    let (lower, price, upper) = (lower as u256, price as u256, upper as u256);
    let (available_a, available_b) = (amount_a as u256, amount_b as u256);
    let is_in_range = lower < price && price < upper && available_a > 0 && available_b > 0;
    let liquidity_a = if (is_in_range) liquidity_for_a(price, upper, available_a) else 0;
    let can_fix_a = liquidity_a > 0 && liquidity_a < (1 << 128)
        && amount_b_up(lower, price, liquidity_a) + MARGIN <= available_b;

    if (can_fix_a) {
        assert!(fix_a);
        assert_eq!(fixed_amount, amount_a);
    } else if (fixed_amount == 0) {
        assert!(fix_a);
    } else {
        assert!(is_in_range && !fix_a);
        assert_eq!(fixed_amount, amount_b);
        let liquidity_b = liquidity_for_b(lower, price, available_b);
        assert!(liquidity_b > 0);
        assert!(amount_a_up(price, upper, liquidity_b) + MARGIN <= available_a);
    };
}

/// `LiquidityAmounts.getLiquidityForAmount0` over [price, upper].
fun liquidity_for_a(price: u256, upper: u256, amount: u256): u256 {
    mul_div(amount, mul_div(price, upper, 1 << 64), upper - price)
}

/// `LiquidityAmounts.getLiquidityForAmount1` over [lower, price].
fun liquidity_for_b(lower: u256, price: u256, amount: u256): u256 {
    mul_div(amount, 1 << 64, price - lower)
}

/// `SqrtPriceMath.getAmount0Delta` over [price, upper], rounded up.
fun amount_a_up(price: u256, upper: u256, liquidity: u256): u256 {
    mul_div_up(liquidity << 64, upper - price, upper).div_ceil(price)
}

/// `SqrtPriceMath.getAmount1Delta` over [lower, price], rounded up.
fun amount_b_up(lower: u256, price: u256, liquidity: u256): u256 {
    mul_div_up(liquidity, price - lower, 1 << 64)
}

fun mul_div(x: u256, y: u256, divisor: u256): u256 {
    let (quotient, _) = mul_div_remainder(x, y, divisor);

    quotient
}

fun mul_div_up(x: u256, y: u256, divisor: u256): u256 {
    let (quotient, remainder) = mul_div_remainder(x, y, divisor);

    if (remainder > 0) quotient + 1 else quotient
}

/// Exact floor(x * y / divisor) and its remainder. A product wider than 256 bits is never formed:
/// the multiple of the divisor in `x` is scaled directly, and the rest is doubled and added over
/// the bits of `y` modulo the divisor. The divisor must be below 2^255.
fun mul_div_remainder(x: u256, y: u256, divisor: u256): (u256, u256) {
    if (x == 0 || y <= std::u256::max_value!() / x) return (x * y / divisor, x * y % divisor);
    let rest = x % divisor;
    let mut quotient = 0;
    let mut remainder = 0;
    let mut bit = 256u16;
    while (bit > 0) {
        bit = bit - 1;
        quotient = quotient * 2;
        remainder = remainder * 2;
        if (remainder >= divisor) {
            remainder = remainder - divisor;
            quotient = quotient + 1;
        };
        if ((y >> (bit as u8)) & 1 == 1) {
            remainder = remainder + rest;
            if (remainder >= divisor) {
                remainder = remainder - divisor;
                quotient = quotient + 1;
            };
        };
    };

    (x / divisor * y + quotient, remainder)
}

// === Constants ===

/// 1.0 in Q64.64.
const ONE: u128 = 1 << 64;

/// Cetus's and Bluefin's full-range sqrt-price bounds.
const MIN_SQRT_PRICE: u128 = 4_295_048_016;

const MAX_SQRT_PRICE: u128 = 79_226_673_515_401_279_992_447_579_055;

/// Atoms of the other asset the selection must leave unused beyond the exact requirement.
const MARGIN: u256 = 2;

const U64_MAX: u64 = 18_446_744_073_709_551_615;

// === Imports ===

use blast_fun_migrators::migration_math;

use std::unit_test::assert_eq;
