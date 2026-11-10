// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Validated rates in parts per million.
module blast_fun_dex::ppm;

// === Constants ===

const DENOMINATOR: u32 = 1_000_000;

// === Public Types ===

/// A rate from zero through 1,000,000 ppm (100%).
public struct Ppm(u32) has copy, drop, store;

// === Package Functions ===

public(package) fun new(value: u32): Ppm {
    assert!(value <= DENOMINATOR, EInvalidPpm);

    Ppm(value)
}

public(package) fun value(self: Ppm): u32 {
    self.0
}

// === Errors ===

#[error(code = 0)]
const EInvalidPpm: vector<u8> = b"A ppm rate must be at most 1,000,000.";
