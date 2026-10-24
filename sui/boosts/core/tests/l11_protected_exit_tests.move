// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_core::l11_protected_exit_tests;

// === Constants ===

const NOW: u64 = 100_000;
const PRICE: u64 = 1_000_000_000;
const MAX: u64 = 18_446_744_073_709_551_615;

// === Test-Only Types ===

public struct Product {}

// === Tests ===

#[test]
#[expected_failure(abort_code = errors::EOrderBelowMinLots, location = blast_boosts_core::accounting_math)]
fun the_largest_holder_redemption_is_locked_below_the_minimum() {
    accounting_math::redemption_base_bounds(500, 64, 1_000, 1, 65);
}

#[test]
fun exact_size_trigger_handles_minimum_equality_and_flat_rounding() {
    assert!(accounting_math::is_redemption_size_locked(64, 1_000, 500, 1, 65));
    // Raw base can exceed the minimum while the accessible burn remains locked.
    assert!(accounting_math::is_redemption_size_locked(128, 1_000, 500, 1, 65));
    assert!(!accounting_math::is_redemption_size_locked(130, 1_000, 500, 1, 65));
    let (minimum, maximum) = accounting_math::redemption_base_bounds(500, 130, 1_000, 1, 65);
    assert_eq!(vector[minimum, maximum], vector[65, 65]);
    // An unrounded proportional keep of zero already permits a full close.
    assert!(!accounting_math::is_redemption_size_locked(1, 1_000, 1, 1, 65));
    let (minimum, maximum) = accounting_math::redemption_base_bounds(999, 1, 1_000, 1, 65);
    assert_eq!(vector[minimum, maximum], vector[0, 0]);
    // The minimum guard runs before rounding the actual close to a whole lot.
    assert!(accounting_math::is_redemption_size_locked(10, 10, 3, 10, 1));
}

#[test]
fun invalid_flat_or_seed_only_positions_cannot_trigger() {
    vector[
        vector[0, 100, 50, 1, 65], vector[64, 100, 100, 1, 65],
        vector[64, 100, 101, 1, 65], vector[64, 100, 0, 1, 65],
        vector[64, 0, 0, 1, 65], vector[64, 100, 50, 0, 65],
        vector[64, 100, 50, 1, 0], vector[65, 100, 50, 2, 65],
    ].do!(|v| assert!(!accounting_math::is_redemption_size_locked(v[0], v[1], v[2], v[3], v[4])));
    assert!(accounting_math::is_redemption_size_locked(MAX, MAX, MAX - 1, MAX, MAX));
}

#[test]
fun exact_trigger_matches_enumerating_every_accessible_burn() {
    let mut supply = 2;
    while (supply <= 10) {
        let mut locked = 1;
        while (locked < supply) {
            let mut base = 1;
            while (base <= 20) {
                let mut any_ordinary_exit = false;
                let mut burn = 1;
                while (burn <= supply - locked) {
                    // Independent small-integer oracle: search every possible holder burn.
                    let keep = base * (supply - burn) / supply;
                    if (keep == 0 || base - keep >= 5) any_ordinary_exit = true;
                    burn = burn + 1;
                };
                assert_eq!(accounting_math::is_redemption_size_locked(base, supply, locked, 1, 5), !any_ordinary_exit);
                base = base + 1;
            };
            locked = locked + 1;
        };
        supply = supply + 1;
    };
}

#[test]
fun protected_exit_keeps_seed_reserve_and_rounding_out_of_holder_claims() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side, 100);
        state.begin_protected_shutdown(64, 1, 1_000, 500, NOW);
        state.assert_unwinding();
        let (eligible, reserve, seed) = state.finalize_shutdown(1_000, 500, 1_001);
        assert_eq!(vector[eligible, reserve, seed], vector[500, 100, 451]);
        let pool = 1_001 - reserve - seed;
        let first = state.shutdown_claim_quote(pool, 1_000, 500, 200, 0);
        let last = state.shutdown_claim_quote(pool - first, 800, 500, 300, 0);
        assert_eq!(vector[first, last, reserve + seed], vector[180, 270, 551]);
        assert_eq!(state.maintenance_reserve(), 0);
        state.destroy_for_testing();
    });
}

#[test]
fun losses_and_recorded_reserve_can_leave_zero_holder_cash() {
    vector[0, 30, 100].do!(|recovered| {
        let mut state = seeded(policy::long(), 100);
        state.begin_protected_shutdown(64, 1, 1_000, 500, NOW);
        let (eligible, reserve, seed) = state.finalize_shutdown(1_000, 500, recovered);
        assert_eq!(vector[eligible, reserve, seed], vector[500, recovered, 0]);
        assert_eq!(state.shutdown_claim_quote(0, 1_000, 500, 500, 0), 0);
        state.destroy_for_testing();
    });
}

#[test]
fun finalization_uses_full_recorded_reserve_and_settled_funding() {
    let mut state = seeded(policy::long(), 2_000);
    state.begin_protected_shutdown(64, 1, 1_000, 500, NOW);
    state.settle_funding(observation::funding_cost(400));
    state.settle_funding(observation::funding_credit(100));
    let (_, reserve, seed) = state.finalize_shutdown(1_000, 500, 2_000);
    assert_eq!(vector[reserve, seed], vector[1_700, 150]);
    state.destroy_for_testing();
}

