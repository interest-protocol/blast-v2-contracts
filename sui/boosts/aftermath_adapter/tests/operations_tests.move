// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for atomic Aftermath Vault initialization seams.
module blast_boosts_aftermath::operations_tests;

// === Constants ===

const SYSTEM: address = @0x0;
const ADMIN: address = @0xA11CE;
const REFERENCE_AT_MS: u64 = 1_000;
/// Sixteen 250-atom orders cover the configured 10-bps minimum at this ceiling.
const NAV_CAP: u64 = 4_000_000;
const SEED_EQUITY: u64 = 1_000;
const SEED_RESERVE: u64 = 100;
/// With 9-decimal base, 6-decimal collateral and unit prices, one collateral atom of notional is 1,000 base atoms.
const BASE_PER_NOTIONAL: u64 = 1_000;
const ABSOLUTE_NOTIONAL: u64 = 1_800;
const ABSOLUTE_BASE: u64 = ABSOLUTE_NOTIONAL * BASE_PER_NOTIONAL;
const LOT_SIZE: u64 = 1;
const PRICE: u64 = 1_000_000_000;
const ALLOCATED_FIXED: u256 = 1_000_000_000_000_000;
const ATOM_FIXED: u256 = 1_000_000_000_000;
const ONE_FIXED: u256 = 1_000_000_000_000_000_000;
/// Cumulative funding rate every fixture starts from. Fixtures hold one base
/// unit long at a unit collateral price, so the venue settles exactly the raw
/// rate move: a rise is a cost, a fall a credit.
const RATE: u256 = 1_000_000_000_000_000_000;
const REFERENCE_GAS_PRICE: u64 = 750;
const PARTNER_PAYOUT: address = @0xFEE;

// === Test-Only Types ===

public struct Product() has drop;

public struct OtherProduct() has drop;

public struct Collateral {}

public struct Fixture {
    scenario: Scenario,
    registry: CoinRegistry,
    protocol: Protocol,
}

public struct ReplayState has drop {
    vault_id: ID,
    binding: Option<Binding>,
    maintenance_reserve: u64,
    lifecycle: u8,
    max_order_notional: u64,
    checkpoint: Option<Checkpoint>,
    unresolved_checkpoint: Option<Checkpoint>,
    supply: u64,
    admin_cash: u64,
    locked_shares: u64,
    fees: vector<u64>,
    terminal_cash: u64,
    protected_cash: u64,
    unrecoverable_collateral_raw: u256,
}

// === Tests ===

#[test]
fun protected_exit_long_replays_and_keeps_cash_locked_after_all_claims() {
    protected_exit(Product(), policy::long(), 1_001);
}

#[test]
fun protected_exit_short_replays_and_keeps_cash_locked_after_all_claims() {
    protected_exit(OtherProduct(), policy::short(), 1_001);
}

#[test]
fun protected_exit_can_burn_worthless_shares_without_spending_reserves() {
    protected_exit(Product(), policy::long(), 30);
}

#[test]
#[expected_failure(abort_code = errors::EInsufficientAdminCash, location = blast_boosts_aftermath::vault)]
fun protected_cash_cannot_be_withdrawn_by_the_admin() {
    let mut fixture = start();
    let checkpoint = protected_checkpoint(100_000_000_000, 1, 0, 0, 0);
    let mut vault = issue_and_activate(&mut fixture, checkpoint);
    let shares = vault.mint_shares(1, fixture.ctx!());
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, checkpoint, REFERENCE_AT_MS);
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(1_000, fixture.ctx!()));
    let clock = fixture.reference_clock();
    let output = vault.redeem_shutdown(&fixture.protocol, shares, 0, REFERENCE_AT_MS, &clock, fixture.ctx!());
    assert_eq!(output.value(), 0);
    assert_eq!(vault.protected_cash_for_testing(), 1_000);
    destroy(vault.withdraw_admin_fees(&fixture.protocol, &risk_admin(), 1, fixture.ctx!()));
    destroy(output);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EProtectedShutdownNotAllowed, location = blast_boosts_core::state)]
fun protected_exit_rejects_seed_only_supply() {
    protected_trigger_case(100_000_000_000, 1, 0, 0, 0, 0, false);
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EProtectedShutdownNotAllowed, location = blast_boosts_core::state)]
fun protected_exit_rejects_an_available_minimum_order() {
    protected_trigger_case(200_000_000_000, 1, 0, 0, 0, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::operations)]
fun protected_exit_rejects_unaccepted_raw_checkpoint() {
    protected_trigger_case(100_000_000_000, 1, 0, 0, 0, 900_000, true);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun protected_exit_rejects_pending_asks() {
    protected_trigger_case(100_000_000_000, 1, 1, 0, 0, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun protected_exit_rejects_pending_bids() {
    protected_trigger_case(100_000_000_000, 1, 0, 1, 0, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun protected_exit_rejects_pending_order_count() {
    protected_trigger_case(100_000_000_000, 1, 0, 0, 1, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun protected_exit_rejects_wrong_side() {
    protected_trigger_case((std::u256::max_value!() - 100_000_000_000 + 1), 1, 0, 0, 0, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun protected_exit_rejects_sub_atom_exposure() {
    protected_trigger_case(100_000_000_001, 1, 0, 0, 0, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun protected_exit_rejects_partial_lots() {
    protected_trigger_case(100_000_000_000, 3, 0, 0, 0, 900_000, false);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun protected_exit_rejects_flat_exposure() {
    protected_trigger_case(0, 1, 0, 0, 0, 900_000, false);
}

#[test]
fun protected_exit_zero_recovery_replays_explicit_zero_allocations() {
    protected_exit(Product(), policy::long(), 0);
}

#[test]
fun protected_exit_accepts_live_market_pause_and_funding_without_sync() {
    protected_policy_case(1, false, 100_000_000_000, 1);
}

#[test]
fun protected_exit_accepts_live_market_freeze_without_sync() {
    protected_policy_case(0, true, 100_000_000_000, 1);
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::operations)]
fun protected_exit_market_pause_does_not_hide_account_drift() {
    protected_policy_case(1, false, 101_000_000_000, 1);
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::operations)]
fun protected_exit_rejects_changed_lot_even_when_aligned() {
    protected_policy_case(1, false, 100_000_000_000, 2);
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::operations)]
fun protected_exit_drift_precedes_seed_only_rejection() {
    protected_trigger_case(100_000_000_000, 1, 0, 0, 0, 0, true);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun protected_exit_version_precedes_lifecycle_and_account_checks() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, protected_checkpoint(100_000_000_000, 1, 0, 0, 0));
    fixture.protocol.set_version_for_testing(3);
    vault.set_unwinding_for_testing();
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, protected_checkpoint(0, 0, 1, 1, 1), REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::operations)]
fun protected_exit_rejects_settled_funding_until_accounted() {
    protected_funding_case(false);
}

#[test]
fun protected_exit_accepts_accounted_funding_and_retains_updated_reserve() {
    protected_funding_case(true);
}

#[test]
fun profit_realization_restores_long_redemption_and_replays_without_changing_holder_claims() {
    let mut fixture = start();
    fixture.realize_then_redeem(policy::long(), 0);
    fixture.end();
}

#[test]
fun profit_realization_restores_short_redemption_and_replays_without_changing_holder_claims() {
    let mut fixture = start();
    fixture.realize_then_redeem(policy::short(), 0);
    fixture.end();
}

#[test]
fun profit_realization_restores_redemption_with_a_collateral_haircut() {
    let mut fixture = start();
    fixture.realize_then_redeem(policy::long(), ONE_FIXED / 10);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ERedemptionExceedsReleasable, location = blast_boosts_aftermath::snapshot)]
fun profitable_position_cannot_pay_proportional_redemption_before_realization() {
    let mut fixture = start();
    let side = policy::long();
    let before = profit_checkpoint(300, 700, ABSOLUTE_NOTIONAL, side);
    let mut vault = issue_and_activate(&mut fixture, before);
    vault.set_fees(&fixture.protocol, &risk_admin(), 0, 0, 0);
    let initial_supply = vault.total_share_supply();
    let shares = vault.mint_shares(initial_supply, fixture.ctx!());
    let plan = vault.state().prepare_redemption(position_observation(1_000), shares.value(), vault.total_share_supply(), 1, REFERENCE_AT_MS);
    let remaining = ABSOLUTE_NOTIONAL - plan.base_to_sell() / BASE_PER_NOTIONAL;
    let (net, admin, _, _) = vault.settle_redemption_for_testing(plan, &shares, active_position(1_000, remaining), REFERENCE_AT_MS);
    // The proportional sale realizes 350 of profit: cash 650, margin 360.
    // The holder is owed 450 but only 290 can be released.
    profit_cash(650, 350, remaining).assert_releasable(net + admin);
    destroy(shares);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationNoProgress, location = blast_boosts_aftermath::snapshot)]
fun profit_realization_rejects_unchanged_cash_even_with_a_changed_mark() {
    let before = profit_checkpoint(300, 700, ABSOLUTE_NOTIONAL, policy::long());
    let cash_before = profit_cash(300, 700, ABSOLUTE_NOTIONAL);
    let cash_after = profit_cash(300, 700, 1_700);
    cash_before.assert_realization_progress(&cash_after, &before, &before, 0);
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationNoProgress, location = blast_boosts_aftermath::snapshot)]
fun profit_realization_rejects_cash_improvement_no_larger_than_holder_cost() {
    let before = profit_checkpoint(300, 700, ABSOLUTE_NOTIONAL, policy::long());
    let after = profit_checkpoint(305, 690, ABSOLUTE_NOTIONAL, policy::long());
    profit_cash(300, 700, ABSOLUTE_NOTIONAL).assert_realization_progress(
        &profit_cash(305, 690, ABSOLUTE_NOTIONAL), &before, &after, 5,
    );
}

#[test]
#[expected_failure(abort_code = errors::EProfitRealizationNoProgress, location = blast_boosts_aftermath::snapshot)]
fun profit_realization_rejects_worsening_shortfall_despite_realized_cash() {
    let before = profit_checkpoint(300, 700, ABSOLUTE_NOTIONAL, policy::long());
    let after = profit_checkpoint(310, 688, ABSOLUTE_NOTIONAL, policy::long());
    profit_cash(300, 700, ABSOLUTE_NOTIONAL).assert_realization_progress(
        &profit_cash(310, 688, 1_900), &before, &after, 2,
    );
}


#[test]
fun rebaseline_reprices_mint_and_redemption_without_changing_existing_claims() {
    let mut fixture = start();
    let before = recovery_checkpoint(1_000, 1_800);
    let after = recovery_checkpoint(550, 900);
    let mut vault = issue_and_activate(&mut fixture, before);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    vault.set_fees(&fixture.protocol, &risk_admin(), 0, 0, 0);
    replay.replay_fees(events::collect_one<events::FeesUpdated<Product>>(0));
    let supply_before = vault.total_share_supply();
    let reserve_before = vault.state().maintenance_reserve();
    let deficit_before = vault.state().uncovered_deficit();
    vault.apply_post_capture_for_testing(after, before.classify_preexisting(&after));
    replay.replay_drift(events::collect_one<events::CheckpointDrifted<Product>>(0));
    replay.assert_replay(&vault);
    assert_eq!(*vault.venue().checkpoint(), before);

    fixture.recover(&mut vault, after, 550, 900, true, true, REFERENCE_AT_MS);
    let (id, recorded_before, recorded_after) =
        events::collect_one<events::CheckpointRebaselined<Product>>(0).checkpoint_rebaselined_fields();
    assert_eq!(id, vault.id());
    assert_eq!(recorded_before, before);
    assert_eq!(recorded_after, after);
    assert_eq!(*vault.venue().checkpoint(), recorded_after);
    replay.replay_rebaseline(events::collect_one<events::CheckpointRebaselined<Product>>(0));
    replay.assert_replay(&vault);
    assert!(replay.unresolved_checkpoint.is_none());
    assert_eq!(vault.total_share_supply(), supply_before);
    assert_eq!(vault.state().maintenance_reserve(), reserve_before);
    assert_eq!(vault.state().uncovered_deficit(), deficit_before);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert!(vault.state().is_active_for_testing());
    assert!(events::collect<events::FundingSettled<Product>>().is_empty());
    assert!(events::collect<events::CheckpointRebaselined<OtherProduct>>().is_empty());
    // Ordinary synchronization now accepts this checkpoint. At half the old
    // holder NAV, an equal-sized deposit receives twice as many shares.
    vault.venue().checkpoint().assert_unchanged(&after);
    let plan = vault.state().prepare_mint(active_position(550, 900), 450, supply_before, supply_before, 10, REFERENCE_AT_MS);
    assert_eq!(plan.base_to_buy(), 900 * BASE_PER_NOTIONAL);
    let shares = vault.complete_mint_for_testing(plan, 450, active_position(1_000, 1_800),
        recovery_checkpoint(1_000, 1_800), REFERENCE_AT_MS, fixture.ctx!());
    assert_eq!(shares.value(), supply_before);
    let plan = vault.state().prepare_redemption(active_position(1_000, 1_800), shares.value(),
        vault.total_share_supply(), 450, REFERENCE_AT_MS);
    assert_eq!(plan.base_to_sell(), 900 * BASE_PER_NOTIONAL);
    let (net, admin, fee, reserve_fee) = vault.settle_redemption_for_testing(
        plan, &shares, active_position(1_000, 900), REFERENCE_AT_MS,
    );
    assert_eq!(net, 450);
    let cash = sui::coin::mint_for_testing<Collateral>(net + admin, fixture.ctx!());
    let cash = vault.complete_redemption_for_testing(shares, cash, net, admin, fee, reserve_fee, after, fixture.ctx!());
    assert_eq!(cash.value(), 450);
    assert_eq!(vault.total_share_supply(), supply_before);
    assert_eq!(*vault.venue().checkpoint(), recorded_after);
    destroy(cash);
    destroy(vault);
    fixture.end();
}

#[test]
fun short_rebaseline_after_full_close() {
    recover_short(0);
}

#[test]
fun short_rebaseline_after_partial_close() {
    recover_short(900);
}

#[test]
fun rebaseline_allows_rebalance_after_full_close() {
    recover_and_rebalance(0);
}

#[test]
fun rebaseline_allows_rebalance_after_partial_close() {
    recover_and_rebalance(600);
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::checkpoint)]
fun ordinary_operations_still_reject_a_forced_reduction_before_rebaseline() {
    let mut fixture = start();
    let before = recovery_checkpoint(1_000, 1_800);
    let after = recovery_checkpoint(550, 900);
    let mut vault = issue_and_activate(&mut fixture, before);
    vault.apply_post_capture_for_testing(after, before.classify_preexisting(&after));
    vault.venue().checkpoint().assert_unchanged(&after);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun rebaseline_cannot_replay_an_already_accepted_reduction() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    let after = recovery_checkpoint(550, 900);
    fixture.recover(&mut vault, after, 550, 900, true, true, REFERENCE_AT_MS);
    fixture.recover(&mut vault, after, 550, 900, true, true, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
fun rebaseline_records_reduction_without_opening_margin() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));

    fixture.recover(&mut vault, recovery_checkpoint(550, 900), 550, 900, false, true, REFERENCE_AT_MS);
    assert_eq!(*vault.venue().checkpoint(), recovery_checkpoint(550, 900));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun rebaseline_does_not_remove_opening_margin_checks_from_trades() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    let after = recovery_checkpoint(550, 900);
    fixture.recover(&mut vault, after, 550, 900, false, true, REFERENCE_AT_MS);
    let (_, _) = snapshot::captured_position_for_testing(after, 550, 900 * BASE_PER_NOTIONAL,
        policy::long(), false, true).into_observation();
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun rebaseline_checks_shape_before_venue_readiness() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    fixture.recover(&mut vault, recovery_checkpoint(550, 1_800), 550, 1_800, false, false, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
fun rebaseline_allows_emergency_reduction_of_remaining_position() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    fixture.recover(&mut vault, recovery_checkpoint(550, 1_700), 550, 1_700, true, true, REFERENCE_AT_MS);
    let mut plan = vault.state().prepare_rebalance(active_position(550, 1_700), 0, REFERENCE_AT_MS);
    let order = vault.state().next_rebalance_order(&plan);
    assert!(order.is_emergency() && !order.is_increase());
    let filled = order.order_base();
    assert!(filled > 0);
    let after_base = 1_700 * BASE_PER_NOTIONAL - filled;
    vault.state().accept_rebalance_fill(&mut plan, order, active_position_with_base(550, after_base), filled, REFERENCE_AT_MS);
    vault.complete_rebalance_for_testing(plan, recovery_checkpoint_with_base(550, after_base));
    assert_eq!(*vault.venue().checkpoint(), recovery_checkpoint_with_base(550, after_base));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun rebaseline_does_not_allow_minting_while_remaining_position_is_overleveraged() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    fixture.recover(&mut vault, recovery_checkpoint(550, 1_700), 550, 1_700, true, true, REFERENCE_AT_MS);
    let plan = vault.state().prepare_mint(active_position(550, 1_700), 450,
        vault.total_share_supply(), 1, 10, REFERENCE_AT_MS);
    destroy(plan);
    destroy(vault);
    fixture.end();
}

#[test]
fun rebaseline_accepts_realized_profit_without_creating_a_funding_entitlement() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    let supply = vault.total_share_supply();
    fixture.recover(&mut vault, recovery_checkpoint(1_100, 900), 1_100, 900, true, true, REFERENCE_AT_MS);
    assert_eq!(*vault.venue().checkpoint(), recovery_checkpoint(1_100, 900));
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(vault.state().uncovered_deficit(), 0);
    assert_eq!(vault.total_share_supply(), supply);
    assert!(events::collect<events::FundingSettled<Product>>().is_empty());
    destroy(vault);
    fixture.end();
}

#[test]
fun rebaseline_isolates_local_funding_cost_from_historical_loss() {
    recover_with_funding(true, 50, false, false);
}

#[test]
fun rebaseline_books_uncovered_local_funding_cost() {
    recover_with_funding(true, 150, false, false);
}

#[test]
fun rebaseline_isolates_local_funding_credit_from_historical_loss() {
    recover_with_funding(false, 50, false, false);
}

#[test]
fun rebaseline_local_funding_credit_restores_an_existing_deficit() {
    recover_with_funding(false, 75, true, false);
}

#[test]
fun short_rebaseline_books_local_funding_cost_from_the_short_rate() {
    recover_with_funding(true, 50, false, true);
}

#[test]
fun short_rebaseline_books_local_funding_credit_from_the_short_rate() {
    recover_with_funding(false, 50, false, true);
}

#[test]
fun flat_rebaseline_replays_locally_refreshed_snapshots_with_zero_funding() {
    let mut fixture = start();
    let previous = recovery_checkpoint(1_000, 1_800);
    let mut vault = issue_and_activate(&mut fixture, previous);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    let market_long = RATE + ONE_FIXED / 20;
    let market_short = RATE + ONE_FIXED / 10;
    let before_checkpoint = checkpoint::checkpoint_for_testing(0, 550 * ATOM_FIXED, 0, 0,
        RATE, RATE, market_long, market_short, LOT_SIZE, 0, 0, 0, 0, false, 1, 1, 1);
    let after_checkpoint = checkpoint::checkpoint_for_testing(0, 550 * ATOM_FIXED, 0, 0,
        market_long, market_short, market_long, market_short, LOT_SIZE, 0, 0, 0, 0, false, 1, 1, 1);
    let before = snapshot::captured_position_for_testing(before_checkpoint, 550, 0, policy::long(), true, true);
    let after = snapshot::captured_position_for_testing(after_checkpoint, 550, 0, policy::long(), true, true);
    vault.rebaseline_from_captures_for_testing(&fixture.protocol, &risk_admin(), before, after, REFERENCE_AT_MS);

    replay.replay_rebaseline(events::collect_one<events::CheckpointRebaselined<Product>>(0));
    assert_eq!(*replay.checkpoint.borrow(), before_checkpoint);
    let funding = events::collect_one<events::FundingSettled<Product>>(0);
    let (_, is_cost, raw, amount, absorbed, uncovered, restored, reserve, event_before, event_after) =
        funding.funding_settled_fields();
    assert!(!is_cost);
    assert_eq!(raw, 0);
    assert_eq!(vector[amount, absorbed, uncovered, restored, reserve], vector[0, 0, 0, 0, SEED_RESERVE]);
    assert_eq!(event_before, before_checkpoint);
    assert_eq!(event_after, after_checkpoint);
    replay.replay_funding(funding);
    replay.assert_replay(&vault);
    assert_eq!(*vault.venue().checkpoint(), after_checkpoint);
    assert_eq!(vault.state().uncovered_deficit(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::operations)]
fun rebaseline_rejects_an_unexplained_change_during_its_own_funding_settlement() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    let market = RATE + ONE_FIXED / 20;
    let before = funding_recovery_capture(550, RATE, market, false);
    // The remaining 0.001 base owes 50 collateral atoms, not 49.
    let after = funding_recovery_capture(501, market, market, false);
    vault.rebaseline_from_captures_for_testing(&fixture.protocol, &risk_admin(), before, after, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EVenueNotReady, location = blast_boosts_aftermath::snapshot)]
fun rebaseline_rejects_paused_or_frozen_market() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));

    fixture.recover(&mut vault, recovery_checkpoint(550, 900), 550, 900, true, false, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EInvalidNav, location = blast_boosts_core::state)]
fun rebaseline_rejects_nonpositive_holder_nav() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));

    fixture.recover(&mut vault, recovery_checkpoint(100, 900), 100, 900, true, true, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EStalePrice, location = blast_boosts_core::policy)]
fun rebaseline_rejects_stale_prices() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));

    fixture.recover(&mut vault, recovery_checkpoint(550, 900), 550, 900, true, true, REFERENCE_AT_MS + 30_001);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun rebaseline_rejects_shutdown() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    vault.set_unwinding_for_testing();
    fixture.recover(&mut vault, recovery_checkpoint(550, 900), 550, 900, true, true, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun rebaseline_rejects_wrong_version_before_lifecycle_or_capture() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    fixture.protocol.set_version_for_testing(3);
    vault.set_unwinding_for_testing();
    fixture.recover(&mut vault, recovery_checkpoint(100, 900), 100, 900, false, false, REFERENCE_AT_MS + 30_001);
    destroy(vault);
    fixture.end();
}

