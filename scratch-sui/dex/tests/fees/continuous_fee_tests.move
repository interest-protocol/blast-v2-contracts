#[test_only]
module blast_fun_dex::continuous_fee_tests;

// === Constants ===

const ONE: u256 = 1 << 96;

// === Tests ===

#[test]
fun smooth_quote_encloses_constant_fee_and_exercises_both_directions() {
    let settings = lp_fee::new_dynamic_unchecked_for_testing(1_000, 10_000, 1_000_000);
    let path = continuous_fee::new(settings, ONE);
    let up = path.quote(ONE, 11 * ONE / 10, 1_000_000);
    let down = path.quote(11 * ONE / 10, ONE, 1_000_000);
    assert!(up.fee_up() > 1_000 && up.fee_up() < 10_102);
    assert!(down.fee_up() > 1_000 && down.fee_up() < 10_102);
    assert!(up.lower_x96() <= up.upper_x96());
    assert!(up.width_x96() < ONE);
    assert!(down.width_x96() < ONE);
}

#[test]
fun exact_input_solver_never_spends_more_than_the_budget() {
    let path = continuous_fee::new(lp_fee::new_dynamic_unchecked_for_testing(1_000, 100_000, 100_000), ONE);
    vector[0, 1, 10, 1_000, u64::max_value!()].do!(|budget| {
        let fill = path.solve_budget(ONE, 7 * ONE / 5, u64::max_value!(), budget);
        assert_eq!(fill.net_input() + fill.fee() + fill.unspent(), budget);
        assert!(fill.net_input() >= budget.mul_div(9, 10).saturating_sub(2));
        assert!(fill.iterations() <= 37);
    });
}

#[test]
fun splitting_the_same_path_at_the_reference_adds_at_most_one_fee_atom() {
    let path = continuous_fee::new(lp_fee::new_dynamic_unchecked_for_testing(1_000, 10_000, 1_000_000), ONE);
    // Both directions traverse [1/2, 2] in their respective net coordinates.
    // Net input is proportional to those coordinate differences.
    vector[true, false].do!(|up| {
        let (start, end) = if (up) (ONE / 2, 2 * ONE) else (2 * ONE, ONE / 2);
        let whole = path.quote(start, end, 3_000_000);
        let first = path.quote(start, ONE, 1_000_000);
        let second = path.quote(ONE, end, 2_000_000);
        assert!(whole.lower_x96() <= first.upper_x96() + second.upper_x96());
        assert!(whole.upper_x96() >= first.lower_x96() + second.lower_x96());
        let split_fee = first.fee_up() + second.fee_up();
        assert!(split_fee >= whole.fee_up() && split_fee <= whole.fee_up() + 1);
    });
}

#[test]
fun rounded_inverse_matches_wide_budget_oracles_in_both_directions() {
    let path = continuous_fee::new(lp_fee::new_dynamic_unchecked_for_testing(1_000, 100_000, 100_000), ONE);
    // Independent integer deltas and 90-digit quadrature. The total net
    // capacity exceeds u64 in both directions and adjacent prices cost >1 atom.
    assert_step(&path, ONE, 2 * ONE, 1 << 120, u64::max_value!(), true,
        79228162514264338691956066484, 18446744073705789758, 18428297329632083712, 18446744073705790);
    assert_step(&path, ONE, ONE / 2, 1 << 120, u64::max_value!(), false,
        79228162514264336495131834188, 18446744073705790015, 18428297329632083968, 18446744073705791);
    assert_step(&path, ONE, ONE + 1, u128::max_value!(), 2, true, ONE, 0, 0, 0);
}

#[test]
fun rounded_inverse_matches_oracles_across_caps_and_reference() {
    let path = continuous_fee::new(lp_fee::new_dynamic_unchecked_for_testing(1_000, 100_000, 100_000), ONE);
    let liquidity = 1_000_000_000_000_000;
    let budget = 1_000_000_000_000_000;
    assert_step(&path, ONE / 10, 2 * ONE, liquidity, budget, true,
        83362941868135160295832472247, budget, 9049599729342701, 47811747456261);
    assert_step(&path, 2 * ONE, ONE / 10, liquidity, budget, false,
        54170081719445139291831013526, budget, 1316277444782437, 37418442072901);
    let path = continuous_fee::new(lp_fee::new_dynamic_unchecked_for_testing(1_000, 100_000, 1_000_000), ONE);
    assert_step(&path, ONE / 8, 2 * ONE, liquidity, budget, true,
        82416933633859472603832614830, budget, 7038690727487646, 84752050048857);
    assert_step(&path, 5 * ONE / 4, ONE / 10, liquidity, budget, false,
        46007438215089638581758163159, budget - 1, 669304490283913, 77927100746963);
}

// === Test Helpers ===

fun assert_step(
    path: &ContinuousPath,
    start: u256,
    limit: u256,
    liquidity: u128,
    budget: u64,
    up: bool,
    expected_end: u256,
    expected_spent: u64,
    expected_output: u256,
    expected_fee: u64,
) {
    let (end, spent, output_x64, fee) = path.swap_step(start, limit, liquidity, budget, up);
    assert_eq!(end, expected_end);
    assert_eq!(spent, expected_spent);
    assert_eq!(output_x64 >> 64, expected_output);
    assert_eq!(fee, expected_fee);
}

// === Imports ===

use blast_fun_dex::{continuous_fee::{Self, ContinuousPath}, lp_fee};
use std::{u128, u64, unit_test::assert_eq};
