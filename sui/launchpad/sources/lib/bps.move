// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Validated basis-points values and explicit rounded application.
module blast_fun::bps;

use blast_fun::constants;

// === Public Structs ===

// The type and every operation are public so dependent packages share one rate unit. The tuple
// field stays private and `new` validates the inclusive range, so no caller can hold an
// out-of-range rate.
/// A rate in the inclusive range zero through 10,000 basis points.
public struct Bps(u64) has copy, drop, store;

// === Public Functions ===

/// Validates and wraps one raw basis-points value.
public fun new(value: u64): Bps {
    assert!(
        value <= constants::basis_points_denominator!(),
        blast_fun::errors::invalid_bps!(),
    );

    Bps(value)
}

/// Returns the raw basis-points value for primitive ABI and event fields.
public fun value(self: Bps): u64 {
    let Bps(value) = self;

    value
}

/// Applies the rate to atomic units, rounding any remainder down.
///
/// The standard method widens the `u64` product to `u128`. Because the rate is
/// at most 10,000, the result is representable and no larger than `amount`.
public fun apply_down(self: Bps, amount: u64): u64 {
    amount.mul_div(self.value(), constants::basis_points_denominator!())
}

/// Applies the rate to atomic units, rounding any remainder up.
///
/// The standard method widens the `u64` product to `u128`. Because the rate is
/// at most 10,000, the result is representable and no larger than `amount`.
public fun apply_up(self: Bps, amount: u64): u64 {
    amount.mul_div_ceil(self.value(), constants::basis_points_denominator!())
}

/// Returns the exact remaining rate through 10,000 basis points.
public fun complement(self: Bps): Bps {
    Bps(constants::basis_points_denominator!() - self.value())
}
