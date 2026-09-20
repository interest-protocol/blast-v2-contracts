#[test_only]
/// Tests for atomic Aftermath Vault initialization seams.
module blast_boosts_aftermath::operations_tests;

// === Constants ===

const SYSTEM: address = @0x0;
const ADMIN: address = @0xA11CE;
const REFERENCE_TIME_MS: u64 = 1_000;
const NAV_CAP: u64 = 1_000_000_000;
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

// === Test-Only Types ===

public struct Product() has drop;

public struct OtherProduct() has drop;

public struct Collateral {}

public struct Fixture {
    scenario: Scenario,
    registry: CoinRegistry,
    protocol: Protocol,
    authority: Authority<BLAST_BOOSTS_CORE>,
    super_admin_cap: SuperAdminCap<BLAST_BOOSTS_CORE>,
    admin_cap: AdminCap<BLAST_BOOSTS_CORE>,
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
    unrecoverable_collateral_raw: u256,
}

// === Tests ===

#[test]
fun order_filled_event_carries_every_fill_fact_in_order() {
    let account = object::id_from_address(@0xA11);
    events::order_filled<Product>(account, true, false, true, 2_500_000_000_000, 2_400_000_000_000,
        4_800_000_000_000_000_000_000, 2_000_000_000, 2_004_000_000);
    let (id, is_ask, reduce_only, emergency, requested, filled, quote, reference, executed) =
        events::collect_one<events::OrderFilled<Product>>(0).order_filled_fields();
    assert_eq!(id, account);
    assert_eq!(vector[is_ask, reduce_only, emergency], vector[true, false, true]);
    assert_eq!(vector[requested, filled], vector[2_500_000_000_000, 2_400_000_000_000]);
    assert_eq!(quote, 4_800_000_000_000_000_000_000);
    assert_eq!(vector[reference, executed], vector[2_000_000_000, 2_004_000_000]);
    assert!(events::collect<events::OrderFilled<OtherProduct>>().is_empty());
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun terminal_claim_checks_version_before_lifecycle_or_zero_shares() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.protocol.set_version_for_testing(2);
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
    fixture.protocol.set_version_for_testing(2);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun revoked_shutdown_role_cannot_retire_a_vault() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    revoke_role(&mut fixture, domain::shutdown_admin_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EDeadlineExpired, location = blast_boosts_aftermath::vault)]
