#[test_only]
/// Independent boundary vectors for per-session cost-aware rebalance sizing.
module blast_leverage_series_one::rebalance_math_tests;

use blast_leverage_series_one::rebalance_math;
use std::unit_test::assert_eq;

// === Tests ===

#[test]
fun reduction_improvement_uses_exact_ratios_and_one_lot_tolerance() {
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 250, 100, 20_000, 500, 1));
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 299, 100, 20_000, 101, 1));
    assert!(rebalance_math::reduction_is_sufficient(300, 100, 201, 100, 20_000, 20_000, 1));
    // A 300-atom position has not improved if its NAV fell in the same proportion.
    assert!(!rebalance_math::reduction_is_sufficient(300, 100, 270, 90, 20_000, 1, 1));
}

#[test]
fun increase_reserves_adverse_execution_and_fee_headroom() {
    let base = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 20_000, 10_000_000_000, 1_000_000_000,
        1_000, 2_000_000, 10, 50,
    );
    assert_eq!(base, 98_813_000);
    let notional = rebalance_math::index_notional_up(base, 10_000_000_000, 1_000_000_000);
    let cost = rebalance_math::execution_cost_up(notional, 10, 50);
    assert_eq!(notional, 988_130);
    assert_eq!(cost, 5_935);
    assert!((1_000_000u128 + (notional as u128)) * 10_000 <= 20_000 * (1_000_000 - cost));
    let next = rebalance_math::index_notional_up(base + 1_000, 10_000_000_000, 1_000_000_000);
    let next_cost = rebalance_math::execution_cost_up(next, 10, 50);
    assert!((1_000_000u128 + (next as u128)) * 10_000 > 20_000 * (1_000_000 - next_cost));
}

#[test]
fun increase_recomputes_headroom_after_each_order_cost() {
    let first = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 20_000, 10_000_000_000, 1_000_000_000,
        1_000, 500_000, 10, 50,
    );
    assert_eq!(first, 50_000_000);
    assert_eq!(rebalance_math::execution_cost_up(500_000, 10, 50), 3_003);
    let second = rebalance_math::increase_base_down(
        996_997, 1_500_000, 20_000, 10_000_000_000, 1_000_000_000,
        1_000, 500_000, 10, 50,
    );
    assert_eq!(second, 48_813_000);
}

#[test]
fun execution_cost_rounds_each_order_instead_of_the_aggregate() {
    assert_eq!(rebalance_math::execution_cost_up(1, 10, 50), 2);
    assert_eq!(rebalance_math::execution_cost_up(16, 10, 50), 2);
    assert_eq!(16 * rebalance_math::execution_cost_up(1, 10, 50), 32);
}

#[test]
fun increase_returns_zero_when_a_whole_lot_cannot_leave_positive_nav() {
    assert_eq!(rebalance_math::increase_base_down(
        1, 0, 20_000, 1_000_000_000, 1_000_000_000, 1_000, 100, 10, 50,
    ), 0);
}

#[test]
fun generic_four_and_six_times_use_the_same_maximal_integer_search() {
    let four = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 40_000, 10_000_000_000, 1_000_000_000,
        1_000, 5_000_000, 0, 0,
    );
    let six = rebalance_math::increase_base_down(
        1_000_000, 1_000_000, 60_000, 10_000_000_000, 1_000_000_000,
        1_000, 5_000_000, 0, 0,
    );
    assert_eq!(four, 300_000_000);
    assert_eq!(six, 500_000_000);
}
