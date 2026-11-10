// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::fee_path_tests;

// === Constants ===

const ONE_X96: u256 = 1 << 96;
const FIRST_RANGE_LIQUIDITY: u256 = 179_520_000;
const SECOND_RANGE_LIQUIDITY: u256 = 240_000_000;

// === Tests ===

#[test]
fun splitting_the_reported_trade_never_discounts_the_fee() {
    let path = lp_fee::new_fee_path(lp_fee::new_dynamic(1_000, 100_000, 1_000_000), ONE_X96);
    let split_x96 = 33 * ONE_X96 / 32;
    let end_x96 = 17 * ONE_X96 / 16;
    let (whole_net, whole_fee) = walk(&path, ONE_X96, end_x96, 2 * ONE_X96);
    let (first_net, first_fee) = walk(&path, ONE_X96, split_x96, 2 * ONE_X96);
    let (second_net, second_fee) = walk(&path, split_x96, end_x96, 2 * ONE_X96);

    assert!(first_net + second_net >= whole_net && first_net + second_net <= whole_net + 1);
    assert!(first_fee + second_fee >= whole_fee && first_fee + second_fee <= whole_fee + 2);
}

#[test]
fun splitting_a_capped_path_across_a_liquidity_boundary_cannot_save_fees() {
    let path = lp_fee::new_fee_path(lp_fee::new_dynamic(1_000, 10_000, 1_000_000), ONE_X96);
    let range_x96 = 33 * ONE_X96 / 32;
    let low_x96 = 7 * ONE_X96 / 8;
    let high_x96 = 5 * ONE_X96 / 4;
    let split_x96 = 31 * ONE_X96 / 32;
    let (whole_net, whole_fee) = walk(&path, high_x96, low_x96, range_x96);
    let (first_net, first_fee) = walk(&path, high_x96, split_x96, range_x96);
    let (second_net, second_fee) = walk(&path, split_x96, low_x96, range_x96);

    assert!(first_net + second_net >= whole_net && first_net + second_net <= whole_net + 1);
    assert!(first_fee + second_fee >= whole_fee && first_fee + second_fee <= whole_fee + 2);
}

#[test]
fun cap_and_gross_budget_rounding_apply_even_to_dust() {
    let path = lp_fee::new_fee_path(lp_fee::new_dynamic(1_000, 100_000, 100_000), ONE_X96);
    let capped = path.next_step(2 * ONE_X96, 3 * ONE_X96);

    assert_eq!(capped.limit_x96(), 3 * ONE_X96);
    assert_eq!(capped.net_budget_down(1), 0);
    assert_eq!(capped.fee_up(0), 0);
    assert_eq!(capped.fee_up(1), 1);
    assert_eq!(capped.net_budget_down(10), 9);
    assert_eq!(capped.fee_up(9), 1);
    assert_eq!(capped.fee_up(10), 2);

    let flat = lp_fee::new_fee_path(lp_fee::new_dynamic(1_000, 1_000, 100_000), ONE_X96);
    let step = flat.next_step(3 * ONE_X96, ONE_X96);
    assert_eq!(step.limit_x96(), ONE_X96);
    assert_eq!(step.net_budget_down(1_000), 999);
    assert_eq!(step.fee_up(999), 1);
}

// === Test Helpers ===

/// Single-pair CLMM harness. It walks the production fee boundaries with one
/// optional liquidity change and exact rational amount deltas rounded up.
fun walk(path: &FeePath, start_x96: u256, end_x96: u256, range_x96: u256): (u64, u64) {
    let mut spot_x96 = start_x96;
    let mut total_net = 0;
    let mut total_fee = 0;
    let mut steps = 0u64;
    let up = end_x96 > start_x96;
    while (spot_x96 != end_x96) {
        let below_range = spot_x96 < range_x96 || (spot_x96 == range_x96 && !up);
        let (range_limit_x96, liquidity) = if (below_range) {
            (if (up) end_x96.min(range_x96) else end_x96, FIRST_RANGE_LIQUIDITY)
        } else {
            (if (up) end_x96 else end_x96.max(range_x96), SECOND_RANGE_LIQUIDITY)
        };
        let step = path.next_step(spot_x96, range_limit_x96);
        let next_x96 = step.limit_x96();
        assert!(next_x96 != spot_x96);

        let delta = spot_x96.diff(next_x96);
        let net = if (up) {
            (liquidity * delta).div_ceil(ONE_X96) as u64
        } else {
            (liquidity * delta * ONE_X96).div_ceil(spot_x96 * next_x96) as u64
        };
        let fee = step.fee_up(net);
        assert_eq!(step.net_budget_down(net + fee), net);
        total_net = total_net + net;
        total_fee = total_fee + fee;
        spot_x96 = next_x96;
        steps = steps + 1;
        assert!(steps <= 1_027);
    };
    (total_net, total_fee)
}

// === Imports ===

use blast_fun_dex::lp_fee::{Self, FeePath};
use std::unit_test::assert_eq;
