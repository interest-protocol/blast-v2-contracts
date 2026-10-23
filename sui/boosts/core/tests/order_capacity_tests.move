// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Execution-quote caps and the bounded minimum-lot closing exception.
module blast_boosts_core::order_capacity_tests;

// === Constants ===

const USDC: u64 = 1_000_000;
const SEED: u64 = 10_000 * USDC;
const RESERVE: u64 = 500 * USDC;
const LARGE_LOT: u64 = 100_000_000_000;

// === Tests ===

#[test]
fun capacity_matches_enumerated_quote_costs_and_rounds_down_to_lots() {
    // Enumerate candidates and evaluate their rounded-up quote directly.
    // A fractional sell price just below the next price atom must fit too.
    vector[1u64, 7, 19].do!(|price| {
        vector[0u64, 100, 500].do!(|slippage| {
            vector[1u64, 3].do!(|lot| {
                let mut cap = 1u64;
                while (cap <= 20) {
                    let upper = price * (10_000 + slippage) / 10_000 + 1;
                    let mut expected = 0;
                    let mut candidate = lot;
                    while (candidate <= 40) {
                        let cost = (candidate * upper).div_ceil(2);
                        if (cost <= cap) expected = candidate;
                        candidate = candidate + lot;
                    };
                    let actual = rebalance_math::base_for_execution_notional_down(cap, price, 2, lot, slippage, 1, 1);
                    assert_eq!(actual, expected);
                    let fractional_quote = actual * (upper * 1_000 - 1);
                    assert!(fractional_quote.div_ceil(2_000) <= cap);
                    cap = cap + 1;
                };
            });
        });
    });
}

#[test]
fun huge_caps_and_prices_keep_wide_arithmetic_and_narrow_only_whole_lots() {
    let max = std::u64::max_value!();
    assert_eq!(rebalance_math::base_for_execution_notional_down(max, 1, max, 7, 9_999, 1_000_000_000_000_000_000, 1), max / 7 * 7);
    let base = rebalance_math::base_for_execution_notional_down(max, max, max, 1, 9_999, 1, 1);
    assert!(base > 0 && base < max);
    let upper = (max as u256) * 19_999 / 10_000 + 1;
    assert!(((base as u256) * upper).div_ceil(max as u256) <= max as u256);
}

#[test]
fun a_large_target_at_a_tiny_price_still_places_a_representable_capped_order() {
    let base = rebalance_math::increase_base_down(
        10_000_000, 0, 20_000, 1, 1_000_000_000, 1, 1_000_000, 0, 0, 1_000_000_000, 1_000_000,
    );
    assert_eq!(base, 500_000_000_000_000_000);
}

#[test]
fun tighter_caps_or_wider_bounds_never_increase_order_capacity() {
    let mut previous = std::u64::max_value!();
    vector[0u64, 100, 250, 500, 9_999].do!(|slippage| {
        let capacity = rebalance_math::base_for_execution_notional_down(10_000, 1_000, 1, 1, slippage, 1_000, 1);
        assert!(capacity <= previous);
        let tighter = rebalance_math::base_for_execution_notional_down(9_999, 1_000, 1, 1, slippage, 1_000, 1);
        assert!(tighter <= capacity);
        previous = capacity;
    });
}

#[test]
fun both_sides_close_over_multiple_transactions_after_a_live_lot_increase() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut vault = test_adapter::calm_venue().with_side(side).issue().activate(SEED, RESERVE);
        vault.set_max_order_notional(100 * USDC);
        // A venue lot now costs $250, above the $100 cap. The 100-lot
        // proportional minimum also exceeds a transaction's 16-order budget.
        vault.venue_mut().set_lot_size(LARGE_LOT);
        vault.begin_shutdown();
        let before = vault.venue().base();
        assert_eq!(vault.unwind(16), 16);
        assert_eq!(vault.venue().base(), before - 16 * LARGE_LOT);
        while (vault.venue().base() > 0) { vault.unwind(16); };
        assert!(vault.finalize() > 0);
        vault.destroy();
    });
}

#[test]
fun cap_sized_short_shutdown_orders_accept_an_allowed_higher_fill() {
    let mut vault = test_adapter::calm_venue().with_side(policy::short()).issue().activate(SEED, RESERVE);
    vault.venue_mut().set_slippage_bps(100);
    vault.begin_shutdown();
    assert!(vault.unwind(16) > 0);
    assert_eq!(vault.venue().base(), 0);
    assert!(vault.finalize() > 0);
    vault.destroy();
}

#[test]
fun short_shutdown_uses_the_widened_bound_when_sizing_cap_limited_buybacks() {
    let mut vault = test_adapter::calm_venue().with_side(policy::short()).issue().activate(SEED, RESERVE);
    vault.set_max_order_notional(1_000 * USDC);
    vault.begin_shutdown();
    vault.venue_mut().advance(86_400_000);
    vault.venue_mut().set_slippage_bps(500);
    assert_eq!(vault.unwind(16), 16);
    assert!(vault.venue().base() > 0);
    while (vault.venue().base() > 0) { vault.unwind(16); };
    assert!(vault.finalize() > 0);
    vault.destroy();
}

#[test]
fun short_emergency_buybacks_reserve_the_wider_execution_price() {
    let mut vault = test_adapter::calm_venue().with_side(policy::short()).issue().activate(SEED, RESERVE);
    vault.set_max_order_notional(1_000 * USDC);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 125 / 100);
    vault.venue_mut().set_slippage_bps(300);
    assert!(vault.leverage_bps() > 30_000);
    assert!(vault.rebalance() > 1);
    assert!(vault.leverage_bps() <= 30_000 && vault.leverage_bps() > 26_000);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun a_lot_above_the_cap_cannot_open_more_exposure() {
    let mut vault = test_adapter::calm_venue().issue().activate(SEED, RESERVE);
    vault.set_max_order_notional(100 * USDC);
    vault.venue_mut().set_lot_size(LARGE_LOT);
    vault.mint(20_000 * USDC, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOrderNotionalExceedsMaximum, location = blast_boosts_core::state)]
fun two_closing_lots_cannot_use_the_one_lot_exception() {
    let vault = test_adapter::calm_venue().issue().activate(SEED, RESERVE);
    let cap = vault.state().max_order_notional_for_testing();
    vault.state().assert_order_notional_allowed(cap + 1, 2 * LARGE_LOT, LARGE_LOT, true);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOrderNotionalExceedsMaximum, location = blast_boosts_core::state)]
fun one_opening_lot_cannot_use_the_closing_exception() {
    let vault = test_adapter::calm_venue().issue().activate(SEED, RESERVE);
    let cap = vault.state().max_order_notional_for_testing();
    vault.state().assert_order_notional_allowed(cap + 1, LARGE_LOT, LARGE_LOT, false);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOrderCapBelowMinimum, location = blast_boosts_core::state)]
fun the_admin_cannot_set_a_cap_below_the_live_proportional_minimum() {
    let mut vault = test_adapter::calm_venue().issue().activate(SEED, RESERVE);
    vault.set_max_order_notional(1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun one_lot_closing_still_checks_the_price_bound() {
    let mut vault = test_adapter::calm_venue().issue().activate(SEED, RESERVE);
    vault.set_max_order_notional(100 * USDC);
    vault.venue_mut().set_lot_size(LARGE_LOT);
    vault.venue_mut().set_slippage_bps(101);
    vault.begin_shutdown();
    vault.unwind(1);
    vault.destroy();
}

// === Imports ===

use blast_boosts_core::{errors, policy, rebalance_math, test_adapter};

use std::unit_test::assert_eq;