#[test]
fun order_filled_event_carries_every_fill_fact_in_order() {
    let account = object::id_from_address(@0xA11);
    events::order_filled<Product>(account, true, false, 2_500_000_000_000, 2_400_000_000_000,
        4_800_000_000_000_000_000_000, 2_000_000_000, 1_990_000_000, 2_004_000_000);
    let (id, is_ask, reduce_only, requested, filled, quote, reference, limit, executed) =
        events::collect_one<events::OrderFilled<Product>>(0).order_filled_fields();
    assert_eq!(id, account);
    assert_eq!(vector[is_ask, reduce_only], vector[true, false]);
    assert_eq!(vector[requested, filled], vector[2_500_000_000_000, 2_400_000_000_000]);
    assert_eq!(quote, 4_800_000_000_000_000_000_000);
    assert_eq!(vector[reference, limit, executed], vector[2_000_000_000, 1_990_000_000, 2_004_000_000]);
    assert!(events::collect<events::OrderFilled<OtherProduct>>().is_empty());
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun terminal_claim_checks_version_before_lifecycle_or_zero_shares() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.protocol.set_version_for_testing(3);
    let shares = vault.mint_shares(0, fixture.ctx!());
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    destroy(vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!()));
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun shutdown_checks_version_before_an_authorized_transition() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.protocol.set_version_for_testing(3);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EDeadlineExpired, location = blast_boosts_aftermath::vault)]
fun expired_terminal_claim_cannot_burn_shares_or_pay_cash() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let shares = vault.mint_shares(5, fixture.ctx!());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    let mut clock = sui::clock::create_for_testing(fixture.ctx!());
    clock.set_for_testing(1);
    destroy(vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!()));
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
fun unwind_partial_budget_then_retry_uses_actual_remaining_exposure_for_both_sides() {
    // Controlled fill ports exercise the exact production sizing and fill guards.
    // They do not execute the external venue or prove submitted transaction effects.
    vector[false, true].do!(|is_bid| {
        let mut remaining = 2_500_000;
        let mut order_count = 0;
        while (order_count < 16) {
            let requested = orders::active_order_size_for_testing(remaining, 250_000, 1, order_count);
            assert_eq!(requested, 250_000);
            let raw = 125_000_000_000_000;
            let filled = orders::active_fill_for_testing(is_bid, requested, 1,
                if (is_bid) { raw } else { 0 }, if (is_bid) { 0 } else { raw }, 0, 0, 0);
            remaining = remaining - filled;
            order_count = order_count + 1;
        };
        assert_eq!(remaining, 500_000);
        // A new successful call starts a fresh bounded budget, not a stale original target.
        let mut retry_orders = 0;
        while (remaining > 0) {
            let requested = orders::active_order_size_for_testing(remaining, 250_000, 1, retry_orders);
            let raw = (requested as u256) * 1_000_000_000;
            let filled = orders::active_fill_for_testing(is_bid, requested, 1,
                if (is_bid) { raw } else { 0 }, if (is_bid) { 0 } else { raw }, 0, 0, 0);
            remaining = remaining - filled;
            retry_orders = retry_orders + 1;
        };
        assert_eq!(retry_orders, 2);
    });
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun unwind_failed_middle_fill_aborts_the_current_atomic_call() {
    let first = orders::active_fill_for_testing(false, 250_000, 1, 0, 125_000_000_000_000, 0, 0, 0);
    assert_eq!(first, 125_000);
    orders::active_fill_for_testing(false, 250_000, 1, 0, 0, 0, 0, 0);
}

#[test]
fun short_terminal_claims_allow_changed_order_and_split_merge_without_fees() {
    let mut fixture = start();
    let mut vault = issue_and_activate_product_with_side(&mut fixture, OtherProduct(), initial_checkpoint(),
        standard_vault_policy_for_side(policy::short()), policy::short());
    let locked = vault.total_share_supply();
    let mut shares = vault.mint_shares(5, fixture.ctx!());
    let first = shares.split(3, fixture.ctx!());
    let split = shares.split(1, fixture.ctx!());
    shares.join(split);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_out = vault.redeem_shutdown<OtherProduct, Collateral>(&fixture.protocol, first, 7, 0, &clock, fixture.ctx!());
    let last_out = vault.redeem_shutdown<OtherProduct, Collateral>(&fixture.protocol, shares, 6, 0, &clock, fixture.ctx!());
    assert_eq!(vector[first_out.value(), last_out.value()], vector[7, 6]);
    assert_eq!(vault.total_share_supply(), locked);
    assert_eq!(vault.terminal_cash_for_testing<OtherProduct, Collateral>(), 0);
    let claims = events::collect<events::ShutdownRedeemed<OtherProduct>>();
    assert_eq!(claims.length(), 2);
    let (_, burned, paid, cash, eligible) = claims[1].shutdown_redeemed_fields();
    assert_eq!(vector[burned, paid, cash, eligible], vector[2, 6, 0, 0]);
    destroy(first_out);
    destroy(last_out);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
fun long_terminal_event_reducer_reconstructs_cash_native_supply_and_reconciliation() {
    replay_terminal_lifecycle(Product(), policy::long());
}

#[test]
fun short_terminal_event_reducer_reconstructs_cash_native_supply_and_reconciliation() {
    replay_terminal_lifecycle(OtherProduct(), policy::short());
}

#[test]
fun terminal_zero_cash_burns_native_shares_and_returns_composable_zero_coin() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let locked = vault.total_share_supply();
    let mut shares = vault.mint_shares(5, fixture.ctx!());
    let split = shares.split(2, fixture.ctx!());
    shares.join(split);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    vault.finalize_recovered(sui::coin::zero<Collateral>(fixture.ctx!()));
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let output = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!());
    assert_eq!(output.value(), 0);
    output.destroy_zero();
    assert_eq!(vault.total_share_supply(), locked);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun shutdown_is_irreversible_even_for_the_same_authorized_witness() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun finalization_cannot_recover_terminal_cash_twice() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    destroy(vault);
    fixture.end();
}

#[test]
fun a4_direct_funding_uses_the_held_side_and_rounds_like_the_venue() {
    // Different rates on each side expose selection errors. One raw base unit
    // times a one-unit rate difference at price 2 has magnitude 1/2 raw unit.
    // The venue rounds that cost up to 1, and that credit down to zero.
    vector[false, true].do!(|short| {
        vector[false, true].do!(|cost| {
            let base = a4_signed(1, short);
            let held_rate = a4_signed(1, short == cost);
            let (long_rate, short_rate) = if (short) { (100, held_rate) } else { (held_rate, 100) };
            let before = checkpoint::checkpoint_for_testing(0, ATOM_FIXED, base, base,
                0, 0, long_rate, short_rate, LOT_SIZE, 0, 0, 0, 1, false, 1, 1, 1);
            let after = checkpoint::checkpoint_for_testing(0, 0, 0, 0,
                long_rate, short_rate, long_rate, short_rate, LOT_SIZE, 0, 0, 0, 1, false, 1, 1, 1);
            let change = before.direct_settlement_funding(&after, 2);
            assert!(change.is_clean());
            assert_eq!(change.is_cost(), cost);
            assert_eq!(change.raw_amount(), if (cost) { 1 } else { 0 });
            assert_eq!(change.amount(), if (cost) { 1 } else { 0 });
        });
    });
}

#[test]
fun a4_long_credit_one_atom_uses_settlement_price() {
    a4_book_close(false, false, 1, false, 990);
}

#[test]
fun a4_long_credit_above_reserve_uses_settlement_price() {
    a4_book_close(false, false, 150, false, 990);
}

#[test]
fun a4_long_credit_with_uncovered_deficit_uses_settlement_price() {
    a4_book_close(false, false, 10, true, 990);
}

#[test]
fun a4_long_credit_beyond_deficit_uses_settlement_price() {
    a4_book_close(false, false, 150, true, 990);
}

#[test]
fun a4_long_cost_one_atom_uses_settlement_price() {
    a4_book_close(false, true, 1, false, 990);
}

#[test]
fun a4_long_cost_above_reserve_uses_settlement_price() {
    a4_book_close(false, true, 150, false, 990);
}

#[test]
fun a4_long_cost_with_uncovered_deficit_uses_settlement_price() {
    a4_book_close(false, true, 10, true, 990);
}

#[test]
fun a4_long_cost_beyond_deficit_uses_settlement_price() {
    a4_book_close(false, true, 150, true, 990);
}

#[test]
fun a4_short_credit_one_atom_uses_settlement_price() {
    a4_book_close(true, false, 1, false, 990);
}

#[test]
fun a4_short_credit_above_reserve_uses_settlement_price() {
    a4_book_close(true, false, 150, false, 990);
}

#[test]
fun a4_short_credit_with_uncovered_deficit_uses_settlement_price() {
    a4_book_close(true, false, 10, true, 990);
}

#[test]
fun a4_short_credit_beyond_deficit_uses_settlement_price() {
    a4_book_close(true, false, 150, true, 990);
}

#[test]
fun a4_short_cost_one_atom_uses_settlement_price() {
    a4_book_close(true, true, 1, false, 990);
}

#[test]
fun a4_short_cost_above_reserve_uses_settlement_price() {
    a4_book_close(true, true, 150, false, 990);
}

#[test]
fun a4_short_cost_with_uncovered_deficit_uses_settlement_price() {
    a4_book_close(true, true, 10, true, 990);
}

#[test]
fun a4_short_cost_beyond_deficit_uses_settlement_price() {
    a4_book_close(true, true, 150, true, 990);
}

#[test]
fun a4_insurance_exhaustion_is_not_counted_as_funding() {
    a4_book_close(false, true, 10, false, 0);
}

#[test]
fun a4_trading_loss_is_not_counted_as_funding() {
    a4_book_close(false, true, 10, false, 890);
}

#[test]
fun a4_trading_profit_is_not_counted_as_funding() {
    a4_book_close(false, true, 10, false, 1090);
}

#[test]
fun a4_zero_funding_still_records_the_completed_close() {
    a4_book_close(false, false, 0, false, 1000);
}

#[test]
fun a4_prior_credit_and_closing_funding_net_one_atom() {
    a4_net_close(false, 3 * ATOM_FIXED / 2, ATOM_FIXED / 2);
}

#[test]
fun a4_prior_credit_and_closing_funding_cancel_before_rounding() {
    a4_net_close(false, 3 * ATOM_FIXED / 2, 3 * ATOM_FIXED / 2);
}

#[test]
fun a4_prior_credit_and_closing_funding_opposite_net() {
    a4_net_close(false, ATOM_FIXED / 2, 3 * ATOM_FIXED / 2);
}

#[test]
fun a4_prior_credit_and_closing_funding_one_raw_remainder() {
    a4_net_close(false, ATOM_FIXED + 1, ATOM_FIXED);
}

#[test]
fun a4_prior_credit_and_closing_funding_opposite_raw_remainder() {
    a4_net_close(false, ATOM_FIXED, ATOM_FIXED + 1);
}

#[test]
fun a4_prior_cost_and_closing_funding_net_one_atom() {
    a4_net_close(true, 3 * ATOM_FIXED / 2, ATOM_FIXED / 2);
}

#[test]
fun a4_prior_cost_and_closing_funding_cancel_before_rounding() {
    a4_net_close(true, 3 * ATOM_FIXED / 2, 3 * ATOM_FIXED / 2);
}

#[test]
fun a4_prior_cost_and_closing_funding_opposite_net() {
    a4_net_close(true, ATOM_FIXED / 2, 3 * ATOM_FIXED / 2);
}

#[test]
fun a4_prior_cost_and_closing_funding_one_raw_remainder() {
    a4_net_close(true, ATOM_FIXED + 1, ATOM_FIXED);
}

#[test]
fun a4_prior_cost_and_closing_funding_opposite_raw_remainder() {
    a4_net_close(true, ATOM_FIXED, ATOM_FIXED + 1);
}

#[test]
fun a4_unrepresentable_gross_funding_can_cancel_before_conversion() {
    let gross = ((std::u64::max_value!() as u256) + 1) * ATOM_FIXED;
    a4_net_close(false, gross, gross);
}

#[test]
fun a4_unknown_history_still_exits_and_books_only_proven_closing_funding() {
    let mut fixture = start();
    let stored = a4_checkpoint(ONE_FIXED, ALLOCATED_FIXED, 0, 0, 0);
    let market = 40 * ATOM_FIXED;
    let before = a4_checkpoint(ONE_FIXED / 2, 500 * ATOM_FIXED, 0, market, 0);
    let after = a4_checkpoint(0, 0, market, market, 490);
    let mut vault = issue_and_begin_shutdown(&mut fixture, stored);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    replay.replay_shutdown(events::collect_one<events::ShutdownBegun<Product>>(0));

    vault.complete_settlement_unwind_for_testing(before, after, 2 * ONE_FIXED);

    let drift = events::collect_one<events::CheckpointDrifted<Product>>(0);
    let (id, observed) = drift.checkpoint_drifted_fields();
    assert_eq!(id, vault.id());
    assert_eq!(observed, before);
    replay.replay_drift(drift);
    let funding = events::collect_one<events::FundingSettled<Product>>(0);
    let (_, _, raw, amount, _, _, _, reserve, previous, checkpoint) = funding.funding_settled_fields();
    assert_eq!(raw, 10 * ATOM_FIXED);
    assert_eq!(vector[amount, reserve], vector[10, 90]);
    assert_eq!(previous, before);
    assert_eq!(checkpoint, after);
    replay.replay_funding(funding);
    replay.assert_replay(&vault);
    assert_eq!(*vault.venue().checkpoint(), after);
    destroy(vault);
    fixture.end();
}

#[test]
fun a4_protected_long_credit_keeps_starter_cash_locked() {
    a4_protected_close(false, false);
}

#[test]
fun a4_protected_long_cost_keeps_starter_cash_locked() {
    a4_protected_close(false, true);
}

#[test]
fun a4_protected_short_credit_keeps_starter_cash_locked() {
    a4_protected_close(true, false);
}

#[test]
fun a4_protected_short_cost_keeps_starter_cash_locked() {
    a4_protected_close(true, true);
}

#[test]
fun a4_flat_collateral_release_does_not_create_funding() {
    let mut fixture = start();
    let before = a4_checkpoint(0, ALLOCATED_FIXED, 0, ONE_FIXED, 0);
    let after = a4_checkpoint(0, 0, ONE_FIXED, ONE_FIXED, 1_000);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    let (_, _, raw, amount, _, _, _, reserve, _, _) =
        events::collect_one<events::FundingSettled<Product>>(0).funding_settled_fields();
    assert_eq!(raw, 0);
    assert_eq!(vector[amount, reserve], vector[0, SEED_RESERVE]);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun a4_repeated_settlement_cannot_book_funding_twice() {
    let mut fixture = start();
    let before = closed_checkpoint();
    let after = settled_flat_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    vault.complete_settlement_unwind_for_testing(after, after, ONE_FIXED);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun a4_invalid_settlement_price_is_rejected_before_any_accounting() {
    let mut fixture = start();
    let before = closed_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, settled_flat_checkpoint(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun a4_unrefreshed_funding_snapshot_cannot_be_booked() {
    let mut fixture = start();
    let before = a4_checkpoint(ONE_FIXED, ALLOCATED_FIXED, 0, ATOM_FIXED, 0);
    let after = a4_checkpoint(0, 0, 0, ATOM_FIXED, 999);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::operations)]
fun a4_unrepresentable_net_funding_is_not_silently_skipped() {
    let mut fixture = start();
    let market = ((std::u64::max_value!() as u256) + 1) * ATOM_FIXED;
    let before = a4_checkpoint(ONE_FIXED, ALLOCATED_FIXED, 0, market, 0);
    let after = a4_checkpoint(0, 0, market, market, 0);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun a4_closing_accounting_requires_shutdown_before_venue_validation() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, before, 0);
    destroy(vault);
    fixture.end();
}

#[test]
fun a4_direct_settlement_books_the_funding_cost_before_adopting_the_close() {
    let mut fixture = start();
    let market = RATE + 10 * ATOM_FIXED;
    let before = checkpoint::checkpoint_for_testing(0, ALLOCATED_FIXED, ONE_FIXED, ONE_FIXED,
        RATE, RATE, market, market, LOT_SIZE, 0, 0, 0, 1, false, 1, 1, 1);
    let after = checkpoint::checkpoint_for_testing(990, 0, 0, 0,
        market, market, market, market, LOT_SIZE, 0, 0, 0, 1, false, 1, 1, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    assert_eq!(vault.state().maintenance_reserve(), 90);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_direct_settlement_reports_actual_cash_and_no_market_order() {
    let mut fixture = start();
    let before = checkpoint::checkpoint_for_testing(0, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1);
    let after = checkpoint::checkpoint_for_testing(5, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1);
    let mut vault = issue_and_activate(&mut fixture, before);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    let event = events::collect_one<events::UnwindProgress<Product>>(0);
    let (id, observed, actual, orders, quote) = event.unwind_progress_fields();
    assert_eq!(id, vault.id());
    assert_eq!(observed, before);
    assert_eq!(actual, after);
    assert_eq!(orders, 0);
    assert!(quote.is_none());
    assert_eq!(*vault.venue().checkpoint(), after);
    assert!(vault.is_unwinding_for_testing());
    destroy(vault);
    fixture.end();
}

#[test]
fun unwind_normalization_keeps_exact_positive_whole_lots_in_both_directions() {
    assert_eq!(orders::unwind_base_for_testing(1_800_000_000_000, true, 1, policy::long()), 1_800);
    assert_eq!(orders::unwind_base_for_testing(1_800_000_000_000, false, 1, policy::short()), 1_800);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun unwind_normalization_rejects_a_forced_opposite_direction() {
    orders::unwind_base_for_testing(1_800_000_000_000, false, 1, policy::long());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun ordinary_unwind_never_rounds_raw_base_dust_to_a_whole_lot() {
    orders::unwind_base_for_testing(1_800_000_000_001, true, 1, policy::long());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun unwind_normalization_rejects_a_flat_position() {
    orders::unwind_base_for_testing(0, true, 1, policy::long());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun unwind_normalization_rejects_a_zero_lot() {
    orders::unwind_base_for_testing(1_800_000_000_000, true, 0, policy::long());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun unwind_normalization_rejects_a_fractional_lot() {
    orders::unwind_base_for_testing(1_805_000_000_000, true, 10, policy::long());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun unwind_normalization_rejects_a_long_position_on_a_short_vault() {
    orders::unwind_base_for_testing(1_800_000_000_000, true, 1, policy::short());
}

#[test]
fun unwind_normalization_accepts_the_largest_representable_base() {
    let max = std::u64::max_value!();
    assert_eq!(orders::unwind_base_for_testing((max as u256) * 1_000_000_000, true, 1, policy::long()), max);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUnwindExposure, location = blast_boosts_aftermath::orders)]
fun unwind_normalization_rejects_a_base_beyond_u64_atoms() {
    orders::unwind_base_for_testing(((std::u64::max_value!() as u256) + 1) * 1_000_000_000, true, 1, policy::long());
}

#[test]
fun insolvent_capture_still_supplies_fresh_close_only_valuation() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let captured = snapshot::captured_health_for_testing(initial_checkpoint(), 0, false, 0, true, true);
    let base = captured.base_price_observation();
    let collateral = captured.collateral_price_observation();
    let (side, max_order_base, base_price, collateral_price, bound) =
        vault.state().unwind_constraints(base, collateral, LOT_SIZE, REFERENCE_AT_MS);
    assert_eq!(side, policy::long());
    assert_eq!(vector[max_order_base, base_price, collateral_price], vector[247_524, PRICE, PRICE]);
    assert_eq!(bound.slippage_bps(), 100);
    destroy(vault);
    fixture.end();
}

#[test]
fun terminal_claims_exclude_locked_seed_burn_native_shares_and_give_last_claimant_dust() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let locked = vault.total_share_supply();
    let mut shares = vault.mint_shares(5, fixture.ctx!());
    let first = shares.split(2, fixture.ctx!());
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(7));
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
    vault.finalize_recovered(recovered);
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_out = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, first, 5, 0, &clock, fixture.ctx!());
    assert_eq!(first_out.value(), 5);
    let last_out = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 8, 0, &clock, fixture.ctx!());
    assert_eq!(last_out.value(), 8);
    assert_eq!(vault.total_share_supply(), locked);
    assert_eq!(vault.state().maintenance_reserve(), 0);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 7);
    let finalization = events::collect_one<events::ShutdownFinalized<Product>>(0);
    let (_, recovered, eligible, checkpoint, remainder, reserve_cash, seed_cash) = finalization.shutdown_finalized_fields();
    assert_eq!(vector[reserve_cash, seed_cash], vector[0, 0]);
    assert_eq!(remainder, 0);
    assert_eq!(recovered, 13);
    assert_eq!(eligible, 5);
    assert_eq!(checkpoint, terminal_checkpoint());
    let claims = events::collect<events::ShutdownRedeemed<Product>>();
    assert_eq!(claims.length(), 2);
    let (_, burned, paid, remaining_cash, remaining_supply) = claims[0].shutdown_redeemed_fields();
    assert_eq!(vector[burned, paid, remaining_cash, remaining_supply], vector[2, 5, 8, 3]);
    let (_, burned, paid, remaining_cash, remaining_supply) = claims[1].shutdown_redeemed_fields();
    assert_eq!(vector[burned, paid, remaining_cash, remaining_supply], vector[3, 8, 0, 0]);
    destroy(first_out);
    destroy(last_out);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
fun zero_eligible_supply_keeps_all_terminal_cash_as_admin_cash() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::observed_venue_change_reason());
    fixture.next_tx!(@0xBEEF, |fixture| {
        let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
        vault.finalize_recovered(recovered);
        assert_eq!(vault.state().maintenance_reserve(), 0);
        let (_, cash, eligible, _, remainder, reserve_cash, seed_cash) = events::collect_one<events::ShutdownFinalized<Product>>(0).shutdown_finalized_fields();
        assert_eq!(vector[reserve_cash, seed_cash], vector[0, 0]);
        assert_eq!(remainder, 0);
        assert_eq!(vector[cash, eligible], vector[13, 0]);
        assert_eq!(vault.admin_cash_balance<_, Collateral>(), 13);
        assert_eq!(vault.terminal_cash_for_testing<_, Collateral>(), 0);
        destroy(vault);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun terminal_claim_before_shutdown_rejects_lifecycle_before_missing_cash_field() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let shares = vault.mint_shares(5, fixture.ctx!());
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    destroy(vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!()));
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun finalization_rejects_a_short_actual_coin_even_when_the_venue_is_empty() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let before = checkpoint::checkpoint_for_testing(13, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(12, fixture.ctx!());
    before.assert_terminal_withdrawal_checkpoint(&terminal_checkpoint(), recovered.value());
    vault.complete_finalization_for_testing(terminal_checkpoint(), recovered);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun finalization_rejects_a_short_actual_coin_with_exact_sub_atomic_remainder() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let before = checkpoint::checkpoint_for_testing(12, 1_000_000_000_001, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let after = checkpoint::checkpoint_for_testing(0, 1, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(12, fixture.ctx!());
    before.assert_terminal_withdrawal_checkpoint_decoded_for_testing(&after, recovered.value(), false, 1_000_000_000_001);
    vault.complete_finalization_for_testing(after, recovered);
    destroy(vault);
    fixture.end();
}

#[test]
fun event_reducer_reconstructs_active_economics_for_two_product_types() {
    let mut fixture = start();
    let vault_policy = fee_capped_vault_policy_for_side(policy::long());
    let mut first = issue_and_activate_product(&mut fixture, Product(), initial_checkpoint(), vault_policy);
    let mut second = issue_and_activate_product(&mut fixture, OtherProduct(), initial_checkpoint(), vault_policy);
    assert!(first.id() != second.id());
    fixture.replay_active_economics(&mut first);
    fixture.replay_active_economics(&mut second);
    assert_eq!(events::collect<events::Minted<Product>>().length(), 1);
    assert_eq!(events::collect<events::Minted<OtherProduct>>().length(), 1);
    assert_eq!(events::collect<events::Redeemed<Product>>().length(), 1);
    assert_eq!(events::collect<events::Redeemed<OtherProduct>>().length(), 1);
    assert_eq!(events::collect<events::Rebalanced<Product>>().length(), 1);
    assert_eq!(events::collect<events::Rebalanced<OtherProduct>>().length(), 1);
    assert_eq!(events::collect<events::PartnerFeePaid<Product>>().length(), 2);
    assert_eq!(events::collect<events::PartnerFeePaid<OtherProduct>>().length(), 2);
    destroy(first);
    destroy(second);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EZeroAmount, location = blast_boosts_aftermath::vault)]
fun zero_admin_withdrawal_fails_before_empty_cash_lookup() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = risk_admin();
    let cash = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 0, fixture.ctx!());
    destroy(cash);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::ERedemptionShareMismatch, location = blast_boosts_aftermath::operations)]
fun mismatched_native_shares_fail_before_unwind_validation() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let shares = sui::coin::mint_for_testing<BlastBoost<Product>>(100_000, fixture.ctx!());
    let plan = vault.state().prepare_redemption(position_observation(SEED_EQUITY), shares.value(), vault.total_share_supply(), 1, REFERENCE_AT_MS);
    destroy(shares);
    let wrong_shares = sui::coin::mint_for_testing<BlastBoost<Product>>(99_999, fixture.ctx!());
    vault.settle_redemption_for_testing(plan, &wrong_shares, position_observation(SEED_EQUITY), REFERENCE_AT_MS);
    destroy(wrong_shares);
    destroy(vault);
    fixture.end();
}

#[test]
fun native_fee_allocations_preserve_historical_cash_through_redemption_and_rate_change() {
    let mut fixture = start();
    let mut vault = issue_and_activate_with_policy(&mut fixture, initial_checkpoint(),
        fee_capped_vault_policy_for_side(policy::long()));
    let witness = risk_admin();
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 10_000, vault.total_share_supply(), 9_989_000, 10, REFERENCE_AT_MS);
    assert_eq!(plan.admin_fee(), 2);
    assert_eq!(plan.base_to_buy(), 19_980_000);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(2));
    let shares = vault.complete_mint_for_testing<Product, Collateral>(
        plan, 10_000, active_position(10_997, 21_780), initial_checkpoint(), REFERENCE_AT_MS, fixture.ctx!(),
    );
    let (_, minted, contribution, fee, admin, buffer, reserve, cash, supply) =
        events::collect_one<events::Minted<Product>>(0).minted_amounts();
    assert_eq!(vector[minted, contribution, fee, admin, buffer, reserve, cash, supply],
        vector[9_989_000, 9_989, 10, 2, 8, 108, 2, 10_889_000]);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    let plan = vault.state().prepare_redemption(active_position(10_997, 21_780), shares.value(), vault.total_share_supply(), 9_978, REFERENCE_AT_MS);
    // 21_780_000 less the floor of its 900_000 / 10_889_000 share, to the atom.
    assert_eq!(plan.base_to_sell(), 19_979_835);
    let (net, admin, fee, reserve_fee) = vault.settle_redemption_for_testing(
        plan, &shares,
        active_position_with_base(10_996, 1_800_165), REFERENCE_AT_MS);
    assert_eq!(net + admin, 9_980);
    let cash = sui::coin::mint_for_testing<Collateral>(9_980, fixture.ctx!());
    let cash = vault.complete_redemption_for_testing(shares, cash, net, admin, fee, reserve_fee, initial_checkpoint(), fixture.ctx!());
    assert_eq!(cash.value(), 9_978);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.state().maintenance_reserve(), 116);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 4);
    assert_eq!(events::collect_one<events::Redeemed<Product>>(0).redeemed_amounts(),
        vector[9_989_000, 9_978, 10, 2, 8, 116, 4, 900_000]);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 4);
    assert_eq!(vault.state().maintenance_reserve(), 116);
    let earnings = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 4, fixture.ctx!());
    assert_eq!(earnings.value(), 4);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(vault.state().maintenance_reserve(), 116);
    assert_eq!(vault.total_share_supply(), 900_000);
    sui::transfer::public_transfer(cash, ADMIN);
    sui::transfer::public_transfer(earnings, ADMIN);
    destroy(vault);
    fixture.end();
}

