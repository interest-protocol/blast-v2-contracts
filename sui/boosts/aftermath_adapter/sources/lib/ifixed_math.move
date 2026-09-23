// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Scaling between Aftermath's 18-decimal IFixed carrier and the adapter's
/// atomic units. Every conversion reports whether the value fit; nothing here
/// aborts, the caller decides what an unrepresentable value means.
module blast_boosts_aftermath::ifixed_math;

// === Package Functions ===

/// A venue rebate reads as a zero rate; no bound ever credits execution.
public(package) fun nonnegative_rate(rate: u256): u256 {
    if (rate.is_neg()) { 0 } else { rate.abs() }
}

/// The IFixed value in `decimals`-decimal atoms, rounded down, and whether it fit in a u64.
public(package) fun fixed_to_u64_down(value: u256, decimals: u64): (u64, bool) {
    to_u64(value / atom_scale(decimals))
}

/// The IFixed value in `decimals`-decimal atoms, rounded up, and whether it fit in a u64.
public(package) fun fixed_to_u64_up(value: u256, decimals: u64): (u64, bool) {
    to_u64(value.div_ceil(atom_scale(decimals)))
}

/// The value as a u64 and whether it fit; an unrepresentable value reads as zero.
public(package) fun to_u64(value: u256): (u64, bool) {
    if (value > std::u64::max_value!() as u256) { (0, false) } else { (value as u64, true) }
}

/// Converts a USD IFixed amount into collateral IFixed at `collateral_price`.
///
/// `usd / price` in IFixed is `usd × 10^18 / price`; the product is split into
/// whole and fractional parts so no intermediate exceeds u256.
public(package) fun usd_fixed_to_collateral_fixed(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    if (collateral_price == 0) return (0, false);

    let one = constants::ifixed_one!();
    let whole_scaled = (usd / collateral_price).checked_mul(one).destroy_or!(return (0, false));
    let fraction_scaled = (usd % collateral_price).checked_mul(one).destroy_or!(return (0, false));
    let quotient = whole_scaled.checked_add(fraction_scaled / collateral_price).destroy_or!(return (0, false));
    if (!round_up || fraction_scaled % collateral_price == 0) return (quotient, true);

    if (quotient == std::u256::max_value!()) { (0, false) } else { (quotient + 1, true) }
}

// === Private Functions ===

/// Raw IFixed units in one `decimals`-decimal atom: `10^(18 - decimals)`.
fun atom_scale(decimals: u64): u256 {
    10u256.pow((18 - decimals) as u8)
}

// === Test-Only Functions ===

#[test_only]
public fun normalize_raw_fixed_for_testing(value: u256, decimals: u64, round_up: bool): u64 {
    let (normalized, representable) = if (round_up) {
        fixed_to_u64_up(value, decimals)
    } else {
        fixed_to_u64_down(value, decimals)
    };
    assert!(representable, blast_boosts_aftermath::errors::normalization_overflow!());
    normalized
}

#[test_only]
public fun usd_fixed_to_collateral_for_testing(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    usd_fixed_to_collateral_fixed(usd, collateral_price, round_up)
}

// === Imports ===

use blast_boosts_aftermath::constants;

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign and magnitude read as methods.
use fun ifixed::abs as u256.abs;
use fun ifixed::is_neg as u256.is_neg;
