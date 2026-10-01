// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Validated basis-points values and explicit rounded application.
module blast_presale::bps;

// === Public Types ===

/// A rate from zero through 10,000 basis points; `new` is the only way to build one.
public struct Bps(u64) has copy, drop, store;

// === Public Functions ===

public fun new(value: u64): Bps {
    assert!(value <= DENOMINATOR, EInvalidBps);

    Bps(value)
}

public fun value(self: Bps): u64 {
    let Bps(value) = self;

    value
}

/// Applies the rate to `amount`, rounding up; the result is at most `amount`.
public fun apply_up(self: Bps, amount: u64): u64 {
    amount.mul_div_ceil(self.value(), DENOMINATOR)
}

// === Package Functions ===

/// The whole: 10,000 basis points.
public(package) fun denominator(): u64 {
    DENOMINATOR
}

// === Constants ===

const DENOMINATOR: u64 = 10_000;

// === Errors ===

#[error(code = 0)]
const EInvalidBps: vector<u8> = b"A basis-points rate must be at most 10,000.";