#[test]
/// A partner is paid only out of the admin fee the operation just retained: of a
/// 30-atom fee a 50% share takes 15, earlier admin cash, the reserve and the
/// supply do not move, and both the vault's and the partner package's events
/// record the payment.
fun a_partner_is_paid_only_out_of_the_admin_fee_its_operation_retained() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(100));
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(30));
    let (reserve, supply) = (vault.state().maintenance_reserve(), vault.total_share_supply());

    vault.pay_partner_for_testing(&partner, 100, &clock, fixture.ctx!());

    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 115);
    assert_eq!(vector[vault.state().maintenance_reserve(), vault.total_share_supply()], vector[reserve, supply]);
    let (vault_id, partner_id, admin_fee, partner_fee) =
        events::collect_one<events::PartnerFeePaid<Product>>(0).partner_fee_paid_fields();
    assert_eq!(vault_id, vault.id());
    assert_eq!(partner_id, object::id(&partner));
    assert_eq!(vector[admin_fee, partner_fee], vector[30, 15]);
    let payments = sui::event::events_by_type<PartnerPaid<Collateral>>();
    assert_eq!(payments.length(), 1);
    let (paid_partner, amount) = payments[0].partner_paid_fields();
    assert_eq!(paid_partner, object::id(&partner));
    assert_eq!(amount, 15);
    destroy(partner);
    clock.destroy_for_testing();
    destroy(vault);
    fixture.end();
}

#[test]
/// An operation that retained no admin fee pays the partner nothing, sends
/// nothing, and is still attributed to the partner.
fun a_zero_admin_fee_pays_nothing_but_is_still_attributed() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(40));

    vault.pay_partner_for_testing(&partner, 40, &clock, fixture.ctx!());

    let (_, partner_id, admin_fee, partner_fee) =
        events::collect_one<events::PartnerFeePaid<Product>>(0).partner_fee_paid_fields();
    assert_eq!(partner_id, object::id(&partner));
    assert_eq!(vector[admin_fee, partner_fee], vector[0, 0]);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 40);
    assert_eq!(sui::event::events_by_type<PartnerPaid<Collateral>>().length(), 0);
    destroy(partner);
    clock.destroy_for_testing();
    destroy(vault);
    fixture.end();
}

#[test]
/// At the maximum 80% share Blast still keeps a fifth of the admin fee.
fun the_maximum_partner_share_leaves_blast_a_fifth_of_the_admin_fee() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 8_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(30));

    vault.pay_partner_for_testing(&partner, 0, &clock, fixture.ctx!());

    let (_, _, _, partner_fee) = events::collect_one<events::PartnerFeePaid<Product>>(0).partner_fee_paid_fields();
    assert_eq!(vector[partner_fee, vault.admin_cash_balance<_, Collateral>()], vector[24, 6]);
    destroy(partner);
    clock.destroy_for_testing();
    destroy(vault);
    fixture.end();
}

#[test]
/// The share is read at the operation's own Clock: a share that switches one
/// millisecond later pays nothing but the operation is still attributed to the
/// partner; one that switches at the operation's time pays in full.
fun a_partner_share_takes_effect_exactly_at_the_operations_clock() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let pending = partners::new_scheduled_for_testing(PARTNER_PAYOUT, 0, 5_000, REFERENCE_AT_MS + 1, fixture.ctx!());
    let switched = partners::new_scheduled_for_testing(PARTNER_PAYOUT, 0, 5_000, REFERENCE_AT_MS, fixture.ctx!());
    let clock = fixture.reference_clock();
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(60));

    vault.pay_partner_for_testing(&pending, 30, &clock, fixture.ctx!());
    vault.pay_partner_for_testing(&switched, 30, &clock, fixture.ctx!());

    let fees = events::collect<events::PartnerFeePaid<Product>>();
    let (_, _, _, pending_fee) = fees[0].partner_fee_paid_fields();
    let (_, _, _, switched_fee) = fees[1].partner_fee_paid_fields();
    assert_eq!(vector[pending_fee, switched_fee], vector[0, 15]);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 45);
    assert_eq!(sui::event::events_by_type<PartnerPaid<Collateral>>().length(), 1);
    destroy(pending);
    destroy(switched);
    clock.destroy_for_testing();
    destroy(vault);
    fixture.end();
}

// --- Accepted partners ---

#[test]
/// An added partner is accepted at once; a removed one stays accepted, and
/// paid, until the partner delay ends, and other partners are untouched.
fun an_added_partner_is_accepted_at_once_and_a_removed_one_until_the_delay_ends() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let other = partners::new_for_testing(PARTNER_PAYOUT, 800, fixture.ctx!());
    let mut clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.add_partner(&other);
    fixture.protocol.assert_partner_for_testing(object::id(&partner), REFERENCE_AT_MS);

    fixture.remove_partner(&partner, &clock);

    let acceptance_ends_at_ms = REFERENCE_AT_MS + partners::delay_ms();
    let added = events::collect<events::PartnerAdded>();
    assert_eq!(added[0].partner_added_id(), object::id(&partner));
    assert_eq!(added[1].partner_added_id(), object::id(&other));
    let (removed_id, until) = events::collect_one<events::PartnerRemoved>(0).partner_removed_fields();
    assert_eq!(removed_id, object::id(&partner));
    assert_eq!(until, acceptance_ends_at_ms);
    fixture.protocol.assert_partner_for_testing(object::id(&partner), acceptance_ends_at_ms - 1);
    clock.set_for_testing(acceptance_ends_at_ms);
    fixture.protocol.assert_partner_for_testing(object::id(&other), acceptance_ends_at_ms);
    destroy(partner);
    destroy(other);
    clock.destroy_for_testing();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EPartnerNotAccepted, location = blast_boosts_aftermath::blast_boosts_aftermath)]
fun a_removed_partner_is_refused_from_the_end_of_the_delay() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.remove_partner(&partner, &clock);

    let acceptance_ends_at_ms = REFERENCE_AT_MS + partners::delay_ms();
    fixture.protocol.assert_partner_for_testing(object::id(&partner), acceptance_ends_at_ms);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EPartnerNotAccepted, location = blast_boosts_aftermath::blast_boosts_aftermath)]
fun a_partner_never_added_is_refused() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());

    fixture.protocol.assert_partner_for_testing(object::id(&partner), REFERENCE_AT_MS);

    abort
}

#[test]
/// Adding a partner whose removal is pending cancels it, and it can be removed again.
fun adding_a_partner_being_removed_cancels_the_removal() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.remove_partner(&partner, &clock);

    fixture.add_partner(&partner);

    assert_eq!(events::collect<events::PartnerAdded>().length(), 2);
    fixture.protocol.assert_partner_for_testing(object::id(&partner), std::u64::max_value!() - 1);
    fixture.remove_partner(&partner, &clock);
    assert_eq!(events::collect<events::PartnerRemoved>().length(), 2);
    destroy(partner);
    clock.destroy_for_testing();
    fixture.end();
}

#[test]
/// A removed partner can be added again, accepted at once.
fun a_removed_partner_added_again_is_accepted_at_once() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let mut clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.remove_partner(&partner, &clock);
    clock.set_for_testing(REFERENCE_AT_MS + partners::delay_ms());

    fixture.add_partner(&partner);

    fixture.protocol.assert_partner_for_testing(object::id(&partner), clock.timestamp_ms());
    destroy(partner);
    clock.destroy_for_testing();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EPartnerUnchanged, location = blast_boosts_aftermath::blast_boosts_aftermath)]
fun adding_an_accepted_partner_again_is_refused() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    fixture.add_partner(&partner);

    fixture.add_partner(&partner);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EPartnerUnchanged, location = blast_boosts_aftermath::blast_boosts_aftermath)]
fun removing_a_partner_already_being_removed_is_refused() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.remove_partner(&partner, &clock);

    fixture.remove_partner(&partner, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EPartnerNotAccepted, location = blast_boosts_aftermath::blast_boosts_aftermath)]
fun removing_a_partner_never_added_is_refused() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();

    fixture.remove_partner(&partner, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EPartnerNotAccepted, location = blast_boosts_aftermath::blast_boosts_aftermath)]
fun removing_a_removed_partner_is_refused() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let mut clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.remove_partner(&partner, &clock);
    clock.set_for_testing(REFERENCE_AT_MS + partners::delay_ms());

    fixture.remove_partner(&partner, &clock);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_adapter_version_rejects_adding_a_partner() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    fixture.protocol.set_version_for_testing(3);

    fixture.add_partner(&partner);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_adapter_version_rejects_removing_a_partner() {
    let mut fixture = start();
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    fixture.add_partner(&partner);
    fixture.protocol.set_version_for_testing(3);

    fixture.remove_partner(&partner, &clock);

    abort
}

#[test]
fun event_reducer_reconstructs_a_positive_funding_checkpoint() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    let before = funding_before_checkpoint(1, false);
    let after = funding_checkpoint(1, false);
    let change = initial.sync_change(&before, &after, ONE_FIXED);
    vault.apply_connected_change(after, change);
    replay.replay_funding(events::collect_one<events::FundingSettled<Product>>(0));
    assert_eq!(replay.maintenance_reserve, vault.state().maintenance_reserve());
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue().checkpoint());
    destroy(vault);
    fixture.end();
}

#[test]
fun every_drifted_sync_reports_the_drift_and_a_clean_sync_is_silent() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let dirty = checkpoint_with_market_imr(0, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 2);
    vault.apply_connected_change(dirty, checkpoint::unexpected_change());
    vault.apply_connected_change(initial, checkpoint::unchanged_change());
    let drifted = events::collect<events::CheckpointDrifted<Product>>();
    assert_eq!(drifted.length(), 1);
    let (_, checkpoint) = drifted[0].checkpoint_drifted_fields();
    assert_eq!(checkpoint, dirty);
    assert_eq!(*vault.venue().checkpoint(), initial);
    vault.apply_connected_change(dirty, checkpoint::unexpected_change());
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 2);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_rebalance_changes_only_holder_equity_and_the_accepted_checkpoint() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let before = observation::new_position(1_000, 3_000_000, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    );
    let mut plan = vault.state().prepare_rebalance(before, 10, REFERENCE_AT_MS);
    let priced = plan.rebalance_position();
    let (base_price, collateral_price, lot) = (priced.base_price(), priced.collateral_price(), priced.lot_size());
    assert_eq!(base_price, PRICE);
    assert_eq!(collateral_price, PRICE);
    assert_eq!(lot, LOT_SIZE);
    let order = vault.state().next_rebalance_order(&plan);
    let base = order.order_base();
    assert_eq!(base, 238_095);
    assert!(!order.is_increase() && order.is_emergency());
    order.bound().assert_execution(PRICE, PRICE);
    let after = observation::new_position(999, 2_761_905, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    );
    vault.state().accept_rebalance_fill(&mut plan, order, after, base, REFERENCE_AT_MS);
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    vault.complete_rebalance_for_testing<Product, Collateral>(plan, checkpoint);
    assert_eq!(vault.state().maintenance_reserve(), 100);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(*vault.venue().checkpoint(), checkpoint);
    let event = events::collect_one<events::Rebalanced<Product>>(0);
    let (before_equity, after_equity, before_base, after_base, increased) = event.rebalanced_amounts();
    assert_eq!(before_equity, 1_000);
    assert_eq!(after_equity, 999);
    assert_eq!(before_base, 3_000_000);
    assert_eq!(after_base, 2_761_905);
    assert!(!increased);
    destroy(vault);
    fixture.end();
}

#[test]
/// The live Aftermath taker fee, 4.5 basis points, budgets as 5.
fun venue_fee_bound_rounds_the_taker_fee_up_to_whole_basis_points() {
    assert_eq!(orders::venue_fee_bound_for_testing(450_000_000_000_000), 5);
    assert_eq!(orders::venue_fee_bound_for_testing(100_000_000_000_000), 1);
    assert_eq!(orders::venue_fee_bound_for_testing(1), 1);
    assert_eq!(orders::venue_fee_bound_for_testing(0), 0);
}

#[test]
fun venue_fee_bound_accepts_a_taker_fee_of_exactly_one() {
    assert_eq!(orders::venue_fee_bound_for_testing(ONE_FIXED), 10_000);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EVenueFeeUnusable, location = blast_boosts_aftermath::orders)]
fun venue_fee_bound_rejects_a_taker_fee_above_one() {
    orders::venue_fee_bound_for_testing(ONE_FIXED + 1);
}

#[test]
fun completed_redemption_burns_the_native_input_only_after_exact_cash_return() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let mint_plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, 10, REFERENCE_AT_MS);
    let (amount, _, _, _, _) = vault.state_mut().complete_mint(mint_plan, active_position(1_998, 3_798), REFERENCE_AT_MS);
    let shares = vault.mint_shares(amount, fixture.ctx!());
    let plan = vault.state().prepare_redemption(active_position(1_998, 3_798), shares.value(), vault.total_share_supply(), 994, REFERENCE_AT_MS);
    // 3_798_000 less the floor of its 900_000 / 1_897_000 share, to the atom.
    assert_eq!(plan.base_to_sell(), 1_996_103);
    let (net, admin, fee, reserve_fee) = vault.settle_redemption_for_testing(
        plan, &shares, active_position_with_base(1_996, 1_801_897), REFERENCE_AT_MS,
    );
    assert_eq!(net + admin, 994);
    let cash = sui::coin::mint_for_testing<Collateral>(994, fixture.ctx!());
    let final_checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 994 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let cash = vault.complete_redemption_for_testing(shares, cash, net, admin, fee, reserve_fee, final_checkpoint, fixture.ctx!());
    assert_eq!(cash.value(), 994);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.state().maintenance_reserve(), 102);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    sui::transfer::public_transfer(cash, ADMIN);
    destroy(vault);
    fixture.end();
}

#[test]
fun allocated_cash_changes_cross_zero_with_exact_signed_magnitudes() {
    checkpoint::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, false, 3 * ATOM_FIXED, 5, true);
    checkpoint::assert_signed_cash_change_for_testing(false, 3 * ATOM_FIXED, true, 2 * ATOM_FIXED, 5, false);
    checkpoint::assert_signed_cash_change_for_testing(true, 5 * ATOM_FIXED, true, 2 * ATOM_FIXED, 3, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_a_reversed_signed_delta() {
    checkpoint::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, false, 3 * ATOM_FIXED, 5, false);
}