fun expired_terminal_claim_cannot_burn_shares_or_pay_cash() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let shares = vault.mint_shares(5, fixture.ctx!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    finalize_recovered(&mut vault, sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    finalize_recovered(&mut vault, sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    finalize_recovered(&mut vault, sui::coin::zero<Collateral>(fixture.ctx!()));
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun finalization_cannot_recover_or_pay_the_seed_funder_twice() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    finalize_recovered(&mut vault, sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    finalize_recovered(&mut vault, sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_direct_settlement_reports_actual_cash_and_no_market_order() {
    let mut fixture = start();
    let before = checkpoint::checkpoint_for_testing(0, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    let after = checkpoint::checkpoint_for_testing(5, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    let mut vault = issue_and_activate(&mut fixture, before);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    operations::complete_unwind_for_testing(&mut vault, before, option::none(), after, 0, option::none());
    let event = events::collect_one<events::UnwindProgress<Product>>(0);
    let (id, observed, funded, actual, orders, quote) = event.unwind_progress_fields();
    assert_eq!(id, vault.id());
    assert_eq!(observed, before);
    assert!(funded.is_none());
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let captured = snapshot::captured_health_for_testing(initial_checkpoint(), 0, false, 0, true, true);
    let base = captured.base_price_observation();
    let collateral = captured.collateral_price_observation();
    let (side, max_order_base, base_price, collateral_price) =
        vault.state().unwind_constraints(base, collateral, LOT_SIZE, REFERENCE_TIME_MS);
    assert_eq!(side, policy::long());
    assert_eq!(vector[max_order_base, base_price, collateral_price], vector[250 * BASE_PER_NOTIONAL, PRICE, PRICE]);
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
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(7, fixture.ctx!()));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
    finalize_recovered(&mut vault, recovered);
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_out = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, first, 5, 0, &clock, fixture.ctx!());
    assert_eq!(first_out.value(), 5);
    let last_out = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 8, 0, &clock, fixture.ctx!());
    assert_eq!(last_out.value(), 8);
    assert_eq!(vault.total_share_supply(), locked);
    assert_eq!(vault.state().maintenance_reserve(), 0);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 7);
    let finalization = events::collect_one<events::ShutdownFinalized<Product>>(0);
    let (_, recovered, eligible, checkpoint, remainder) = finalization.shutdown_finalized_fields();
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::observed_venue_change_reason());
    fixture.next_tx!(@0xBEEF, |fixture| {
        let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
        finalize_recovered(&mut vault, recovered);
        assert_eq!(vault.state().maintenance_reserve(), 0);
        let (_, cash, eligible, _, remainder) = events::collect_one<events::ShutdownFinalized<Product>>(0).shutdown_finalized_fields();
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let before = checkpoint::checkpoint_for_testing(13, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(12, fixture.ctx!());
    before.assert_terminal_withdrawal_checkpoint(&terminal_checkpoint(), recovered.value());
    operations::complete_finalization_for_testing(&mut vault, terminal_checkpoint(), recovered);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun finalization_rejects_a_short_actual_coin_with_exact_sub_atomic_remainder() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let before = checkpoint::checkpoint_for_testing(12, 1_000_000_000_001, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let after = checkpoint::checkpoint_for_testing(0, 1, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(12, fixture.ctx!());
    before.assert_terminal_withdrawal_checkpoint_decoded_for_testing(&after, recovered.value(), false, 1_000_000_000_001);
    operations::complete_finalization_for_testing(&mut vault, after, recovered);
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
    replay_active_economics(&mut fixture, &mut first);
    replay_active_economics(&mut fixture, &mut second);
    assert_eq!(events::collect<events::Minted<Product>>().length(), 1);
    assert_eq!(events::collect<events::Minted<OtherProduct>>().length(), 1);
    assert_eq!(events::collect<events::Redeemed<Product>>().length(), 1);
    assert_eq!(events::collect<events::Redeemed<OtherProduct>>().length(), 1);
    assert_eq!(events::collect<events::Rebalanced<Product>>().length(), 1);
    assert_eq!(events::collect<events::Rebalanced<OtherProduct>>().length(), 1);
    destroy(first);
    destroy(second);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EZeroAmount, location = blast_boosts_aftermath::vault)]
fun zero_admin_withdrawal_fails_before_empty_cash_lookup() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
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
    let plan = vault.state().prepare_redemption(position_observation(SEED_EQUITY), shares.value(), vault.total_share_supply(), 1, REFERENCE_TIME_MS);
    destroy(shares);
    let wrong_shares = sui::coin::mint_for_testing<BlastBoost<Product>>(99_999, fixture.ctx!());
    operations::settle_redemption_for_testing(&mut vault, plan, &wrong_shares, position_observation(SEED_EQUITY), REFERENCE_TIME_MS);
    destroy(wrong_shares);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun wrong_role_precedes_zero_admin_withdrawal() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    revoke_role(&mut fixture, domain::risk_admin_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let cash = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 0, fixture.ctx!());
    destroy(cash);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun wrong_role_precedes_invalid_fee_settings() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    revoke_role(&mut fixture, domain::risk_admin_role());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10_000, 10_000, 10_001);
    destroy(vault);
    fixture.end();
}

#[test]
fun native_fee_allocations_preserve_historical_cash_through_redemption_and_rate_change() {
    let mut fixture = start();
    let mut vault = issue_and_activate_with_policy(&mut fixture, initial_checkpoint(),
        fee_capped_vault_policy_for_side(policy::long()));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 10_000, vault.total_share_supply(), 9_989_000, REFERENCE_TIME_MS);
    assert_eq!(plan.admin_fee(), 2);
    assert_eq!(plan.base_to_buy(), 19_980_000);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(2, fixture.ctx!()));
    let shares = operations::complete_mint_for_testing<Product, Collateral>(
        &mut vault, plan, 10_000, active_position(10_997, 21_780), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!(),
    );
    let (_, minted, contribution, fee, admin, buffer, reserve, cash, supply) =
        events::collect_one<events::Minted<Product>>(0).minted_amounts();
    assert_eq!(vector[minted, contribution, fee, admin, buffer, reserve, cash, supply],
        vector[9_989_000, 9_989, 10, 2, 8, 108, 2, 10_889_000]);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    let plan = vault.state().prepare_redemption(active_position(10_997, 21_780), shares.value(), vault.total_share_supply(), 9_978, REFERENCE_TIME_MS);
    // 21_780_000 less the floor of its 900_000 / 10_889_000 share, to the atom.
    assert_eq!(plan.base_to_sell(), 19_979_835);
    let (net, admin, fee, reserve_fee) = operations::settle_redemption_for_testing(&mut vault, plan, &shares,
        active_position_with_base(10_996, 1_800_165), REFERENCE_TIME_MS);
    assert_eq!(net + admin, 9_980);
    let cash = sui::coin::mint_for_testing<Collateral>(9_980, fixture.ctx!());
    let cash = operations::complete_redemption_for_testing(&mut vault, shares, cash, net, admin, fee, reserve_fee, initial_checkpoint(), fixture.ctx!());
    assert_eq!(cash.value(), 9_978);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.state().maintenance_reserve(), 116);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 4);
    assert_eq!(events::collect_one<events::Redeemed<Product>>(0).redeemed_amounts(),
        vector[9_989_000, 9_978, 10, 2, 8, 116, 4, 900_000]);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
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
fun event_reducer_reconstructs_a_positive_funding_checkpoint() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Product>>(0));
    replay_initialized(&mut replay, events::collect_one<events::VaultInitialized<Product>>(0));
    let before = funding_before_checkpoint(1, false);
    let after = funding_checkpoint(1, false);
    let change = initial.classify_sync_change_for_testing(&before, &after, ONE_FIXED);
    apply_connected_change(&mut vault, after, change);
    replay_funding(&mut replay, events::collect_one<events::FundingSettled<Product>>(0));
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
    apply_connected_change(&mut vault, dirty, checkpoint::unexpected_change());
    apply_connected_change(&mut vault, initial, checkpoint::unchanged_change());
    let drifted = events::collect<events::CheckpointDrifted<Product>>();
    assert_eq!(drifted.length(), 1);
    let (_, checkpoint) = drifted[0].checkpoint_drifted_fields();
    assert_eq!(checkpoint, dirty);
    assert_eq!(*vault.venue().checkpoint(), initial);
    apply_connected_change(&mut vault, dirty, checkpoint::unexpected_change());
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
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    let mut plan = vault.state().prepare_rebalance(before, 10, REFERENCE_TIME_MS);
    let priced = plan.rebalance_position();
    let (base_price, collateral_price, lot) = (priced.base_price(), priced.collateral_price(), priced.lot_size());
    assert_eq!(base_price, PRICE);
    assert_eq!(collateral_price, PRICE);
    assert_eq!(lot, LOT_SIZE);
    let order = vault.state().next_rebalance_order(&plan);
    let base = order.order_base();
    assert_eq!(base, 250_000);
    assert!(!order.is_increase() && order.is_emergency());
    vault.state().assert_execution(order.is_emergency(), PRICE, PRICE);
    let after = observation::new_position(999, 2_750_000, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    vault.state().accept_rebalance_fill(&mut plan, order, after, base, REFERENCE_TIME_MS);
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    operations::complete_rebalance_for_testing<Product, Collateral>(&mut vault, plan, checkpoint);
    assert_eq!(vault.state().maintenance_reserve(), 100);
    assert_eq!(vault.total_share_supply(), 900_000);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(*vault.venue().checkpoint(), checkpoint);
    let event = events::collect_one<events::Rebalanced<Product>>(0);
    let (before_equity, after_equity, before_base, after_base, increased) = event.rebalanced_amounts();
    assert_eq!(before_equity, 1_000);
    assert_eq!(after_equity, 999);
    assert_eq!(before_base, 3_000_000);
    assert_eq!(after_base, 2_750_000);
    assert!(!increased);
    destroy(vault);
    fixture.end();
}

#[test]
fun venue_fee_bound_adds_priority_surcharge_and_rounds_up_once() {
    assert_eq!(orders::venue_fee_bound_for_testing(1_000_000_000_000_000, 500_000_000_000_000), 15);
    assert_eq!(orders::venue_fee_bound_for_testing(1, 0), 1);
    assert_eq!(orders::venue_fee_bound_for_testing(0, 0), 0);
    assert_eq!(orders::venue_fee_bound_for_testing(1_000_000_000_000_000_000, 0), 10_000);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EVenueFeeUnusable, location = blast_boosts_aftermath::orders)]
fun venue_fee_bound_rejects_unrepresentable_addition_before_overflow() {
    orders::venue_fee_bound_for_testing(std::u256::max_value!(), 1);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EVenueFeeUnusable, location = blast_boosts_aftermath::orders)]
fun venue_fee_bound_rejects_a_priority_surcharge_above_one() {
    orders::venue_fee_bound_for_testing(0, 1_000_000_000_000_000_001);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EVenueFeeUnusable, location = blast_boosts_aftermath::orders)]
fun venue_fee_bound_rejects_a_combined_fee_above_one() {
    orders::venue_fee_bound_for_testing(600_000_000_000_000_000, 500_000_000_000_000_000);
}

#[test]
fun venue_fee_bound_accepts_a_combined_fee_of_exactly_one() {
    assert_eq!(orders::venue_fee_bound_for_testing(500_000_000_000_000_000, 500_000_000_000_000_000), 10_000);
}

