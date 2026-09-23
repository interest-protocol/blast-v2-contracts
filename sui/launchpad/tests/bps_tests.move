// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::bps_tests;

// === Tests ===

#[test]
fun constructor_accepts_the_complete_closed_range() {
    assert_eq!(bps::new(0).value(), 0);
    assert_eq!(bps::new(1).value(), 1);
    assert_eq!(bps::new(10_000).value(), 10_000);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidBps,
    location = blast_fun::bps,
)]
fun constructor_rejects_the_first_value_above_one_hundred_percent() {
    bps::new(10_001);
}

#[test]
fun upward_application_assigns_the_remainder_to_the_rate() {
    assert_eq!(bps::new(0).apply_up(10_001), 0);
    assert_eq!(bps::new(2_500).apply_up(10_001), 2_501);
    assert_eq!(bps::new(1).apply_up(1), 1);
    assert_eq!(bps::new(10_000).apply_up(std::u64::max_value!()), std::u64::max_value!());
}

#[test]
fun complement_is_exact_and_involutive() {
    assert_eq!(bps::new(0).complement().value(), 10_000);
    assert_eq!(bps::new(10_000).complement().value(), 0);
    assert_eq!(bps::new(2_501).complement().complement().value(), 2_501);
}

// === Imports ===

use blast_fun::bps;

use std::unit_test::assert_eq;