#[test]
fun allocated_cash_changes_cover_every_sign_shape_in_both_directions() {
    // Both positive: up is a deposit, down a withdrawal.
    checkpoint::assert_signed_cash_change_for_testing(false, 3 * ATOM_FIXED, false, 5 * ATOM_FIXED, 2, true);
    checkpoint::assert_signed_cash_change_for_testing(false, 5 * ATOM_FIXED, false, 3 * ATOM_FIXED, 2, false);
    // Both negative: a deeper liability is a withdrawal, a shallower one a deposit.
    checkpoint::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, true, 5 * ATOM_FIXED, 3, false);
    checkpoint::assert_signed_cash_change_for_testing(true, 5 * ATOM_FIXED, true, 2 * ATOM_FIXED, 3, true);
    // Leaving and landing on zero: zero is nonnegative, so these are same-sign and crossing moves respectively.
    checkpoint::assert_signed_cash_change_for_testing(false, 0, false, 5 * ATOM_FIXED, 5, true);
    checkpoint::assert_signed_cash_change_for_testing(true, 5 * ATOM_FIXED, false, 0, 5, true);
    checkpoint::assert_signed_cash_change_for_testing(false, 5 * ATOM_FIXED, false, 0, 5, false);
    // No move with no amount has no direction to disagree with.
    checkpoint::assert_signed_cash_change_for_testing(false, 5 * ATOM_FIXED, false, 5 * ATOM_FIXED, 0, true);
    checkpoint::assert_signed_cash_change_for_testing(true, 5 * ATOM_FIXED, true, 5 * ATOM_FIXED, 0, false);
    // The largest atomic amount still scales into the carrier.
    let max = std::u64::max_value!();
    checkpoint::assert_signed_cash_change_for_testing(false, 0, false, (max as u256) * ATOM_FIXED, max, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_a_positive_rise_called_a_withdrawal() {
    checkpoint::assert_signed_cash_change_for_testing(false, 3 * ATOM_FIXED, false, 5 * ATOM_FIXED, 2, false);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_a_deeper_liability_called_a_deposit() {
    checkpoint::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, true, 5 * ATOM_FIXED, 3, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_a_zero_crossing_of_the_wrong_size() {
    checkpoint::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, false, 3 * ATOM_FIXED, 4, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_a_move_when_nothing_was_expected() {
    checkpoint::assert_signed_cash_change_for_testing(false, 3 * ATOM_FIXED, false, 4 * ATOM_FIXED, 0, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_no_move_when_an_amount_was_expected() {
    checkpoint::assert_signed_cash_change_for_testing(false, 3 * ATOM_FIXED, false, 3 * ATOM_FIXED, 1, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_reject_a_sub_atom_remainder() {
    // One raw unit short of an atom: the proof is exact at 10^-18, not at the atom.
    checkpoint::assert_signed_cash_change_for_testing(false, 0, false, ATOM_FIXED - 1, 1, true);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun allocated_cash_changes_refuse_an_overflowing_zero_crossing() {
    // Unreachable with magnitudes decoded by `abs` (each below 2^255); the branch refuses rather than wraps.
    let half = std::u256::max_value!() / 2 + 1;
    checkpoint::assert_signed_cash_change_for_testing(true, half, false, half, 1, true);
}

#[test]
fun redemption_cash_checkpoint_paid_entirely_from_free_cash_leaves_allocated_untouched() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(5, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_withdrawal_checkpoint(&after, 20);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun redemption_cash_checkpoint_rejects_deallocating_what_free_cash_covered() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(5, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_withdrawal_checkpoint(&after, 20);
}

#[test]
fun active_checkpoint_admits_only_the_executed_position_and_venue_cost() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_trade_checkpoint(&after, ONE_FIXED, 1);
    let allocated = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 50 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_allocated_deposit_checkpoint(&allocated, 50);
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun active_checkpoint_rejects_a_foreign_market_parameter_change() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 2);
    before.assert_trade_checkpoint(&after, ONE_FIXED, 1);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun active_checkpoint_rejects_an_inexact_allocated_deposit() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 49 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_allocated_deposit_checkpoint(&after, 50);
}

#[test]
fun redemption_cash_checkpoint_spends_free_cash_before_deallocating() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 15 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_withdrawal_checkpoint(&after, 40);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun redemption_cash_checkpoint_rejects_inexact_payout() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 14 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_withdrawal_checkpoint(&after, 40);
}

#[test]
fun active_order_uses_the_sealed_base_without_a_notional_round_trip() {
    assert_eq!(orders::active_order_size_for_testing(1_998, 1_000, 1, 0), 1_000);
    assert_eq!(orders::active_order_size_for_testing(998, 1_000, 1, 15), 998);
}

#[test]
fun a_deadline_equal_to_now_is_still_open() {
    operations::assert_deadline_for_testing(1_000, 1_000);
    operations::assert_deadline_for_testing(0, 0);
}

#[test]
fun active_order_takes_the_whole_remainder_at_the_cap_and_a_whole_lot_multiple() {
    assert_eq!(orders::active_order_size_for_testing(1_000, 1_000, 1, 0), 1_000);
    assert_eq!(orders::active_order_size_for_testing(2_000, 1_000, 10, 0), 1_000);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_order_rejects_a_zero_cap() {
    orders::active_order_size_for_testing(1_000, 0, 1, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_order_rejects_nothing_remaining() {
    orders::active_order_size_for_testing(0, 1_000, 1, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_order_rejects_a_zero_lot_before_dividing_by_it() {
    orders::active_order_size_for_testing(1_000, 1_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_order_rejects_a_remainder_off_the_lot() {
    orders::active_order_size_for_testing(105, 1_000, 10, 0);
}

#[test]
fun terms_open_with_the_side_and_reduce_against_it() {
    let mut fixture = start();
    let vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, 10, REFERENCE_AT_MS);
    let position = plan.mint_position();

    let (is_ask, reduce_only, max_order_base, lot_size, base_price, collateral_price, slippage_bps) =
        vault.increasing_terms(position).order_terms_fields();
    assert!(!is_ask && !reduce_only);
    assert_eq!(max_order_base, vault.state().max_order_base(&position, false));
    assert_eq!(vector[lot_size, base_price, collateral_price], vector[LOT_SIZE, PRICE, PRICE]);
    // Mint and redemption orders run under the ordinary bound.
    assert_eq!(slippage_bps, 100);

    let (is_ask, reduce_only, _, _, _, _, _) = vault.reducing_terms(position).order_terms_fields();
    assert!(is_ask && reduce_only);

    destroy(plan);
    destroy(vault);
    fixture.end();
}

#[test]
fun terms_of_a_short_vault_open_with_an_ask_and_reduce_with_a_bid() {
    let mut fixture = start();
    let vault = issue_and_activate_product_with_side(&mut fixture, OtherProduct(), initial_checkpoint(),
        standard_vault_policy_for_side(policy::short()), policy::short());
    let plan = vault.state().prepare_mint(position_observation_for_side(SEED_EQUITY, policy::short()), 1_000, vault.total_share_supply(), 997_000, 10, REFERENCE_AT_MS);
    let position = plan.mint_position();

    let (is_ask, reduce_only, _, _, _, _, _) = vault.increasing_terms(position).order_terms_fields();
    assert!(is_ask && !reduce_only);
    let (is_ask, reduce_only, _, _, _, _, _) = vault.reducing_terms(position).order_terms_fields();
    assert!(!is_ask && reduce_only);

    destroy(plan);
    destroy(vault);
    fixture.end();
}

#[test]
fun unwind_terms_close_a_long_with_an_ask_at_the_capped_size() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let captured = snapshot::captured_health_for_testing(checkpoint, 0, false, 0, true, true);

    let (terms, remaining, before) = vault.unwind_terms(&captured, REFERENCE_AT_MS);
    let (is_ask, reduce_only, max_order_base, lot_size, base_price, collateral_price, slippage_bps) =
        terms.order_terms_fields();
    assert!(is_ask && reduce_only);
    assert_eq!(vector[max_order_base, lot_size, base_price, collateral_price], vector[247_524, LOT_SIZE, PRICE, PRICE]);
    // Shutdown has just begun, so the close runs under the ordinary bound.
    assert_eq!(slippage_bps, 100);
    assert_eq!(remaining, 1_000_000_000);
    assert_eq!(before, checkpoint);

    destroy(vault);
    fixture.end();
}

/// The clock `begin_shutdown` reads fixes when the close-only bound starts
/// widening: a day later a close runs under the emergency bound.
#[test]
fun unwind_bound_widens_from_the_clock_shutdown_began_at() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());

    let later_at_ms = REFERENCE_AT_MS + 86_400_000;
    let (_, _, _, _, bound) = vault.state().unwind_constraints(
        observation::new_price(PRICE, 0, later_at_ms), observation::new_price(PRICE, 0, later_at_ms), LOT_SIZE, later_at_ms,
    );

    assert_eq!(bound.slippage_bps(), 500);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun unwind_terms_reject_a_checkpoint_with_resting_orders() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let resting = checkpoint::checkpoint_for_testing(
        0, ALLOCATED_FIXED, ONE_FIXED, 1, RATE, RATE, RATE, RATE, LOT_SIZE, 0, 0, 1, 0, false, 1, 1, 1,
    );
    let captured = snapshot::captured_health_for_testing(resting, 0, false, 0, true, true);

    vault.unwind_terms(&captured, REFERENCE_AT_MS);

    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun unwind_terms_require_an_unwinding_vault_before_reading_orders() {
    let mut fixture = start();
    let vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let captured = snapshot::captured_health_for_testing(initial_checkpoint(), 0, false, 0, true, true);

    vault.unwind_terms(&captured, REFERENCE_AT_MS);

    destroy(vault);
    fixture.end();
}

/// The guard mirrors the pinned venue formula: the next update is the start of
/// the period after the one containing the last update, and it is due at that
/// instant, not one millisecond before it.
#[test]
fun funding_update_is_due_at_the_next_period_boundary_and_not_before() {
    let frequency = 3_600_000;
    let last = 7 * frequency + 1_234;
    let next = 8 * frequency;

    assert_eq!(venue_account::next_funding_update_time_ms_for_testing(last, frequency), next);
    assert!(!venue_account::is_time_to_update_funding_for_testing(next - 1, last, frequency));
    assert!(venue_account::is_time_to_update_funding_for_testing(next, last, frequency));
    assert!(venue_account::is_time_to_update_funding_for_testing(next + 1, last, frequency));
    assert!(venue_account::is_time_to_update_funding_for_testing(next + 5 * frequency, last, frequency));
}

/// An aligned last update is due exactly one period later, and a market whose
/// last update is the current instant is not due.
#[test]
fun funding_update_from_an_aligned_last_update_is_due_one_period_later() {
    let frequency = 60_000;

    assert_eq!(venue_account::next_funding_update_time_ms_for_testing(0, frequency), frequency);
    assert_eq!(venue_account::next_funding_update_time_ms_for_testing(frequency, frequency), 2 * frequency);
    assert!(!venue_account::is_time_to_update_funding_for_testing(frequency, frequency, frequency));
    assert!(!venue_account::is_time_to_update_funding_for_testing(2 * frequency - 1, frequency, frequency));
    assert!(venue_account::is_time_to_update_funding_for_testing(2 * frequency, frequency, frequency));
}

/// A not-due market receives no update call: the production helper only calls
/// the venue under a true guard, which the source-boundary gate pins, so every
/// instant strictly inside the current period decides "no call".
#[test]
fun a_not_due_market_receives_no_funding_update_call() {
    let frequency = 1_000;
    let last = 4_321;
    let next = 5_000;
    let mut now = last;
    while (now < next) {
        assert!(!venue_account::is_time_to_update_funding_for_testing(now, last, frequency));
        now = now + 1;
    };
    assert!(venue_account::is_time_to_update_funding_for_testing(now, last, frequency));
}

/// The funding update authenticates the bound market, then the base storage
/// against that market's current parameter, before touching either.
#[test]
fun funding_update_inputs_accept_the_bound_market_and_its_base_storage() {
    funding_binding().assert_funding_update_inputs_for_testing(@0xD.to_id(), 3, 3);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EClearingHouseMismatch, location = blast_boosts_aftermath::venue_account)]
fun funding_update_rejects_an_unbound_market_before_the_oracle() {
    funding_binding().assert_funding_update_inputs_for_testing(@0xDD.to_id(), 4, 3);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EBaseOracleMismatch, location = blast_boosts_aftermath::venue_account)]
fun funding_update_rejects_a_storage_the_market_does_not_price_with() {
    funding_binding().assert_funding_update_inputs_for_testing(@0xD.to_id(), 1, 3);
}

/// A zero frequency is never due, so the adapter never asks the venue to divide by it.
#[test]
fun a_market_without_a_funding_cadence_is_never_due() {
    assert!(!venue_account::is_time_to_update_funding_for_testing(0, 0, 0));
    assert!(!venue_account::is_time_to_update_funding_for_testing(std::u64::max_value!(), 0, 0));
}

/// Exhausts small periods and offsets against an independent reference of the
/// venue formula.
#[test]
fun funding_update_guard_matches_the_small_domain_reference() {
    1u64.range_do!(6, |frequency| {
        0u64.range_do!(25, |last| {
            let next = (last / frequency + 1) * frequency;
            assert_eq!(venue_account::next_funding_update_time_ms_for_testing(last, frequency), next);
            0u64.range_do!(31, |now| {
                assert_eq!(
                    venue_account::is_time_to_update_funding_for_testing(now, last, frequency),
                    now >= next,
                );
            });
        });
    });
}

#[test]
#[expected_failure(abort_code = errors::EActiveOrderCountExceeded, location = blast_boosts_aftermath::orders)]
fun active_order_rejects_a_seventeenth_session() {
    orders::active_order_size_for_testing(10, 1_000, 1, 16);
}

#[test]
#[expected_failure(abort_code = errors::EDeadlineExpired, location = blast_boosts_aftermath::operations)]
fun active_order_rejects_an_expired_deadline() {
    operations::assert_deadline_for_testing(1_001, 1_000);
}

#[test]
fun ordinary_rebalances_accept_the_reference_gas_price_and_below() {
    vector[policy::long(), policy::short()].do!(|side| {
        vector[1_000, 2_500, 2_700].do!(|notional| {
            assert_rebalance_gas_at(side, notional, REFERENCE_GAS_PRICE);
            assert_rebalance_gas_at(side, notional, REFERENCE_GAS_PRICE - 1);
        });
    });
}

#[test]
#[expected_failure(abort_code = errors::EPriorityGasPrice, location = blast_boosts_aftermath::operations)]
fun an_ordinary_increase_rejects_priority_gas() {
    assert_rebalance_gas_at(policy::long(), 1_000, REFERENCE_GAS_PRICE + 1);
}

#[test]
#[expected_failure(abort_code = errors::EPriorityGasPrice, location = blast_boosts_aftermath::operations)]
fun an_ordinary_reduction_rejects_priority_gas() {
    assert_rebalance_gas_at(policy::short(), 2_500, REFERENCE_GAS_PRICE + 1);
}

#[test]
#[expected_failure(abort_code = errors::EPriorityGasPrice, location = blast_boosts_aftermath::operations)]
fun a_rebalance_starting_exactly_at_the_hard_cap_rejects_priority_gas() {
    // Seed equity 1_000 minus reserve 100 gives NAV 900; the hard cap is 3x.
    assert_rebalance_gas_at(policy::long(), 2_700, REFERENCE_GAS_PRICE + 1);
}

#[test]
fun emergency_rebalances_accept_priority_gas_for_both_sides() {
    vector[policy::long(), policy::short()].do!(|side| {
        assert_rebalance_gas_at(side, 2_701, REFERENCE_GAS_PRICE + 1);
        assert_rebalance_gas_at(side, 3_000, std::u64::max_value!());
    });
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun an_inside_band_position_is_rejected_before_its_priority_gas_bid() {
    assert_rebalance_gas_at(policy::long(), 1_800, REFERENCE_GAS_PRICE + 1);
}

#[test]
fun active_partial_fill_consumes_only_filled_whole_lots() {
    assert_eq!(orders::active_fill_for_testing(true, 100, 10, 60_000_000_000, 0, 0, 0, 0), 60);
    assert_eq!(orders::active_fill_for_testing(false, 100, 10, 0, 100_000_000_000, 0, 0, 0), 100);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_zero_progress() {
    orders::active_fill_for_testing(true, 100, 10, 0, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_opposite_side() {
    orders::active_fill_for_testing(true, 100, 10, 60_000_000_000, 10_000_000_000, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_fractional_lot() {
    orders::active_fill_for_testing(true, 100, 10, 61_000_000_000, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_overfill() {
    orders::active_fill_for_testing(true, 100, 10, 110_000_000_000, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EOrdersPosted, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_posted_orders() {
    orders::active_fill_for_testing(true, 100, 10, 60_000_000_000, 0, 1, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::ELiquidation, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_liquidation() {
    orders::active_fill_for_testing(true, 100, 10, 60_000_000_000, 0, 0, 1, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_a_zero_lot_before_dividing_by_it() {
    orders::active_fill_for_testing(true, 100, 0, 60_000_000_000, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun active_partial_fill_rejects_a_bid_leak_on_an_ask() {
    orders::active_fill_for_testing(false, 100, 10, 10_000_000_000, 100_000_000_000, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EOrdersPosted, location = blast_boosts_aftermath::orders)]
fun posted_orders_are_reported_before_a_liquidation_in_the_same_session() {
    orders::active_fill_for_testing(true, 100, 10, 0, 0, 1, 1, 1);
}

#[test]
fun completed_mint_returns_native_shares_and_updates_the_same_treasury_supply() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, 10, REFERENCE_AT_MS);
    assert_eq!(plan.base_to_buy(), 1_998_000);
    let priced = plan.mint_position();
    let (base_price, collateral_price, lot) = (priced.base_price(), priced.collateral_price(), priced.lot_size());
    assert_eq!(base_price, PRICE);
    assert_eq!(collateral_price, PRICE);
    assert_eq!(lot, LOT_SIZE);
    assert_eq!(vault.state().side(), policy::long());
    assert!(vault.max_order_notional_for_testing() > 0);
    vault.state().execution_bound().assert_execution(PRICE, PRICE);
    let after = observation::new_position(1_998, 3_798 * BASE_PER_NOTIONAL, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    );
    let shares = vault.complete_mint_for_testing<Product, Collateral>(plan, 1_000, after, initial_checkpoint(), REFERENCE_AT_MS, fixture.ctx!());
    let event = events::collect_one<events::Minted<Product>>(0);
    let (deposit, minted, contribution, fee, admin, buffer, reserve, admin_cash, supply) = event.minted_amounts();
    assert_eq!(deposit, 1_000);
    assert_eq!(minted, 997_000);
    assert_eq!(contribution, 997);
    assert_eq!(fee, 1);
    assert_eq!(admin, 0);
    assert_eq!(buffer, 1);
    assert_eq!(reserve, 101);
    assert_eq!(admin_cash, 0);
    assert_eq!(supply, 1_897_000);
    assert_eq!(shares.value(), 997_000);
    assert_eq!(vault.total_share_supply(), 1_897_000);
    assert_eq!(vault.state().maintenance_reserve(), 101);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    sui::transfer::public_transfer(shares, ADMIN);
    destroy(vault);
    fixture.end();
}

#[test]
fun donation_can_partly_repair_margin_without_restoring_the_opening_requirement() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 10 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let (observation, checkpoint) = snapshot::captured_position_for_testing(
        after, SEED_EQUITY + 10, ABSOLUTE_BASE, policy::long(), false, true,
    ).into_recovery_observation();
    vault.complete_donation_for_testing(observation, checkpoint, 10, REFERENCE_AT_MS);
    assert_eq!(vault.state().maintenance_reserve(), 110);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(*vault.venue().checkpoint(), after);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun donation_rejects_cash_left_in_the_free_account() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let after = checkpoint_with_market_imr(50, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    vault.complete_donation_for_testing(position_observation(SEED_EQUITY + 50), after, 50, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun donation_rejects_allocating_less_than_the_donated_amount() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let after = checkpoint_with_market_imr(1, ALLOCATED_FIXED + 49 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    vault.complete_donation_for_testing(position_observation(SEED_EQUITY + 50), after, 50, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_donation_accepts_only_the_exact_allocated_collateral_deposit() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 50 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    vault.complete_donation_for_testing(position_observation(SEED_EQUITY + 50), after, 50, REFERENCE_AT_MS);
    assert_eq!(vault.state().maintenance_reserve(), 150);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(*vault.venue().checkpoint(), after);
    let (id, amount, reserve, checkpoint) =
        events::collect_one<events::Donated<Product>>(0).donated_fields();
    assert_eq!(id, vault.id());
    assert_eq!(vector[amount, reserve], vector[50, 150]);
    assert_eq!(checkpoint, after);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun donation_cannot_accept_an_unrelated_position_margin_change() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 50 * ATOM_FIXED, RATE, RATE, RATE, RATE, 2);
    vault.complete_donation_for_testing(position_observation(SEED_EQUITY + 50), after, 50, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
fun earned_admin_cash_withdraws_without_venue_or_oracle_in_terminal_state() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(25));
    let witness = risk_admin();
    vault.set_unwinding_for_testing();
    let cash = vault.withdraw_admin_fees<_, Collateral>(
        &fixture.protocol, &witness, 10, fixture.ctx!(),
    );
    assert_eq!(cash.value(), 10);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 15);
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(*vault.venue().checkpoint(), initial);
    assert_eq!(vault.total_share_supply(), 900_000);
    let event = events::collect_one<events::AdminFeesWithdrawn<Product>>(0);
    let (id, amount, remaining) = event.admin_fees_withdrawn_fields();
    assert_eq!(id, vault.id());
    assert_eq!(vector[amount, remaining], vector[10, 15]);
    sui::coin::burn_for_testing(cash);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInsufficientAdminCash, location = blast_boosts_aftermath::vault)]
fun admin_cash_withdrawal_cannot_spend_the_buffer_when_earnings_are_absent() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = risk_admin();
    let cash = vault.withdraw_admin_fees<_, Collateral>(
        &fixture.protocol, &witness, 1, fixture.ctx!(),
    );
    sui::coin::burn_for_testing(cash);
    destroy(vault);
    fixture.end();
}

#[test]
fun target_above_one_order_cap_splits_into_compliant_whole_lot_orders() {
    let orders = orders::order_sizes_for_testing(50_000_000_000, 15_000_000_000);

    assert_eq!(orders, vector[15_000_000_000, 15_000_000_000, 15_000_000_000, 5_000_000_000]);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidInitializationOrderSize, location = blast_boosts_aftermath::orders)]
fun a_zero_target_is_rejected_as_an_invalid_order_size() {
    orders::order_sizes_for_testing(0, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidInitializationOrderSize, location = blast_boosts_aftermath::orders)]
fun a_zero_order_cap_is_rejected_as_an_invalid_order_size() {
    orders::order_sizes_for_testing(1, 0);
}

#[test]
fun a_target_at_or_below_one_cap_is_a_single_order() {
    assert_eq!(orders::order_sizes_for_testing(5, 10), vector[5]);
    assert_eq!(orders::order_sizes_for_testing(10, 10), vector[10]);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidInitializationOrderSize, location = blast_boosts_aftermath::orders)]
fun order_count_rejects_a_zero_cap_on_its_own() {
    orders::order_count_for_testing(1, 0);
}

#[test]
fun order_count_rounds_a_remainder_up() {
    assert_eq!(orders::order_count_for_testing(17, 2), 9);
    assert_eq!(orders::order_count_for_testing(16, 2), 8);
}

#[test]
fun initialization_order_count_accepts_zero_remaining_and_the_fixed_maximum() {
    assert_eq!(orders::max_initialization_orders_for_testing(), 16);
    assert_eq!(orders::order_count_for_testing(0, 1), 0);
    assert_eq!(orders::order_count_for_testing(16, 1), 16);
}

#[test]
fun maximum_order_count_preserves_the_exact_total_and_per_order_cap() {
    let orders = orders::order_sizes_for_testing(16_000, 1_000);
    let mut total = 0;
    let mut index = 0;
    while (index < orders.length()) {
        let order = *orders.borrow(index);
        assert_eq!(order, 1_000);
        total = total + order;
        index = index + 1;
    };

    assert_eq!(orders.length(), 16);
    assert_eq!(total, 16_000);
}

#[test]
fun actual_fill_notional_uses_the_session_quote_and_rounds_against_the_vault() {
    // $30.000000000001 of filled quote is 31 atomic USDC after conservative
    // rounding, even if the reference-price plan expected only 30.
    assert_eq!(
        orders::actual_fill_notional_for_testing(
            30_000_000_000_001_000_000,
            1_000_000_000,
        ),
        30_000_001,
    );
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::orders)]
fun actual_fill_notional_rejects_a_zero_collateral_price() {
    orders::actual_fill_notional_for_testing(1, 0);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::orders)]
fun actual_fill_notional_rejects_a_quote_beyond_u64_atoms() {
    orders::actual_fill_notional_for_testing(std::u256::max_value!(), 1);
}

#[test]
fun actual_fill_notional_does_not_round_an_exact_quote() {
    assert_eq!(orders::actual_fill_notional_for_testing(30_000_000_000_000_000_000, 1_000_000_000), 30_000_000);
    assert_eq!(orders::actual_fill_notional_for_testing(0, 1_000_000_000), 0);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationOrderCountExceeded, location = blast_boosts_aftermath::orders)]
fun initialization_order_count_rejects_the_first_value_above_the_maximum() {
    orders::order_count_for_testing(17, 1);
}

#[test]
fun initialization_order_count_ceil_does_not_add_before_dividing() {
    assert_eq!(
        orders::order_count_for_testing(
            std::u64::max_value!(),
            std::u64::max_value!() - 1,
        ),
        2,
    );
}

#[test]
fun exact_long_and_short_full_fills_are_accepted() {
    orders::assert_seed_fill_for_testing(
        true,
        5_000_000_000,
        1,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
        0,
    );
    orders::assert_seed_fill_for_testing(
        false,
        5_000_000_000,
        1,
        0,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
    );
}

#[test]
fun series_side_maps_to_the_aftermath_port_convention() {
    assert_eq!(orders::opens_with_ask_for_testing(policy::long()), false);
    assert_eq!(orders::opens_with_ask_for_testing(policy::short()), true);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationFillMismatch, location = blast_boosts_aftermath::orders)]
fun a_partial_fill_is_rejected() {
    orders::assert_seed_fill_for_testing(
        true,
        5_000_000_000,
        1,
        4_999_999_999_000_000_000,
        0,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = errors::EFillMismatch, location = blast_boosts_aftermath::orders)]
fun a_fill_on_the_wrong_side_is_rejected() {
    orders::assert_seed_fill_for_testing(
        true,
        5_000_000_000,
        1,
        0,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = errors::EOrdersPosted, location = blast_boosts_aftermath::orders)]
fun a_posted_order_is_rejected_before_fill_validation() {
    orders::assert_seed_fill_for_testing(
        true,
        5_000_000_000,
        1,
        0,
        0,
        1,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = errors::ELiquidation, location = blast_boosts_aftermath::orders)]
fun a_liquidation_is_rejected_before_fill_validation() {
    orders::assert_seed_fill_for_testing(
        true,
        5_000_000_000,
        1,
        0,
        0,
        0,
        1,
        0,
    );
}

#[test]
#[expected_failure(abort_code = errors::ELiquidation, location = blast_boosts_aftermath::orders)]
fun bad_debt_is_rejected_before_fill_validation() {
    orders::assert_seed_fill_for_testing(
        true,
        5_000_000_000,
        1,
        0,
        0,
        0,
        0,
        1,
    );
}

#[test]
fun valid_local_initialization_inputs_are_accepted() {
    operations::assert_initialization_inputs_for_testing(6, ATOM_FIXED, 100, 10);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidCollateralDecimals, location = blast_boosts_aftermath::operations)]
fun non_six_decimal_collateral_is_rejected_before_seed_validation() {
    operations::assert_initialization_inputs_for_testing(7, ATOM_FIXED, 0, 0);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidCollateralDecimals, location = blast_boosts_aftermath::operations)]
fun a_market_whose_collateral_scale_is_not_six_decimals_is_rejected() {
    operations::assert_initialization_inputs_for_testing(6, ATOM_FIXED * 10, 100, 10);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSeed, location = blast_boosts_aftermath::operations)]
fun a_zero_seed_is_rejected_before_reserve_validation() {
    operations::assert_initialization_inputs_for_testing(6, ATOM_FIXED, 0, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSeedReserve, location = blast_boosts_aftermath::operations)]
fun a_reserve_equal_to_the_seed_is_rejected() {
    operations::assert_initialization_inputs_for_testing(6, ATOM_FIXED, 100, 100);
}

#[test]
fun locked_share_scaling_accepts_the_largest_seed_nav() {
    assert_eq!(
        vault::seed_shares_for_testing(std::u64::max_value!() / 1_000),
        std::u64::max_value!() / 1_000 * 1_000,
    );
}

#[test]
#[expected_failure(abort_code = errors::ELockedSharesOverflow, location = blast_boosts_aftermath::vault)]
fun locked_share_scaling_rejects_the_first_overflow() {
    vault::seed_shares_for_testing(std::u64::max_value!() / 1_000 + 1);
}

#[test]
fun execution_price_rounds_against_the_vault() {
    assert_eq!(
        orders::execution_price_for_testing(2_000_000_000_000_000_001, true, false),
        2_000_000_001,
    );
    assert_eq!(
        orders::execution_price_for_testing(2_000_000_000_999_999_999, false, false),
        2_000_000_000,
    );
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::orders)]
fun negative_execution_price_is_rejected() {
    orders::execution_price_for_testing(1, true, true);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::orders)]
fun unrepresentable_execution_price_is_rejected() {
    orders::execution_price_for_testing(std::u256::max_value!(), false, false);
}

#[test]
fun execution_price_does_not_round_up_an_exact_price() {
    assert_eq!(orders::execution_price_for_testing(2_000_000_000_000_000_000, true, false), 2_000_000_000);
    let max = std::u64::max_value!();
    assert_eq!(orders::execution_price_for_testing((max as u256) * 1_000_000_000, true, false), max);
}

#[test]
#[expected_failure(abort_code = errors::ENormalizationOverflow, location = blast_boosts_aftermath::orders)]
fun execution_price_rejects_a_round_up_past_the_largest_representable() {
    orders::execution_price_for_testing((std::u64::max_value!() as u256) * 1_000_000_000 + 1, true, false);
}

#[test]
fun vault_initialized_event_records_every_activation_primitive() {
    let checkpoint = checkpoint::checkpoint_for_testing(
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        false,
        24,
        25,
        26,
    );
    events::vault_initialized<Product>(
        @0xA.to_id(),
        venue_account::new_binding(@0xB.to_id(), 27, @0xC.to_id(), @0xD.to_id()),
        28,
        29,
        30,
        31,
        32,
        33,
        35,
        policy::short(),
        36,
        checkpoint,
    );

    let event = events::collect_one<events::VaultInitialized<Product>>(0);
    let (
        vault_id,
        binding,
        seed_amount,
        seed_venue_equity,
        seed_reserve,
        seed_shareholder_nav,
        locked_shares,
        position_base,
        lot_size,
        side,
        position_imr,
        event_checkpoint,
    ) = event.vault_initialized_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert_eq!(
        binding,
        venue_account::new_binding(@0xB.to_id(), 27, @0xC.to_id(), @0xD.to_id()),
    );
    assert_eq!(seed_amount, 28);
    assert_eq!(seed_venue_equity, 29);
    assert_eq!(seed_reserve, 30);
    assert_eq!(seed_shareholder_nav, 31);
    assert_eq!(locked_shares, 32);
    assert_eq!(position_base, 33);
    assert_eq!(lot_size, 35);
    assert_eq!(side, policy::short());
    assert_eq!(position_imr, 36);
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
fun synchronization_classifies_no_change_and_replay_as_no_funding() {
    let settled = RATE + 10 * ATOM_FIXED;
    let before = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, settled, settled, 0, ONE_FIXED, 0);

    let first = before.sync_change(&before, &before, ONE_FIXED);
    assert!(first.is_unchanged_for_testing());

    let after = sync_checkpoint(1_000, 110_000_000_000_000, settled, settled, settled, settled, 0, ONE_FIXED, 0);
    let replay = after.sync_change(&after, &after, ONE_FIXED);
    assert!(replay.is_unchanged_for_testing());
}

#[test]
fun synchronization_accepts_only_an_isolated_funding_credit() {
    let settled = RATE - 10_000_000_000_000;
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, RATE, RATE, 0, ONE_FIXED, 0);
    let before = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, settled, settled, 0, ONE_FIXED, 0);
    let after = sync_checkpoint(1_000, 110_000_000_000_000, settled, settled, settled, settled, 0, ONE_FIXED, 0);

    let change = stored.sync_change(&before, &after, ONE_FIXED);
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());

    assert!(has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert!(checkpoint_clean);
    assert!(change.is_credit_for_testing());
}

#[test]
fun synchronization_rounds_an_isolated_funding_cost_against_the_reserve() {
    let settled = RATE + 999_999_999_999;
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, RATE, RATE, 0, ONE_FIXED, 0);
    let before = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, settled, settled, 0, ONE_FIXED, 0);
    let after = sync_checkpoint(1_000, 99_000_000_000_001, settled, settled, settled, settled, 0, ONE_FIXED, 0);

    let change = stored.sync_change(&before, &after, ONE_FIXED);
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());

    assert!(has_funding);
    assert!(is_cost);
    assert_eq!(raw_amount, 999_999_999_999);
    assert_eq!(amount, 1);
    assert!(checkpoint_clean);
    assert!(change.is_cost());
}

#[test]
fun synchronization_recognizes_permissionlessly_settled_funding_once() {
    let refreshed = RATE - 10_000_000_000_000;
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, RATE, RATE, 0, ONE_FIXED, 0);
    let settled = sync_checkpoint(1_000, 110_000_000_000_000, refreshed, refreshed, refreshed, refreshed, 0, ONE_FIXED, 0);

    let change = stored.sync_change(&settled, &settled, ONE_FIXED);
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());

    assert!(has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert!(checkpoint_clean);

    let replay = settled.sync_change(&settled, &settled, ONE_FIXED);
    assert!(replay.is_unchanged_for_testing());
}

#[test]
fun synchronization_preserves_external_then_local_funding_as_two_ordered_changes() {
    // Rates rose 10 while the vault was away (settled elsewhere as a cost), then fell 5 before this sync.
    let (external_rate, local_rate) = (RATE + 10 * ATOM_FIXED, RATE + 5 * ATOM_FIXED);
    let stored = sync_checkpoint(1_000, 100 * ATOM_FIXED, RATE, RATE, RATE, RATE, 0, ONE_FIXED, 0);
    let before = sync_checkpoint(1_000, 90 * ATOM_FIXED, external_rate, external_rate, local_rate, local_rate, 0, ONE_FIXED, 0);
    let after = sync_checkpoint(1_000, 95 * ATOM_FIXED, local_rate, local_rate, local_rate, local_rate, 0, ONE_FIXED, 0);

    let (external, local) = stored.classify_sync_changes(&before, &after, ONE_FIXED);

    let (has_external, external_is_cost, external_raw, _, external_clean) =
        (external.has_funding(), external.is_cost(), external.raw_amount(), external.amount(), external.is_clean());
    let (has_local, local_is_cost, local_raw, _, local_clean) =
        (local.has_funding(), local.is_cost(), local.raw_amount(), local.amount(), local.is_clean());
    assert!(has_external && external_is_cost && external_clean);
    assert_eq!(external_raw, 10 * ATOM_FIXED);
    assert!(has_local && !local_is_cost && local_clean);
    assert_eq!(local_raw, 5 * ATOM_FIXED);
}

#[test]
fun preexisting_pnl_collateral_or_liquidation_change_is_never_funding() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let clean_after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);
    let pnl_before = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 1, 0, 0);
    let collateral_before = sync_checkpoint(999, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let liquidation_after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 1, 0);

    stored.assert_unexpected_sync_change(&pnl_before, &clean_after);
    stored.assert_unexpected_sync_change(&collateral_before, &clean_after);
    stored.assert_unexpected_sync_change(&stored, &liquidation_after);
}

#[test]
fun stored_drift_plus_an_exact_settlement_is_unexpected_and_not_funding() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let before = sync_checkpoint(999, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(999, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    stored.assert_unexpected_sync_change(&before, &after);
}

#[test]
fun funding_event_records_exact_amount_reserve_effect_and_checkpoint() {
    let previous_checkpoint = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let checkpoint = sync_checkpoint(1_000, 90_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    events::funding_settled<Product>(
        @0xA.to_id(),
        true,
        10_000_000_000_000,
        10,
        10,
        0,
        0,
        90,
        previous_checkpoint,
        checkpoint,
    );
    let event = events::collect_one<events::FundingSettled<Product>>(0);
    let (
        vault_id,
        is_cost,
        raw_amount,
        amount,
        absorbed,
        uncovered,
        _,
        reserve_after,
        event_previous_checkpoint,
        event_checkpoint,
    ) = event.funding_settled_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert!(is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert_eq!(absorbed, 10);
    assert_eq!(uncovered, 0);
    assert_eq!(reserve_after, 90);
    assert_eq!(event_previous_checkpoint, previous_checkpoint);
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
fun drift_event_records_the_vault_and_the_drifted_checkpoint() {
    let checkpoint = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 1);

    events::checkpoint_drifted<Product>(@0xA.to_id(), checkpoint);
    let (vault_id, event_checkpoint) =
        events::collect_one<events::CheckpointDrifted<Product>>(0).checkpoint_drifted_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::checkpoint)]
fun active_operation_rejects_unresolved_checkpoint_with_its_own_error() {
    let before = sync_checkpoint(1_000, 100, 10, 20, 11, 21, 0, 0, 1);
    let after = sync_checkpoint(1_001, 100, 10, 20, 11, 21, 0, 0, 1);
    before.assert_unchanged(&after);
}

#[test]
fun connected_cost_below_reserve_is_applied_once_and_emitted_from_real_state() {
    assert_connected_cost(10, 90, 10, 0);
}

#[test]
fun connected_cost_equal_to_reserve_exhausts_it_exactly() {
    assert_connected_cost(100, 0, 100, 0);
}

#[test]
fun connected_cost_above_reserve_reports_the_uncovered_remainder() {
    assert_connected_cost(120, 0, 100, 20);
}

/// A cost past the reserve leaves a deficit; the next credit repays holders
/// through NAV first and the event carries the split, so a reducer can rebuild
/// the reserve without the deficit.
#[test]
fun a_credit_after_an_exhausting_cost_repays_holders_before_the_reserve() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let cost = SEED_RESERVE + 30;
    let funded = funding_checkpoint(cost, true);
    let change = initial.sync_change(&funding_before_checkpoint(cost, true), &funded, ONE_FIXED);
    vault.apply_connected_change(funded, change);
    assert_eq!(vault.state().maintenance_reserve(), 0);

    // Second interval: market rates fall again and a 50-unit credit lands.
    let (costed_rate, credited_rate) = (settled_rate(cost, true), settled_rate(cost, true) - 50 * ATOM_FIXED);
    let allocated_after_cost = ALLOCATED_FIXED - (cost as u256) * ATOM_FIXED;
    let before = checkpoint_with_market_imr(0, allocated_after_cost, costed_rate, costed_rate, credited_rate, credited_rate, 1);
    let credited = checkpoint_with_market_imr(
        0, allocated_after_cost + 50 * ATOM_FIXED, credited_rate, credited_rate, credited_rate, credited_rate, 1,
    );
    let change = funded.sync_change(&before, &credited, ONE_FIXED);
    vault.apply_connected_change(credited, change);

    // 30 of the 50 repay the deficit and stay in NAV; 20 rebuild the reserve.
    assert_eq!(vault.state().maintenance_reserve(), 20);
    let events = events::collect<events::FundingSettled<Product>>();
    assert_eq!(events.length(), 2);
    let (_, is_cost, _, amount, absorbed, uncovered, restored, reserve_after, previous, current) =
        events.borrow(1).funding_settled_fields();
    assert!(!is_cost);
    assert_eq!(vector[amount, absorbed, uncovered, restored, reserve_after], vector[50, 0, 0, 30, 20]);
    assert_eq!(previous, funded);
    assert_eq!(current, credited);

    destroy(vault);
    fixture.end();
}

#[test]
fun connected_credit_credits_the_buffer_once() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = funding_before_checkpoint(10, false);
    let credited = funding_checkpoint(10, false);
    let credit = initial.sync_change(&before, &credited, ONE_FIXED);

    vault.apply_connected_change(credited, credit);
    let unchanged = credited.sync_change(&credited, &credited, ONE_FIXED);
    vault.apply_connected_change(credited, unchanged);

    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE + 10);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    assert_eq!(*vault.venue().checkpoint(), credited);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_second_call_at_the_same_checkpoint_is_exactly_once() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = funding_before_checkpoint(10, true);
    let funded = funding_checkpoint(10, true);
    let cost = initial.sync_change(&before, &funded, ONE_FIXED);
    vault.apply_connected_change(funded, cost);

    let replay = funded.sync_change(&funded, &funded, ONE_FIXED);
    vault.apply_connected_change(funded, replay);

    assert_eq!(vault.state().maintenance_reserve(), 90);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    assert_eq!(*vault.venue().checkpoint(), funded);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_permissionless_pre_settlement_debits_the_reserve_exactly_once() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let settled = funding_checkpoint(10, true);
    let cost = initial.sync_change(&settled, &settled, ONE_FIXED);
    vault.apply_connected_change(settled, cost);

    let replay = settled.sync_change(&settled, &settled, ONE_FIXED);
    vault.apply_connected_change(settled, replay);

    assert_eq!(vault.state().maintenance_reserve(), 90);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    assert_eq!(*vault.venue().checkpoint(), settled);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_external_cost_and_local_income_settle_one_net_checkpoint() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let (external_rate, local_rate) = (RATE + 110 * ATOM_FIXED, RATE + 90 * ATOM_FIXED);
    let before = checkpoint_with_market_imr(
        0, ALLOCATED_FIXED - 110 * ATOM_FIXED, external_rate, external_rate, local_rate, local_rate, 1,
    );
    let after = checkpoint_with_market_imr(
        0, ALLOCATED_FIXED - 90 * ATOM_FIXED, local_rate, local_rate, local_rate, local_rate, 1,
    );
    let (external, local) = initial.classify_sync_changes(&before, &after, ONE_FIXED);

    vault.apply_post_captures_for_testing(after, external, local);

    assert_eq!(vault.state().maintenance_reserve(), 10);
    let funding_events = events::collect<events::FundingSettled<Product>>();
    assert_eq!(funding_events.length(), 1);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    assert_eq!(*vault.venue().checkpoint(), after);
    let first = *funding_events.borrow(0);
    let (
        _, first_is_cost, first_raw, first_amount, first_absorbed,
        first_uncovered, _, first_reserve_after, first_previous, first_checkpoint,
    ) = first.funding_settled_fields();
    assert!(first_is_cost);
    assert_eq!(first_raw, 90 * ATOM_FIXED);
    assert_eq!(first_amount, 90);
    assert_eq!(first_absorbed, 90);
    assert_eq!(first_uncovered, 0);
    assert_eq!(first_reserve_after, 10);
    assert_eq!(first_previous, initial);
    assert_eq!(first_checkpoint, after);
    destroy(vault);
    fixture.end();
}

#[test]
/// Each market-wide setting the venue's admin can change (pause mode, frozen
/// flag, market IMR, market MMR) is adopted into the accepted checkpoint
/// through the ordinary synchronization, with a zero funding delta, and an
/// identical retry stays quiet. A lot-size change stays unexplained drift.
fun venue_policy_updates_adopt_each_setting_and_preserve_funding_totals() {
    let mut fixture = start();
    let initial = policy_checkpoint(LOT_SIZE, 0, false, 10, 5);
    let mut vault = issue_and_activate(&mut fixture, initial);
    let resized = policy_checkpoint(LOT_SIZE * 2, 0, false, 10, 5);
    assert!(initial.classify_preexisting(&resized).is_unexpected_for_testing());
    let updates = vector[
        policy_checkpoint(LOT_SIZE, 2, false, 10, 5),
        policy_checkpoint(LOT_SIZE, 2, true, 10, 5),
        policy_checkpoint(LOT_SIZE, 2, true, 7, 5),
        policy_checkpoint(LOT_SIZE, 2, true, 7, 3),
        policy_checkpoint(LOT_SIZE, 0, false, 10, 5),
    ];
    updates.do_ref!(|current| {
        let previous = *vault.venue().checkpoint();
        let change = previous.sync_change(current, current, ONE_FIXED);
        vault.apply_connected_change(*current, change);
        assert_eq!(*vault.venue().checkpoint(), *current);
        assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
        let repeated = current.sync_change(current, current, ONE_FIXED);
        vault.apply_connected_change(*current, repeated);
    });
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    let facts = events::collect<events::FundingSettled<Product>>();
    assert_eq!(facts.length(), updates.length());
    let mut replayed = initial;
    facts.length().do!(|index| {
        let (vault_id, is_cost, raw, amount, absorbed, uncovered, restored, reserve, previous, current) =
            facts[index].funding_settled_fields();
        assert_eq!(vault_id, vault.id());
        assert!(!is_cost);
        assert_eq!(raw, 0);
        assert_eq!(vector[amount, absorbed, uncovered, restored, reserve], vector[0, 0, 0, 0, SEED_RESERVE]);
        assert_eq!(previous, replayed);
        assert_eq!(current, updates[index]);
        replayed = current;
    });
    assert_eq!(replayed, *vault.venue().checkpoint());
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_zero_net_checkpoint_emits_once_and_preserves_the_buffer() {
    // A flat position: the rates move and the snapshots refresh, but nothing settles.
    let mut fixture = start();
    let initial = flat_checkpoint(RATE, RATE);
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = flat_checkpoint(RATE, RATE + ATOM_FIXED);
    let after = flat_checkpoint(RATE + ATOM_FIXED, RATE + ATOM_FIXED);
    let change = initial.sync_change(&before, &after, ONE_FIXED);
    vault.apply_connected_change(after, change);
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(*vault.venue().checkpoint(), after);
    let facts = events::collect<events::FundingSettled<Product>>();
    assert_eq!(facts.length(), 1);
    let (_, is_cost, raw, amount, absorbed, uncovered, _, reserve, previous, current) =
        facts.borrow(0).funding_settled_fields();
    assert!(!is_cost);
    assert_eq!(raw, 0);
    assert_eq!(vector[amount, absorbed, uncovered, reserve], vector[0, 0, 0, SEED_RESERVE]);
    assert_eq!(previous, initial);
    assert_eq!(current, after);
    let unchanged = after.sync_change(&after, &after, ONE_FIXED);
    vault.apply_connected_change(after, unchanged);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    destroy(vault);
    fixture.end();
}

#[test]
fun gross_funding_width_is_checked_only_after_the_signed_net() {
    let large = (18_446_744_073_709_551_615u256 + 10) * ATOM_FIXED;
    let (external_rate, local_rate) = (2 * large, 2 * large - (large - ATOM_FIXED));
    let stored = checkpoint_with_market_imr(0, large + 100 * ATOM_FIXED, large, large, large, large, 1);
    let before = checkpoint_with_market_imr(0, 100 * ATOM_FIXED, external_rate, external_rate, local_rate, local_rate, 1);
    let after = checkpoint_with_market_imr(0, large + 99 * ATOM_FIXED, local_rate, local_rate, local_rate, local_rate, 1);
    let (external, local) = stored.classify_sync_changes(&before, &after, ONE_FIXED);
    let net = external.net_funding(local);
    let (has_funding, is_cost, raw, amount, clean) =
        (net.has_funding(), net.is_cost(), net.raw_amount(), net.amount(), net.is_clean());
    assert!(clean && has_funding && is_cost);
    assert_eq!(raw, ATOM_FIXED);
    assert_eq!(amount, 1);
}

#[test]
fun connected_unresolved_drift_preserves_the_accepted_checkpoint_across_retries() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let costed_rate = settled_rate(10, true);
    // A changed market IMR alone is venue policy; the free-collateral move is what the classifier cannot explain.
    let before = checkpoint_with_market_imr(1, ALLOCATED_FIXED, RATE, RATE, costed_rate, costed_rate, 2);
    let after = checkpoint_with_market_imr(
        1, ALLOCATED_FIXED - 10 * ATOM_FIXED, costed_rate, costed_rate, costed_rate, costed_rate, 2,
    );
    let unexpected = initial.sync_change(&before, &after, ONE_FIXED);

    vault.apply_connected_change(after, unexpected);

    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(*vault.venue().checkpoint(), initial);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    let (_, checkpoint) = events::collect_one<events::CheckpointDrifted<Product>>(0).checkpoint_drifted_fields();
    assert_eq!(checkpoint, after);

    let replay = vault.venue().checkpoint().sync_change(&after, &after, ONE_FIXED);
    vault.apply_connected_change(after, replay);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 2);
    assert_eq!(*vault.venue().checkpoint(), initial);
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_temporary_health_fault_keeps_lifecycle_and_emits_no_mutation() {
    let mut fixture = start();
    let checkpoint = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, checkpoint);
    let unchanged = checkpoint.sync_change(&checkpoint, &checkpoint, ONE_FIXED);
    vault.apply_connected_change(checkpoint, unchanged);

    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(*vault.venue().checkpoint(), checkpoint);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);

    let repeated = checkpoint.sync_change(&checkpoint, &checkpoint, ONE_FIXED);
    vault.apply_connected_change(checkpoint, repeated);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