#[test]
fun completed_redemption_burns_the_native_input_only_after_exact_cash_return() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let mint_plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, REFERENCE_TIME_MS);
    let (amount, _, _, _, _) = vault.state_mut().complete_mint(mint_plan, active_position(1_998, 3_798), REFERENCE_TIME_MS);
    let shares = vault.mint_shares(amount, fixture.ctx!());
    let plan = vault.state().prepare_redemption(active_position(1_998, 3_798), shares.value(), vault.total_share_supply(), 994, REFERENCE_TIME_MS);
    // 3_798_000 less the floor of its 900_000 / 1_897_000 share, to the atom.
    assert_eq!(plan.base_to_sell(), 1_996_103);
    let (net, admin, fee, reserve_fee) = operations::settle_redemption_for_testing(
        &mut vault, plan, &shares, active_position_with_base(1_996, 1_801_897), REFERENCE_TIME_MS,
    );
    assert_eq!(net + admin, 994);
    let cash = sui::coin::mint_for_testing<Collateral>(994, fixture.ctx!());
    let final_checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 994 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let cash = operations::complete_redemption_for_testing(&mut vault, shares, cash, net, admin, fee, reserve_fee, final_checkpoint, fixture.ctx!());
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
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 20, false);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun redemption_cash_checkpoint_rejects_deallocating_what_free_cash_covered() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(5, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 20, false);
}

#[test]
fun active_checkpoint_admits_only_the_executed_position_and_venue_cost() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_trade_checkpoint(&after, ONE_FIXED, 1);
    let allocated = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 50 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&allocated, 50, true);
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
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 50, true);
}

#[test]
fun redemption_cash_checkpoint_spends_free_cash_before_deallocating() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 15 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 40, false);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun redemption_cash_checkpoint_rejects_inexact_payout() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 14 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 40, false);
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
fun active_terms_open_with_the_side_and_reduce_against_it() {
    let mut fixture = start();
    let vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, REFERENCE_TIME_MS);
    let position = plan.mint_position();

    let (is_ask, reduce_only, max_order_base, lot_size, base_price, collateral_price) =
        orders::active_terms(&vault, false, position).order_terms_fields();
    assert!(!is_ask && !reduce_only);
    assert_eq!(max_order_base, vault.state().max_order_base(&position));
    assert_eq!(vector[lot_size, base_price, collateral_price], vector[LOT_SIZE, PRICE, PRICE]);

    let (is_ask, reduce_only, _, _, _, _) = orders::active_terms(&vault, true, position).order_terms_fields();
    assert!(is_ask && reduce_only);

    destroy(plan);
    destroy(vault);
    fixture.end();
}

#[test]
fun active_terms_of_a_short_vault_open_with_an_ask_and_reduce_with_a_bid() {
    let mut fixture = start();
    let vault = issue_and_activate_product_with_side(&mut fixture, OtherProduct(), initial_checkpoint(),
        standard_vault_policy_for_side(policy::short()), policy::short());
    let plan = vault.state().prepare_mint(position_observation_for_side(SEED_EQUITY, policy::short()), 1_000, vault.total_share_supply(), 997_000, REFERENCE_TIME_MS);
    let position = plan.mint_position();

    let (is_ask, reduce_only, _, _, _, _) = orders::active_terms(&vault, false, position).order_terms_fields();
    assert!(is_ask && !reduce_only);
    let (is_ask, reduce_only, _, _, _, _) = orders::active_terms(&vault, true, position).order_terms_fields();
    assert!(!is_ask && reduce_only);

    destroy(plan);
    destroy(vault);
    fixture.end();
}

