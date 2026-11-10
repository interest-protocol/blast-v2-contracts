// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// The package registry supplies the numeric abort code.
#[allow(lint(abort_without_constant))]
/// Validated rates in parts per million.
module blast_fun_dex::ppm;

// === Constants ===

const DENOMINATOR: u32 = 1_000_000;

// === Public Types ===

/// A rate from zero through 1,000,000 ppm (100%).
public struct Ppm(u32) has copy, drop, store;

// === Package Functions ===

public(package) fun new(value: u32): Ppm {
    assert!(value <= DENOMINATOR, blast_fun_dex::errors::invalid_ppm!());

    Ppm(value)
}

public(package) fun value(self: Ppm): u32 {
    self.0
}