fun reducer_reconstructs_every_canonical_vault_fact_from_the_event_stream() {
    let mut fixture = start();
    let initial_checkpoint = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint);
    let vault_id = vault.id();

    let funded_checkpoint = funding_checkpoint(10, true);
    let funding_before = funding_before_checkpoint(10, true);
    let funding = initial_checkpoint.sync_change(&funding_before, &funded_checkpoint, ONE_FIXED);
    vault.apply_connected_change(funded_checkpoint, funding);
    vault.set_max_order_notional(
        &fixture.protocol, &risk_admin(), 300, observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), LOT_SIZE, REFERENCE_AT_MS,
    );
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());

    let costed_rate = settled_rate(10, true);
    let final_checkpoint = checkpoint_with_market_imr(
        1, ALLOCATED_FIXED - 10 * ATOM_FIXED, costed_rate, costed_rate, costed_rate, costed_rate, 1,
    );
    let unexpected = funded_checkpoint.sync_change(&final_checkpoint, &final_checkpoint, ONE_FIXED);
    vault.apply_connected_change(final_checkpoint, unexpected);

    let mut replay = replay_issued(
        events::collect_one<events::VaultIssued<Product>>(0),
    );
    replay.replay_initialized(
        events::collect_one<events::VaultInitialized<Product>>(0),
    );
    replay.replay_funding(
        events::collect_one<events::FundingSettled<Product>>(0),
    );
    replay.replay_max_order_notional(
        events::collect_one<events::MaxOrderNotionalUpdated<Product>>(0),
    );
    replay.replay_shutdown(
        events::collect_one<events::ShutdownBegun<Product>>(0),
    );
    replay.replay_drift(
        events::collect_one<events::CheckpointDrifted<Product>>(0),
    );

    assert_eq!(replay.binding, option::some(vault.venue().binding()));
    assert_eq!(replay.vault_id, vault_id);
    assert_eq!(replay.maintenance_reserve, vault.state().maintenance_reserve());
    assert_eq!(replay.lifecycle == 2, vault.is_unwinding_for_testing());
    let actual_order_notional = vault.max_order_notional_for_testing();
    assert_eq!(replay.max_order_notional, actual_order_notional);
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue().checkpoint());
    assert_eq!(*vault.venue().checkpoint(), funded_checkpoint);
    assert_eq!(*replay.unresolved_checkpoint.borrow(), final_checkpoint);

    destroy(vault);
    fixture.end();
}