#[test]
fun unwind_terms_close_a_long_with_an_ask_at_the_capped_size() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let captured = snapshot::captured_health_for_testing(initial_checkpoint(), 0, false, 0, true, true);

    let (terms, remaining, before) =
        orders::unwind_terms_for_testing(&vault, &captured, REFERENCE_TIME_MS, 1_800_000_000_000, true);
    let (is_ask, reduce_only, max_order_base, lot_size, base_price, collateral_price) = terms.order_terms_fields();
    assert!(is_ask && reduce_only);
    assert_eq!(vector[max_order_base, lot_size, base_price, collateral_price], vector[250 * BASE_PER_NOTIONAL, LOT_SIZE, PRICE, PRICE]);
    assert_eq!(remaining, 1_800);
    assert_eq!(before, initial_checkpoint());

    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun unwind_terms_reject_a_checkpoint_with_resting_orders() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let resting = checkpoint::checkpoint_for_testing(
        0, ALLOCATED_FIXED, ONE_FIXED, 1, RATE, RATE, RATE, RATE, LOT_SIZE, 0, 0, 1, 0, false, 1, 1, 1,
    );
    let captured = snapshot::captured_health_for_testing(resting, 0, false, 0, true, true);

    orders::unwind_terms_for_testing(&vault, &captured, REFERENCE_TIME_MS, 1_800_000_000_000, true);

    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun unwind_terms_require_an_unwinding_vault_before_reading_orders() {
    let mut fixture = start();
    let vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let captured = snapshot::captured_health_for_testing(initial_checkpoint(), 0, false, 0, true, true);

    orders::unwind_terms_for_testing(&vault, &captured, REFERENCE_TIME_MS, 1_800_000_000_000, true);

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

/// The funding update authenticates the bound market and base oracle before touching either.
#[test]
fun funding_update_inputs_accept_the_bound_market_and_base_oracle() {
    funding_binding().assert_funding_update_inputs_for_testing(@0xD.to_id(), @0xE.to_id());
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EClearingHouseMismatch, location = blast_boosts_aftermath::venue_account)]
fun funding_update_rejects_an_unbound_market_before_the_oracle() {
    funding_binding().assert_funding_update_inputs_for_testing(@0xDD.to_id(), @0xEE.to_id());
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EBaseOracleMismatch, location = blast_boosts_aftermath::venue_account)]
fun funding_update_rejects_the_collateral_oracle_as_its_storage() {
    funding_binding().assert_funding_update_inputs_for_testing(@0xD.to_id(), @0xF.to_id());
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
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, REFERENCE_TIME_MS);
    assert_eq!(plan.base_to_buy(), 1_998_000);
    let priced = plan.mint_position();
    let (base_price, collateral_price, lot) = (priced.base_price(), priced.collateral_price(), priced.lot_size());
    assert_eq!(base_price, PRICE);
    assert_eq!(collateral_price, PRICE);
    assert_eq!(lot, LOT_SIZE);
    assert_eq!(vault.state().side(), policy::long());
    assert!(vault.max_order_notional_for_testing() > 0);
    vault.state().assert_execution(false, PRICE, PRICE);
    let after = observation::new_position(1_998, 3_798 * BASE_PER_NOTIONAL, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    let shares = operations::complete_mint_for_testing<Product, Collateral>(&mut vault, plan, 1_000, after, initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
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
fun connected_donation_accepts_only_the_exact_free_collateral_deposit() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let after = checkpoint_with_market_imr(50, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    operations::complete_donation_for_testing(&mut vault, position_observation(SEED_EQUITY + 50), after, 50, REFERENCE_TIME_MS);
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
    let after = checkpoint_with_market_imr(50, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 2);
    operations::complete_donation_for_testing(&mut vault, position_observation(SEED_EQUITY + 50), after, 50, REFERENCE_TIME_MS);
    destroy(vault);
    fixture.end();
}

#[test]
fun earned_admin_cash_withdraws_without_venue_or_oracle_in_terminal_state() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(25, fixture.ctx!()));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
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
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
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
fun nonnegative_position_imr_is_accepted() {
    operations::assert_position_imr_for_testing(false);
}

#[test]
#[expected_failure(abort_code = errors::EInitializationImrMismatch, location = blast_boosts_aftermath::operations)]
fun negative_position_imr_is_rejected() {
    operations::assert_position_imr_for_testing(true);
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
        venue_account::new_binding(@0xB.to_id(), 27, @0xC.to_id(), @0xD.to_id(), @0xE.to_id(), @0xF.to_id(), @0xF1.to_id(), @0xF2.to_id()),
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
        venue_account::new_binding(@0xB.to_id(), 27, @0xC.to_id(), @0xD.to_id(), @0xE.to_id(), @0xF.to_id(), @0xF1.to_id(), @0xF2.to_id()),
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

    let first = before.classify_sync_change_for_testing(&before, &before, ONE_FIXED);
    assert!(first.is_unchanged_for_testing());

    let after = sync_checkpoint(1_000, 110_000_000_000_000, settled, settled, settled, settled, 0, ONE_FIXED, 0);
    let replay = after.classify_sync_change_for_testing(&after, &after, ONE_FIXED);
    assert!(replay.is_unchanged_for_testing());
}

#[test]
fun synchronization_accepts_only_an_isolated_funding_credit() {
    let settled = RATE - 10_000_000_000_000;
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, RATE, RATE, 0, ONE_FIXED, 0);
    let before = sync_checkpoint(1_000, 100_000_000_000_000, RATE, RATE, settled, settled, 0, ONE_FIXED, 0);
    let after = sync_checkpoint(1_000, 110_000_000_000_000, settled, settled, settled, settled, 0, ONE_FIXED, 0);

    let change = stored.classify_sync_change_for_testing(&before, &after, ONE_FIXED);
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

    let change = stored.classify_sync_change_for_testing(&before, &after, ONE_FIXED);
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

    let change = stored.classify_sync_change_for_testing(&settled, &settled, ONE_FIXED);
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        (change.has_funding(), change.is_cost(), change.raw_amount(), change.amount(), change.is_clean());

    assert!(has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert!(checkpoint_clean);

    let replay = settled.classify_sync_change_for_testing(&settled, &settled, ONE_FIXED);
    assert!(replay.is_unchanged_for_testing());
}

#[test]
fun synchronization_preserves_external_then_local_funding_as_two_ordered_changes() {
    // Rates rose 10 while the vault was away (settled elsewhere as a cost), then fell 5 before this sync.
    let (external_rate, local_rate) = (RATE + 10 * ATOM_FIXED, RATE + 5 * ATOM_FIXED);
    let stored = sync_checkpoint(1_000, 100 * ATOM_FIXED, RATE, RATE, RATE, RATE, 0, ONE_FIXED, 0);
    let before = sync_checkpoint(1_000, 90 * ATOM_FIXED, external_rate, external_rate, local_rate, local_rate, 0, ONE_FIXED, 0);
    let after = sync_checkpoint(1_000, 95 * ATOM_FIXED, local_rate, local_rate, local_rate, local_rate, 0, ONE_FIXED, 0);

    let (external, local) = stored.classify_sync_changes_for_testing(&before, &after, ONE_FIXED);

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

    assert_unexpected_sync_change(&stored, &pnl_before, &clean_after);
    assert_unexpected_sync_change(&stored, &collateral_before, &clean_after);
    assert_unexpected_sync_change(&stored, &stored, &liquidation_after);
}

#[test]
fun stored_drift_plus_an_exact_settlement_is_unexpected_and_not_funding() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let before = sync_checkpoint(999, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(999, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    assert_unexpected_sync_change(&stored, &before, &after);
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
    let change = initial.classify_sync_change_for_testing(&funding_before_checkpoint(cost, true), &funded, ONE_FIXED);
    apply_connected_change(&mut vault, funded, change);
    assert_eq!(vault.state().maintenance_reserve(), 0);

    // Second interval: market rates fall again and a 50-unit credit lands.
    let (costed_rate, credited_rate) = (settled_rate(cost, true), settled_rate(cost, true) - 50 * ATOM_FIXED);
    let allocated_after_cost = ALLOCATED_FIXED - (cost as u256) * ATOM_FIXED;
    let before = checkpoint_with_market_imr(0, allocated_after_cost, costed_rate, costed_rate, credited_rate, credited_rate, 1);
    let credited = checkpoint_with_market_imr(
        0, allocated_after_cost + 50 * ATOM_FIXED, credited_rate, credited_rate, credited_rate, credited_rate, 1,
    );
    let change = funded.classify_sync_change_for_testing(&before, &credited, ONE_FIXED);
    apply_connected_change(&mut vault, credited, change);

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
    let credit = initial.classify_sync_change_for_testing(&before, &credited, ONE_FIXED);

    apply_connected_change(&mut vault, credited, credit);
    let unchanged = credited.classify_sync_change_for_testing(&credited, &credited, ONE_FIXED);
    apply_connected_change(&mut vault, credited, unchanged);

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
    let cost = initial.classify_sync_change_for_testing(&before, &funded, ONE_FIXED);
    apply_connected_change(&mut vault, funded, cost);

    let replay = funded.classify_sync_change_for_testing(&funded, &funded, ONE_FIXED);
    apply_connected_change(&mut vault, funded, replay);

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
    let cost = initial.classify_sync_change_for_testing(&settled, &settled, ONE_FIXED);
    apply_connected_change(&mut vault, settled, cost);

    let replay = settled.classify_sync_change_for_testing(&settled, &settled, ONE_FIXED);
    apply_connected_change(&mut vault, settled, replay);

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
    let (external, local) = initial.classify_sync_changes_for_testing(&before, &after, ONE_FIXED);

    operations::apply_post_captures_for_testing(&mut vault, after, external, local);

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
fun connected_zero_net_checkpoint_emits_once_and_preserves_the_buffer() {
    // A flat position: the rates move and the snapshots refresh, but nothing settles.
    let mut fixture = start();
    let initial = flat_checkpoint(RATE, RATE);
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = flat_checkpoint(RATE, RATE + ATOM_FIXED);
    let after = flat_checkpoint(RATE + ATOM_FIXED, RATE + ATOM_FIXED);
    let change = initial.classify_sync_change_for_testing(&before, &after, ONE_FIXED);
    apply_connected_change(&mut vault, after, change);
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
    let unchanged = after.classify_sync_change_for_testing(&after, &after, ONE_FIXED);
    apply_connected_change(&mut vault, after, unchanged);
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
    let (external, local) = stored.classify_sync_changes_for_testing(&before, &after, ONE_FIXED);
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
    let before = checkpoint_with_market_imr(0, ALLOCATED_FIXED, RATE, RATE, costed_rate, costed_rate, 2);
    let after = checkpoint_with_market_imr(
        0, ALLOCATED_FIXED - 10 * ATOM_FIXED, costed_rate, costed_rate, costed_rate, costed_rate, 2,
    );
    let unexpected = initial.classify_sync_change_for_testing(&before, &after, ONE_FIXED);

    apply_connected_change(&mut vault, after, unexpected);

    assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(*vault.venue().checkpoint(), initial);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    let (_, checkpoint) = events::collect_one<events::CheckpointDrifted<Product>>(0).checkpoint_drifted_fields();
    assert_eq!(checkpoint, after);

    let replay = vault.venue().checkpoint().classify_sync_change_for_testing(&after, &after, ONE_FIXED);
    apply_connected_change(&mut vault, after, replay);
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
    let unchanged = checkpoint.classify_sync_change_for_testing(&checkpoint, &checkpoint, ONE_FIXED);
    apply_connected_change(&mut vault, checkpoint, unchanged);

    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(*vault.venue().checkpoint(), checkpoint);
    assert_eq!(events::collect<events::CheckpointDrifted<Product>>().length(), 0);

    let repeated = checkpoint.classify_sync_change_for_testing(&checkpoint, &checkpoint, ONE_FIXED);
    apply_connected_change(&mut vault, checkpoint, repeated);
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
    let funding = initial_checkpoint.classify_sync_change_for_testing(&funding_before, &funded_checkpoint, ONE_FIXED);
    apply_connected_change(&mut vault, funded_checkpoint, funding);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_max_order_notional(&fixture.protocol, &admin_witness, 300);
    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

    let costed_rate = settled_rate(10, true);
    let final_checkpoint = checkpoint_with_market_imr(
        1, ALLOCATED_FIXED - 10 * ATOM_FIXED, costed_rate, costed_rate, costed_rate, costed_rate, 1,
    );
    let unexpected = funded_checkpoint.classify_sync_change_for_testing(&final_checkpoint, &final_checkpoint, ONE_FIXED);
    apply_connected_change(&mut vault, final_checkpoint, unexpected);

    let mut replay = replay_issued(
        events::collect_one<events::VaultIssued<Product>>(0),
    );
    replay_initialized(
        &mut replay,
        events::collect_one<events::VaultInitialized<Product>>(0),
    );
    replay_funding(
        &mut replay,
        events::collect_one<events::FundingSettled<Product>>(0),
    );
    replay_max_order_notional(
        &mut replay,
        events::collect_one<events::MaxOrderNotionalUpdated<Product>>(0),
    );
    replay_shutdown(
        &mut replay,
        events::collect_one<events::ShutdownBegun<Product>>(0),
    );
    replay_drift(
        &mut replay,
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
    let (external, local) = stored.classify_sync_changes_for_testing(&before, &before, ONE_FIXED);

    operations::apply_post_captures_for_testing(&mut vault, before, external, local);

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
    let cost = initial.classify_sync_change_for_testing(&before, &funded, ONE_FIXED);
    apply_connected_change(&mut vault, funded, cost);
    assert_eq!(vault.state().maintenance_reserve(), 90);
    assert_eq!(*vault.venue().checkpoint(), funded);
    finalize_recovered(&mut vault, sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));

    let cost = initial.classify_sync_change_for_testing(&before, &funded, ONE_FIXED);
    apply_connected_change(&mut vault, funded, cost);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_market_unwind_step_records_the_funded_checkpoint_orders_and_quote() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);

    operations::complete_unwind_for_testing(&mut vault, before, option::some(before), after, 3, option::some(1_500));

    let (id, observed, funded, actual, orders, quote) =
        events::collect_one<events::UnwindProgress<Product>>(0).unwind_progress_fields();
    assert_eq!(id, vault.id());
    assert_eq!(observed, before);
    assert_eq!(funded, option::some(before));
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

    operations::complete_unwind_for_testing(
        &mut vault, before, option::some(before), after, constants::max_active_orders!(), option::some(1_500),
    );

    let (_, _, _, _, orders, _) = events::collect_one<events::UnwindProgress<Product>>(0).unwind_progress_fields();
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
    operations::complete_unwind_for_testing(
        &mut vault, before, option::some(before), after, constants::max_active_orders!() + 1, option::some(1_500),
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
    operations::complete_unwind_for_testing(&mut vault, before, option::some(before), after, 0, option::some(1_500));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun completed_market_unwind_step_rejects_a_missing_funded_checkpoint() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    operations::complete_unwind_for_testing(&mut vault, before, option::none(), after, 1, option::some(1_500));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun completed_direct_settlement_rejects_a_funded_checkpoint() {
    let mut fixture = start();
    let before = frozen_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    operations::complete_unwind_for_testing(
        &mut vault, before, option::some(before), settled_flat_checkpoint(), 0, option::none(),
    );
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::operations)]
fun completed_direct_settlement_rejects_a_market_order() {
    let mut fixture = start();
    let before = frozen_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    operations::complete_unwind_for_testing(&mut vault, before, option::none(), settled_flat_checkpoint(), 1, option::none());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ETerminalVenueUnsettled, location = blast_boosts_aftermath::checkpoint)]
fun completed_direct_settlement_rejects_an_unfrozen_market() {
    let mut fixture = start();
    let before = initial_checkpoint();
    let mut vault = issue_and_begin_shutdown(&mut fixture, before);
    operations::complete_unwind_for_testing(&mut vault, before, option::none(), settled_flat_checkpoint(), 0, option::none());
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
    operations::complete_unwind_for_testing(&mut vault, before, option::some(before), after, 3, option::some(1_500));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun finalization_is_rejected_before_shutdown_begins() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    finalize_recovered(&mut vault, sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()));
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun completed_mint_is_rejected_after_shutdown_begins() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, REFERENCE_TIME_MS);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let shares = operations::complete_mint_for_testing<Product, Collateral>(
        &mut vault, plan, 1_000, active_position(1_998, 3_798), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!(),
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
    let mut plan = vault.state().prepare_rebalance(rebalance_position(1_000, 1_000_000), 10, REFERENCE_TIME_MS);
    let order = vault.state().next_rebalance_order(&plan);
    assert!(order.is_increase() && !order.is_emergency());
    assert_eq!(order.order_base(), 250_000);
    vault.state().accept_rebalance_fill(&mut plan, order, rebalance_position(999, 1_250_000), 250_000, REFERENCE_TIME_MS);
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);

    operations::complete_rebalance_for_testing<Product, Collateral>(&mut vault, plan, checkpoint);

    let (before_equity, after_equity, before_base, after_base, increased) =
        events::collect_one<events::Rebalanced<Product>>(0).rebalanced_amounts();
    assert_eq!(vector[before_equity, after_equity, before_base, after_base], vector[1_000, 999, 1_000_000, 1_250_000]);
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
    operations::complete_donation_for_testing(&mut vault, position_observation(SEED_EQUITY), initial, 0, REFERENCE_TIME_MS);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun deposit_checkpoint_refuses_a_free_collateral_sum_that_overflows() {
    let before = checkpoint_with_market_imr(std::u64::max_value!(), ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_deposit_checkpoint(&before, 1);
}

#[test]
fun zero_deposit_checkpoint_accepts_only_an_identical_venue() {
    let initial = initial_checkpoint();
    initial.assert_deposit_checkpoint(&initial, 0);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun zero_deposit_checkpoint_rejects_free_collateral_that_moved() {
    let after = checkpoint_with_market_imr(1, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    initial_checkpoint().assert_deposit_checkpoint(&after, 0);
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
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 15, false);
}

#[test]
fun redemption_cash_checkpoint_paid_exactly_by_free_cash() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = initial_checkpoint();
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 25, false);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun cash_checkpoint_rejects_free_collateral_that_disagrees_with_the_payout() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(6, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 20, false);
}

#[test]
#[expected_failure(abort_code = errors::ECashCheckpointMismatch, location = blast_boosts_aftermath::checkpoint)]
fun cash_checkpoint_rejects_an_unrelated_field_change_after_an_exact_move() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    let after = checkpoint_with_market_imr(5, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 2);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 20, false);
}

