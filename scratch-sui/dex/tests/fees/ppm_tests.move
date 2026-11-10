// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::ppm_tests;

// === Tests ===

#[test]
fun accepts_zero_and_one_hundred_percent() {
    assert_eq!(ppm::new(0).value(), 0);
    assert_eq!(ppm::new(1_000_000).value(), 1_000_000);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::ppm::EInvalidPpm, location = blast_fun_dex::ppm)]
fun rejects_the_first_rate_above_one_hundred_percent() {
    ppm::new(1_000_001);
}

// === Imports ===

use blast_fun_dex::ppm;
use std::unit_test::assert_eq;