#[test]
fun an_unchanged_nonnegative_position_imr_survives_the_seed_orders() {
    operations::assert_position_imr_unchanged_for_testing(false, 1, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun a_position_imr_the_seed_orders_changed_is_rejected() {
    operations::assert_position_imr_unchanged_for_testing(false, 2, 1);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun a_negative_final_position_imr_is_rejected_even_when_its_bits_match() {
    operations::assert_position_imr_unchanged_for_testing(true, 1, 1);
}

#[test]
fun settlement_valuation_accepts_two_enabled_positive_prices() {
    operations::assert_settlement_valuation_for_testing(true, PRICE as u256, false, PRICE as u256, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun settlement_valuation_rejects_a_disabled_settlement() {
    operations::assert_settlement_valuation_for_testing(false, PRICE as u256, false, PRICE as u256, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun settlement_valuation_rejects_a_zero_base_price() {
    operations::assert_settlement_valuation_for_testing(true, 0, false, PRICE as u256, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun settlement_valuation_rejects_a_zero_collateral_price() {
    operations::assert_settlement_valuation_for_testing(true, PRICE as u256, false, 0, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun settlement_valuation_rejects_a_negative_base_price() {
    operations::assert_settlement_valuation_for_testing(true, PRICE as u256, true, PRICE as u256, false);
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun settlement_valuation_rejects_a_negative_collateral_price() {
    operations::assert_settlement_valuation_for_testing(true, PRICE as u256, false, PRICE as u256, true);
}

#[test]
fun vault_initialized_event_reads_activation_facts_from_the_vault() {
    let mut fixture = start();
    let vault = issue_and_activate_product_with_side(&mut fixture, OtherProduct(), initial_checkpoint(),
        standard_vault_policy_for_side(policy::short()), policy::short());
    let (
        vault_id, binding, seed_amount, seed_venue_equity, seed_reserve, seed_shareholder_nav,
        locked_shares, position_base, lot_size, side, position_imr, checkpoint,
    ) = events::collect_one<events::VaultInitialized<OtherProduct>>(0).vault_initialized_fields();
    assert_eq!(vault_id, vault.id());
    assert_eq!(binding, vault.venue().binding());
    assert_eq!(vector[seed_amount, seed_venue_equity], vector[SEED_EQUITY, SEED_EQUITY]);
    assert_eq!(seed_reserve, vault.state().maintenance_reserve());
    assert_eq!(seed_reserve, SEED_RESERVE);
    assert_eq!(seed_shareholder_nav, SEED_EQUITY - SEED_RESERVE);
    assert_eq!(locked_shares, vault.locked_shares());
    assert_eq!(vector[position_base, lot_size], vector[ABSOLUTE_BASE, LOT_SIZE]);
    assert_eq!(side, policy::short());
    assert_eq!(position_imr, 1);
    assert_eq!(checkpoint, *vault.venue().checkpoint());
    assert_eq!(checkpoint, initial_checkpoint());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::operations)]
fun completed_redemption_rejects_a_payout_one_atom_short() {
    complete_redemption_with_cash(993);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::operations)]
fun completed_redemption_rejects_a_payout_one_atom_over() {
    complete_redemption_with_cash(995);
}

#[test]
fun unrepresentable_net_funding_is_drift_not_settlement() {
    let mut fixture = start();
    let large = (std::u64::max_value!() as u256 + 10) * ATOM_FIXED;
    let stored = checkpoint_with_market_imr(0, large + 100 * ATOM_FIXED, large, large, large, large, 1);
    let before = checkpoint_with_market_imr(0, 100 * ATOM_FIXED, 2 * large, 2 * large, 2 * large, 2 * large, 1);
    let mut vault = issue_and_activate(&mut fixture, stored);
    let (external, local) = stored.classify_sync_changes(&before, &before, ONE_FIXED);

    vault.apply_post_captures_for_testing(before, external, local);

    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(*vault.venue().checkpoint(), stored);
    assert!(!vault.is_unwinding_for_testing());
    let (_, drifted) = events::collect_one<events::CheckpointDrifted<Product>>(0).checkpoint_drifted_fields();
    assert_eq!(drifted, before);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
fun two_edge_netting_debits_two_costs_from_the_reserve_once() {
    assert_two_edge_netting(10, true, 5, true, 85, 15, true);
}

#[test]
fun two_edge_netting_credits_two_credits_to_the_reserve_once() {
    assert_two_edge_netting(10, false, 5, false, 115, 15, false);
}

#[test]
fun two_edge_netting_keeps_the_remainder_of_a_credit_over_a_smaller_cost() {
    assert_two_edge_netting(10, false, 4, true, 106, 6, false);
}

#[test]
fun two_edge_netting_keeps_the_remainder_of_a_cost_under_a_larger_credit() {
    assert_two_edge_netting(4, true, 10, false, 106, 6, false);
}

#[test]
fun two_edge_netting_treats_an_unexpected_external_edge_as_drift() {
    assert_unexpected_edge_keeps_the_checkpoint(true);
}

#[test]
fun two_edge_netting_treats_an_unexpected_local_edge_as_drift() {
    assert_unexpected_edge_keeps_the_checkpoint(false);
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun funding_settles_while_unwinding_and_aborts_once_settled() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, initial);
    let (before, funded) = (funding_before_checkpoint(10, true), funding_checkpoint(10, true));
    let cost = initial.sync_change(&before, &funded, ONE_FIXED);
    vault.apply_connected_change(funded, cost);
    assert_eq!(vault.state().maintenance_reserve(), 90);
    assert_eq!(*vault.venue().checkpoint(), funded);
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));

    let cost = initial.sync_change(&before, &funded, ONE_FIXED);
    vault.apply_connected_change(funded, cost);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_market_unwind_step_records_the_checkpoints_orders_and_quote() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);

    vault.complete_market_unwind_for_testing(before, after, 3, 1_500);

    let (id, observed, actual, orders, quote) =
        events::collect_one<events::UnwindProgress<Product>>(0).unwind_progress_fields();
    assert_eq!(id, vault.id());
    assert_eq!(observed, before);
    assert_eq!(actual, after);
    assert_eq!(orders, 3);
    assert_eq!(quote, option::some(1_500));
    assert_eq!(*vault.venue().checkpoint(), after);
    assert!(vault.is_unwinding_for_testing());
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_market_unwind_step_accepts_the_maximum_order_count() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);

    vault.complete_market_unwind_for_testing(
        before, after, constants::max_active_orders!(), 1_500,
    );

    let (_, _, _, orders, _) = events::collect_one<events::UnwindProgress<Product>>(0).unwind_progress_fields();
    assert_eq!(orders, 16);
    assert_eq!(*vault.venue().checkpoint(), after);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun completed_market_unwind_step_rejects_one_order_past_the_maximum() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_market_unwind_for_testing(
        before, after, constants::max_active_orders!() + 1, 1_500,
    );
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun completed_market_unwind_step_rejects_a_quote_without_orders() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_market_unwind_for_testing(before, after, 0, 1_500);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun completed_direct_settlement_rejects_an_unpaused_market() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    vault.complete_settlement_unwind_for_testing(before, settled_flat_checkpoint(), ONE_FIXED);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun unwind_progress_is_rejected_while_active() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_activate(&mut fixture, before);
    vault.complete_market_unwind_for_testing(before, after, 3, 1_500);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun finalization_is_rejected_before_shutdown_begins() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun completed_mint_is_rejected_after_shutdown_begins() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, 10, REFERENCE_AT_MS);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let shares = vault.complete_mint_for_testing<Product, Collateral>(
        plan, 1_000, active_position(1_998, 3_798), initial_checkpoint(), REFERENCE_AT_MS, fixture.ctx!(),
    );
    destroy(shares);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_rebalance_reports_an_increase() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    // 1_000 notional on a 900 NAV is 1.11x, under the 1.6x band floor; the
    // 250 order cap sizes the buy and its 4 atoms of execution cost fit the target.
    let mut plan = vault.state().prepare_rebalance(rebalance_position(1_000, 1_000_000), 10, REFERENCE_AT_MS);
    let order = vault.state().next_rebalance_order(&plan);
    assert!(order.is_increase() && !order.is_emergency());
    assert_eq!(order.order_base(), 247_524);
    vault.state().accept_rebalance_fill(&mut plan, order, rebalance_position(999, 1_247_524), 247_524, REFERENCE_AT_MS);
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);

    vault.complete_rebalance_for_testing<Product, Collateral>(plan, checkpoint);

    let (before_equity, after_equity, before_base, after_base, increased) =
        events::collect_one<events::Rebalanced<Product>>(0).rebalanced_amounts();
    assert_eq!(vector[before_equity, after_equity, before_base, after_base], vector[1_000, 999, 1_000_000, 1_247_524]);
    assert!(increased);
    assert_eq!(*vault.venue().checkpoint(), checkpoint);
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(vault.total_share_supply(), 900_000);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EZeroAmount, location = blast_boosts_core::state)]
fun zero_donation_is_rejected_by_the_core_after_a_trivially_exact_checkpoint() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    vault.complete_donation_for_testing(position_observation(SEED_EQUITY), initial, 0, REFERENCE_AT_MS);
    destroy(vault);
    fixture.end();
}

#[test]
fun zero_allocated_deposit_checkpoint_accepts_only_an_identical_venue() {
    let initial = initial_checkpoint();
    initial.assert_allocated_deposit_checkpoint(&initial, 0);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun zero_allocated_deposit_checkpoint_rejects_free_collateral_that_moved() {
    let after = checkpoint_with_market_imr(1, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    initial_checkpoint().assert_allocated_deposit_checkpoint(&after, 0);
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun active_checkpoint_rejects_a_position_that_differs_from_the_fill() {
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    initial_checkpoint().assert_trade_checkpoint(&after, 2 * ONE_FIXED, 1);
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun active_checkpoint_rejects_a_quote_that_differs_from_the_fill() {
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    initial_checkpoint().assert_trade_checkpoint(&after, ONE_FIXED, 2);
}

#[test]
fun reduction_checkpoint_adopts_the_venue_quote_and_proves_only_the_base() {
    initial_checkpoint().assert_reduction_checkpoint(&reduced_checkpoint(), ONE_FIXED / 2);
}

#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun reduction_checkpoint_rejects_a_base_the_fill_did_not_leave() {
    initial_checkpoint().assert_reduction_checkpoint(&reduced_checkpoint(), ONE_FIXED);
}

#[test]
fun unchanged_checkpoint_passes_the_priced_operation_gate() {
    let checkpoint = initial_checkpoint();
    checkpoint.assert_unchanged(&checkpoint);
}

#[test]
fun redemption_cash_checkpoint_with_no_free_cash_deallocates_the_whole_payout() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 15 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_withdrawal_checkpoint(&after, 15);
}

#[test]
fun redemption_cash_checkpoint_paid_exactly_by_free_cash() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = initial_checkpoint();
    before.assert_withdrawal_checkpoint(&after, 25);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun cash_checkpoint_rejects_free_collateral_that_disagrees_with_the_payout() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(6, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_withdrawal_checkpoint(&after, 20);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun cash_checkpoint_rejects_an_unrelated_field_change_after_an_exact_move() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(5, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 2);
    before.assert_withdrawal_checkpoint(&after, 20);
}

#[test]
fun net_funding_adds_two_costs_and_keeps_the_larger_side_of_a_cost_and_a_credit() {
    let (before, after) = two_edge_checkpoints(10, true, 5, true);
    let (external, local) = initial_checkpoint().classify_sync_changes(&before, &after, ONE_FIXED);
    let net = external.net_funding(local);
    assert!(net.is_clean() && net.is_cost());
    assert_eq!(net.raw_amount(), 15 * ATOM_FIXED);
    assert_eq!(net.amount(), 15);

    let (before, after) = two_edge_checkpoints(10, true, 15, false);
    let (external, local) = initial_checkpoint().classify_sync_changes(&before, &after, ONE_FIXED);
    let net = external.net_funding(local);
    assert!(net.is_clean() && !net.is_cost());
    assert_eq!(net.raw_amount(), 5 * ATOM_FIXED);
    assert_eq!(net.amount(), 5);
    assert!(net.is_credit_for_testing());
}

// === Test Helpers ===

/// Same account shape on a closed market; raw signed values stay explicit.
fun a4_checkpoint(base: u256, allocated: u256, snapshot: u256, market: u256, free: u64): Checkpoint {
    checkpoint::checkpoint_for_testing(free, allocated, base, base, snapshot, snapshot, market, market,
        LOT_SIZE, 0, 0, 0, 1, false, 1, 1, 1)
}

fun a4_signed(magnitude: u256, negative: bool): u256 {
    if (negative && magnitude > 0) { std::u256::max_value!() - magnitude + 1 } else { magnitude }
}

fun a4_book_close(short: bool, cost: bool, amount: u64, with_deficit: bool, recovered: u64) {
    let mut fixture = start();
    let side = if (short) { policy::short() } else { policy::long() };
    // The settlement collateral price is $2, independently of the fixture's $1 oracle.
    let market = a4_signed((amount as u256) * ATOM_FIXED * 2, short == cost);
    let before = a4_checkpoint(a4_signed(ONE_FIXED, short), ALLOCATED_FIXED, 0, market, 0);
    let after = a4_checkpoint(0, 0, market, market, recovered);
    let mut vault = issue_and_activate_product_with_side(&mut fixture, Product(), before,
        standard_vault_policy_for_side(side), side);
    if (with_deficit) { vault.state_mut().settle_funding(observation::funding_cost(150)); };
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    let reserve_before = vault.state().maintenance_reserve();
    let deficit_before = vault.state().uncovered_deficit();
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    replay.maintenance_reserve = reserve_before;
    replay.replay_shutdown(events::collect_one<events::ShutdownBegun<Product>>(0));

    vault.complete_settlement_unwind_for_testing(before, after, 2 * ONE_FIXED);

    let funding = events::collect_one<events::FundingSettled<Product>>(0);
    let (id, is_cost, raw, rounded, absorbed, uncovered, restored, reserve, previous, checkpoint) = funding.funding_settled_fields();
    assert_eq!(id, vault.id());
    assert_eq!(is_cost, cost && amount > 0);
    assert_eq!(raw, (amount as u256) * ATOM_FIXED);
    assert_eq!(rounded, amount);
    assert_eq!(previous, before);
    assert_eq!(checkpoint, after);
    let expected_absorbed = if (cost) { amount.min(reserve_before) } else { 0 };
    let expected_restored = if (cost) { 0 } else { amount.min(deficit_before) };
    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, if (cost) { amount - expected_absorbed } else { 0 });
    assert_eq!(restored, expected_restored);
    assert_eq!(reserve, if (cost) { reserve_before - expected_absorbed } else { reserve_before + amount - expected_restored });
    assert_eq!(vault.state().uncovered_deficit(), deficit_before + uncovered - restored);
    replay.replay_funding(funding);
    replay.assert_replay(&vault);
    let (id, observed, final_checkpoint, orders, quote) =
        events::collect_one<events::UnwindProgress<Product>>(0).unwind_progress_fields();
    assert_eq!(id, vault.id());
    assert_eq!(observed, before);
    assert_eq!(final_checkpoint, after);
    assert_eq!(orders, 0);
    assert!(quote.is_none());
    assert!(events::collect<events::CheckpointDrifted<Product>>().is_empty());
    destroy(vault);
    fixture.end();
}

fun a4_net_close(external_cost: bool, external: u256, local: u256) {
    let mut fixture = start();
    // A large initial allocation admits the cancellation test without a liability.
    let allocated = ALLOCATED_FIXED + external;
    let stored = a4_checkpoint(ONE_FIXED, allocated, 0, 0, 0);
    let snapshot = a4_signed(external, !external_cost);
    let before_allocated = if (external_cost) { allocated - external } else { allocated + external };
    let net_cost = if (external >= local) { external_cost } else { !external_cost };
    let magnitude = external.diff(local);
    let market = a4_signed(magnitude, !net_cost);
    let before = a4_checkpoint(ONE_FIXED, before_allocated, snapshot, market, 0);
    let after = a4_checkpoint(0, 0, market, market, 1_000);
    let mut vault = issue_and_begin_shutdown(&mut fixture, stored);
    vault.complete_settlement_unwind_for_testing(before, after, ONE_FIXED);
    let (_, cost, raw, amount, absorbed, uncovered, restored, reserve, previous, checkpoint) =
        events::collect_one<events::FundingSettled<Product>>(0).funding_settled_fields();
    let rounded = (magnitude / ATOM_FIXED + if (net_cost && magnitude % ATOM_FIXED != 0) { 1 } else { 0 }) as u64;
    assert_eq!(cost, net_cost && magnitude > 0);
    assert_eq!(raw, magnitude);
    assert_eq!(amount, rounded);
    assert_eq!(absorbed, if (cost) { rounded } else { 0 });
    assert_eq!(vector[uncovered, restored], vector[0, 0]);
    assert_eq!(reserve, if (cost) { SEED_RESERVE - rounded } else { SEED_RESERVE + rounded });
    assert_eq!(vault.state().maintenance_reserve(), reserve);
    assert_eq!(previous, stored);
    assert_eq!(checkpoint, after);
    assert!(events::collect<events::CheckpointDrifted<Product>>().is_empty());
    destroy(vault);
    fixture.end();
}

fun a4_protected_close(short: bool, cost: bool) {
    let mut fixture = start();
    let side = if (short) { policy::short() } else { policy::long() };
    let raw_base = 100_000_000_000;
    let market = a4_signed(10 * ATOM_FIXED * 2 * ONE_FIXED / raw_base, short == cost);
    let before = a4_checkpoint(a4_signed(raw_base, short), ALLOCATED_FIXED, 0, market, 0);
    let after = a4_checkpoint(0, 0, market, market, 1_001);
    let mut vault = issue_and_activate_product_with_side(&mut fixture, Product(), before,
        standard_vault_policy_for_side(side), side);
    let locked = vault.locked_shares();
    let shares = vault.mint_shares(locked, fixture.ctx!());
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    replay.supply = replay.supply + locked;
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, before, REFERENCE_AT_MS);
    replay.replay_protected_shutdown(events::collect_one<events::ProtectedShutdownBegun<Product>>(0));
    vault.complete_settlement_unwind_for_testing(before, after, 2 * ONE_FIXED);
    replay.replay_funding(events::collect_one<events::FundingSettled<Product>>(0));
    let reserve = if (cost) { 90 } else { 110 };
    assert_eq!(vault.state().maintenance_reserve(), reserve);
    let withdrawn = a4_checkpoint(0, 0, market, market, 0);
    after.assert_terminal_withdrawal_checkpoint(&withdrawn, 1_001);
    vault.complete_finalization_for_testing(withdrawn, sui::coin::mint_for_testing<Collateral>(1_001, fixture.ctx!()));
    let finalized = events::collect_one<events::ShutdownFinalized<Product>>(0);
    let (id, recovered, eligible, checkpoint, remainder, protected_reserve, protected_seed) = finalized.shutdown_finalized_fields();
    assert_eq!(id, vault.id());
    assert_eq!(recovered, 1_001);
    assert_eq!(eligible, locked);
    assert_eq!(checkpoint, withdrawn);
    assert_eq!(remainder, 0);
    assert_eq!(protected_reserve, reserve);
    let holder_pool = (1_001 - reserve) / 2;
    assert_eq!(protected_seed, 1_001 - reserve - holder_pool);
    replay.replay_finalization(finalized);
    let clock = reference_clock(&mut fixture);
    let cash = vault.redeem_shutdown(&fixture.protocol, shares, holder_pool, REFERENCE_AT_MS, &clock, fixture.ctx!());
    assert_eq!(cash.value(), holder_pool);
    replay.replay_terminal_claim(events::collect_one<events::ShutdownRedeemed<Product>>(0));
    assert_eq!(vault.terminal_cash_for_testing(), 0);
    assert_eq!(vault.total_share_supply(), locked);
    assert_eq!(vault.protected_cash_for_testing(), reserve + protected_seed);
    replay.assert_replay(&vault);
    destroy(cash);
    destroy(clock);
    destroy(vault);
    fixture.end();
}


/// Authenticated raw-capture seam: no live price, NAV, mark or margin validation.
/// The fixture deliberately has no equity and unusable margins. Real venue execution
/// and the binding graph remain separate deployment evidence.
fun protected_checkpoint(base: u256, lot: u64, asks: u256, bids: u256, orders: u64): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 0, base, 0, RATE, RATE, RATE, RATE, lot,
        asks, bids, orders, 0, false, 0, 0, 0)
}

fun protected_policy_case(pause: u8, frozen: bool, base: u256, lot: u64) {
    let mut fixture = start();
    let before = protected_checkpoint(100_000_000_000, 1, 0, 0, 0);
    let after = checkpoint::checkpoint_for_testing(0, 0, base, 0, RATE, RATE, RATE + 1, RATE + 2, lot,
        0, 0, 0, pause, frozen, 0, 1, 1);
    let mut vault = issue_and_activate(&mut fixture, before);
    let locked = vault.locked_shares();
    let shares = vault.mint_shares(locked, fixture.ctx!());
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, after, REFERENCE_AT_MS);
    vault.state().assert_unwinding();
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(*vault.venue().checkpoint(), after);
    let (_, event_checkpoint, _, _) = events::collect_one<events::ProtectedShutdownBegun<Product>>(0).protected_shutdown_begun_fields();
    assert_eq!(event_checkpoint, after);
    destroy(shares);
    destroy(vault);
    fixture.end();
}

fun protected_funding_case(account_first: bool) {
    let mut fixture = start();
    let before = checkpoint::checkpoint_for_testing(0, 20 * ATOM_FIXED, 100_000_000_000, 0,
        RATE, RATE, RATE, RATE, 1, 0, 0, 0, 0, false, 0, 0, 0);
    let after = checkpoint::checkpoint_for_testing(0, 15 * ATOM_FIXED, 100_000_000_000, 0,
        RATE + 1, RATE + 1, RATE + 1, RATE + 1, 1, 0, 0, 0, 0, false, 0, 0, 0);
    let mut vault = issue_and_activate(&mut fixture, before);
    let locked = vault.locked_shares();
    let shares = vault.mint_shares(locked, fixture.ctx!());
    if (account_first) {
        let change = before.classify_preexisting(&after);
        assert!(change.is_cost());
        assert_eq!(change.amount(), 5);
        vault.apply_post_capture_for_testing(after, change);
    };
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, after, REFERENCE_AT_MS);
    vault.state().assert_unwinding();
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE - 5);
    assert_eq!(*vault.venue().checkpoint(), after);
    destroy(shares);
    destroy(vault);
    fixture.end();
}

fun protected_trigger_case(base: u256, lot: u64, asks: u256, bids: u256, orders: u64, minted: u64, drift: bool) {
    let mut fixture = start();
    let checkpoint = protected_checkpoint(base, lot, asks, bids, orders);
    let mut vault = issue_and_activate(&mut fixture, checkpoint);
    let shares = vault.mint_shares(minted, fixture.ctx!());
    let observed = if (drift) protected_checkpoint(base + 1_000_000_000, lot, asks, bids, orders) else checkpoint;
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, observed, REFERENCE_AT_MS);
    destroy(shares);
    destroy(vault);
    fixture.end();
}

/// Replays the new trigger/allocation events and actual native coin claims.
fun protected_exit<Tag: drop>(product: Tag, side: PositionSide, recovered: u64) {
    let mut fixture = start();
    let raw_base = if (side == policy::long()) 100_000_000_000 else (std::u256::max_value!() - 100_000_000_000 + 1);
    let checkpoint = protected_checkpoint(raw_base, 1, 0, 0, 0);
    let mut vault = issue_and_activate_product_with_side(&mut fixture, product, checkpoint,
        standard_vault_policy_for_side(side), side);
    let locked = vault.total_share_supply();
    let mut shares = vault.mint_shares(locked, fixture.ctx!());
    // Earned admin cash remains distinct from both protected and holder cash.
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(7));
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Tag>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Tag>>(0));
    // Fixture-only mint/admin deposit establish the initial native balances.
    replay.supply = replay.supply + locked;
    replay.admin_cash = 7;
    vault.begin_protected_shutdown_for_testing(&fixture.protocol, checkpoint, REFERENCE_AT_MS);
    vault.state().assert_unwinding();
    replay.replay_protected_shutdown(events::collect_one<events::ProtectedShutdownBegun<Tag>>(0));
    assert_eq!(events::collect<events::ShutdownBegun<Tag>>().length(), 0);
    vault.finalize_recovered(sui::coin::mint_for_testing<Collateral>(recovered, fixture.ctx!()));
    replay.replay_finalization(events::collect_one<events::ShutdownFinalized<Tag>>(0));
    let reserve_cash = recovered.min(SEED_RESERVE);
    let holder_pool = (recovered - reserve_cash) / 2;
    let seed_cash = recovered - reserve_cash - holder_pool;
    assert_eq!(replay.lifecycle, 3);
    assert_eq!(replay.maintenance_reserve, 0);
    assert_eq!(replay.terminal_cash, holder_pool);
    assert_eq!(replay.protected_cash, reserve_cash + seed_cash);
    assert_eq!(*replay.checkpoint.borrow(), terminal_checkpoint());
    assert_eq!(replay.unrecoverable_collateral_raw, 0);
    let clock = fixture.reference_clock();
    let first = shares.split(locked / 3, fixture.ctx!());
    let first_out = vault.redeem_shutdown(&fixture.protocol, first, 0, REFERENCE_AT_MS, &clock, fixture.ctx!());
    let last_out = vault.redeem_shutdown(&fixture.protocol, shares, 0, REFERENCE_AT_MS, &clock, fixture.ctx!());
    assert_eq!(first_out.value() + last_out.value(), holder_pool);
    let claims = events::collect<events::ShutdownRedeemed<Tag>>();
    assert_eq!(claims.length(), 2);
    replay.replay_terminal_claim(claims[0]);
    replay.replay_terminal_claim(claims[1]);
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing());
    assert_eq!(replay.protected_cash, vault.protected_cash_for_testing());
    assert_eq!(replay.supply, vault.total_share_supply());
    let (_, first_burn, first_paid, remaining_cash, remaining_eligible) = claims[0].shutdown_redeemed_fields();
    assert_eq!(vector[first_burn, first_paid, remaining_cash, remaining_eligible],
        vector[locked / 3, first_out.value(), holder_pool - first_out.value(), locked - locked / 3]);
    let (_, last_burn, last_paid, remaining_cash, remaining_eligible) = claims[1].shutdown_redeemed_fields();
    assert_eq!(vector[last_burn, last_paid, remaining_cash, remaining_eligible],
        vector[locked - locked / 3, last_out.value(), 0, 0]);
    let admin = vault.withdraw_admin_fees(&fixture.protocol, &risk_admin(), 7, fixture.ctx!());
    assert_eq!(admin.value(), 7);
    assert_eq!(vault.protected_cash_for_testing(), reserve_cash + seed_cash);
    assert_eq!(vault.terminal_cash_for_testing(), 0);
    assert_eq!(vault.admin_cash_balance(), 0);
    assert_eq!(vault.total_share_supply(), locked);
    destroy(first_out);
    destroy(last_out);
    destroy(admin);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

fun recover_with_funding(is_cost: bool, amount: u64, with_deficit: bool, short: bool) {
    let mut fixture = start();
    let side = if (short) { policy::short() } else { policy::long() };
    let previous = if (short) { short_recovery_checkpoint(1_000, 1_800) } else { recovery_checkpoint(1_000, 1_800) };
    let mut vault = issue_and_activate_product_with_side(&mut fixture, Product(), previous,
        standard_vault_policy_for_side(side), side);
    if (with_deficit) {
        let (_, _, _) = vault.state_mut().settle_funding(observation::funding_cost(150));
    };
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Product>>(0));
    replay.maintenance_reserve = vault.state().maintenance_reserve();
    let supply = vault.total_share_supply();
    let reserve_before = vault.state().maintenance_reserve();
    let deficit_before = vault.state().uncovered_deficit();
    // A 0.001-base remainder turns this rate delta into exactly `amount` atoms.
    let delta = (amount as u256) * ONE_FIXED / 1_000;
    let market = if (is_cost != short) { RATE + delta } else { RATE - delta };
    let equity = if (is_cost) { 550 - amount } else { 550 + amount };
    let before = funding_recovery_capture(550, RATE, market, short);
    let before_checkpoint = before.checkpoint();
    let after = funding_recovery_capture(equity, market, market, short);
    let after_checkpoint = after.checkpoint();
    vault.rebaseline_from_captures_for_testing(&fixture.protocol, &risk_admin(), before, after, REFERENCE_AT_MS);

    let baseline = events::collect_one<events::CheckpointRebaselined<Product>>(0);
    let (_, event_previous, event_before) = baseline.checkpoint_rebaselined_fields();
    assert_eq!(event_previous, previous);
    assert_eq!(event_before, before_checkpoint);
    replay.replay_rebaseline(baseline);
    let funding = events::collect_one<events::FundingSettled<Product>>(0);
    let (_, event_cost, raw, rounded, absorbed, uncovered, restored, reserve_after, event_before, event_after) =
        funding.funding_settled_fields();
    assert_eq!(event_cost, is_cost);
    assert_eq!(raw, (amount as u256) * ATOM_FIXED);
    assert_eq!(rounded, amount);
    assert_eq!(event_before, before_checkpoint);
    assert_eq!(event_after, after_checkpoint);
    if (is_cost) {
        assert_eq!(absorbed, amount.min(reserve_before));
        assert_eq!(uncovered, amount - absorbed);
        assert_eq!(restored, 0);
        assert_eq!(reserve_after, reserve_before - absorbed);
        assert_eq!(vault.state().uncovered_deficit(), deficit_before + uncovered);
    } else {
        assert_eq!(absorbed, 0);
        assert_eq!(uncovered, 0);
        assert_eq!(restored, amount.min(deficit_before));
        assert_eq!(reserve_after, reserve_before + amount - restored);
        assert_eq!(vault.state().uncovered_deficit(), deficit_before - restored);
    };
    replay.replay_funding(funding);
    replay.assert_replay(&vault);
    assert_eq!(vault.total_share_supply(), supply);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert!(vault.state().is_active_for_testing());
    assert_eq!(*vault.venue().checkpoint(), after_checkpoint);
    destroy(vault);
    fixture.end();
}

fun funding_recovery_capture(equity: u64, snapshot: u256, market: u256, short: bool): CapturedSnapshot {
    let magnitude = 1_000 * ATOM_FIXED;
    let base = if (short) { std::u256::max_value!() - magnitude + 1 } else { magnitude };
    let (snapshot_long, snapshot_short, market_long, market_short) =
        if (short) { (RATE, snapshot, RATE, market) } else { (snapshot, RATE, market, RATE) };
    let checkpoint = checkpoint::checkpoint_for_testing(0, (equity as u256) * ATOM_FIXED, base, base,
        snapshot_long, snapshot_short, market_long, market_short, LOT_SIZE, 0, 0, 0, 0, false, 1, 1, 1);
    snapshot::captured_position_for_testing(checkpoint, equity, 1_000 * BASE_PER_NOTIONAL,
        if (short) { policy::short() } else { policy::long() }, true, true)
}

fun recover_and_rebalance(notional: u64) {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, recovery_checkpoint(1_000, 1_800));
    let after = recovery_checkpoint(550, notional);
    fixture.recover(&mut vault, after, 550, notional, true, true, REFERENCE_AT_MS);
    let mut plan = vault.state().prepare_rebalance(active_position(550, notional), 0, REFERENCE_AT_MS);
    let order = vault.state().next_rebalance_order(&plan);
    assert!(order.is_increase());
    let filled = order.order_base();
    assert!(filled > 0);
    let after_base = notional * BASE_PER_NOTIONAL + filled;
    vault.state().accept_rebalance_fill(&mut plan, order, active_position_with_base(550, after_base), filled, REFERENCE_AT_MS);
    vault.complete_rebalance_for_testing(plan, recovery_checkpoint_with_base(550, after_base));
    assert_eq!(events::collect<events::Rebalanced<Product>>().length(), 1);
    destroy(vault);
    fixture.end();
}

fun recover_short(notional: u64) {
    let mut fixture = start();
    let before = short_recovery_checkpoint(1_000, 1_800);
    let after = short_recovery_checkpoint(550, notional);
    let mut vault = issue_and_activate_product_with_side(&mut fixture, Product(), before,
        standard_vault_policy_for_side(policy::short()), policy::short());
    let capture = snapshot::captured_position_for_testing(after, 550, notional * BASE_PER_NOTIONAL,
        if (notional == 0) { policy::long() } else { policy::short() }, true, true);
    let before_funding = snapshot::captured_position_for_testing(after, 550, notional * BASE_PER_NOTIONAL,
        if (notional == 0) { policy::long() } else { policy::short() }, true, true);
    vault.rebaseline_from_captures_for_testing(&fixture.protocol, &risk_admin(), before_funding, capture, REFERENCE_AT_MS);
    assert_eq!(*vault.venue().checkpoint(), after);
    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert!(vault.state().is_active_for_testing());
    destroy(vault);
    fixture.end();
}

