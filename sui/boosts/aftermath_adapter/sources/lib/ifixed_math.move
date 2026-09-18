/// Scaling between Aftermath's 18-decimal IFixed carrier and the adapter's
/// atomic units. Every conversion reports whether the value fit; nothing here
/// aborts, the caller decides what an unrepresentable value means.
module blast_boosts_aftermath::ifixed_math;

// === Package Functions ===

/// A venue rebate reads as a zero rate; no bound ever credits execution.
public(package) fun nonnegative_rate(rate: u256): u256 {
    if (rate.is_neg()) { 0 } else { rate.abs() }
}

/// `10^exponent` as an IFixed-width integer.
public(package) fun pow10(exponent: u64): u256 {
    let mut result = 1;
    exponent.do!(|_| result = result * 10);

    result
}

/// The IFixed value in `decimals`-decimal atoms, rounded down, and whether it fit in a u64.
public(package) fun fixed_to_u64_down(value: u256, decimals: u64): (u64, bool) {
    let normalized = value / pow10(18 - decimals);
    if (normalized > std::u64::max_value!() as u256) { (0, false) } else { (normalized as u64, true) }
}

/// The IFixed value in `decimals`-decimal atoms, rounded up, and whether it fit in a u64.
public(package) fun fixed_to_u64_up(value: u256, decimals: u64): (u64, bool) {
    let scale = pow10(18 - decimals);
    let down = value / scale;
    let exact = value % scale == 0;
    let up = if (exact) { down } else { down + 1 };

    if (up > std::u64::max_value!() as u256) { (0, false) } else { (up as u64, true) }
}

/// Converts a USD IFixed amount into collateral IFixed at `collateral_price`.
public(package) fun usd_fixed_to_collateral_fixed(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    if (collateral_price == 0) return (0, false);

    let one = constants::ifixed_one!();
    let whole = usd / collateral_price;
    let remainder = usd % collateral_price;
    if (whole > std::u256::max_value!() / one || remainder > std::u256::max_value!() / one) return (0, false);
    let fractional_scaled = remainder * one;
    let whole_scaled = whole * one;
    let fraction = fractional_scaled / collateral_price;
    if (whole_scaled > std::u256::max_value!() - fraction) return (0, false);

    let down = whole_scaled + fraction;
    if (round_up && fractional_scaled % collateral_price != 0) {
        if (down == std::u256::max_value!()) { (0, false) } else { (down + 1, true) }
    } else {
        (down, true)
    }
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