#[test]
fun net_funding_adds_two_costs_and_keeps_the_larger_side_of_a_cost_and_a_credit() {
    let (before, after) = two_edge_checkpoints(10, true, 5, true);
    let (external, local) = initial_checkpoint().classify_sync_changes_for_testing(&before, &after, ONE_FIXED);
    let net = external.net_funding(local);
    assert!(net.is_clean() && net.is_cost());
    assert_eq!(net.raw_amount(), 15 * ATOM_FIXED);
    assert_eq!(net.amount(), 15);

    let (before, after) = two_edge_checkpoints(10, true, 15, false);
    let (external, local) = initial_checkpoint().classify_sync_changes_for_testing(&before, &after, ONE_FIXED);
    let net = external.net_funding(local);
    assert!(net.is_clean() && !net.is_cost());
    assert_eq!(net.raw_amount(), 5 * ATOM_FIXED);
    assert_eq!(net.amount(), 5);
    assert!(net.is_credit_for_testing());
}

// === Test Helpers ===

/// Proves and completes the recovery of `recovered` from an otherwise empty venue.
fun finalize_recovered<P>(vault: &mut Vault<P, Collateral>, recovered: Coin<Collateral>) {
    let before = checkpoint::checkpoint_for_testing(recovered.value(), 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    before.assert_terminal_withdrawal_checkpoint(&terminal_checkpoint(), recovered.value());
    operations::complete_finalization_for_testing(vault, terminal_checkpoint(), recovered);
}

fun terminal_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1)
}