/// Coherent unit-price position: raw base and entry quote are 18-decimal;
/// allocated collateral is six-decimal cash scaled to the venue's carrier.
fun recovery_checkpoint(equity: u64, notional: u64): Checkpoint {
    recovery_checkpoint_with_base(equity, notional * BASE_PER_NOTIONAL)
}

fun short_recovery_checkpoint(equity: u64, notional: u64): Checkpoint {
    let raw = (notional as u256) * ATOM_FIXED;
    let signed = if (raw == 0) { 0 } else { std::u256::max_value!() - raw + 1 };
    checkpoint::checkpoint_for_testing(0, (equity as u256) * ATOM_FIXED, signed, signed,
        RATE, RATE, RATE, RATE, LOT_SIZE, 0, 0, 0, 0, false, 1, 1, 1)
}

fun recovery_checkpoint_with_base(equity: u64, base: u64): Checkpoint {
    checkpoint::checkpoint_for_testing(0, (equity as u256) * ATOM_FIXED,
        (base as u256) * 1_000_000_000, (base as u256) * 1_000_000_000,
        RATE, RATE, RATE, RATE, LOT_SIZE, 0, 0, 0, 0, false, 1, 1, 1)
}

fun recover(
    fixture: &Fixture,
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    equity: u64,
    notional: u64,
    margin_safe: bool,
    venue_operational: bool,
    now_at_ms: u64,
) {
    let capture = snapshot::captured_position_for_testing(
        checkpoint, equity, notional * BASE_PER_NOTIONAL, policy::long(), margin_safe, venue_operational,
    );
    let before_funding = snapshot::captured_position_for_testing(
        checkpoint, equity, notional * BASE_PER_NOTIONAL, policy::long(), margin_safe, venue_operational,
    );
    vault.rebaseline_from_captures_for_testing(&fixture.protocol, &risk_admin(), before_funding, capture, now_at_ms);
}

fun assert_rebalance_gas_at(side: PositionSide, notional: u64, gas_price: u64) {
    let (state, _, _) = state::issue<Product>(
        &vault_issuer(), fee_capped_vault_policy_for_side(side), 250, NAV_CAP, 9, 6,
    ).activate(position_observation_for_side(SEED_EQUITY, side), SEED_RESERVE, REFERENCE_AT_MS);
    let position = active_position_for_side(SEED_EQUITY, notional, side);
    let plan = state.prepare_rebalance(position, 10, REFERENCE_AT_MS);
    plan.assert_gas_price(&ctx_at_gas_price(gas_price));
    destroy(plan);
    state.destroy_for_testing();
}

fun ctx_at_gas_price(gas_price: u64): TxContext {
    tx_context::create(
        SYSTEM,
        tx_context::dummy_tx_hash_with_hint(0),
        0,
        0,
        0,
        REFERENCE_GAS_PRICE,
        gas_price,
        0,
        option::none(),
    )
}

/// Proves and completes the recovery of `recovered` from an otherwise empty venue.
fun finalize_recovered<P>(vault: &mut Vault<P, Collateral>, recovered: Coin<Collateral>) {
    let before = checkpoint::checkpoint_for_testing(recovered.value(), 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    before.assert_terminal_withdrawal_checkpoint(&terminal_checkpoint(), recovered.value());
    vault.complete_finalization_for_testing(terminal_checkpoint(), recovered);
}

fun terminal_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1)
}

/// A closed market, paused with settlement enabled, still holding one unit of base.
fun closed_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1)
}

/// The flat, order-free venue the settlement of `closed_checkpoint` leaves, with its cash released.
fun settled_flat_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(5, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1)
}

/// The venue after a reduce-only fill halved the position at a quote the venue chose.
fun reduced_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, ALLOCATED_FIXED - ATOM_FIXED, ONE_FIXED / 2, 7, RATE, RATE, RATE, RATE, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1)
}

/// An active vault at `checkpoint` whose shutdown has begun.
fun issue_and_begin_shutdown(fixture: &mut Fixture, checkpoint: Checkpoint): Vault<Product, Collateral> {
    let mut vault = issue_and_activate(fixture, checkpoint);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::emergency_reason());
    vault
}

/// Begins shutdown for `reason` under the shutdown admin's witness at the reference time.
fun begin_shutdown_at_reference<Tag>(fixture: &mut Fixture, vault: &mut Vault<Tag, Collateral>, reason: ShutdownReason) {
    let clock = fixture.reference_clock();
    vault.begin_shutdown(&fixture.protocol, &shutdown_admin(), reason, &clock);
    destroy(clock);
}

/// Runs `completed_redemption_burns_the_native_input_only_after_exact_cash_return`
/// with a payout coin of `cash_amount` where the settlement is owed 994.
fun complete_redemption_with_cash(cash_amount: u64) {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let mint_plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, 10, REFERENCE_AT_MS);
    let (amount, _, _, _, _) = vault.state_mut().complete_mint(mint_plan, active_position(1_998, 3_798), REFERENCE_AT_MS);
    let shares = vault.mint_shares(amount, fixture.ctx!());
    let plan = vault.state().prepare_redemption(active_position(1_998, 3_798), shares.value(), vault.total_share_supply(), 994, REFERENCE_AT_MS);
    let (net, admin, fee, reserve_fee) = vault.settle_redemption_for_testing(
        plan, &shares, active_position_with_base(1_996, 1_801_897), REFERENCE_AT_MS,
    );
    assert_eq!(net + admin, 994);
    let cash = sui::coin::mint_for_testing<Collateral>(cash_amount, fixture.ctx!());
    let final_checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 994 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let cash = vault.complete_redemption_for_testing(shares, cash, net, admin, fee, reserve_fee, final_checkpoint, fixture.ctx!());
    destroy(cash);
    destroy(vault);
    fixture.end();
}

macro fun ctx($self: &mut Fixture): &mut TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

macro fun next_tx($self: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun funding_binding(): Binding {
    venue_account::new_binding(@0xB.to_id(), 7, @0xC.to_id(), @0xD.to_id())
}

fun end(fixture: Fixture) {
    let Fixture { scenario, registry, protocol } = fixture;
    destroy(registry);
    destroy(protocol);
    scenario.end();
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(SYSTEM);
    let registry = coin_registry::create_coin_data_registry_for_testing(
        scenario.ctx(),
    );
    let protocol = protocol::new_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    Fixture { scenario, registry, protocol }
}

fun vault_issuer(): AdminWitness<VaultIssuer> {
    blast_acl::witness_for_testing()
}

fun risk_admin(): AdminWitness<RiskAdmin> {
    blast_acl::witness_for_testing()
}

fun shutdown_admin(): AdminWitness<ShutdownAdmin> {
    blast_acl::witness_for_testing()
}

fun issue_and_activate(
    fixture: &mut Fixture,
    checkpoint: Checkpoint,
): Vault<Product, Collateral> {
    issue_and_activate_with_policy(fixture, checkpoint, standard_vault_policy())
}

/// A clock at the reference time the completion helpers price at.
fun reference_clock(fixture: &mut Fixture): Clock {
    let mut clock = sui::clock::create_for_testing(fixture.ctx!());
    clock.set_for_testing(REFERENCE_AT_MS);
    clock
}

fun add_partner(self: &mut Fixture, partner: &Partner) {
    let witness = risk_admin();
    self.protocol.add_partner(&witness, partner);
}

fun remove_partner(self: &mut Fixture, partner: &Partner, clock: &Clock) {
    let witness = risk_admin();
    self.protocol.remove_partner(&witness, partner, clock);
}

fun issue_and_activate_with_policy(
    fixture: &mut Fixture,
    checkpoint: Checkpoint,
    vault_policy: VaultPolicy,
): Vault<Product, Collateral> {
    issue_and_activate_product(fixture, Product(), checkpoint, vault_policy)
}

fun issue_and_activate_product<Tag: drop>(
    fixture: &mut Fixture,
    product: Tag,
    checkpoint: Checkpoint,
    vault_policy: VaultPolicy,
): Vault<Tag, Collateral> {
    issue_and_activate_product_with_side(fixture, product, checkpoint, vault_policy, policy::long())
}

fun issue_and_activate_product_with_side<Tag: drop>(
    fixture: &mut Fixture,
    _: Tag,
    checkpoint: Checkpoint,
    vault_policy: VaultPolicy,
    side: PositionSide,
): Vault<Tag, Collateral> {
    let Fixture { scenario, registry, protocol } = fixture;
    let issuance = vault::issue<Tag, Collateral>(
        protocol,
        &vault_issuer(),
        registry,
        vault_policy,
        250,
        NAV_CAP,
        b"SYNC".to_string(),
        b"Sync Vault".to_string(),
        b"Connected Task 7 fixture".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let binding = venue_account::new_binding(@0xB.to_id(), 7, @0xC.to_id(), @0xD.to_id());
    let admin_cap = authority::new_for_testing<ACCOUNT, AdminRole>(@0xB.to_id(), scenario.ctx());
    let seeded = observation::new_position(
        SEED_EQUITY, ABSOLUTE_BASE, LOT_SIZE, side,
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    );
    let (vault, seed_nav, _) = issuance.activate(
        seeded, SEED_RESERVE, venue_account::new(binding, checkpoint, admin_cap), REFERENCE_AT_MS, scenario.ctx(),
    );
    vault.emit_vault_initialized_for_testing<Tag, Collateral>(SEED_EQUITY, seed_nav, SEED_EQUITY, ABSOLUTE_BASE, LOT_SIZE, side, 1);

    vault
}

fun position_observation(venue_equity: u64): PositionObservation {
    position_observation_for_side(venue_equity, policy::long())
}

fun position_observation_for_side(venue_equity: u64, side: PositionSide): PositionObservation {
    observation::new_position(venue_equity, ABSOLUTE_BASE, LOT_SIZE, side,
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        PRICE,
    )
}

fun active_position(equity: u64, notional: u64): PositionObservation {
    active_position_for_side(equity, notional, policy::long())
}

/// A live position of an exact base, valued at the unit price rounded up.
fun active_position_with_base(equity: u64, base: u64): PositionObservation {
    observation::new_position(equity, base, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    )
}

/// A live position of `notional` collateral atoms, held as the base that values to it.
fun active_position_for_side(equity: u64, notional: u64, side: PositionSide): PositionObservation {
    observation::new_position(equity, notional * BASE_PER_NOTIONAL, LOT_SIZE, side,
        observation::new_price(PRICE, 0, REFERENCE_AT_MS),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    )
}

fun initial_checkpoint(): Checkpoint {
    checkpoint_with_market_imr(0, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1)
}

/// The cumulative rate after the market moved by `amount` collateral units of
/// funding for the fixture's one-unit long: up for a cost, down for a credit.
fun settled_rate(amount: u64, is_cost: bool): u256 {
    if (is_cost) { RATE + (amount as u256) * ATOM_FIXED } else { RATE - (amount as u256) * ATOM_FIXED }
}

/// The venue before the vault settles: snapshots still at `RATE`, market rates moved.
fun funding_before_checkpoint(amount: u64, is_cost: bool): Checkpoint {
    let rate = settled_rate(amount, is_cost);
    checkpoint_with_market_imr(0, ALLOCATED_FIXED, RATE, RATE, rate, rate, 1)
}

/// The venue after settling `amount`: collateral moved and snapshots refreshed.
fun funding_checkpoint(amount: u64, is_cost: bool): Checkpoint {
    let rate = settled_rate(amount, is_cost);
    let allocated = if (is_cost) {
        ALLOCATED_FIXED - (amount as u256) * ATOM_FIXED
    } else {
        ALLOCATED_FIXED + (amount as u256) * ATOM_FIXED
    };
    checkpoint_with_market_imr(0, allocated, rate, rate, rate, rate, 1)
}

/// A flat position whose rates may move without settling anything.
fun flat_checkpoint(snapshot_rate: u256, market_rate: u256): Checkpoint {
    checkpoint::checkpoint_for_testing(
        0, ALLOCATED_FIXED, 0, 0, snapshot_rate, snapshot_rate, market_rate, market_rate,
        LOT_SIZE, 0, 0, 0, 0, false, 1, 1, 1,
    )
}

/// The seeded position under one lot size and venue-wide policy: pause mode,
/// frozen flag and both market margin ratios.
fun policy_checkpoint(lot_size: u64, pause_mode: u8, frozen: bool, market_imr: u256, market_mmr: u256): Checkpoint {
    checkpoint::checkpoint_for_testing(
        0, ALLOCATED_FIXED, ONE_FIXED, 1, RATE, RATE, RATE, RATE, lot_size, 0, 0, 0, pause_mode, frozen, 1,
        market_imr, market_mmr,
    )
}

fun checkpoint_with_market_imr(
    free_collateral: u64,
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    market_initial_margin_ratio: u256,
): Checkpoint {
    checkpoint::checkpoint_for_testing(
        free_collateral,
        allocated_collateral,
        ONE_FIXED,
        1,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        LOT_SIZE,
        0,
        0,
        0,
        0,
        false,
        1,
        market_initial_margin_ratio,
        1,
    )
}

fun apply_connected_change<Tag>(vault: &mut Vault<Tag, Collateral>, checkpoint: Checkpoint, change: CheckpointChange) {
    vault.apply_post_capture_for_testing(checkpoint, change);
}

fun assert_connected_cost(
    amount: u64,
    expected_reserve: u64,
    expected_absorbed: u64,
    expected_uncovered: u64,
) {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = funding_before_checkpoint(amount, true);
    let funded = funding_checkpoint(amount, true);
    let change = initial.sync_change(&before, &funded, ONE_FIXED);
    vault.apply_connected_change(funded, change);

    assert_eq!(vault.state().maintenance_reserve(), expected_reserve);
    assert_eq!(*vault.venue().checkpoint(), funded);
    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    let event = events::collect_one<events::FundingSettled<Product>>(0);
    let (
        vault_id,
        is_cost,
        raw_amount,
        normalized_amount,
        absorbed,
        uncovered,
        _,
        reserve_after,
        previous_checkpoint,
        checkpoint,
    ) = event.funding_settled_fields();
    assert_eq!(vault_id, vault.id());
    assert!(is_cost);
    assert_eq!(raw_amount, (amount as u256) * ATOM_FIXED);
    assert_eq!(normalized_amount, amount);
    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, expected_uncovered);
    assert_eq!(reserve_after, expected_reserve);
    assert_eq!(previous_checkpoint, initial);
    assert_eq!(checkpoint, funded);

    destroy(vault);
    fixture.end();
}

/// A cumulative rate moved by `amount` collateral units of funding for the
/// fixture's one-unit long: up for a cost, down for a credit.
fun shifted_rate(rate: u256, amount: u64, is_cost: bool): u256 {
    if (is_cost) { rate + (amount as u256) * ATOM_FIXED } else { rate - (amount as u256) * ATOM_FIXED }
}

/// Allocated collateral after the venue settled `amount` of funding: down for a cost, up for a credit.
fun shifted_allocated(allocated: u256, amount: u64, is_cost: bool): u256 {
    if (is_cost) { allocated - (amount as u256) * ATOM_FIXED } else { allocated + (amount as u256) * ATOM_FIXED }
}

/// The venue before and after one sync from `initial_checkpoint`: `external`
/// funding was settled elsewhere since the stored checkpoint, and the market
/// then moved by `local` more, which this settlement moves.
fun two_edge_checkpoints(
    external: u64,
    external_is_cost: bool,
    local: u64,
    local_is_cost: bool,
): (Checkpoint, Checkpoint) {
    let external_rate = shifted_rate(RATE, external, external_is_cost);
    let local_rate = shifted_rate(external_rate, local, local_is_cost);
    let external_allocated = shifted_allocated(ALLOCATED_FIXED, external, external_is_cost);
    let local_allocated = shifted_allocated(external_allocated, local, local_is_cost);
    let before = checkpoint_with_market_imr(
        0, external_allocated, external_rate, external_rate, local_rate, local_rate, 1,
    );
    let after = checkpoint_with_market_imr(0, local_allocated, local_rate, local_rate, local_rate, local_rate, 1);

    (before, after)
}

/// Syncs a fresh vault across the two funding edges and checks the reserve
/// moved once, by the net, with one settlement fact.
fun assert_two_edge_netting(
    external: u64,
    external_is_cost: bool,
    local: u64,
    local_is_cost: bool,
    expected_reserve: u64,
    expected_amount: u64,
    expected_is_cost: bool,
) {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let (before, after) = two_edge_checkpoints(external, external_is_cost, local, local_is_cost);
    let (external_change, local_change) = initial.classify_sync_changes(&before, &after, ONE_FIXED);

    vault.apply_post_captures_for_testing(after, external_change, local_change);

    assert_eq!(vault.state().maintenance_reserve(), expected_reserve);
    assert_eq!(*vault.venue().checkpoint(), after);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);
    let (_, is_cost, raw_amount, amount, _, _, _, reserve_after, previous, checkpoint) =
        events::collect_one<events::FundingSettled<Product>>(0).funding_settled_fields();
    assert_eq!(is_cost, expected_is_cost);
    assert_eq!(raw_amount, (expected_amount as u256) * ATOM_FIXED);
    assert_eq!(amount, expected_amount);
    assert_eq!(reserve_after, expected_reserve);
    assert_eq!(previous, initial);
    assert_eq!(checkpoint, after);
    destroy(vault);
    fixture.end();
}

/// An unexpected edge on either side of a ten-unit cost is drift: nothing settles and the checkpoint is kept.
fun assert_unexpected_edge_keeps_the_checkpoint(external_is_unexpected: bool) {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let funded = funding_checkpoint(10, true);
    let cost = funding_before_checkpoint(10, true).classify_change(&funded, ONE_FIXED);
    assert!(cost.is_cost() && cost.amount() == 10);
    let (external_change, local_change) = if (external_is_unexpected) {
        (checkpoint::unexpected_change(), cost)
    } else {
        (cost, checkpoint::unexpected_change())
    };

    vault.apply_post_captures_for_testing(funded, external_change, local_change);

    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert_eq!(*vault.venue().checkpoint(), initial);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    let (_, drifted) = events::collect_one<events::CheckpointDrifted<Product>>(0).checkpoint_drifted_fields();
    assert_eq!(drifted, funded);
    destroy(vault);
    fixture.end();
}

fun sync_checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    signed_quote_notional: u256,
    signed_base: u256,
    pending_order_count: u64,
): Checkpoint {
    checkpoint::checkpoint_for_testing(
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        1,
        0,
        0,
        pending_order_count,
        0,
        false,
        1,
        1,
        1,
    )
}

/// Both edges of one synchronization netted, as `synchronize` applies them.
fun sync_change(stored: &Checkpoint, before: &Checkpoint, after: &Checkpoint, collateral_price: u256): CheckpointChange {
    let (preexisting_change, local_change) = stored.classify_sync_changes(before, after, collateral_price);
    preexisting_change.net_funding(local_change)
}

fun assert_unexpected_sync_change(
    stored: &Checkpoint,
    before: &Checkpoint,
    after: &Checkpoint,
) {
    let change = stored.sync_change(before, after, ONE_FIXED);
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());

    assert!(!has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 0);
    assert_eq!(amount, 0);
    assert!(!checkpoint_clean);
    assert!(change.is_unexpected_for_testing());
}

fun standard_vault_policy(): VaultPolicy {
    standard_vault_policy_for_side(policy::long())
}

fun standard_vault_policy_for_side(side: PositionSide): VaultPolicy {
    vault_policy_for_side(side, 10, 10, 0)
}

/// The standard policy whose admin may raise fees to 1% and keep 30% of them.
fun fee_capped_vault_policy_for_side(side: PositionSide): VaultPolicy {
    vault_policy_for_side(side, 100, 100, 3_000)
}

fun vault_policy_for_side(
    side: PositionSide,
    mint_fee_cap_bps: u64,
    redeem_fee_cap_bps: u64,
    admin_share_cap_bps: u64,
): VaultPolicy {
    policy::new_vault_policy(
        side,
        policy::new_rebalance_policy(
            16_000,
            20_000,
            26_000,
            30_000,
            100,
            500,
            10,
        ),
        policy::new_price_policy(30_000, 2_000, 100, 500),
        10,
        10,
        mint_fee_cap_bps,
        redeem_fee_cap_bps,
        admin_share_cap_bps,
        100,
        5_000,
    )
}

fun replay_terminal_lifecycle<Tag: drop>(product: Tag, side: PositionSide) {
    let mut fixture = start();
    let vault_policy = fee_capped_vault_policy_for_side(side);
    let mut vault = issue_and_activate_product_with_side(&mut fixture, product, initial_checkpoint(), vault_policy, side);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Tag>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Tag>>(0));
    let witness = risk_admin();
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay.replay_fees(events::collect_one<events::FeesUpdated<Tag>>(0));
    let plan = vault.state().prepare_mint(position_observation_for_side(SEED_EQUITY, side), 10_000, vault.total_share_supply(), 9_989_000, 10, REFERENCE_AT_MS);
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(2));
    let mut shares = vault.complete_mint_for_testing<Tag, Collateral>(
        plan, 10_000,
        active_position_for_side(10_997, 21_780, side), initial_checkpoint(), REFERENCE_AT_MS, fixture.ctx!());
    replay.replay_mint(events::collect_one<events::Minted<Tag>>(0));
    let dirty = checkpoint::checkpoint_for_testing(13, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1);
    vault.apply_connected_change(dirty, checkpoint::unexpected_change());
    replay.replay_drift(events::collect<events::CheckpointDrifted<Tag>>()[0]);
    fixture.begin_shutdown_at_reference(&mut vault, blast_boosts_core::lifecycle::observed_venue_change_reason());
    let shutdown = events::collect_one<events::ShutdownBegun<Tag>>(0);
    assert_eq!(shutdown.shutdown_reason(), blast_boosts_core::lifecycle::observed_venue_change_reason());
    replay.replay_shutdown(shutdown);
    let flat = checkpoint::checkpoint_for_testing(12, 1_000_000_000_001, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1);
    vault.complete_settlement_unwind_for_testing(dirty, flat, ONE_FIXED);
    let (_, before, after, orders, quote) = events::collect_one<events::UnwindProgress<Tag>>(0).unwind_progress_fields();
    assert_eq!(before, dirty);
    assert_eq!(orders, 0);
    assert!(quote.is_none());
    replay.checkpoint = option::some(after);
    let final_checkpoint = checkpoint::checkpoint_for_testing(0, 1, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 1, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
    flat.assert_terminal_withdrawal_checkpoint_decoded_for_testing(&final_checkpoint, recovered.value(), false, 1_000_000_000_001);
    vault.complete_finalization_for_testing(final_checkpoint, recovered);
    assert_eq!(events::collect<events::CheckpointDrifted<Tag>>().length(), 2);
    replay.unresolved_checkpoint = option::none();
    replay.replay_finalization(events::collect_one<events::ShutdownFinalized<Tag>>(0));
    assert_eq!(replay.protected_cash, 0);
    assert_eq!(replay.unrecoverable_collateral_raw, 1);
    assert_eq!(*vault.venue().checkpoint(), final_checkpoint);
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing<Tag, Collateral>());
    let first = shares.split(2_000_000, fixture.ctx!());
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_cash = vault.redeem_shutdown<Tag, Collateral>(&fixture.protocol, first, 2, 0, &clock, fixture.ctx!());
    replay.replay_terminal_claim(events::collect<events::ShutdownRedeemed<Tag>>()[0]);
    let last_cash = vault.redeem_shutdown<Tag, Collateral>(&fixture.protocol, shares, 11, 0, &clock, fixture.ctx!());
    replay.replay_terminal_claim(events::collect<events::ShutdownRedeemed<Tag>>()[1]);
    assert_eq!(first_cash.value() + last_cash.value(), 13);
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing<Tag, Collateral>());
    assert_eq!(replay.supply, vault.total_share_supply());
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue().checkpoint());
    assert!(replay.unresolved_checkpoint.is_none());
    let admin = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 2, fixture.ctx!());
    let (_, paid, remaining) = events::collect_one<events::AdminFeesWithdrawn<Tag>>(0).admin_fees_withdrawn_fields();
    assert_eq!(paid, admin.value());
    assert_eq!(remaining, replay.admin_cash - paid);
    assert_eq!(remaining, vault.admin_cash_balance<_, Collateral>());
    destroy(admin);
    destroy(first_cash);
    destroy(last_cash);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

