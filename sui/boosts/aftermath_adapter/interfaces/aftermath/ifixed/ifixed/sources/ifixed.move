// Copyright (c) Aftermath Technologies, Inc.
// SPDX-License-Identifier: Apache-2.0

#[allow(unused_use, unused_const, unused_variable, unused_mut_parameter, unused_let_mut, unused_field, unused_function, unused_type_parameter)]
module ifixed::ifixed;

const ONE: u256  = 1__000_000_000_000_000_000;const NEG_ONE: u256 = 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff;
const GREATEST_BIT: u256 = (1 << 255);
const NOT_GREATEST_BIT: u256 = (1 << 255) - 1;
const OVERFLOW_ERROR: u64 = 12001;
const SCALING_FACTORS: vector<u64> = vector<u64>[
    1__000_000_000_000_000_000,
    0__100_000_000_000_000_000,
    0__010_000_000_000_000_000,
    0__001_000_000_000_000_000,
    0__000_100_000_000_000_000,
    0__000_010_000_000_000_000,
    0__000_001_000_000_000_000,
    0__000_000_100_000_000_000,
    0__000_000_010_000_000_000,
    0__000_000_001_000_000_000,
    0__000_000_000_100_000_000,
    0__000_000_000_010_000_000,
    0__000_000_000_001_000_000,
    0__000_000_000_000_100_000,
    0__000_000_000_000_010_000,
    0__000_000_000_000_001_000,
    0__000_000_000_000_000_100,
    0__000_000_000_000_000_010,
    0__000_000_000_000_000_001,
];

#[allow(implicit_const_copy)]
public fun decimal_scalar_from_decimals(decimals: u64): u64 {
    abort 404
}

// Blast: `one`, `add`, `sub`, `abs` and `is_neg` carry the bodies of the
// deployed mainnet module (package 0x4b4703a7…8760, module sha256
// ab7e23db…140e, disassembled 2026-09-19/20), transcribed instruction for
// instruction, so adapter tests execute the production decode paths. They
// never reach the chain: the adapter links to the published package. Every
// other function keeps the interface's `abort 404` body.
public fun one(): u256 {
    ONE
}

public fun neg_one(): u256 {
    abort 404
}

public fun min_value(): u256 {
    abort 404
}

public fun max_value(): u256 {
    abort 404
}

public fun overflow_error(): u64 {
    abort 404
}

public fun is_cast_safe(x: u256): bool {
    abort 404
}

// =========================================================================
//  u64 Conversion Functions
// =========================================================================

public fun from_u64(a: u64): u256 {
    abort 404
}

public fun to_u64(x: u256): u64 {
    abort 404
}

public fun from_u64fraction(numerator: u64, denominator: u64): u256 {
    abort 404
}

// =========================================================================
//  u128 Conversion Functions
// =========================================================================

public fun from_u128(a: u128): u256 {
    abort 404
}

public fun to_u128(x: u256): u128 {
    abort 404
}

public fun from_u128fraction(numerator: u128, denominator: u128): u256 {
    abort 404
}

// =========================================================================
//  U256 Conversion Functions
// =========================================================================

public fun from_u256(x: u256): u256 {
    abort 404
}

public fun to_u256(x: u256): u256 {
    abort 404
}

public fun from_u256fraction(numerator: u256, denominator: u256): u256 {
    abort 404
}

// =========================================================================
//  Balance Conversion Functions
// =========================================================================

public fun from_balance(balance: u64, scaling_factor: u256): u256 {
    abort 404
}

public fun to_balance(x: u256, scaling_factor: u256): u64 {
    abort 404
}

public fun from_u128balance(balance: u128, scaling_factor: u256): u256 {
    abort 404
}

public fun to_u128balance(x: u256, scaling_factor: u256): u128 {
    abort 404
}

public fun from_u256balance(balance: u256, scaling_factor: u256): u256 {
    abort 404
}

public fun to_u256balance(x: u256, scaling_factor: u256): u256 {
    abort 404
}

// =========================================================================
//  Math Functions
// =========================================================================

public fun add(x: u256, y: u256): u256 {
    // Bytecode: low-255-bit sum; same signs keep the sum and abort when its
    // sign differs from `x`; different signs flip the sum's sign bit.
    let sum = (x & NOT_GREATEST_BIT) + (y & NOT_GREATEST_BIT);
    if ((x ^ y) < GREATEST_BIT) {
        assert!((x ^ sum) < GREATEST_BIT, OVERFLOW_ERROR);
        sum
    } else {
        sum ^ GREATEST_BIT
    }
}

public fun sub(x: u256, y: u256): u256 {
    // Bytecode: raw difference, negated in two's complement when `y > x`;
    // same signs never overflow, different signs must keep `x`'s sign.
    let difference = if (x >= y) { x - y } else { ((y - x) ^ NEG_ONE) + 1 };
    let in_range = if ((x ^ y) < GREATEST_BIT) { true } else { (x ^ difference) < GREATEST_BIT };
    assert!(in_range, OVERFLOW_ERROR);
    difference
}

public fun mul(x: u256, y: u256): u256 {
    abort 404
}

public fun mul_toward_zero(x: u256, y: u256): u256 {
    abort 404
}

public fun mul_up(x: u256, y: u256): u256 {
    abort 404
}

public fun mul_away_from_zero(x: u256, y: u256): u256 {
    abort 404
}

public fun div(x: u256, y: u256): u256 {
    abort 404
}

public fun div_toward_zero(x: u256, y: u256): u256 {
    abort 404
}

public fun div_up(x: u256, y: u256): u256 {
    abort 404
}

public fun div_away_from_zero(x: u256, y: u256): u256 {
    abort 404
}

public fun neg(x: u256): u256 {
    abort 404
}

public fun abs(x: u256): u256 {
    // Bytecode: a negative's magnitude is `((x xor (2^255 - 1)) + 1) xor 2^255`;
    // the addition overflows only for `-2^255`, whose magnitude has no encoding.
    if (x >= GREATEST_BIT) { ((x ^ NOT_GREATEST_BIT) + 1) ^ GREATEST_BIT } else { x }
}

// =========================================================================
//  Compare Functions
// =========================================================================

public fun max(x: u256, y: u256): u256 {
    abort 404
}

public fun min(x: u256, y: u256): u256 {
    abort 404
}

public fun is_neg(x: u256): bool {
    x >= GREATEST_BIT
}

public fun same_sign(x: u256, y: u256): bool {
    abort 404
}

public fun diff_sign(x: u256, y: u256): bool {
    abort 404
}

public fun greater_than(x: u256, y: u256): bool {
    abort 404
}

public fun greater_than_eq(x: u256, y: u256): bool {
    abort 404
}

public fun less_than(x: u256, y: u256): bool {
    abort 404
}

public fun less_than_eq(x: u256, y: u256): bool {
    abort 404
}

/**
 * @dev Compares two fixed point numbers for relative error
 */
public fun close_enough(a: u256, b: u256, tolerance: u256): bool {
    abort 404
}

public fun mul_i256(x: u256, y: u256): u256 {
    abort 404
}