/// A frozen market still holding one unit of base, before a direct settlement.
fun frozen_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1)
}

/// The flat, order-free venue a direct settlement of `frozen_checkpoint` leaves, with its cash released.
fun settled_flat_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(5, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1)
}

/// The venue after a reduce-only fill halved the position at a quote the venue chose.
fun reduced_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(0, ALLOCATED_FIXED - ATOM_FIXED, ONE_FIXED / 2, 7, RATE, RATE, RATE, RATE, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1)
}

/// An active vault at `checkpoint` whose shutdown has begun.
fun issue_and_begin_shutdown(fixture: &mut Fixture, checkpoint: Checkpoint): Vault<Product, Collateral> {
    let mut vault = issue_and_activate(fixture, checkpoint);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    vault
}

/// Runs `completed_redemption_burns_the_native_input_only_after_exact_cash_return`
/// with a payout coin of `cash_amount` where the settlement is owed 994.
fun complete_redemption_with_cash(cash_amount: u64) {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let mint_plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 1_000, vault.total_share_supply(), 997_000, REFERENCE_TIME_MS);
    let (amount, _, _, _, _) = vault.state_mut().complete_mint(mint_plan, active_position(1_998, 3_798), REFERENCE_TIME_MS);
    let shares = vault.mint_shares(amount, fixture.ctx!());
    let plan = vault.state().prepare_redemption(active_position(1_998, 3_798), shares.value(), vault.total_share_supply(), 994, REFERENCE_TIME_MS);
    let (net, admin, fee, reserve_fee) = operations::settle_redemption_for_testing(
        &mut vault, plan, &shares, active_position_with_base(1_996, 1_801_897), REFERENCE_TIME_MS,
    );
    assert_eq!(net + admin, 994);
    let cash = sui::coin::mint_for_testing<Collateral>(cash_amount, fixture.ctx!());
    let final_checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 994 * ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    let cash = operations::complete_redemption_for_testing(&mut vault, shares, cash, net, admin, fee, reserve_fee, final_checkpoint, fixture.ctx!());
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
    venue_account::new_binding(
        @0xB.to_id(), 7, @0xC.to_id(), @0xD.to_id(), @0xE.to_id(), @0xF.to_id(), @0xF1.to_id(), @0xF2.to_id(),
    )
}

fun end(fixture: Fixture) {
    let Fixture { scenario, registry, protocol, authority, super_admin_cap, admin_cap } = fixture;
    destroy(registry);
    destroy(protocol);
    destroy(authority);
    destroy(super_admin_cap);
    destroy(admin_cap);
    scenario.end();
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(SYSTEM);
    let registry = coin_registry::create_coin_data_registry_for_testing(
        scenario.ctx(),
    );
    let protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        domain::vault_issuer_role() | domain::risk_admin_role()
            | domain::shutdown_admin_role(),
        ADMIN,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_BOOSTS_CORE>>();

    Fixture {
        scenario,
        registry,
        protocol,
        authority,
        super_admin_cap,
        admin_cap,
    }
}

fun issue_and_activate(
    fixture: &mut Fixture,
    checkpoint: Checkpoint,
): Vault<Product, Collateral> {
    issue_and_activate_with_policy(fixture, checkpoint, standard_vault_policy())
}