// Reduces events immediately after each local completion, preserving call order.
// Captures are authenticated-boundary fixtures, not evidence of venue execution.
fun replay_active_economics<Tag>(fixture: &mut Fixture, vault: &mut Vault<Tag, Collateral>) {
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Tag>>(0));
    replay.replay_initialized(events::collect_one<events::VaultInitialized<Tag>>(0));
    replay.assert_replay(vault);

    let witness = risk_admin();
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay.replay_fees(events::collect<events::FeesUpdated<Tag>>()[0]);
    replay.assert_replay(vault);
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 10_000, vault.total_share_supply(), 9_989_000, 10, REFERENCE_AT_MS);
    // Several events in this same transaction: live rates change after the plan seals.
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    replay.replay_fees(events::collect<events::FeesUpdated<Tag>>()[1]);
    replay.assert_replay(vault);
    let partner = partners::new_for_testing(PARTNER_PAYOUT, 5_000, fixture.ctx!());
    let clock = fixture.reference_clock();
    let admin_cash_before = vault.admin_cash_balance<_, Collateral>();
    vault.retain_admin_cash(sui::balance::create_for_testing<Collateral>(2));
    let shares = vault.complete_mint_for_testing<Tag, Collateral>(
        plan, 10_000,
        active_position(10_997, 21_780), initial_checkpoint(), REFERENCE_AT_MS, fixture.ctx!());
    replay.replay_mint(events::collect_one<events::Minted<Tag>>(0));
    replay.assert_replay(vault);
    vault.pay_partner_for_testing(&partner, admin_cash_before, &clock, fixture.ctx!());
    replay.replay_partner_fee_paid(events::collect<events::PartnerFeePaid<Tag>>()[0]);
    replay.assert_replay(vault);

    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay.replay_fees(events::collect<events::FeesUpdated<Tag>>()[2]);
    replay.assert_replay(vault);
    let admin_cash_before = vault.admin_cash_balance<_, Collateral>();
    let plan = vault.state().prepare_redemption(active_position(10_997, 21_780), shares.value(), vault.total_share_supply(), 9_978, REFERENCE_AT_MS);
    let (net, admin, fee, reserve_fee) = vault.settle_redemption_for_testing(
        plan, &shares,
        active_position_with_base(10_996, 1_800_165), REFERENCE_AT_MS);
    let cash = sui::coin::mint_for_testing<Collateral>(9_980, fixture.ctx!());
    let cash = vault.complete_redemption_for_testing(shares, cash, net, admin, fee, reserve_fee, initial_checkpoint(), fixture.ctx!());
    replay.replay_redemption(events::collect_one<events::Redeemed<Tag>>(0));
    replay.assert_replay(vault);
    vault.pay_partner_for_testing(&partner, admin_cash_before, &clock, fixture.ctx!());
    replay.replay_partner_fee_paid(events::collect<events::PartnerFeePaid<Tag>>()[1]);
    replay.assert_replay(vault);
    sui::transfer::public_transfer(cash, ADMIN);
    destroy(partner);
    clock.destroy_for_testing();

    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    replay.replay_fees(events::collect<events::FeesUpdated<Tag>>()[3]);
    replay.assert_replay(vault);
    let cash = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 2, fixture.ctx!());
    let (id, amount, remaining) = events::collect_one<events::AdminFeesWithdrawn<Tag>>(0).admin_fees_withdrawn_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(remaining, replay.admin_cash - amount);
    replay.admin_cash = remaining;
    replay.assert_replay(vault);
    sui::transfer::public_transfer(cash, ADMIN);

    let donated_checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 10 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    vault.complete_donation_for_testing(active_position(1_026, 1_800), donated_checkpoint, 10, REFERENCE_AT_MS);
    let (id, amount, reserve, checkpoint) = events::collect_one<events::Donated<Tag>>(0).donated_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(reserve, replay.maintenance_reserve + amount);
    replay.maintenance_reserve = reserve;
    replay.checkpoint = option::some(checkpoint);
    replay.assert_replay(vault);

    let mut plan = vault.state().prepare_rebalance(rebalance_position(1_026, 3_000_000), 10, REFERENCE_AT_MS);
    let order = vault.state().next_rebalance_order(&plan);
    assert!(!order.is_increase());
    let after_base = 3_000_000 - order.order_base();
    let filled = order.order_base();
    vault.state().accept_rebalance_fill(&mut plan, order, rebalance_position(1_025, after_base), filled, REFERENCE_AT_MS);
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 9 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    vault.complete_rebalance_for_testing<Tag, Collateral>(plan, checkpoint);
    let event = events::collect_one<events::Rebalanced<Tag>>(0);
    let (before_equity, after_equity, before_base, event_after_base, event_increase) = event.rebalanced_amounts();
    assert_eq!(vector[before_equity, after_equity, before_base, event_after_base], vector[1_026, 1_025, 3_000_000, after_base]);
    assert!(!event_increase);
    let (id, reserve, cash, supply, checkpoint) = event.rebalanced_checkpoint_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(vector[reserve, cash, supply], vector[replay.maintenance_reserve, replay.admin_cash, replay.supply]);
    replay.checkpoint = option::some(checkpoint);
    replay.assert_replay(vault);

    let dirty = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 9 * ATOM_FIXED, RATE, RATE, RATE, RATE, 2);
    vault.apply_connected_change(dirty, checkpoint::unexpected_change());
    replay.replay_drift(events::collect<events::CheckpointDrifted<Tag>>()[0]);
    replay.assert_replay(vault);
    vault.apply_connected_change(dirty, checkpoint::unexpected_change());
    replay.replay_drift(events::collect<events::CheckpointDrifted<Tag>>()[1]);
    replay.assert_replay(vault);
    vault.apply_connected_change(checkpoint, checkpoint::unchanged_change());
    assert_eq!(events::collect<events::CheckpointDrifted<Tag>>().length(), 2);
    replay.unresolved_checkpoint = option::none();
    replay.assert_replay(vault);

    let credited_rate = RATE - ATOM_FIXED;
    let before = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 9 * ATOM_FIXED, RATE, RATE, credited_rate, credited_rate, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 10 * ATOM_FIXED, credited_rate, credited_rate, credited_rate, credited_rate, 1);
    let change = checkpoint.sync_change(&before, &after, ONE_FIXED);
    vault.apply_connected_change(after, change);
    replay.replay_funding(events::collect_one<events::FundingSettled<Tag>>(0));
    replay.assert_replay(vault);
    vault.apply_connected_change(after, checkpoint::unchanged_change());
    assert_eq!(events::collect<events::FundingSettled<Tag>>().length(), 1);
    replay.assert_replay(vault);
}

fun rebalance_position(equity: u64, base: u64): PositionObservation {
    observation::new_position(equity, base, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE)
}

fun replay_fees<Tag>(replay: &mut ReplayState, event: events::FeesUpdated<Tag>) {
    let (id, old_mint, old_redeem, old_admin, mint, redeem, admin) = event.fees_updated_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(vector[old_mint, old_redeem, old_admin], replay.fees);
    replay.fees = vector[mint, redeem, admin];
}

fun replay_mint<Tag>(replay: &mut ReplayState, event: events::Minted<Tag>) {
    let (id, checkpoint) = event.minted_checkpoint_fields();
    let (deposit, shares, contribution, fee, admin, buffer, reserve, cash, supply) = event.minted_amounts();
    assert_eq!(id, replay.vault_id);
    // The fee was sealed at the rates in force when the plan was prepared; only its split is replayed.
    assert_eq!(fee, admin + buffer);
    assert_eq!(vector[deposit, shares, contribution], vector[10_000, 9_989_000, 9_989]);
    assert_eq!(vector[reserve, cash, supply], vector[replay.maintenance_reserve + buffer, replay.admin_cash + admin, replay.supply + shares]);
    replay.maintenance_reserve = reserve;
    replay.admin_cash = cash;
    replay.supply = supply;
    replay.checkpoint = option::some(checkpoint);
}

fun replay_redemption<Tag>(replay: &mut ReplayState, event: events::Redeemed<Tag>) {
    let (id, checkpoint) = event.redeemed_checkpoint_fields();
    let amounts = event.redeemed_amounts();
    let shares = amounts[0];
    let net = amounts[1];
    let fee = amounts[2];
    let admin = amounts[3];
    let buffer = amounts[4];
    assert_eq!(id, replay.vault_id);
    assert_eq!(fee, admin + buffer);
    assert_eq!(vector[shares, net], vector[9_989_000, 9_978]);
    assert_eq!(vector[amounts[5], amounts[6], amounts[7]], vector[replay.maintenance_reserve + buffer, replay.admin_cash + admin, replay.supply - shares]);
    replay.maintenance_reserve = amounts[5];
    replay.admin_cash = amounts[6];
    replay.supply = amounts[7];
    replay.checkpoint = option::some(checkpoint);
}

// Follows the operation's own event, whose admin cash still includes the partner's fee.
fun replay_partner_fee_paid<Tag>(replay: &mut ReplayState, event: events::PartnerFeePaid<Tag>) {
    let (id, _, admin_fee, partner_fee) = event.partner_fee_paid_fields();
    assert_eq!(id, replay.vault_id);
    assert!(partner_fee > 0 && partner_fee <= admin_fee);
    replay.admin_cash = replay.admin_cash - partner_fee;
}

fun assert_replay<Tag>(replay: &ReplayState, vault: &Vault<Tag, Collateral>) {
    assert_eq!(replay.vault_id, vault.id());
    assert_eq!(replay.maintenance_reserve, vault.state().maintenance_reserve());
    assert_eq!(replay.admin_cash, vault.admin_cash_balance<_, Collateral>());
    assert_eq!(replay.protected_cash, vault.protected_cash_for_testing());
    assert_eq!(replay.supply, vault.total_share_supply());
    let locked = vault.locked_shares();
    assert_eq!(replay.locked_shares, locked);
    let (mint, redeem, admin) = vault.fee_settings_for_testing();
    assert_eq!(replay.fees, vector[mint, redeem, admin]);
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue().checkpoint());
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing());
    match (replay.lifecycle) {
        1 => vault.state().assert_active(),
        2 => vault.state().assert_unwinding(),
        3 => vault.state().assert_settled(),
        _ => abort 0,
    };
}

/// `VaultIssued` carries no Vault id: the Vault does not exist yet, and the
/// `VaultInitialized` that follows in the same transaction names it.
fun replay_issued<Tag>(event: events::VaultIssued<Tag>): ReplayState {
    let (_, _, vault_policy, max_order_notional, _) = event.vault_issued_fields();
    let (mint, redeem) = vault_policy.initial_fee_rates_for_testing();

    ReplayState {
        vault_id: @0x0.to_id(),
        binding: option::none(),
        maintenance_reserve: 0,
        lifecycle: 0,
        max_order_notional,
        checkpoint: option::none(),
        unresolved_checkpoint: option::none(),
        supply: 0,
        admin_cash: 0,
        locked_shares: 0,
        fees: vector[mint, redeem, 0],
        terminal_cash: 0,
        protected_cash: 0,
        unrecoverable_collateral_raw: 0,
    }
}

fun replay_initialized<Tag>(
    replay: &mut ReplayState,
    event: events::VaultInitialized<Tag>,
) {
    let (
        vault_id,
        binding,
        _,
        _,
        maintenance_reserve,
        _,
        locked_shares,
        _,
        _,
        _,
        _,
        checkpoint,
    ) = event.vault_initialized_fields();

    replay.vault_id = vault_id;
    replay.binding = option::some(binding);
    replay.maintenance_reserve = maintenance_reserve;
    replay.supply = locked_shares;
    replay.locked_shares = locked_shares;
    replay.lifecycle = 1;
    replay.checkpoint = option::some(checkpoint);
}

fun replay_rebaseline<Tag>(replay: &mut ReplayState, event: events::CheckpointRebaselined<Tag>) {
    let (vault_id, previous, checkpoint) = event.checkpoint_rebaselined_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous, *replay.checkpoint.borrow());
    replay.checkpoint = option::some(checkpoint);
    replay.unresolved_checkpoint = option::none();
}

fun replay_funding<Tag>(
    replay: &mut ReplayState,
    event: events::FundingSettled<Tag>,
) {
    let (vault_id, is_cost, raw_amount, amount, absorbed, uncovered, restored, reserve_after, previous_checkpoint, checkpoint) =
        event.funding_settled_fields();
    assert_eq!(vault_id, replay.vault_id);
    if (previous_checkpoint != *replay.checkpoint.borrow()) {
        assert_eq!(replay.lifecycle, 2);
        assert_eq!(previous_checkpoint, *replay.unresolved_checkpoint.borrow());
        replay.unresolved_checkpoint = option::none();
    };
    let rounded = raw_amount / ATOM_FIXED + if (is_cost && raw_amount % ATOM_FIXED > 0) { 1 } else { 0 };
    assert_eq!(amount as u256, rounded);
    let expected_absorbed = if (is_cost) { std::u64::min(amount, replay.maintenance_reserve) } else { 0 };
    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, if (is_cost) { amount - absorbed } else { 0 });
    // A credit repays holders before the reserve; the event carries the split.
    assert!(restored <= amount && (restored == 0 || !is_cost));

    assert_eq!(reserve_after, if (is_cost) { replay.maintenance_reserve - absorbed } else { replay.maintenance_reserve + amount - restored });
    replay.maintenance_reserve = reserve_after;
    replay.checkpoint = option::some(checkpoint);
}

fun replay_max_order_notional<Tag>(
    replay: &mut ReplayState,
    event: events::MaxOrderNotionalUpdated<Tag>,
) {
    let (vault_id, previous, current) = event.max_order_notional_updated_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous, replay.max_order_notional);
    replay.max_order_notional = current;
}

fun replay_shutdown<Tag>(
    replay: &mut ReplayState,
    event: events::ShutdownBegun<Tag>,
) {
    assert_eq!(event.shutdown_begun_vault_id(), replay.vault_id);
    replay.lifecycle = 2;
}

fun replay_protected_shutdown<Tag>(replay: &mut ReplayState, event: events::ProtectedShutdownBegun<Tag>) {
    let (id, checkpoint, supply, locked) = event.protected_shutdown_begun_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(vector[supply, locked], vector[replay.supply, replay.locked_shares]);
    replay.checkpoint = option::some(checkpoint);
    replay.lifecycle = 2;
}

fun replay_finalization<Tag>(replay: &mut ReplayState, event: events::ShutdownFinalized<Tag>) {
    let (id, cash, eligible, checkpoint, remainder, reserve_cash, seed_cash) = event.shutdown_finalized_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(replay.lifecycle, 2);
    assert_eq!(eligible, replay.supply - replay.locked_shares);
    replay.lifecycle = 3;
    replay.maintenance_reserve = 0;
    replay.protected_cash = reserve_cash + seed_cash;
    if (eligible == 0) {
        replay.admin_cash = replay.admin_cash + cash - replay.protected_cash;
    } else {
        replay.terminal_cash = cash - replay.protected_cash;
    };
    replay.unrecoverable_collateral_raw = remainder;
    replay.checkpoint = option::some(checkpoint);
}

fun replay_terminal_claim<Tag>(replay: &mut ReplayState, event: events::ShutdownRedeemed<Tag>) {
    let (id, burned, paid, remaining_cash, remaining_eligible) = event.shutdown_redeemed_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(replay.lifecycle, 3);
    assert_eq!(paid, replay.terminal_cash.mul_div(burned, replay.supply - replay.locked_shares));
    assert_eq!(remaining_cash, replay.terminal_cash - paid);
    assert_eq!(remaining_eligible, replay.supply - replay.locked_shares - burned);
    replay.supply = replay.supply - burned;
    replay.terminal_cash = remaining_cash;
}

fun replay_drift<Tag>(replay: &mut ReplayState, event: events::CheckpointDrifted<Tag>) {
    let (vault_id, checkpoint) = event.checkpoint_drifted_fields();
    assert_eq!(vault_id, replay.vault_id);
    replay.unresolved_checkpoint = option::some(checkpoint);
}

/// Unit-price venue reference: 40% initial margin, no free cash.
/// Expected amounts are derived here, independently of production normalization.
fun profit_cash(cash: u64, profit: u64, notional: u64): snapshot::CashLiquidity {
    profit_cash_with_haircut(cash, profit, notional, 0)
}

fun profit_cash_with_haircut(cash: u64, profit: u64, notional: u64, haircut: u256): snapshot::CashLiquidity {
    let requirement = (notional as u256) * ATOM_FIXED * 4 / 10;
    let allocated = (cash as u256) * ATOM_FIXED * (ONE_FIXED - haircut) / ONE_FIXED;
    let deficit = if (requirement >= allocated) { requirement - allocated } else { std::u256::max_value!() - (allocated - requirement) + 1 };
    let free = if (allocated > requirement) { (allocated - requirement) * ONE_FIXED / (ONE_FIXED - haircut) } else { 0 };
    snapshot::cash_liquidity_for_testing(0, free, deficit, (profit as u256) * ATOM_FIXED, ONE_FIXED, haircut)
}

fun profit_checkpoint(cash: u64, profit: u64, notional: u64, side: PositionSide): Checkpoint {
    let base = (notional as u256) * ATOM_FIXED;
    let quote = if (side == policy::long()) { ((notional - profit) as u256) * ATOM_FIXED } else { ((notional + profit) as u256) * ATOM_FIXED };
    let signed_base = if (side == policy::long()) { base } else { std::u256::max_value!() - base + 1 };
    let signed_quote = if (side == policy::long()) { quote } else { std::u256::max_value!() - quote + 1 };
    checkpoint::checkpoint_for_testing(0, (cash as u256) * ATOM_FIXED, signed_base, signed_quote,
        RATE, RATE, RATE, RATE, LOT_SIZE, 0, 0, 0, 0, false, ONE_FIXED * 4 / 10, ONE_FIXED * 4 / 10, ONE_FIXED / 10)
}

fun realize_then_redeem(self: &mut Fixture, side: PositionSide, haircut: u256) {
    let mut cash = 300;
    let mut profit = 700;
    let mut equity = cash + profit;
    let initial = profit_checkpoint(cash, profit, ABSOLUTE_NOTIONAL, side);
    let mut vault = issue_and_activate_product_with_side(self, Product(), initial, standard_vault_policy_for_side(side), side);
    vault.set_fees(&self.protocol, &risk_admin(), 0, 0, 0);
    let initial_supply = vault.total_share_supply();
    let shares = vault.mint_shares(initial_supply, self.ctx!());
    let supply = vault.total_share_supply();
    let reserve = vault.state().maintenance_reserve();
    let deficit = vault.state().uncovered_deficit();
    let mut steps = 0;
    let mut replay_checkpoint = initial;
    let mut replay_equity = equity;
    while (profit_cash_with_haircut(cash, profit, ABSOLUTE_NOTIONAL, haircut).shortfall() > 0) {
        assert!(steps < 16);
        let before_cash = profit_cash_with_haircut(cash, profit, ABSOLUTE_NOTIONAL, haircut);
        let before_checkpoint = *vault.venue().checkpoint();
        let plan = vault.state().prepare_profit_realization(
            position_observation_for_side(equity, side), before_cash.shortfall(), profit, 10, REFERENCE_AT_MS,
        );
        let base = plan.base_to_realize();
        let realized = profit.mul_div(base, ABSOLUTE_BASE);
        assert!(realized > 4);
        // Independent venue fixture: both orders fill at oracle; total fee is two atoms.
        cash = cash + realized - 2;
        profit = profit - realized;
        equity = equity - 2;
        let after_checkpoint = profit_checkpoint(cash, profit, ABSOLUTE_NOTIONAL, side);
        vault.complete_profit_realization_for_testing(
            plan, before_cash, profit_cash_with_haircut(cash, profit, ABSOLUTE_NOTIONAL, haircut), before_checkpoint,
            position_observation_for_side(equity, side), after_checkpoint, REFERENCE_AT_MS,
        );
        let recorded = events::collect<events::ProfitRealized<Product>>();
        assert_eq!(recorded.length(), steps + 1);
        let (id, equity_before, equity_after, base_realized, shortage_before, shortage_after, previous, checkpoint) =
            recorded[steps].profit_realized_fields();
        assert_eq!(id, vault.id());
        assert_eq!(equity_before, replay_equity);
        assert_eq!(equity_after, equity);
        assert_eq!(base_realized, base);
        assert_eq!(shortage_before, before_cash.shortfall());
        assert_eq!(shortage_after, profit_cash_with_haircut(cash, profit, ABSOLUTE_NOTIONAL, haircut).shortfall());
        assert_eq!(previous, replay_checkpoint);
        assert_eq!(checkpoint, after_checkpoint);
        replay_checkpoint = checkpoint;
        replay_equity = equity_after;
        assert_eq!(*vault.venue().checkpoint(), replay_checkpoint);
        assert_eq!(vault.total_share_supply(), supply);
        assert_eq!(vault.state().maintenance_reserve(), reserve);
        assert_eq!(vault.state().uncovered_deficit(), deficit);
        assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
        assert!(vault.state().is_active_for_testing());
        steps = steps + 1;
    };
    assert!(steps > 1);
    assert!(events::collect<events::ProfitRealized<OtherProduct>>().is_empty());
    let plan = vault.state().prepare_redemption(
        position_observation_for_side(equity, side), shares.value(), supply, 1, REFERENCE_AT_MS,
    );
    let realized = profit.mul_div(plan.base_to_sell(), ABSOLUTE_BASE);
    let remaining = ABSOLUTE_NOTIONAL - plan.base_to_sell() / BASE_PER_NOTIONAL;
    let (net, admin, fee, reserve_fee) = vault.settle_redemption_for_testing(
        plan, &shares, active_position_for_side(equity, remaining, side), REFERENCE_AT_MS,
    );
    profit_cash_with_haircut(cash + realized, profit - realized, remaining, haircut).assert_releasable(net + admin);
    assert_eq!(net, (equity - reserve) / 2);
    assert_eq!(admin, 0);
    let after_sell = profit_checkpoint(cash + realized, profit - realized, remaining, side);
    let withdrawn = profit_checkpoint(cash + realized - net, profit - realized, remaining, side);
    after_sell.assert_withdrawal_checkpoint(&withdrawn, net);
    let payment = sui::coin::mint_for_testing<Collateral>(net, self.ctx!());
    let output = vault.complete_redemption_for_testing(shares, payment, net, admin, fee, reserve_fee, withdrawn, self.ctx!());
    assert_eq!(output.value(), net);
    assert_eq!(vault.total_share_supply(), supply / 2);
    assert!(equity - reserve - net >= net);
    destroy(output);
    destroy(vault);
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN as AdminRole};

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    checkpoint::{Self, Checkpoint, CheckpointChange},
    constants,
    errors,
    events,
    operations,
    orders,
    blast_boosts_aftermath::{Self as protocol, Protocol},
    snapshot::{Self, CapturedSnapshot},
    vault::{Self, Vault},
    venue_account::{Self, Binding},
};

use blast_boosts_core::{
    lifecycle::ShutdownReason,
    state::{Self, RebalancePlan},
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide, VaultPolicy},
    blast_boosts_core::{RiskAdmin, ShutdownAdmin, VaultIssuer},
};

use blast_partners::blast_partners::{Self as partners, Partner, PartnerPaid};

use perpetuals::authority::ACCOUNT;

use std::{
    string::String,
    type_name::{Self, TypeName},
    unit_test::{assert_eq, destroy},
};

use sui::{
    clock::Clock,
    coin::Coin,
    coin_registry::{Self, CoinRegistry},
    test_scenario::{Self, Scenario},
};

use fun apply_connected_change as Vault.apply_connected_change;

use fun assert_unexpected_sync_change as Checkpoint.assert_unexpected_sync_change;

use fun finalize_recovered as Vault.finalize_recovered;

use fun sync_change as Checkpoint.sync_change;

use fun operations::add_partner as Protocol.add_partner;

use fun operations::apply_post_capture_for_testing as Vault.apply_post_capture_for_testing;

use fun operations::apply_post_captures_for_testing as Vault.apply_post_captures_for_testing;

use fun operations::complete_donation_for_testing as Vault.complete_donation_for_testing;

use fun operations::complete_finalization_for_testing as Vault.complete_finalization_for_testing;

use fun operations::complete_mint_for_testing as Vault.complete_mint_for_testing;

use fun operations::complete_rebalance_for_testing as Vault.complete_rebalance_for_testing;

use fun operations::complete_redemption_for_testing as Vault.complete_redemption_for_testing;

use fun operations::complete_market_unwind_for_testing as Vault.complete_market_unwind_for_testing;

use fun operations::complete_settlement_unwind_for_testing as Vault.complete_settlement_unwind_for_testing;

use fun operations::emit_vault_initialized_for_testing as Vault.emit_vault_initialized_for_testing;

use fun operations::pay_partner_for_testing as Vault.pay_partner_for_testing;

use fun operations::remove_partner as Protocol.remove_partner;

use fun operations::settle_redemption_for_testing as Vault.settle_redemption_for_testing;

use fun orders::increasing_terms as Vault.increasing_terms;

use fun orders::reducing_terms as Vault.reducing_terms;

use fun orders::unwind_terms as Vault.unwind_terms;

use fun operations::assert_rebalance_gas_price_for_testing as RebalancePlan.assert_gas_price;

use fun operations::rebaseline_from_captures_for_testing as Vault.rebaseline_from_captures_for_testing;


use fun operations::complete_profit_realization_for_testing as Vault.complete_profit_realization_for_testing;

use fun operations::begin_protected_shutdown_for_testing as Vault.begin_protected_shutdown_for_testing;
