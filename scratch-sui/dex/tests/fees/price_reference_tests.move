// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::price_reference_tests;

// === Constants ===

const WINDOW_MS: u64 = 600_000;

// === Tests ===

#[test]
fun half_window_observation_does_not_change_full_window_reference() {
    let mut direct = price_reference::new(32);
    let mut split = price_reference::new(32);

    assert_eq!(split.observe(36, WINDOW_MS / 2), 34);
    assert_eq!(split.observe(99, WINDOW_MS / 2), 34);
    assert_eq!(split.observe(36, WINDOW_MS), 36);
    assert_eq!(direct.observe(36, WINDOW_MS), 36);
}

#[test]
fun observation_before_first_price_move_cannot_shift_window_origin() {
    let mut direct = price_reference::new(32);
    let mut extra = price_reference::new(32);
    let first_move_ms = WINDOW_MS / 2;

    assert_eq!(extra.observe(32, 1), 32);
    assert_eq!(direct.observe(32, first_move_ms), 32);
    assert_eq!(extra.observe(32, first_move_ms), 32);
    assert_eq!(direct.observe(36, WINDOW_MS), 34);
    assert_eq!(extra.observe(36, WINDOW_MS), 34);
    assert_eq!(direct.observe(36, 3 * WINDOW_MS / 2), 35);
    assert_eq!(extra.observe(36, 3 * WINDOW_MS / 2), 35);
}

#[test]
fun integrates_small_price_changes_and_rounds_only_the_result() {
    let mut direct = price_reference::new(100);
    let mut extra = price_reference::new(100);

    direct.observe(100, WINDOW_MS / 4);
    extra.observe(100, WINDOW_MS / 4);
    assert_eq!(extra.observe(101, WINDOW_MS / 2), 100);
    assert_eq!(direct.observe(101, 3 * WINDOW_MS / 4), 100);
    assert_eq!(extra.observe(101, 3 * WINDOW_MS / 4), 100);
    assert_eq!(direct.observe(99, WINDOW_MS), 100);
    assert_eq!(extra.observe(99, WINDOW_MS), 100);

    let mut falling = price_reference::new(100);
    assert_eq!(falling.observe(97, WINDOW_MS / 2), 98);
}

#[test]
fun long_gaps_skip_completed_windows_at_the_maximum_timestamp() {
    let mut reference = price_reference::new(4_295_128_739);
    let highest = (1u256 << 160) - 1;
    assert!(reference.observe(highest, WINDOW_MS - 1) < highest);
    assert_eq!(reference.observe(highest, std::u64::max_value!()), highest);
}

// === Imports ===

use blast_fun_dex::price_reference;
use std::unit_test::assert_eq;