fun revoke_role(fixture: &mut Fixture, role: u64) {
    let Fixture { authority, super_admin_cap, admin_cap, .. } = fixture;
    authority.revoke_role(super_admin_cap, object::id(admin_cap), role);
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
    let Fixture {
        scenario,
        registry,
        protocol,
        authority,
        admin_cap,
        ..
    } = fixture;
    let admin_witness = authority.sign_in(admin_cap);
    let issuance = vault::issue<Tag, Collateral>(
        protocol,
        &admin_witness,
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
    let binding = venue_account::new_binding(
        @0xB.to_id(),
        7,
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        @0xF.to_id(),
        @0xF1.to_id(),
        @0xF2.to_id(),
    );
    let admin_cap = authority::new_for_testing<ACCOUNT, AdminRole>(@0xB.to_id(), scenario.ctx());
    let seeded = observation::new_position(
        SEED_EQUITY, ABSOLUTE_BASE, LOT_SIZE, side,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    let (vault, seed_nav, _) = issuance.activate(
        seeded, SEED_RESERVE, venue_account::new(binding, checkpoint, admin_cap), REFERENCE_TIME_MS, scenario.ctx(),
    );
    operations::emit_vault_initialized_for_testing<Tag, Collateral>(&vault, SEED_EQUITY, seed_nav, SEED_EQUITY, ABSOLUTE_BASE, LOT_SIZE, side, 1);

    vault
}

fun position_observation(venue_equity: u64): PositionObservation {
    position_observation_for_side(venue_equity, policy::long())
}

fun position_observation_for_side(venue_equity: u64, side: PositionSide): PositionObservation {
    observation::new_position(venue_equity, ABSOLUTE_BASE, LOT_SIZE, side,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        PRICE,
    )
}

fun active_position(equity: u64, notional: u64): PositionObservation {
    active_position_for_side(equity, notional, policy::long())
}

/// A live position of an exact base, valued at the unit price rounded up.
fun active_position_with_base(equity: u64, base: u64): PositionObservation {
    observation::new_position(equity, base, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    )
}

/// A live position of `notional` collateral atoms, held as the base that values to it.
fun active_position_for_side(equity: u64, notional: u64, side: PositionSide): PositionObservation {
    observation::new_position(equity, notional * BASE_PER_NOTIONAL, LOT_SIZE, side,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
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
    operations::apply_post_capture_for_testing(vault, checkpoint, change);
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
    let change = initial.classify_sync_change_for_testing(&before, &funded, ONE_FIXED);
    apply_connected_change(&mut vault, funded, change);

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
    let (external_change, local_change) = initial.classify_sync_changes_for_testing(&before, &after, ONE_FIXED);

    operations::apply_post_captures_for_testing(&mut vault, after, external_change, local_change);

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
    let cost = funding_before_checkpoint(10, true).classify_change_for_testing(&funded, ONE_FIXED);
    assert!(cost.is_cost() && cost.amount() == 10);
    let (external_change, local_change) = if (external_is_unexpected) {
        (checkpoint::unexpected_change(), cost)
    } else {
        (cost, checkpoint::unexpected_change())
    };

    operations::apply_post_captures_for_testing(&mut vault, funded, external_change, local_change);

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

fun assert_unexpected_sync_change(
    stored: &Checkpoint,
    before: &Checkpoint,
    after: &Checkpoint,
) {
    let change = stored.classify_sync_change_for_testing(before, after, ONE_FIXED);
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
    replay_initialized(&mut replay, events::collect_one<events::VaultInitialized<Tag>>(0));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay_fees(&mut replay, events::collect_one<events::FeesUpdated<Tag>>(0));
    let plan = vault.state().prepare_mint(position_observation_for_side(SEED_EQUITY, side), 10_000, vault.total_share_supply(), 9_989_000, REFERENCE_TIME_MS);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(2, fixture.ctx!()));
    let mut shares = operations::complete_mint_for_testing<Tag, Collateral>(&mut vault, plan, 10_000,
        active_position_for_side(10_997, 21_780, side), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
    replay_mint(&mut replay, events::collect_one<events::Minted<Tag>>(0));
    let dirty = checkpoint::checkpoint_for_testing(13, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    apply_connected_change(&mut vault, dirty, checkpoint::unexpected_change());
    replay_drift(&mut replay, events::collect<events::CheckpointDrifted<Tag>>()[0]);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::observed_venue_change_reason());
    let shutdown = events::collect_one<events::ShutdownBegun<Tag>>(0);
    assert_eq!(shutdown.shutdown_reason(), blast_boosts_core::lifecycle::observed_venue_change_reason());
    replay_shutdown(&mut replay, shutdown);
    let flat = checkpoint::checkpoint_for_testing(12, 1_000_000_000_001, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    operations::complete_unwind_for_testing(&mut vault, dirty, option::none(), flat, 0, option::none());
    let (_, before, _, after, orders, quote) = events::collect_one<events::UnwindProgress<Tag>>(0).unwind_progress_fields();
    assert_eq!(before, dirty);
    assert_eq!(orders, 0);
    assert!(quote.is_none());
    replay.checkpoint = option::some(after);
    let final_checkpoint = checkpoint::checkpoint_for_testing(0, 1, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
    flat.assert_terminal_withdrawal_checkpoint_decoded_for_testing(&final_checkpoint, recovered.value(), false, 1_000_000_000_001);
    operations::complete_finalization_for_testing(&mut vault, final_checkpoint, recovered);
    assert_eq!(events::collect<events::CheckpointDrifted<Tag>>().length(), 1);
    replay.unresolved_checkpoint = option::none();
    let (id, cash, eligible, checkpoint, remainder) = events::collect_one<events::ShutdownFinalized<Tag>>(0).shutdown_finalized_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(eligible, replay.supply - replay.locked_shares);
    replay.lifecycle = 3;
    replay.maintenance_reserve = 0;
    replay.terminal_cash = cash;
    replay.unrecoverable_collateral_raw = remainder;
    replay.checkpoint = option::some(checkpoint);
    assert_eq!(replay.unrecoverable_collateral_raw, 1);
    assert_eq!(*vault.venue().checkpoint(), final_checkpoint);
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing<Tag, Collateral>());
    let first = shares.split(2_000_000, fixture.ctx!());
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_cash = vault.redeem_shutdown<Tag, Collateral>(&fixture.protocol, first, 2, 0, &clock, fixture.ctx!());
    replay_terminal_claim(&mut replay, events::collect<events::ShutdownRedeemed<Tag>>()[0]);
    let last_cash = vault.redeem_shutdown<Tag, Collateral>(&fixture.protocol, shares, 11, 0, &clock, fixture.ctx!());
    replay_terminal_claim(&mut replay, events::collect<events::ShutdownRedeemed<Tag>>()[1]);
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
    replay_initialized(&mut replay, events::collect_one<events::VaultInitialized<Tag>>(0));
    assert_replay(&replay, vault);

    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[0]);
    assert_replay(&replay, vault);
    let plan = vault.state().prepare_mint(position_observation(SEED_EQUITY), 10_000, vault.total_share_supply(), 9_989_000, REFERENCE_TIME_MS);
    // Several events in this same transaction: live rates change after the plan seals.
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[1]);
    assert_replay(&replay, vault);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(2, fixture.ctx!()));
    let shares = operations::complete_mint_for_testing<Tag, Collateral>(vault, plan, 10_000,
        active_position(10_997, 21_780), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
    replay_mint(&mut replay, events::collect_one<events::Minted<Tag>>(0));
    assert_replay(&replay, vault);

    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[2]);
    assert_replay(&replay, vault);
    let plan = vault.state().prepare_redemption(active_position(10_997, 21_780), shares.value(), vault.total_share_supply(), 9_978, REFERENCE_TIME_MS);
    let (net, admin, fee, reserve_fee) = operations::settle_redemption_for_testing(vault, plan, &shares,
        active_position_with_base(10_996, 1_800_165), REFERENCE_TIME_MS);
    let cash = sui::coin::mint_for_testing<Collateral>(9_980, fixture.ctx!());
    let cash = operations::complete_redemption_for_testing(vault, shares, cash, net, admin, fee, reserve_fee, initial_checkpoint(), fixture.ctx!());
    replay_redemption(&mut replay, events::collect_one<events::Redeemed<Tag>>(0));
    assert_replay(&replay, vault);
    sui::transfer::public_transfer(cash, ADMIN);

    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[3]);
    assert_replay(&replay, vault);
    let cash = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 4, fixture.ctx!());
    let (id, amount, remaining) = events::collect_one<events::AdminFeesWithdrawn<Tag>>(0).admin_fees_withdrawn_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(remaining, replay.admin_cash - amount);
    replay.admin_cash = remaining;
    assert_replay(&replay, vault);
    sui::transfer::public_transfer(cash, ADMIN);

    let donated_checkpoint = checkpoint_with_market_imr(10, ALLOCATED_FIXED, RATE, RATE, RATE, RATE, 1);
    operations::complete_donation_for_testing(vault, active_position(1_026, 1_800), donated_checkpoint, 10, REFERENCE_TIME_MS);
    let (id, amount, reserve, checkpoint) = events::collect_one<events::Donated<Tag>>(0).donated_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(reserve, replay.maintenance_reserve + amount);
    replay.maintenance_reserve = reserve;
    replay.checkpoint = option::some(checkpoint);
    assert_replay(&replay, vault);

    let mut plan = vault.state().prepare_rebalance(rebalance_position(1_026, 3_000_000), 10, REFERENCE_TIME_MS);
    let order = vault.state().next_rebalance_order(&plan);
    assert!(!order.is_increase());
    let after_base = 3_000_000 - order.order_base();
    let filled = order.order_base();
    vault.state().accept_rebalance_fill(&mut plan, order, rebalance_position(1_025, after_base), filled, REFERENCE_TIME_MS);
    let checkpoint = checkpoint_with_market_imr(10, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 1);
    operations::complete_rebalance_for_testing<Tag, Collateral>(vault, plan, checkpoint);
    let event = events::collect_one<events::Rebalanced<Tag>>(0);
    let (before_equity, after_equity, before_base, event_after_base, event_increase) = event.rebalanced_amounts();
    assert_eq!(vector[before_equity, after_equity, before_base, event_after_base], vector[1_026, 1_025, 3_000_000, after_base]);
    assert!(!event_increase);
    let (id, reserve, cash, supply, checkpoint) = event.rebalanced_checkpoint_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(vector[reserve, cash, supply], vector[replay.maintenance_reserve, replay.admin_cash, replay.supply]);
    replay.checkpoint = option::some(checkpoint);
    assert_replay(&replay, vault);

    let dirty = checkpoint_with_market_imr(10, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, RATE, RATE, 2);
    apply_connected_change(vault, dirty, checkpoint::unexpected_change());
    replay_drift(&mut replay, events::collect<events::CheckpointDrifted<Tag>>()[0]);
    assert_replay(&replay, vault);
    apply_connected_change(vault, dirty, checkpoint::unexpected_change());
    replay_drift(&mut replay, events::collect<events::CheckpointDrifted<Tag>>()[1]);
    assert_replay(&replay, vault);
    apply_connected_change(vault, checkpoint, checkpoint::unchanged_change());
    assert_eq!(events::collect<events::CheckpointDrifted<Tag>>().length(), 2);
    replay.unresolved_checkpoint = option::none();
    assert_replay(&replay, vault);

    let credited_rate = RATE - ATOM_FIXED;
    let before = checkpoint_with_market_imr(10, ALLOCATED_FIXED - ATOM_FIXED, RATE, RATE, credited_rate, credited_rate, 1);
    let after = checkpoint_with_market_imr(10, ALLOCATED_FIXED, credited_rate, credited_rate, credited_rate, credited_rate, 1);
    let change = checkpoint.classify_sync_change_for_testing(&before, &after, ONE_FIXED);
    apply_connected_change(vault, after, change);
    replay_funding(&mut replay, events::collect_one<events::FundingSettled<Tag>>(0));
    assert_replay(&replay, vault);
    apply_connected_change(vault, after, checkpoint::unchanged_change());
    assert_eq!(events::collect<events::FundingSettled<Tag>>().length(), 1);
    assert_replay(&replay, vault);
}

