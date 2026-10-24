// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l6_scenario_tests;

// === Constants ===

const USDC: u64 = 1_000_000;

// === Tests ===

#[test]
fun full_batches_make_repeated_progress_with_realistic_fills_and_costs() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut vault = large_vault_with_small_orders(side);
        2u64.do!(|_| {
            let before = vault.leverage_bps();
            let shares = vault.supply();
            let cash = vault.admin_cash();
            assert_eq!(vault.rebalance(), 16);
            let after = vault.leverage_bps();
            assert!(after < before && before - after < 10);
            assert_eq!(vault.supply(), shares);
            assert_eq!(vault.admin_cash(), cash);
            assert!(vault.needs_rebalance());
        });
        vault.destroy();
    });
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNoProgress, location = blast_boosts_core::state)]
fun many_tiny_simulated_fills_do_not_earn_the_full_batch_exception() {
    let mut vault = large_vault_with_small_orders(policy::short());
    vault.venue_mut().set_fill_ratio_bps(100);
    vault.rebalance();
    vault.destroy();
}

#[test]
fun cheaper_emergency_execution_commits_a_sixteenth_tail_fill_above_the_cap() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut vault = test_adapter::calm_venue().with_side(side)
            .issue_with(test_adapter::standard_policy(side), 3_000_000 * USDC, 2_000_000 * USDC)
            .activate(1_000_000 * USDC, 0);
        let venue = vault.venue();
        let notional = venue.notional() as u128;
        let equity = venue.equity() as u128;
        let leverage = if (side == policy::long()) { 30_003u128 } else { 30_002u128 };
        let cash_basis = if (side == policy::long()) { notional - equity } else { notional + equity };
        let denominator = if (side == policy::long()) { leverage - 10_000 } else { leverage + 10_000 };
        let price = (venue.base_price() as u128) * leverage * cash_basis / (notional * denominator);
        vault.venue_mut().set_base_price(price as u64);
        vault.state_mut().set_nav_cap(10 * USDC);
        vault.set_max_order_notional(10 * USDC);
        let before = vault.leverage_bps();
        let shares = vault.supply();
        assert_eq!(vault.rebalance(), 16);
        assert!(vault.leverage_bps() > 30_000 && vault.leverage_bps() < before);
        assert_eq!(vault.supply(), shares);
        assert_eq!(vault.admin_cash(), 0);
        vault.destroy();
    });
}

// === Test Helpers ===

/// A valid issuance grows its live-to-limit ratio by lowering the deposit
/// ceiling, then reducing the order cap. Both settings remain valid together.
fun large_vault_with_small_orders(side: PositionSide): Vault {
    let mut vault = test_adapter::calm_venue().with_side(side)
        .issue_with(test_adapter::standard_policy(side), 3_000_000 * USDC, 2_000_000 * USDC)
        .activate(1_000_000 * USDC, 0);
    vault.venue_mut().set_base_price(if (side == policy::long()) { 1_900_000_000 } else { 2_750_000_000 });
    assert!(vault.leverage_bps() > 26_000 && vault.leverage_bps() < 30_000);
    vault.state_mut().set_nav_cap(10 * USDC);
    vault.set_max_order_notional(10 * USDC);
    assert!(vault.nav() > vault.state().nav_cap_for_testing());
    vault
}

// === Imports ===

use blast_boosts_core::{errors, policy::{Self, PositionSide}, test_adapter::{Self, Vault}};
use std::unit_test::assert_eq;
