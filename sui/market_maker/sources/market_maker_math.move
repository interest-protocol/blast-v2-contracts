// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Wide integer arithmetic shared by presale and curve fee ledgers.
module blast_market_maker::market_maker_math;

// === Package Functions ===

/// Applies a validated basis-points rate, rounding down.
public(package) fun apply_down(amount: u64, bps: u64): u64 {
    assert!(bps <= 10_000, EInvalidRate);

    (((amount as u128) * (bps as u128) / 10_000) as u64)
}

/// Applies a validated basis-points rate, rounding up, without overflowing u64 multiplication.
public(package) fun apply_up(amount: u64, bps: u64): u64 {
    assert!(bps <= 10_000, EInvalidRate);

    ((((amount as u128) * (bps as u128) + 9_999) / 10_000) as u64)
}

/// Adds a funded receipt to a fixed-weight accumulator while retaining global dust.
public(package) fun accrued_index_down(
    accumulator: u256,
    remainder: u256,
    funded: u64,
    total_weight: u64,
): (u256, u256) {
    assert!(total_weight > 0, EEmptyDistribution);
    let numerator = (funded as u256) * SCALE + remainder;

    (accumulator + numerator / (total_weight as u256), numerator % (total_weight as u256))
}

/// Settles one fixed weight, preserving its fractional entitlement across repeated claims.
public(package) fun claim_amount_down(accumulator: u256, paid_index: u256, remainder: u256, weight: u64): (u64, u256) {
    let numerator = (weight as u256) * (accumulator - paid_index) + remainder;

    (((numerator / SCALE) as u64), numerator % SCALE)
}

// === Constants ===

const SCALE: u256 = 18_446_744_073_709_551_616;

// === Errors ===

#[error(code = 0)]
const EInvalidRate: vector<u8> = b"A basis-points rate must be at most 10,000.";
#[error(code = 1)]
const EEmptyDistribution: vector<u8> =
    b"An empty contributor set cannot create backer liabilities.";