#[test]
fun protected_split_uses_wide_products_and_conserves_maximum_cash() {
    let mut state = seeded(policy::long(), 0);
    state.begin_protected_shutdown(64, 1, MAX, MAX - 1, NOW);
    let (eligible, reserve, seed) = state.finalize_shutdown(MAX, MAX - 1, MAX);
    assert_eq!(vector[eligible, reserve, seed], vector[1, 0, MAX - 1]);
    assert_eq!(state.shutdown_claim_quote(1, MAX, MAX - 1, 1, 1), 1);
    state.destroy_for_testing();
}

#[test]
fun reachable_mint_then_redeem_cannot_gift_seed_cash_to_one_remaining_share() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side, 0);
        // One native 9-decimal share per whole collateral unit; this fixture has 0 collateral decimals.
        let locked = 1_000_000_000_000;
        let plan = state.prepare_mint(position(side, 1_000, 2_000), 1_000, locked, 0, 0, NOW);
        let (minted, _, _, _, _) = state.complete_mint(plan, position(side, 2_000, 4_000), NOW);
        assert_eq!(minted, locked);
        let supply = locked + minted;
        let burn = minted - 1;
        let plan = state.prepare_redemption(position(side, 2_000, 4_000), burn, supply, 0, NOW);
        let after_base = 4_000 - plan.base_to_sell();
        let (paid, _, _, _) = state.complete_redemption(plan, position(side, 2_000, after_base), NOW);
        assert_eq!(paid, 999);
        assert_eq!(after_base, 2_000);
        state.begin_protected_shutdown(after_base, 1, supply - burn, locked, NOW);
        let cash = 2_000 - paid;
        let (_, reserve, seed) = state.finalize_shutdown(supply - burn, locked, cash);
        assert_eq!(vector[reserve, seed], vector[0, cash]);
        assert_eq!(state.shutdown_claim_quote(cash - reserve - seed, supply - burn, locked, 1, 0), 0);
        state.destroy_for_testing();
    });
}

#[test]
fun a_rebalance_can_shrink_below_the_accessible_minimum_then_holders_exit() {
    vector[policy::long(), policy::short()].do!(|side| {
        let mut state = seeded(side, 0);
        assert!(!accounting_math::is_redemption_size_locked(200, 1_000, 500, 1, 65));
        let mut plan = state.prepare_rebalance(position(side, 40, 200), 0, NOW);
        let order = state.next_rebalance_order(&plan);
        assert_eq!(order.order_base(), 80);
        state.accept_rebalance_fill(&mut plan, order, position(side, 40, 120), 80, NOW);
        state.complete_rebalance(plan);
        state.begin_protected_shutdown(120, 1, 1_000, 500, NOW);
        let (_, reserve, seed) = state.finalize_shutdown(1_000, 500, 40);
        assert_eq!(state.shutdown_claim_quote(40 - reserve - seed, 1_000, 500, 500, 0), 20);
        state.destroy_for_testing();
    });
}

#[test]
fun administrator_approved_shutdown_retains_its_existing_allocation() {
    let mut state = seeded(policy::long(), 100);
    state.begin_shutdown(NOW);
    let (eligible, reserve, seed) = state.finalize_shutdown(1_000_001, 1_000_000, 1_001);
    assert_eq!(vector[eligible, reserve, seed], vector[1, 0, 0]);
    assert_eq!(state.shutdown_claim_quote(1_001, 1_000_001, 1_000_000, 1, 0), 1_001);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProtectedShutdownNotAllowed, location = blast_boosts_core::state)]
fun ordinary_exit_at_the_minimum_cannot_be_forced_to_shutdown() {
    let mut state = seeded(policy::long(), 0);
    state.begin_protected_shutdown(130, 1, 1_000, 500, NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun administrator_cannot_switch_protected_settlement_to_legacy_distribution() {
    let mut state = seeded(policy::long(), 100);
    state.begin_protected_shutdown(64, 1, 1_000, 500, NOW);
    state.begin_shutdown(NOW);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun protected_shutdown_cannot_be_restarted() {
    let mut state = seeded(policy::long(), 100);
    state.begin_protected_shutdown(64, 1, 1_000, 500, NOW);
    state.begin_protected_shutdown(64, 1, 1_000, 500, NOW + 1);
    state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun protected_shutdown_blocks_ordinary_redemptions() {
    let mut state = seeded(policy::long(), 100);
    state.begin_protected_shutdown(64, 1, 1_000, 500, NOW);
    destroy(state.prepare_redemption(position(policy::long(), 100, 64), 500, 1_000, 0, NOW));
    state.destroy_for_testing();
}

// === Test Helpers ===

fun seeded(side: PositionSide, reserve: u64): State<Product> {
    let vault_policy = policy::new_vault_policy(
        side, policy::new_rebalance_policy(18_000, 20_000, 22_000, 30_000, 100, 200, 100),
        policy::new_price_policy(30_000, 2_000, 100, 500), 0, 0, 100, 100, 10_000, 65, 5_000,
    );
    let (mut state, _, _) = state::issue<Product>(
        &blast_acl::witness_for_testing(), vault_policy, 1_000_000, 1_000_000, 0, 0,
    ).activate(position(side, 1_000, 2_000), 0, NOW);
    state.settle_funding(observation::funding_credit(reserve));
    state
}

fun position(side: PositionSide, equity: u64, base: u64): PositionObservation {
    observation::new_position(
        equity, base, 1, side, observation::new_price(PRICE, 0, NOW),
        observation::new_price(PRICE, 0, NOW), PRICE,
    )
}

// === Imports ===

use blast_admin::blast_acl;
use blast_boosts_core::{
    accounting_math,
    errors,
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide},
    state::{Self, State},
};
use std::unit_test::{assert_eq, destroy};