fun rebalance_position(equity: u64, base: u64): PositionObservation {
    observation::new_position(equity, base, LOT_SIZE, policy::long(),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE)
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

fun assert_replay<Tag>(replay: &ReplayState, vault: &Vault<Tag, Collateral>) {
    assert_eq!(replay.vault_id, vault.id());
    assert_eq!(replay.maintenance_reserve, vault.state().maintenance_reserve());
    assert_eq!(replay.admin_cash, vault.admin_cash_balance<_, Collateral>());
    assert_eq!(replay.supply, vault.total_share_supply());
    let locked = vault.locked_shares();
    assert_eq!(replay.locked_shares, locked);
    let (mint, redeem, admin) = vault.fee_settings_for_testing();
    assert_eq!(replay.fees, vector[mint, redeem, admin]);
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue().checkpoint());
    assert_eq!(replay.lifecycle, 1);
    assert!(!vault.is_unwinding_for_testing());
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

fun replay_funding<Tag>(
    replay: &mut ReplayState,
    event: events::FundingSettled<Tag>,
) {
    let (vault_id, is_cost, raw_amount, amount, absorbed, uncovered, restored, reserve_after, previous_checkpoint, checkpoint) =
        event.funding_settled_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous_checkpoint, *replay.checkpoint.borrow());
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

// === Imports ===

use authority_cap::authority::{Self, ADMIN as AdminRole};

use blast_admin::acl::{Authority, AdminCap, SuperAdminCap};

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    checkpoint::{Self, Checkpoint, CheckpointChange},
    constants,
    domain_fixture,
    errors,
    events,
    operations,
    orders,
    protocol::{Self, Protocol},
    snapshot,
    vault::{Self as vault, Vault},
    venue_account::{Self, Binding},
};

use blast_boosts_core::{
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide, VaultPolicy},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
};

use perpetuals::authority::ACCOUNT;

use std::{
    string::String,
    type_name::{Self, TypeName},
    unit_test::{assert_eq, destroy},
};

use sui::{
    coin::Coin,
    coin_registry::{Self, CoinRegistry},
    test_scenario::{Self, Scenario},
};
