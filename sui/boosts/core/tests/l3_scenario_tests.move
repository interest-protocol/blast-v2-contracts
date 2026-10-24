// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// L3 sequences use the simulated venue's cost model, order loop and share accounting.
module blast_boosts_core::l3_scenario_tests;

// === Tests ===

#[test]
fun redemptions_can_reach_lot_dust_and_deposits_restore_normal_operations() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut vault = shrunk_vault(side);
        assert!(vault.is_below_band() && !vault.needs_rebalance());
        let holder_value = vault.nav_per_share();
        vault.mint(50_000, 1);
        assert!(vault.last_orders() == 1 && !vault.needs_rebalance());
        assert!(vault.nav_per_share() >= holder_value);
        let deposit = vault.nav();
        let ordinary_shares = vault.mint(deposit, 1);
        assert!(vault.redeem(ordinary_shares, 1) > 0);
        assert!(vault.supply() >= vault.locked());
        vault.destroy();
    });
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceNotActionable, location = blast_boosts_core::state)]
fun a_real_redeemed_lot_dust_position_rejects_standalone_rebalance_early() {
    let mut vault = shrunk_vault(policy::long());
    vault.rebalance();
    vault.destroy();
}

#[test]
fun recovery_can_fill_in_multiple_sessions_without_charging_old_holders() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut vault = shrunk_vault(side);
        vault.venue_mut().set_fill_ratio_bps(5_000);
        let holder_value = vault.nav_per_share();
        vault.mint(50_000, 1);
        assert!(vault.last_orders() > 1 && vault.last_orders() <= 16);
        assert!(vault.nav_per_share() >= holder_value);
        assert!(!vault.is_below_band() && !vault.needs_rebalance());
        vault.destroy();
    });
}

#[test]
#[expected_failure(abort_code = errors::EActiveFillIncomplete, location = blast_boosts_core::state)]
fun stopping_after_two_partial_recovery_sessions_cannot_mint_shares() {
    let mut vault = shrunk_vault(policy::short());
    vault.venue_mut().set_fill_ratio_bps(5_000);
    let now = vault.venue().now_ms();
    let plan = vault.state().prepare_mint(vault.venue().observe(), 50_000, vault.supply(), 1, 5, now);
    let price = plan.mint_position().base_price();
    let mut remaining = plan.base_to_buy();
    vault.venue_mut().deposit(50_000);
    2u64.do!(|_| {
        let (executed, filled, _) = vault.venue_mut().fill(remaining, true);
        vault.state().execution_bound().assert_execution(price, executed);
        remaining = remaining - filled;
    });
    assert!(remaining > 0);
    let after = vault.venue().observe();
    vault.state_mut().complete_mint(plan, after, now);
    vault.destroy();
}

// === Test Helpers ===

/// A market move followed by a legal redemption reaches dust without touching
/// locked seed shares or inventing a post-fill equity. The pre-redemption hint
/// is actionable; the remaining three lots cannot fit another standalone buy.
fun shrunk_vault(side: PositionSide): Vault {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 2, 1_000,
    );
    let mut vault = test_adapter::calm_venue().with_side(side).issue_with(vault_policy, 1_000_000, 1_000_000_000)
        .activate(3_750, 0);
    let shares = vault.mint(5_000, 1);
    let long = side == policy::long();
    vault.venue_mut().set_base_price(if (long) { 2_300_000_000 } else { 2_400_000_000 });
    assert!(vault.needs_rebalance());
    let redeem = if (long) { shares * 80 / 100 } else { shares };
    assert!(redeem <= vault.supply() - vault.locked());
    vault.redeem(redeem, 1);
    assert!(vault.venue().base() == 3 * vault.venue().lot_size());
    assert!(vault.supply() >= vault.locked());
    assert!(vault.is_below_band() && !vault.needs_rebalance());

    vault
}

// === Imports ===

use blast_boosts_core::{errors, policy::{Self, PositionSide}, test_adapter::{Self, Vault}};
