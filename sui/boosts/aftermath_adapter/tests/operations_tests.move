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
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: type_name::TypeName,
    maintenance_reserve: u64,
    lifecycle: u8,
    risk_module_witness: type_name::TypeName,
    max_order_notional: u64,
    checkpoint: Option<venue_account::Checkpoint>,
    unresolved_checkpoint: Option<venue_account::Checkpoint>,
    supply: u64,
    admin_cash: u64,
    locked_shares: u64,
    seed_funder: address,
    fees: vector<u64>,
    terminal_cash: u64,
    unrecoverable_collateral_raw: u256,
}

// === Tests ===

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun terminal_claim_checks_version_before_lifecycle_or_zero_shares() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    fixture.protocol.set_version_for_testing(2);
    let shares = vault.mint_eligible_shares_for_testing(0, fixture.ctx!());
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
#[expected_failure(abort_code = 47, location = blast_boosts_aftermath::vault)]
fun expired_terminal_claim_cannot_burn_shares_or_pay_cash() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let shares = vault.mint_eligible_shares_for_testing(5, fixture.ctx!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    vault.complete_shutdown(terminal_withdrawal(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!())));
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
        let mut orders = 0;
        while (orders < 16) {
            let requested = operations::active_order_size_for_testing(remaining, 250, PRICE, PRICE, 1, orders);
            assert_eq!(requested, 250_000);
            let raw = 125_000_000_000_000;
            let filled = operations::active_fill_for_testing(is_bid, requested, 1,
                if (is_bid) { raw } else { 0 }, if (is_bid) { 0 } else { raw }, 0, 0, 0);
            remaining = remaining - filled;
            orders = orders + 1;
        };
        assert_eq!(remaining, 500_000);
        // A new successful call starts a fresh bounded budget, not a stale original target.
        let mut retry_orders = 0;
        while (remaining > 0) {
            let requested = operations::active_order_size_for_testing(remaining, 250, PRICE, PRICE, 1, retry_orders);
            let raw = (requested as u256) * 1_000_000_000;
            let filled = operations::active_fill_for_testing(is_bid, requested, 1,
                if (is_bid) { raw } else { 0 }, if (is_bid) { 0 } else { raw }, 0, 0, 0);
            remaining = remaining - filled;
            retry_orders = retry_orders + 1;
        };
        assert_eq!(retry_orders, 2);
    });
}

#[test]
#[expected_failure(abort_code = 43, location = blast_boosts_aftermath::operations)]
fun unwind_failed_middle_fill_aborts_the_current_atomic_call() {
    let first = operations::active_fill_for_testing(false, 250_000, 1, 0, 125_000_000_000_000, 0, 0, 0);
    assert_eq!(first, 125_000);
    operations::active_fill_for_testing(false, 250_000, 1, 0, 0, 0, 0, 0);
}

#[test]
fun short_terminal_claims_allow_changed_order_and_split_merge_without_fees() {
    let mut fixture = start();
    let mut vault = issue_and_activate_product_with_side(&mut fixture, OtherProduct(), initial_checkpoint(),
        standard_vault_policy_for_side(policy::short()), policy::short());
    let locked = vault.share_supply();
    let mut shares = vault.mint_eligible_shares_for_testing(5, fixture.ctx!());
    let first = shares.split(3, fixture.ctx!());
    let split = shares.split(1, fixture.ctx!());
    shares.join(split);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    vault.complete_shutdown(terminal_withdrawal(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!())));
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_out = vault.redeem_shutdown<OtherProduct, Collateral>(&fixture.protocol, first, 7, 0, &clock, fixture.ctx!());
    let last_out = vault.redeem_shutdown<OtherProduct, Collateral>(&fixture.protocol, shares, 6, 0, &clock, fixture.ctx!());
    assert_eq!(vector[first_out.value(), last_out.value()], vector[7, 6]);
    assert_eq!(vault.share_supply(), locked);
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
    let locked = vault.share_supply();
    let mut shares = vault.mint_eligible_shares_for_testing(5, fixture.ctx!());
    let split = shares.split(2, fixture.ctx!());
    shares.join(split);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    vault.complete_shutdown(terminal_withdrawal(sui::coin::zero<Collateral>(fixture.ctx!())));
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let output = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!());
    assert_eq!(output.value(), 0);
    output.destroy_zero();
    assert_eq!(vault.share_supply(), locked);
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
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun finalization_cannot_recover_or_pay_the_seed_funder_twice() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    vault.complete_shutdown(terminal_withdrawal(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!())));
    vault.complete_shutdown(terminal_withdrawal(sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!())));
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_direct_settlement_reports_actual_cash_and_no_market_order() {
    let mut fixture = start();
    let before = venue_account::new_checkpoint(0, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    let after = venue_account::new_checkpoint(5, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    let mut vault = issue_and_activate(&mut fixture, before);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    operations::complete_unwind_for_testing(&mut vault, before, option::none(), after, 0, option::none());
    let event = events::collect_one<events::UnwindProgress<Product>>(0);
    let (id, observed, funded, actual, orders, quote) = event.unwind_progress_fields();
    assert_eq!(id, vault.id_for_testing());
    assert_eq!(observed, before);
    assert!(funded.is_none());
    assert_eq!(actual, after);
    assert_eq!(orders, 0);
    assert!(quote.is_none());
    assert_eq!(*vault.venue_checkpoint(), after);
    assert!(vault.is_unwinding_for_testing());
    destroy(vault);
    fixture.end();
}

#[test]
fun unwind_normalization_keeps_exact_positive_whole_lots_in_both_directions() {
    assert_eq!(operations::unwind_base_for_testing(1_800_000_000_000, true, 1, policy::long()), 1_800);
    assert_eq!(operations::unwind_base_for_testing(1_800_000_000_000, false, 1, policy::short()), 1_800);
}

#[test]
#[expected_failure(abort_code = 55, location = blast_boosts_aftermath::operations)]
fun unwind_normalization_rejects_a_forced_opposite_direction() {
    operations::unwind_base_for_testing(1_800_000_000_000, false, 1, policy::long());
}

#[test]
#[expected_failure(abort_code = 55, location = blast_boosts_aftermath::operations)]
fun ordinary_unwind_never_rounds_raw_base_dust_to_a_whole_lot() {
    operations::unwind_base_for_testing(1_800_000_000_001, true, 1, policy::long());
}

#[test]
fun insolvent_capture_still_supplies_fresh_close_only_valuation() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let captured = snapshot::captured_health_for_testing(initial_checkpoint(), 0, false);
    let base = captured.base_price_observation();
    let collateral = captured.collateral_price_observation();
    captured.into_checkpoint();
    let (side, cap, base_price, collateral_price) = vault.unwind_constraints(base, collateral, REFERENCE_TIME_MS);
    assert_eq!(side, policy::long());
    assert_eq!(vector[cap, base_price, collateral_price], vector[250, PRICE, PRICE]);
    destroy(vault);
    fixture.end();
}

#[test]
fun terminal_claims_exclude_locked_seed_burn_native_shares_and_give_last_claimant_dust() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let locked = vault.share_supply_for_testing();
    let mut shares = vault.mint_eligible_shares_for_testing(5, fixture.ctx!());
    let first = shares.split(2, fixture.ctx!());
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(7, fixture.ctx!()));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
    vault.complete_shutdown(terminal_withdrawal(recovered));
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_out = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, first, 5, 0, &clock, fixture.ctx!());
    assert_eq!(first_out.value(), 5);
    let last_out = vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 8, 0, &clock, fixture.ctx!());
    assert_eq!(last_out.value(), 8);
    assert_eq!(vault.share_supply_for_testing(), locked);
    assert_eq!(vault.maintenance_reserve_for_testing(), 0);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 7);
    let finalization = events::collect_one<events::ShutdownFinalized<Product>>(0);
    let (_, recovered, eligible, fallback, checkpoint, remainder) = finalization.shutdown_finalized_fields();
    assert_eq!(remainder, 0);
    assert_eq!(recovered, 13);
    assert_eq!(eligible, 5);
    assert!(fallback.is_none());
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
fun zero_eligible_supply_sends_all_terminal_cash_to_recorded_funder_not_finalizer() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::observed_venue_change_reason());
    fixture.next_tx!(@0xBEEF, |fixture| {
        let recovered = sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!());
        vault.complete_shutdown(terminal_withdrawal(recovered));
        assert_eq!(vault.maintenance_reserve_for_testing(), 0);
        let (_, cash, eligible, beneficiary, _, remainder) = events::collect_one<events::ShutdownFinalized<Product>>(0).shutdown_finalized_fields();
        assert_eq!(remainder, 0);
        assert_eq!(vector[cash, eligible], vector[13, 0]);
        assert_eq!(beneficiary, option::some(ADMIN));
        destroy(vault);
    });
    fixture.next_tx!(ADMIN, |fixture| {
        let returned = fixture.take_collateral();
        assert_eq!(returned.value(), 13);
        destroy(returned);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun terminal_claim_before_shutdown_rejects_lifecycle_before_missing_cash_field() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let shares = vault.mint_eligible_shares_for_testing(5, fixture.ctx!());
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    destroy(vault.redeem_shutdown<Product, Collateral>(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!()));
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_boosts_aftermath::venue_account)]
fun finalization_rejects_a_short_actual_coin_even_when_the_venue_is_empty() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let before = venue_account::new_checkpoint(13, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(12, fixture.ctx!());
    operations::complete_finalization_for_testing(&mut vault, recovered, before, terminal_checkpoint());
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_boosts_aftermath::venue_account)]
fun finalization_rejects_a_short_actual_coin_with_exact_sub_atomic_remainder() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    let before = venue_account::new_checkpoint(12, 1_000_000_000_001, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let after = venue_account::new_checkpoint(0, 1, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    let recovered = sui::coin::mint_for_testing<Collateral>(12, fixture.ctx!());
    vault.complete_shutdown(before.terminal_withdrawal_for_testing(after, recovered, false, 1_000_000_000_001));
    destroy(vault);
    fixture.end();
}

#[test]
fun event_reducer_reconstructs_active_economics_for_two_product_types() {
    let mut fixture = start();
    let vault_policy = standard_vault_policy().with_fee_limits(100, 100, 3_000);
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
    let plan = vault.prepare_redemption(position_observation(SEED_EQUITY, true), &shares, 1, REFERENCE_TIME_MS);
    destroy(shares);
    let wrong_shares = sui::coin::mint_for_testing<BlastBoost<Product>>(99_999, fixture.ctx!());
    let receipt = operations::seal_redemption_receipt(&mut vault, plan, wrong_shares,
        position_observation(SEED_EQUITY, false), initial_checkpoint(), REFERENCE_TIME_MS);
    destroy(receipt);
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
        standard_vault_policy().with_fee_limits(100, 100, 3_000));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    let plan = vault.prepare_mint(position_observation(SEED_EQUITY, true), 10_000, 9_989_000, REFERENCE_TIME_MS);
    assert_eq!(plan.admin_fee(), 2);
    assert_eq!(plan.base_to_buy(), 19_980_000);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(2, fixture.ctx!()));
    let shares = operations::complete_mint<Product, Collateral>(
        &mut vault, plan, active_position(10_997, 21_780), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!(),
    );
    let (_, minted, contribution, fee, admin, buffer, rate, allocation, reserve, cash, supply) =
        events::collect_one<events::Minted<Product>>(0).minted_amounts();
    assert_eq!(vector[minted, contribution, fee, admin, buffer, rate, allocation, reserve, cash, supply],
        vector[9_989_000, 9_989, 10, 2, 8, 10, 2_000, 108, 2, 10_889_000]);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    let plan = vault.prepare_redemption(active_position(10_997, 21_780), &shares, 9_978, REFERENCE_TIME_MS);
    // 21_780_000 less the floor of its 900_000 / 10_889_000 share, to the atom.
    assert_eq!(plan.base_to_sell(), 19_979_835);
    let receipt = operations::seal_redemption_receipt(&mut vault, plan, shares,
        active_position_with_base(10_996, 1_800_165), initial_checkpoint(), REFERENCE_TIME_MS);
    assert_eq!(receipt.redemption_cash_required(), 9_980);
    let cash = sui::coin::mint_for_testing<Collateral>(9_980, fixture.ctx!());
    let cash = operations::complete_redemption(&mut vault, receipt, cash,
        active_position_with_base(1_016, 1_800_165), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
    assert_eq!(cash.value(), 9_978);
    assert_eq!(vault.share_supply(), 900_000);
    assert_eq!(vault.maintenance_reserve(), 116);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 4);
    assert_eq!(events::collect_one<events::Redeemed<Product>>(0).redeemed_amounts(),
        vector[9_989_000, 9_978, 10, 2, 8, 10, 2_000, 116, 4, 900_000]);
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 4);
    assert_eq!(vault.maintenance_reserve(), 116);
    let earnings = vault.withdraw_admin_fees<_, Collateral>(&fixture.protocol, &witness, 4, fixture.ctx!());
    assert_eq!(earnings.value(), 4);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(vault.maintenance_reserve(), 116);
    assert_eq!(vault.share_supply(), 900_000);
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
    let before = checkpoint_with_market_imr(0, ALLOCATED_FIXED, 10, 20, 11, 21, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + ATOM_FIXED, 11, 21, 11, 21, 1);
    let change = operations::classify_sync_change_for_testing(&initial, &before, &after, false, ATOM_FIXED);
    apply_connected_change(&mut vault, after, change, SEED_EQUITY + 1, true);
    replay_funding(&mut replay, events::collect_one<events::FundingSettled<Product>>(0));
    assert_eq!(replay.maintenance_reserve, vault.maintenance_reserve());
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue_checkpoint());
    destroy(vault);
    fixture.end();
}

#[test]
fun recovered_diagnostic_emits_once_without_claiming_lifecycle_failure() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let dirty = checkpoint_with_market_imr(0, ALLOCATED_FIXED, 10, 20, 10, 20, 2);
    apply_connected_change(&mut vault, dirty, snapshot::unexpected_change(), SEED_EQUITY, true);
    apply_connected_change(&mut vault, initial, snapshot::unchanged_change(), SEED_EQUITY, true);
    let recovered = events::collect<events::HealthSynchronized<Product>>();
    let event = recovered[1];
    let (_, reason, checkpoint) = event.health_synchronized_fields();
    assert_eq!(reason, 2);
    assert_eq!(checkpoint, initial);
    assert!(vault.unresolved_checkpoint_digest_for_testing().is_none());
    apply_connected_change(&mut vault, initial, snapshot::unchanged_change(), SEED_EQUITY, true);
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 2);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
fun completed_rebalance_changes_only_holder_equity_and_the_accepted_checkpoint() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let before = observation::new_position(
        1_000, 3_000_000, 3_000, LOT_SIZE, policy::long(), 0, true, true, true,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    let mut plan = vault.prepare_rebalance(before, 10, REFERENCE_TIME_MS);
    let base_price = plan.base_price();
    let collateral_price = plan.collateral_price();
    let lot = plan.lot_size();
    assert_eq!(base_price, PRICE);
    assert_eq!(collateral_price, PRICE);
    assert_eq!(lot, LOT_SIZE);
    let (base, increase, wide) = vault.rebalance_order(&plan);
    assert_eq!(base, 250_000);
    assert!(!increase && wide);
    vault.assert_rebalance_execution(&plan, PRICE, PRICE);
    let after = observation::new_position(
        999, 2_750_000, 2_750, LOT_SIZE, policy::long(), 0, true, true, true,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    vault.accept_rebalance_fill(&mut plan, after, base, REFERENCE_TIME_MS);
    let checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, 10, 20, 10, 20, 1);
    operations::complete_rebalance<Product, Collateral>(&mut vault, plan, checkpoint);
    assert_eq!(vault.maintenance_reserve_for_testing(), 100);
    assert_eq!(vault.share_supply(), 900_000);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(*vault.venue_checkpoint(), checkpoint);
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
    assert_eq!(operations::venue_fee_bound_for_testing(1_000_000_000_000_000, 500_000_000_000_000), 15);
    assert_eq!(operations::venue_fee_bound_for_testing(1, 0), 1);
    assert_eq!(operations::venue_fee_bound_for_testing(0, 0), 0);
    assert_eq!(operations::venue_fee_bound_for_testing(1_000_000_000_000_000_000, 0), 10_000);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EVenueFeeUnusable, location = blast_boosts_aftermath::operations)]
fun venue_fee_bound_rejects_unrepresentable_addition_before_overflow() {
    operations::venue_fee_bound_for_testing(std::u256::max_value!(), 1);
}

#[test]
fun completed_redemption_burns_the_native_input_only_after_exact_cash_return() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let mint_plan = vault.prepare_mint(position_observation(SEED_EQUITY, true), 1_000, 997_000, REFERENCE_TIME_MS);
    let (shares, _, _, _, _, _, _) = vault.complete_mint(mint_plan, active_position(1_998, 3_798), REFERENCE_TIME_MS, fixture.ctx!());
    let plan = vault.prepare_redemption(active_position(1_998, 3_798), &shares, 994, REFERENCE_TIME_MS);
    // 3_798_000 less the floor of its 900_000 / 1_897_000 share, to the atom.
    assert_eq!(plan.base_to_sell(), 1_996_103);
    let receipt = operations::seal_redemption_receipt(
        &mut vault, plan, shares, active_position_with_base(1_996, 1_801_897), initial_checkpoint(), REFERENCE_TIME_MS,
    );
    assert_eq!(receipt.redemption_cash_required(), 994);
    let cash = sui::coin::mint_for_testing<Collateral>(994, fixture.ctx!());
    let final_checkpoint = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 994 * ATOM_FIXED, 10, 20, 10, 20, 1);
    let cash = operations::complete_redemption(
        &mut vault, receipt, cash, active_position_with_base(1_002, 1_801_897), final_checkpoint, REFERENCE_TIME_MS, fixture.ctx!(),
    );
    assert_eq!(cash.value(), 994);
    assert_eq!(vault.share_supply_for_testing(), 900_000);
    assert_eq!(vault.maintenance_reserve_for_testing(), 102);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    sui::transfer::public_transfer(cash, ADMIN);
    destroy(vault);
    fixture.end();
}

#[test]
fun allocated_cash_changes_cross_zero_with_exact_signed_magnitudes() {
    venue_account::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, false, 3 * ATOM_FIXED, 5, true);
    venue_account::assert_signed_cash_change_for_testing(false, 3 * ATOM_FIXED, true, 2 * ATOM_FIXED, 5, false);
    venue_account::assert_signed_cash_change_for_testing(true, 5 * ATOM_FIXED, true, 2 * ATOM_FIXED, 3, true);
}

#[test]
#[expected_failure(abort_code = 42, location = blast_boosts_aftermath::venue_account)]
fun allocated_cash_changes_reject_a_reversed_signed_delta() {
    venue_account::assert_signed_cash_change_for_testing(true, 2 * ATOM_FIXED, false, 3 * ATOM_FIXED, 5, false);
}

#[test]
fun active_checkpoint_admits_only_the_executed_position_and_venue_cost() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, 10, 20, 10, 20, 1);
    before.assert_trade_checkpoint(&after, 1, 1);
    let allocated = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 50 * ATOM_FIXED, 10, 20, 10, 20, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&allocated, 50, true);
}

#[test]
#[expected_failure(abort_code = 48, location = blast_boosts_aftermath::venue_account)]
fun active_checkpoint_rejects_a_foreign_market_parameter_change() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - ATOM_FIXED, 10, 20, 10, 20, 2);
    before.assert_trade_checkpoint(&after, 1, 1);
}

#[test]
#[expected_failure(abort_code = 42, location = blast_boosts_aftermath::venue_account)]
fun active_checkpoint_rejects_an_inexact_allocated_deposit() {
    let before = initial_checkpoint();
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED + 49 * ATOM_FIXED, 10, 20, 10, 20, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 50, true);
}

#[test]
fun redemption_cash_checkpoint_spends_free_cash_before_deallocating() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, 10, 20, 10, 20, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 15 * ATOM_FIXED, 10, 20, 10, 20, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 40, false);
}

#[test]
#[expected_failure(abort_code = 42, location = blast_boosts_aftermath::venue_account)]
fun redemption_cash_checkpoint_rejects_inexact_payout() {
    let before = checkpoint_with_market_imr(25, ALLOCATED_FIXED, 10, 20, 10, 20, 1);
    let after = checkpoint_with_market_imr(0, ALLOCATED_FIXED - 14 * ATOM_FIXED, 10, 20, 10, 20, 1);
    before.assert_nonnegative_cash_checkpoint_for_testing(&after, 40, false);
}

#[test]
fun active_order_uses_the_sealed_base_without_a_notional_round_trip() {
    assert_eq!(operations::active_order_size_for_testing(1_998, 1, PRICE, PRICE, 1, 0), 1_000);
    assert_eq!(operations::active_order_size_for_testing(998, 1, PRICE, PRICE, 1, 15), 998);
    operations::assert_deadline_for_testing(1_000, 1_000);
}

/// The guard mirrors the pinned venue formula: the next update is the start of
/// the period after the one containing the last update, and it is due at that
/// instant, not one millisecond before it.
#[test]
fun funding_update_is_due_at_the_next_period_boundary_and_not_before() {
    let frequency = 3_600_000;
    let last = 7 * frequency + 1_234;
    let next = 8 * frequency;

    assert_eq!(operations::next_funding_update_time_ms_for_testing(last, frequency), next);
    assert!(!operations::is_time_to_update_funding_for_testing(next - 1, last, frequency));
    assert!(operations::is_time_to_update_funding_for_testing(next, last, frequency));
    assert!(operations::is_time_to_update_funding_for_testing(next + 1, last, frequency));
    assert!(operations::is_time_to_update_funding_for_testing(next + 5 * frequency, last, frequency));
}

/// An aligned last update is due exactly one period later, and a market whose
/// last update is the current instant is not due.
#[test]
fun funding_update_from_an_aligned_last_update_is_due_one_period_later() {
    let frequency = 60_000;

    assert_eq!(operations::next_funding_update_time_ms_for_testing(0, frequency), frequency);
    assert_eq!(operations::next_funding_update_time_ms_for_testing(frequency, frequency), 2 * frequency);
    assert!(!operations::is_time_to_update_funding_for_testing(frequency, frequency, frequency));
    assert!(!operations::is_time_to_update_funding_for_testing(2 * frequency - 1, frequency, frequency));
    assert!(operations::is_time_to_update_funding_for_testing(2 * frequency, frequency, frequency));
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
        assert!(!operations::is_time_to_update_funding_for_testing(now, last, frequency));
        now = now + 1;
    };
    assert!(operations::is_time_to_update_funding_for_testing(now, last, frequency));
}

/// The funding update authenticates the bound market and base oracle before touching either.
#[test]
fun funding_update_inputs_accept_the_bound_market_and_base_oracle() {
    funding_binding().assert_funding_update_inputs(@0xD.to_id(), @0xE.to_id());
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EClearingHouseMismatch, location = blast_boosts_aftermath::venue_account)]
fun funding_update_rejects_an_unbound_market_before_the_oracle() {
    funding_binding().assert_funding_update_inputs(@0xDD.to_id(), @0xEE.to_id());
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EBaseOracleMismatch, location = blast_boosts_aftermath::venue_account)]
fun funding_update_rejects_the_collateral_oracle_as_its_storage() {
    funding_binding().assert_funding_update_inputs(@0xD.to_id(), @0xF.to_id());
}

/// A zero frequency is never due, so the adapter never asks the venue to divide by it.
#[test]
fun a_market_without_a_funding_cadence_is_never_due() {
    assert!(!operations::is_time_to_update_funding_for_testing(0, 0, 0));
    assert!(!operations::is_time_to_update_funding_for_testing(std::u64::max_value!(), 0, 0));
}

/// Exhausts small periods and offsets against an independent reference of the
/// venue formula.
#[test]
fun funding_update_guard_matches_the_small_domain_reference() {
    1u64.range_do!(6, |frequency| {
        0u64.range_do!(25, |last| {
            let next = (last / frequency + 1) * frequency;
            assert_eq!(operations::next_funding_update_time_ms_for_testing(last, frequency), next);
            0u64.range_do!(31, |now| {
                assert_eq!(
                    operations::is_time_to_update_funding_for_testing(now, last, frequency),
                    now >= next,
                );
            });
        });
    });
}

#[test]
#[expected_failure(abort_code = 46, location = blast_boosts_aftermath::operations)]
fun active_order_rejects_a_seventeenth_session() {
    operations::active_order_size_for_testing(10, 1, PRICE, PRICE, 1, 16);
}

#[test]
#[expected_failure(abort_code = 47, location = blast_boosts_aftermath::operations)]
fun active_order_rejects_an_expired_deadline() {
    operations::assert_deadline_for_testing(1_001, 1_000);
}

#[test]
fun active_partial_fill_consumes_only_filled_whole_lots() {
    assert_eq!(operations::active_fill_for_testing(true, 100, 10, 60_000_000_000, 0, 0, 0, 0), 60);
    assert_eq!(operations::active_fill_for_testing(false, 100, 10, 0, 100_000_000_000, 0, 0, 0), 100);
}

#[test]
#[expected_failure(abort_code = 43, location = blast_boosts_aftermath::operations)]
fun active_partial_fill_rejects_zero_progress() {
    operations::active_fill_for_testing(true, 100, 10, 0, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 43, location = blast_boosts_aftermath::operations)]
fun active_partial_fill_rejects_opposite_side() {
    operations::active_fill_for_testing(true, 100, 10, 60_000_000_000, 10_000_000_000, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 43, location = blast_boosts_aftermath::operations)]
fun active_partial_fill_rejects_fractional_lot() {
    operations::active_fill_for_testing(true, 100, 10, 61_000_000_000, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 43, location = blast_boosts_aftermath::operations)]
fun active_partial_fill_rejects_overfill() {
    operations::active_fill_for_testing(true, 100, 10, 110_000_000_000, 0, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 44, location = blast_boosts_aftermath::operations)]
fun active_partial_fill_rejects_posted_orders() {
    operations::active_fill_for_testing(true, 100, 10, 60_000_000_000, 0, 1, 0, 0);
}

#[test]
#[expected_failure(abort_code = 45, location = blast_boosts_aftermath::operations)]
fun active_partial_fill_rejects_liquidation() {
    operations::active_fill_for_testing(true, 100, 10, 60_000_000_000, 0, 0, 1, 0);
}

#[test]
fun completed_mint_returns_native_shares_and_updates_the_same_treasury_supply() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    vault.assert_active_observation(position_observation(SEED_EQUITY, true), PRICE, PRICE, REFERENCE_TIME_MS);
    let plan = vault.prepare_mint(position_observation(SEED_EQUITY, true), 1_000, 997_000, REFERENCE_TIME_MS);
    assert_eq!(plan.base_to_buy(), 1_998_000);
    let base_price = plan.mint_base_price();
    let collateral_price = plan.mint_collateral_price();
    let lot = plan.mint_lot_size();
    assert_eq!(base_price, PRICE);
    assert_eq!(collateral_price, PRICE);
    assert_eq!(lot, LOT_SIZE);
    let (side, cap) = vault.active_constraints();
    assert_eq!(side, policy::long());
    assert!(cap > 0);
    vault.assert_active_execution(PRICE, PRICE);
    let after = observation::new_position(
        1_998, 3_798 * BASE_PER_NOTIONAL, 3_798, LOT_SIZE, policy::long(), 0, true, true, true,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    );
    let shares = operations::complete_mint<Product, Collateral>(&mut vault, plan, after, initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
    let event = events::collect_one<events::Minted<Product>>(0);
    let (deposit, minted, contribution, fee, admin, buffer, rate, admin_rate, reserve, admin_cash, supply) = event.minted_amounts();
    assert_eq!(deposit, 1_000);
    assert_eq!(minted, 997_000);
    assert_eq!(contribution, 997);
    assert_eq!(fee, 1);
    assert_eq!(admin, 0);
    assert_eq!(buffer, 1);
    assert_eq!(rate, 10);
    assert_eq!(admin_rate, 0);
    assert_eq!(reserve, 101);
    assert_eq!(admin_cash, 0);
    assert_eq!(supply, 1_897_000);
    assert_eq!(shares.value(), 997_000);
    assert_eq!(vault.share_supply_for_testing(), 1_897_000);
    assert_eq!(vault.maintenance_reserve_for_testing(), 101);
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
    let after = checkpoint_with_market_imr(50, ALLOCATED_FIXED, 10, 20, 10, 20, 1);
    let plan = vault.prepare_donation(position_observation(SEED_EQUITY, true), 50, REFERENCE_TIME_MS);
    operations::complete_donation(
        &mut vault, plan,
        position_observation(SEED_EQUITY + 50, true), after, 50, REFERENCE_TIME_MS,
    );
    assert_eq!(vault.maintenance_reserve_for_testing(), 150);
    assert_eq!(vault.share_supply_for_testing(), 900_000);
    assert_eq!(vault.admin_cash_balance<_, Collateral>(), 0);
    assert_eq!(*vault.venue_checkpoint(), after);
    let (id, amount, reserve, checkpoint) =
        events::collect_one<events::Donated<Product>>(0).donated_fields();
    assert_eq!(id, vault.id_for_testing());
    assert_eq!(vector[amount, reserve], vector[50, 150]);
    assert_eq!(checkpoint, after);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 42, location = blast_boosts_aftermath::venue_account)]
fun donation_cannot_accept_an_unrelated_position_margin_change() {
    let mut fixture = start();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint());
    let after = checkpoint_with_market_imr(50, ALLOCATED_FIXED, 10, 20, 10, 20, 2);
    let plan = vault.prepare_donation(position_observation(SEED_EQUITY, true), 50, REFERENCE_TIME_MS);
    operations::complete_donation(
        &mut vault, plan,
        position_observation(SEED_EQUITY + 50, true), after, 50, REFERENCE_TIME_MS,
    );
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
    assert_eq!(vault.maintenance_reserve_for_testing(), SEED_RESERVE);
    assert_eq!(*vault.venue_checkpoint(), initial);
    assert_eq!(vault.share_supply_for_testing(), 900_000);
    let event = events::collect_one<events::AdminFeesWithdrawn<Product>>(0);
    let (id, amount, remaining) = event.admin_fees_withdrawn_fields();
    assert_eq!(id, vault.id_for_testing());
    assert_eq!(vector[amount, remaining], vector[10, 15]);
    sui::coin::burn_for_testing(cash);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 41, location = blast_boosts_aftermath::vault)]
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
    let orders = operations::order_sizes_for_testing(
        100_000_000,
        30_000_000,
        2_000_000_000,
        1_000_000_000,
        1_000_000,
    );

    assert_eq!(orders, vector[15_000_000_000, 15_000_000_000, 15_000_000_000, 5_000_000_000]);
}

#[test]
fun target_and_order_cap_round_down_to_whole_base_lots() {
    let orders = operations::order_sizes_for_testing(
        10_000_001,
        6_000_001,
        2_000_000_000,
        1_000_000_000,
        1_000_000_000,
    );

    assert_eq!(orders, vector[3_000_000_000, 2_000_000_000]);
}

#[test]
#[expected_failure(abort_code = 32, location = blast_boosts_aftermath::operations)]
fun target_below_one_lot_is_rejected() {
    operations::order_sizes_for_testing(
        1,
        1,
        2_000_000_000,
        1_000_000_000,
        1_000_000_000,
    );
}

#[test]
#[expected_failure(abort_code = 32, location = blast_boosts_aftermath::operations)]
fun a_zero_target_is_rejected_as_an_invalid_order_size() {
    operations::order_sizes_for_testing(
        0,
        1,
        2_000_000_000,
        1_000_000_000,
        1,
    );
}

#[test]
#[expected_failure(abort_code = 32, location = blast_boosts_aftermath::operations)]
fun a_zero_order_cap_is_rejected_as_an_invalid_order_size() {
    operations::order_sizes_for_testing(
        1,
        0,
        2_000_000_000,
        1_000_000_000,
        1,
    );
}

#[test]
fun initialization_order_count_accepts_zero_remaining_and_the_fixed_maximum() {
    assert_eq!(operations::max_initialization_orders_for_testing(), 16);
    assert_eq!(operations::order_count_for_testing(0, 1), 0);
    assert_eq!(operations::order_count_for_testing(16, 1), 16);
}

#[test]
fun maximum_order_count_preserves_the_exact_total_and_per_order_cap() {
    let orders = operations::order_sizes_for_testing(
        16,
        1,
        1_000_000_000,
        1_000_000_000,
        1,
    );
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
        operations::actual_fill_notional_for_testing(
            30_000_000_000_001_000_000,
            1_000_000_000,
        ),
        30_000_001,
    );
}

#[test]
#[expected_failure(
    abort_code = 26,
    location = blast_boosts_aftermath::operations,
)]
fun actual_fill_notional_rejects_a_zero_collateral_price() {
    operations::actual_fill_notional_for_testing(1, 0);
}

#[test]
#[expected_failure(abort_code = 38, location = blast_boosts_aftermath::operations)]
fun initialization_order_count_rejects_the_first_value_above_the_maximum() {
    operations::order_count_for_testing(17, 1);
}

#[test]
fun initialization_order_count_ceil_does_not_add_before_dividing() {
    assert_eq!(
        operations::order_count_for_testing(
            std::u64::max_value!(),
            std::u64::max_value!() - 1,
        ),
        2,
    );
}

#[test]
#[expected_failure(abort_code = 32, location = blast_boosts_aftermath::operations)]
fun one_lot_above_the_order_cap_is_rejected() {
    operations::order_sizes_for_testing(
        2_000_000,
        1_999_999,
        2_000_000_000,
        1_000_000_000,
        1_000_000_000,
    );
}

#[test]
fun exact_long_and_short_full_fills_are_accepted() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
        0,
    );
    operations::assert_session_result_for_testing(
        false,
        5_000_000_000,
        0,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
    );
}

#[test]
fun series_side_maps_to_the_aftermath_port_convention() {
    assert_eq!(operations::opens_with_ask_for_testing(policy::long()), false);
    assert_eq!(operations::opens_with_ask_for_testing(policy::short()), true);
}

#[test]
#[expected_failure(abort_code = 33, location = blast_boosts_aftermath::operations)]
fun a_partial_fill_is_rejected() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        4_999_999_999_000_000_000,
        0,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 33, location = blast_boosts_aftermath::operations)]
fun a_fill_on_the_wrong_side_is_rejected() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34, location = blast_boosts_aftermath::operations)]
fun a_posted_order_is_rejected_before_fill_validation() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        0,
        1,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 35, location = blast_boosts_aftermath::operations)]
fun a_liquidation_is_rejected_before_fill_validation() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        0,
        0,
        1,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 35, location = blast_boosts_aftermath::operations)]
fun bad_debt_is_rejected_before_fill_validation() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        0,
        0,
        0,
        1,
    );
}

#[test]
fun valid_local_initialization_inputs_are_accepted() {
    operations::assert_initialization_inputs_for_testing(false, 6, 100, 10, 0);
}

#[test]
#[expected_failure(abort_code = 19, location = blast_boosts_aftermath::vault)]
fun already_initialized_precedes_currency_and_seed_validation() {
    operations::assert_initialization_inputs_for_testing(true, 7, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = 28, location = blast_boosts_aftermath::operations)]
fun non_six_decimal_collateral_is_rejected_before_seed_validation() {
    operations::assert_initialization_inputs_for_testing(false, 7, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = 29, location = blast_boosts_aftermath::operations)]
fun a_zero_seed_is_rejected_before_reserve_validation() {
    operations::assert_initialization_inputs_for_testing(false, 6, 0, 1, 1);
}

#[test]
#[expected_failure(abort_code = 30, location = blast_boosts_aftermath::operations)]
fun a_reserve_equal_to_the_seed_is_rejected_before_supply_validation() {
    operations::assert_initialization_inputs_for_testing(false, 6, 100, 100, 1);
}

#[test]
#[expected_failure(abort_code = 31, location = blast_boosts_aftermath::operations)]
fun preexisting_share_supply_is_rejected() {
    operations::assert_initialization_inputs_for_testing(false, 6, 100, 10, 1);
}

#[test]
fun locked_share_scaling_accepts_the_largest_seed_nav() {
    assert_eq!(
        operations::locked_shares_for_testing(std::u64::max_value!() / 1_000),
        std::u64::max_value!() / 1_000 * 1_000,
    );
}

#[test]
#[expected_failure(abort_code = 37, location = blast_boosts_aftermath::operations)]
fun locked_share_scaling_rejects_the_first_overflow() {
    operations::locked_shares_for_testing(std::u64::max_value!() / 1_000 + 1);
}

#[test]
fun execution_price_rounds_against_the_vault() {
    assert_eq!(
        operations::execution_price_for_testing(2_000_000_000_000_000_001, true, false),
        2_000_000_001,
    );
    assert_eq!(
        operations::execution_price_for_testing(2_000_000_000_999_999_999, false, false),
        2_000_000_000,
    );
}

#[test]
#[expected_failure(abort_code = 26, location = blast_boosts_aftermath::operations)]
fun negative_execution_price_is_rejected() {
    operations::execution_price_for_testing(1, true, true);
}

#[test]
#[expected_failure(abort_code = 26, location = blast_boosts_aftermath::operations)]
fun unrepresentable_execution_price_is_rejected() {
    operations::execution_price_for_testing(std::u256::max_value!(), false, false);
}

#[test]
fun nonnegative_position_imr_is_accepted() {
    operations::assert_position_imr_for_testing(false);
}

#[test]
#[expected_failure(abort_code = 36, location = blast_boosts_aftermath::operations)]
fun negative_position_imr_is_rejected() {
    operations::assert_position_imr_for_testing(true);
}

#[test]
fun vault_initialized_event_records_every_activation_primitive() {
    let checkpoint = venue_account::checkpoint_for_testing(
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
        @0xB.to_id(),
        27,
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        @0xF.to_id(),
        type_name::with_original_ids<Collateral>(),
        28,
        29,
        30,
        31,
        32,
        ADMIN,
        33,
        34,
        35,
        policy::short(),
        36,
        checkpoint,
    );

    let event = events::collect_one<events::VaultInitialized<Product>>(0);
    assert_eq!(event.vault_initialized_seed_funder(), ADMIN);
    let (
        vault_id,
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        seed_amount,
        seed_venue_equity,
        seed_reserve,
        seed_shareholder_nav,
        locked_shares,
        position_base,
        position_collateral,
        lot_size,
        side,
        position_imr,
        event_checkpoint,
    ) = event.vault_initialized_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert_eq!(account_object_id, @0xB.to_id());
    assert_eq!(account_number, 27);
    assert_eq!(registry_id, @0xC.to_id());
    assert_eq!(clearing_house_id, @0xD.to_id());
    assert_eq!(base_oracle_id, @0xE.to_id());
    assert_eq!(collateral_oracle_id, @0xF.to_id());
    assert_eq!(collateral_type, type_name::with_original_ids<Collateral>());
    assert_eq!(seed_amount, 28);
    assert_eq!(seed_venue_equity, 29);
    assert_eq!(seed_reserve, 30);
    assert_eq!(seed_shareholder_nav, 31);
    assert_eq!(locked_shares, 32);
    assert_eq!(position_base, 33);
    assert_eq!(position_collateral, 34);
    assert_eq!(lot_size, 35);
    assert_eq!(side, policy::short());
    assert_eq!(position_imr, 36);
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
fun synchronization_classifies_no_change_and_replay_as_no_funding() {
    let before = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);

    let first = operations::classify_sync_change_for_testing(
        &before,
        &before,
        &before,
        false,
        0,
    );
    assert!(first.is_unchanged_for_testing());

    let after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);
    let replay = operations::classify_sync_change_for_testing(
        &after,
        &after,
        &after,
        false,
        0,
    );
    assert!(replay.is_unchanged_for_testing());
}

#[test]
fun synchronization_accepts_only_an_isolated_funding_credit() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 10, 20, 0, 0, 0);
    let before = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    let change = operations::classify_sync_change_for_testing(
        &stored,
        &before,
        &after,
        false,
        10_000_000_000_000,
    );
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        change.funding_change_fields();

    assert!(has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert!(checkpoint_clean);
    assert!(change.is_credit_for_testing());
}

#[test]
fun synchronization_rounds_an_isolated_funding_cost_against_the_reserve() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 10, 20, 0, 0, 0);
    let before = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(1_000, 99_000_000_000_001, 11, 21, 11, 21, 0, 0, 0);

    let change = operations::classify_sync_change_for_testing(
        &stored,
        &before,
        &after,
        true,
        999_999_999_999,
    );
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        change.funding_change_fields();

    assert!(has_funding);
    assert!(is_cost);
    assert_eq!(raw_amount, 999_999_999_999);
    assert_eq!(amount, 1);
    assert!(checkpoint_clean);
    assert!(change.is_cost_for_testing());
}

#[test]
fun synchronization_recognizes_permissionlessly_settled_funding_once() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 10, 20, 0, 0, 0);
    let settled = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    let change = operations::classify_sync_change_for_testing(
        &stored,
        &settled,
        &settled,
        false,
        0,
    );
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        change.funding_change_fields();

    assert!(has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert!(checkpoint_clean);

    let replay = operations::classify_sync_change_for_testing(
        &settled,
        &settled,
        &settled,
        false,
        0,
    );
    assert!(replay.is_unchanged_for_testing());
}

#[test]
fun synchronization_preserves_external_then_local_funding_as_two_ordered_changes() {
    let stored = sync_checkpoint(1_000, 100 * ATOM_FIXED, 10, 20, 10, 20, 0, 0, 0);
    let before = sync_checkpoint(1_000, 90 * ATOM_FIXED, 11, 21, 12, 22, 0, 0, 0);
    let after = sync_checkpoint(1_000, 95 * ATOM_FIXED, 12, 22, 12, 22, 0, 0, 0);

    let (external, local) = operations::classify_sync_changes_for_testing(
        &stored,
        &before,
        &after,
        false,
        5 * ATOM_FIXED,
    );

    let (has_external, external_is_cost, external_raw, _, external_clean) =
        external.funding_change_fields();
    let (has_local, local_is_cost, local_raw, _, local_clean) =
        local.funding_change_fields();
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
fun health_event_records_stable_reason_and_latest_checkpoint() {
    let checkpoint = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 1);

    events::health_synchronized<Product>(
        @0xA.to_id(),
        events::diagnostic_raised_reason(),
        checkpoint,
    );
    let event = events::collect_one<events::HealthSynchronized<Product>>(0);
    let (vault_id, reason, event_checkpoint) =
        event.health_synchronized_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert_eq!(reason, events::diagnostic_raised_reason());
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EUnresolvedCheckpoint, location = blast_boosts_aftermath::venue_account)]
fun active_operation_rejects_unresolved_checkpoint_with_its_own_error() {
    let before = sync_checkpoint(1_000, 100, 10, 20, 11, 21, 0, 0, 1);
    let after = sync_checkpoint(1_001, 100, 10, 20, 11, 21, 0, 0, 1);
    before.assert_accepted_checkpoint(&after);
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
    let change = operations::classify_sync_change_for_testing(
        &initial, &funding_before_checkpoint(), &funded, true, (cost as u256) * ATOM_FIXED,
    );
    apply_connected_change(&mut vault, funded, change, SEED_EQUITY - cost, true);
    assert_eq!(vault.maintenance_reserve_for_testing(), 0);

    // Second interval: market rates advance again and a 50-unit credit lands.
    let credited = checkpoint_with_market_imr(
        0, ALLOCATED_FIXED - (cost as u256) * ATOM_FIXED + 50 * ATOM_FIXED, 12, 22, 12, 22, 1,
    );
    let change = operations::classify_sync_change_for_testing(
        &funded,
        &checkpoint_with_market_imr(0, ALLOCATED_FIXED - (cost as u256) * ATOM_FIXED, 11, 21, 12, 22, 1),
        &credited, false, 50 * ATOM_FIXED,
    );
    apply_connected_change(&mut vault, credited, change, SEED_EQUITY - cost + 50, true);

    // 30 of the 50 repay the deficit and stay in NAV; 20 rebuild the reserve.
    assert_eq!(vault.maintenance_reserve_for_testing(), 20);
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
    let before = funding_before_checkpoint();
    let credited = funding_checkpoint(10, false);
    let credit = operations::classify_sync_change_for_testing(
        &initial,
        &before,
        &credited,
        false,
        10 * ATOM_FIXED,
    );

    apply_connected_change(
        &mut vault,
        credited,
        credit,
        SEED_EQUITY + 10,
        true,
    );
    let unchanged = operations::classify_sync_change_for_testing(
        &credited,
        &credited,
        &credited,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        credited,
        unchanged,
        SEED_EQUITY + 10,
        true,
    );

    assert_eq!(vault.maintenance_reserve_for_testing(), SEED_RESERVE + 10);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);
    assert_eq!(*vault.venue_checkpoint(), credited);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_second_call_at_the_same_checkpoint_is_exactly_once() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = funding_before_checkpoint();
    let funded = funding_checkpoint(10, true);
    let cost = operations::classify_sync_change_for_testing(
        &initial,
        &before,
        &funded,
        true,
        10 * ATOM_FIXED,
    );
    apply_connected_change(
        &mut vault,
        funded,
        cost,
        SEED_EQUITY - 10,
        true,
    );

    let replay = operations::classify_sync_change_for_testing(
        &funded,
        &funded,
        &funded,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        funded,
        replay,
        SEED_EQUITY - 10,
        true,
    );

    assert_eq!(vault.maintenance_reserve_for_testing(), 90);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);
    assert_eq!(*vault.venue_checkpoint(), funded);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_permissionless_pre_settlement_debits_the_reserve_exactly_once() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let settled = funding_checkpoint(10, true);
    let cost = operations::classify_sync_change_for_testing(
        &initial,
        &settled,
        &settled,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        settled,
        cost,
        SEED_EQUITY - 10,
        true,
    );

    let replay = operations::classify_sync_change_for_testing(
        &settled,
        &settled,
        &settled,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        settled,
        replay,
        SEED_EQUITY - 10,
        true,
    );

    assert_eq!(vault.maintenance_reserve_for_testing(), 90);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);
    assert_eq!(*vault.venue_checkpoint(), settled);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_external_cost_and_local_income_settle_one_net_checkpoint() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = checkpoint_with_market_imr(
        0,
        ALLOCATED_FIXED - 110 * ATOM_FIXED,
        11,
        21,
        12,
        22,
        1,
    );
    let after = checkpoint_with_market_imr(
        0,
        ALLOCATED_FIXED - 90 * ATOM_FIXED,
        12,
        22,
        12,
        22,
        1,
    );
    let (external, local) = operations::classify_sync_changes_for_testing(
        &initial,
        &before,
        &after,
        false,
        20 * ATOM_FIXED,
    );

    operations::apply_post_captures_for_testing(
        &mut vault,
        snapshot::captured_health_for_testing(
            after,
            SEED_EQUITY - 90,
            true,
        ),
        external,
        local,
    );

    assert_eq!(vault.maintenance_reserve_for_testing(), 10);
    let funding_events = events::collect<events::FundingSettled<Product>>();
    assert_eq!(funding_events.length(), 1);
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);
    assert_eq!(*vault.venue_checkpoint(), after);
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
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = funding_before_checkpoint();
    let after = funding_checkpoint(0, false);
    let change = operations::classify_sync_change_for_testing(&initial, &before, &after, false, 0);
    apply_connected_change(&mut vault, after, change, SEED_EQUITY, true);
    assert_eq!(vault.maintenance_reserve_for_testing(), SEED_RESERVE);
    assert_eq!(*vault.venue_checkpoint(), after);
    let facts = events::collect<events::FundingSettled<Product>>();
    assert_eq!(facts.length(), 1);
    let (_, is_cost, raw, amount, absorbed, uncovered, _, reserve, previous, current) =
        facts.borrow(0).funding_settled_fields();
    assert!(!is_cost);
    assert_eq!(raw, 0);
    assert_eq!(vector[amount, absorbed, uncovered, reserve], vector[0, 0, 0, SEED_RESERVE]);
    assert_eq!(previous, initial);
    assert_eq!(current, after);
    let unchanged = operations::classify_sync_change_for_testing(&after, &after, &after, false, 0);
    apply_connected_change(&mut vault, after, unchanged, SEED_EQUITY, true);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 1);
    destroy(vault);
    fixture.end();
}

#[test]
fun gross_funding_width_is_checked_only_after_the_signed_net() {
    let large = (18_446_744_073_709_551_615u256 + 10) * ATOM_FIXED;
    let stored = checkpoint_with_market_imr(0, large + 100 * ATOM_FIXED, 10, 20, 10, 20, 1);
    let before = checkpoint_with_market_imr(0, 100 * ATOM_FIXED, 11, 21, 12, 22, 1);
    let after = checkpoint_with_market_imr(0, large + 99 * ATOM_FIXED, 12, 22, 12, 22, 1);
    let (external, local) = operations::classify_sync_changes_for_testing(
        &stored, &before, &after, false, large - ATOM_FIXED,
    );
    let net = external.net_funding(local);
    let (has_funding, is_cost, raw, amount, clean) = net.funding_change_fields();
    assert!(clean && has_funding && is_cost);
    assert_eq!(raw, ATOM_FIXED);
    assert_eq!(amount, 1);
}

#[test]
fun connected_unresolved_drift_preserves_the_accepted_checkpoint_across_retries() {
    let mut fixture = start();
    let initial = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial);
    let before = checkpoint_with_market_imr(
        0,
        ALLOCATED_FIXED,
        10,
        20,
        11,
        21,
        2,
    );
    let after = checkpoint_with_market_imr(
        0,
        ALLOCATED_FIXED - 10 * ATOM_FIXED,
        11,
        21,
        11,
        21,
        2,
    );
    let unexpected = operations::classify_sync_change_for_testing(
        &initial,
        &before,
        &after,
        true,
        10 * ATOM_FIXED,
    );

    apply_connected_change(
        &mut vault,
        after,
        unexpected,
        SEED_EQUITY - 10,
        true,
    );

    assert_eq!(vault.maintenance_reserve_for_testing(), SEED_RESERVE);
    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(*vault.venue_checkpoint(), initial);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    let synchronized = events::collect_one<events::HealthSynchronized<Product>>(0);
    let (_, reason, checkpoint) =
        synchronized.health_synchronized_fields();
    assert_eq!(reason, events::diagnostic_raised_reason());
    assert_eq!(checkpoint, after);

    let replay = operations::classify_sync_change_for_testing(
        vault.venue_checkpoint(),
        &after,
        &after,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        after,
        replay,
        SEED_EQUITY - 10,
        true,
    );
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 1);
    assert_eq!(vault.maintenance_reserve_for_testing(), SEED_RESERVE);
    destroy(vault);
    fixture.end();
}

#[test]
fun connected_temporary_health_fault_keeps_lifecycle_and_emits_no_mutation() {
    let mut fixture = start();
    let checkpoint = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, checkpoint);
    let unchanged = operations::classify_sync_change_for_testing(
        &checkpoint,
        &checkpoint,
        &checkpoint,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        checkpoint,
        unchanged,
        SEED_EQUITY,
        false,
    );

    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(*vault.venue_checkpoint(), checkpoint);
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);

    let repeated = operations::classify_sync_change_for_testing(
        &checkpoint,
        &checkpoint,
        &checkpoint,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        checkpoint,
        repeated,
        SEED_EQUITY,
        false,
    );
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);
    assert_eq!(events::collect<events::FundingSettled<Product>>().length(), 0);
    destroy(vault);
    fixture.end();
}

#[test]
fun reducer_reconstructs_every_canonical_vault_fact_from_the_event_stream() {
    let mut fixture = start();
    let initial_checkpoint = initial_checkpoint();
    let mut vault = issue_and_activate(&mut fixture, initial_checkpoint);
    let vault_id = vault.id_for_testing();

    let funded_checkpoint = funding_checkpoint(10, true);
    let funding_before = funding_before_checkpoint();
    let funding = operations::classify_sync_change_for_testing(
        &initial_checkpoint,
        &funding_before,
        &funded_checkpoint,
        true,
        10 * ATOM_FIXED,
    );
    apply_connected_change(
        &mut vault,
        funded_checkpoint,
        funding,
        SEED_EQUITY - 10,
        true,
    );
    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new(),
        300,
    );
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.rotate_risk_module<Product, RiskModuleV2>(
        &fixture.protocol,
        &admin_witness,
        test_risk_module::new_v2(),
    );
    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

    let final_checkpoint = checkpoint_with_market_imr(
        1,
        ALLOCATED_FIXED - 10 * ATOM_FIXED,
        11,
        21,
        11,
        21,
        1,
    );
    let unexpected = operations::classify_sync_change_for_testing(
        &funded_checkpoint,
        &final_checkpoint,
        &final_checkpoint,
        false,
        0,
    );
    apply_connected_change(
        &mut vault,
        final_checkpoint,
        unexpected,
        SEED_EQUITY - 9,
        true,
    );

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
    replay_risk_rotation(
        &mut replay,
        events::collect_one<events::RiskModuleWitnessRotated<Product>>(0),
    );
    replay_shutdown(
        &mut replay,
        events::collect_one<events::ShutdownBegun<Product>>(0),
    );
    replay_health(
        &mut replay,
        events::collect_one<events::HealthSynchronized<Product>>(0),
    );

    let actual_binding = vault.venue_binding();
    actual_binding.assert_exact(
        replay.account_object_id,
        replay.account_number,
        replay.registry_id,
        replay.clearing_house_id,
        replay.base_oracle_id,
        replay.collateral_oracle_id,
        replay.collateral_type,
    );
    assert_eq!(replay.vault_id, vault_id);
    assert_eq!(replay.maintenance_reserve, vault.maintenance_reserve_for_testing());
    assert_eq!(replay.lifecycle == 2, vault.is_unwinding_for_testing());
    assert_eq!(
        replay.risk_module_witness,
        vault.risk_module_witness_for_testing(),
    );
    let actual_order_notional = vault.max_order_notional_for_testing();
    assert_eq!(replay.max_order_notional, actual_order_notional);
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue_checkpoint());
    assert_eq!(*vault.venue_checkpoint(), funded_checkpoint);
    assert_eq!(*replay.unresolved_checkpoint.borrow(), final_checkpoint);
    assert_eq!(
        vault.unresolved_checkpoint_digest_for_testing(),
        option::some(sui::hash::blake2b256(&std::bcs::to_bytes(replay.unresolved_checkpoint.borrow()))),
    );

    destroy(vault);
    fixture.end();
}

// === Test Helpers ===

fun terminal_withdrawal(recovered: sui::coin::Coin<Collateral>): venue_account::TerminalWithdrawal<Collateral> {
    let before = venue_account::new_checkpoint(recovered.value(), 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1);
    before.terminal_withdrawal(terminal_checkpoint(), recovered)
}

fun terminal_checkpoint(): venue_account::Checkpoint {
    venue_account::new_checkpoint(0, 0, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, false, 1, 1, 1)
}

macro fun ctx($self: &mut Fixture): &mut sui::tx_context::TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

macro fun next_tx($self: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun take_collateral(fixture: &Fixture): sui::coin::Coin<Collateral> {
    fixture.scenario.take_from_sender()
}

fun funding_binding(): venue_account::Binding {
    venue_account::new_binding(
        @0xB.to_id(), 7, @0xC.to_id(), @0xD.to_id(), @0xE.to_id(), @0xF.to_id(),
        type_name::with_original_ids<sui::sui::SUI>(),
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
    checkpoint: venue_account::Checkpoint,
): Vault<Product> {
    issue_and_activate_with_policy(fixture, checkpoint, standard_vault_policy())
}

fun revoke_role(fixture: &mut Fixture, role: u64) {
    let Fixture { authority, super_admin_cap, admin_cap, .. } = fixture;
    authority.revoke_role(super_admin_cap, object::id(admin_cap), role);
}

fun issue_and_activate_with_policy(
    fixture: &mut Fixture, checkpoint: venue_account::Checkpoint, vault_policy: policy::VaultPolicy,
): Vault<Product> {
    issue_and_activate_product(fixture, Product(), checkpoint, vault_policy)
}

fun issue_and_activate_product<Tag: drop>(
    fixture: &mut Fixture, product: Tag, checkpoint: venue_account::Checkpoint, vault_policy: policy::VaultPolicy,
): Vault<Tag> {
    issue_and_activate_product_with_side(fixture, product, checkpoint, vault_policy, policy::long())
}

fun issue_and_activate_product_with_side<Tag: drop>(
    fixture: &mut Fixture, _: Tag, checkpoint: venue_account::Checkpoint, vault_policy: policy::VaultPolicy, side: policy::PositionSide,
): Vault<Tag> {
    let Fixture {
        scenario,
        registry,
        protocol,
        authority,
        admin_cap,
        ..
    } = fixture;
    let admin_witness = authority.sign_in(admin_cap);
    let mut vault = vault::issue<Tag, RiskModule>(
        protocol,
        &admin_witness,
        test_risk_module::new(),
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
    let seed_nav = vault.initialize(
        observation::new_position(SEED_EQUITY, ABSOLUTE_BASE, ABSOLUTE_NOTIONAL, LOT_SIZE, side, 0, true, true, true,
            observation::new_price(PRICE, 0, REFERENCE_TIME_MS), observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE),
        SEED_RESERVE,
        6,
        REFERENCE_TIME_MS,
    );
    vault.mint_locked_shares_for_testing(
        seed_nav * 1_000,
        ADMIN,
        scenario.ctx(),
    );
    let binding = venue_account::new_binding(
        @0xB.to_id(),
        7,
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        @0xF.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
    let venue = venue_account::new_for_testing(binding, checkpoint);
    vault.install_venue_account(venue);
    operations::emit_vault_initialized<Tag>(
        &vault,
        SEED_EQUITY,
        SEED_EQUITY,
        ABSOLUTE_BASE,
        ABSOLUTE_NOTIONAL,
        LOT_SIZE,
        side,
        1,
    );

    vault
}

fun position_observation(
    venue_equity: u64,
    margin_safe: bool,
): observation::PositionObservation {
    position_observation_for_side(venue_equity, margin_safe, policy::long())
}

fun position_observation_for_side(venue_equity: u64, margin_safe: bool, side: policy::PositionSide): observation::PositionObservation {
    observation::new_position(
        venue_equity,
        ABSOLUTE_BASE,
        ABSOLUTE_NOTIONAL,
        LOT_SIZE,
        side,
        0,
        margin_safe,
        true,
        true,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        PRICE,
    )
}

fun active_position(equity: u64, notional: u64): observation::PositionObservation {
    active_position_for_side(equity, notional, policy::long())
}

/// A live position of an exact base, valued at the unit price rounded up.
fun active_position_with_base(equity: u64, base: u64): observation::PositionObservation {
    observation::new_position(
        equity, base, base.div_ceil(BASE_PER_NOTIONAL), LOT_SIZE, policy::long(), 0, true, true, true,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    )
}

/// A live position of `notional` collateral atoms, held as the base that values to it.
fun active_position_for_side(equity: u64, notional: u64, side: policy::PositionSide): observation::PositionObservation {
    observation::new_position(
        equity, notional * BASE_PER_NOTIONAL, notional, LOT_SIZE, side, 0, true, true, true,
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS),
        observation::new_price(PRICE, 0, REFERENCE_TIME_MS), PRICE,
    )
}

fun initial_checkpoint(): venue_account::Checkpoint {
    checkpoint_with_market_imr(
        0,
        ALLOCATED_FIXED,
        10,
        20,
        10,
        20,
        1,
    )
}

fun funding_before_checkpoint(): venue_account::Checkpoint {
    checkpoint_with_market_imr(
        0,
        ALLOCATED_FIXED,
        10,
        20,
        11,
        21,
        1,
    )
}

fun funding_checkpoint(
    amount: u64,
    is_cost: bool,
): venue_account::Checkpoint {
    checkpoint_with_market_imr(
        0,
        if (is_cost) {
            ALLOCATED_FIXED - (amount as u256) * ATOM_FIXED
        } else {
            ALLOCATED_FIXED + (amount as u256) * ATOM_FIXED
        },
        11,
        21,
        11,
        21,
        1,
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
): venue_account::Checkpoint {
    venue_account::checkpoint_for_testing(
        free_collateral,
        allocated_collateral,
        1,
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

fun apply_connected_change<Tag>(
    vault: &mut Vault<Tag>,
    checkpoint: venue_account::Checkpoint,
    change: snapshot::Change,
    venue_equity: u64,
    margin_safe: bool,
) {
    operations::apply_post_capture_for_testing(
        vault,
        snapshot::captured_health_for_testing(
            checkpoint,
            venue_equity,
            margin_safe,
        ),
        change,
    );
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
    let before = funding_before_checkpoint();
    let funded = funding_checkpoint(amount, true);
    let change = operations::classify_sync_change_for_testing(
        &initial,
        &before,
        &funded,
        true,
        (amount as u256) * ATOM_FIXED,
    );
    apply_connected_change(
        &mut vault,
        funded,
        change,
        SEED_EQUITY - amount,
        true,
    );

    assert_eq!(vault.maintenance_reserve_for_testing(), expected_reserve);
    assert_eq!(*vault.venue_checkpoint(), funded);
    assert!(!vault.is_unwinding_for_testing());
    assert_eq!(events::collect<events::HealthSynchronized<Product>>().length(), 0);
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
    assert_eq!(vault_id, vault.id_for_testing());
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
): venue_account::Checkpoint {
    venue_account::checkpoint_for_testing(
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
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
) {
    let change = operations::classify_sync_change_for_testing(
        stored,
        before,
        after,
        false,
        10_000_000_000_000,
    );
    let (has_funding, _, _, _, checkpoint_clean) =
        change.funding_change_fields();

    assert!(!has_funding);
    assert!(!checkpoint_clean);
    assert!(change.is_unexpected_for_testing());
}

fun standard_vault_policy(): policy::VaultPolicy {
    standard_vault_policy_for_side(policy::long())
}

fun standard_vault_policy_for_side(side: policy::PositionSide): policy::VaultPolicy {
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
        100,
        5_000,
    )
}

fun replay_terminal_lifecycle<Tag: drop>(product: Tag, side: policy::PositionSide) {
    let mut fixture = start();
    let vault_policy = standard_vault_policy_for_side(side).with_fee_limits(100, 100, 3_000);
    let mut vault = issue_and_activate_product_with_side(&mut fixture, product, initial_checkpoint(), vault_policy, side);
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Tag>>(0));
    replay_initialized(&mut replay, events::collect_one<events::VaultInitialized<Tag>>(0));
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay_fees(&mut replay, events::collect_one<events::FeesUpdated<Tag>>(0));
    let plan = vault.prepare_mint(position_observation_for_side(SEED_EQUITY, true, side), 10_000, 9_989_000, REFERENCE_TIME_MS);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(2, fixture.ctx!()));
    let mut shares = operations::complete_mint<Tag, Collateral>(&mut vault, plan,
        active_position_for_side(10_997, 21_780, side), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
    replay_mint(&mut replay, events::collect_one<events::Minted<Tag>>(0));
    let dirty = venue_account::new_checkpoint(13, 0, 1, 1, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    apply_connected_change(&mut vault, dirty, snapshot::unexpected_change(), 0, false);
    replay_health(&mut replay, events::collect<events::HealthSynchronized<Tag>>()[0]);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::observed_venue_change_reason());
    let shutdown = events::collect_one<events::ShutdownBegun<Tag>>(0);
    assert_eq!(shutdown.shutdown_reason(), blast_boosts_core::lifecycle::observed_venue_change_reason());
    replay_shutdown(&mut replay, shutdown);
    let flat = venue_account::new_checkpoint(12, 1_000_000_000_001, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    operations::complete_unwind_for_testing(&mut vault, dirty, option::none(), flat, 0, option::none());
    let (_, before, _, after, orders, quote) = events::collect_one<events::UnwindProgress<Tag>>(0).unwind_progress_fields();
    assert_eq!(before, dirty);
    assert_eq!(orders, 0);
    assert!(quote.is_none());
    replay.checkpoint = option::some(after);
    let final_checkpoint = venue_account::new_checkpoint(0, 1, 0, 0, 11, 21, 11, 21, LOT_SIZE,
        0, 0, 0, 0, true, 1, 1, 1);
    let withdrawal = flat.terminal_withdrawal_for_testing(final_checkpoint,
        sui::coin::mint_for_testing<Collateral>(13, fixture.ctx!()), false, 1_000_000_000_001);
    vault.complete_shutdown(withdrawal);
    replay_health(&mut replay, events::collect<events::HealthSynchronized<Tag>>()[1]);
    let (id, cash, eligible, fallback, checkpoint, remainder) = events::collect_one<events::ShutdownFinalized<Tag>>(0).shutdown_finalized_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(eligible, replay.supply - replay.locked_shares);
    assert!(fallback.is_none());
    replay.lifecycle = 3;
    replay.maintenance_reserve = 0;
    replay.terminal_cash = cash;
    replay.unrecoverable_collateral_raw = remainder;
    replay.checkpoint = option::some(checkpoint);
    assert_eq!(replay.unrecoverable_collateral_raw, 1);
    assert_eq!(*vault.venue_checkpoint(), final_checkpoint);
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing<Tag, Collateral>());
    let first = shares.split(2_000_000, fixture.ctx!());
    let clock = sui::clock::create_for_testing(fixture.ctx!());
    let first_cash = vault.redeem_shutdown<Tag, Collateral>(&fixture.protocol, first, 2, 0, &clock, fixture.ctx!());
    replay_terminal_claim(&mut replay, events::collect<events::ShutdownRedeemed<Tag>>()[0]);
    let last_cash = vault.redeem_shutdown<Tag, Collateral>(&fixture.protocol, shares, 11, 0, &clock, fixture.ctx!());
    replay_terminal_claim(&mut replay, events::collect<events::ShutdownRedeemed<Tag>>()[1]);
    assert_eq!(first_cash.value() + last_cash.value(), 13);
    assert_eq!(replay.terminal_cash, vault.terminal_cash_for_testing<Tag, Collateral>());
    assert_eq!(replay.supply, vault.share_supply());
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue_checkpoint());
    assert!(replay.unresolved_checkpoint.is_none());
    assert!(vault.unresolved_checkpoint_digest_for_testing().is_none());
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
fun replay_active_economics<Tag>(fixture: &mut Fixture, vault: &mut Vault<Tag>) {
    let mut replay = replay_issued(events::collect_one<events::VaultIssued<Tag>>(0));
    replay_initialized(&mut replay, events::collect_one<events::VaultInitialized<Tag>>(0));
    assert_replay(&replay, vault);

    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[0]);
    assert_replay(&replay, vault);
    let plan = vault.prepare_mint(position_observation(SEED_EQUITY, true), 10_000, 9_989_000, REFERENCE_TIME_MS);
    // Several events in this same transaction: live rates change after the plan seals.
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[1]);
    assert_replay(&replay, vault);
    vault.retain_admin_cash(sui::coin::mint_for_testing<Collateral>(2, fixture.ctx!()));
    let shares = operations::complete_mint<Tag, Collateral>(vault, plan,
        active_position(10_997, 21_780), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
    replay_mint(&mut replay, events::collect_one<events::Minted<Tag>>(0));
    assert_replay(&replay, vault);

    vault.set_fees(&fixture.protocol, &witness, 10, 10, 2_000);
    replay_fees(&mut replay, events::collect<events::FeesUpdated<Tag>>()[2]);
    assert_replay(&replay, vault);
    let plan = vault.prepare_redemption(active_position(10_997, 21_780), &shares, 9_978, REFERENCE_TIME_MS);
    let receipt = operations::seal_redemption_receipt(vault, plan, shares,
        active_position_with_base(10_996, 1_800_165), initial_checkpoint(), REFERENCE_TIME_MS);
    let cash = sui::coin::mint_for_testing<Collateral>(9_980, fixture.ctx!());
    let cash = operations::complete_redemption(vault, receipt, cash,
        active_position_with_base(1_016, 1_800_165), initial_checkpoint(), REFERENCE_TIME_MS, fixture.ctx!());
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

    let plan = vault.prepare_donation(active_position(1_016, 1_800), 10, REFERENCE_TIME_MS);
    let donated_checkpoint = checkpoint_with_market_imr(10, ALLOCATED_FIXED, 10, 20, 10, 20, 1);
    operations::complete_donation(vault, plan, active_position(1_026, 1_800), donated_checkpoint, 10, REFERENCE_TIME_MS);
    let (id, amount, reserve, checkpoint) = events::collect_one<events::Donated<Tag>>(0).donated_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(reserve, replay.maintenance_reserve + amount);
    replay.maintenance_reserve = reserve;
    replay.checkpoint = option::some(checkpoint);
    assert_replay(&replay, vault);

    let mut plan = vault.prepare_rebalance(rebalance_position(1_026, 3_000_000, 3_000), 10, REFERENCE_TIME_MS);
    let (base, increase, _) = vault.rebalance_order(&plan);
    assert!(!increase);
    let after_base = 3_000_000 - base;
    vault.accept_rebalance_fill(&mut plan, rebalance_position(1_025, after_base, after_base / 1_000), base, REFERENCE_TIME_MS);
    let checkpoint = checkpoint_with_market_imr(10, ALLOCATED_FIXED - ATOM_FIXED, 10, 20, 10, 20, 1);
    operations::complete_rebalance<Tag, Collateral>(vault, plan, checkpoint);
    let event = events::collect_one<events::Rebalanced<Tag>>(0);
    let (before_equity, after_equity, before_base, event_after_base, event_increase) = event.rebalanced_amounts();
    assert_eq!(vector[before_equity, after_equity, before_base, event_after_base], vector[1_026, 1_025, 3_000_000, after_base]);
    assert!(!event_increase);
    let (id, reserve, cash, supply, checkpoint) = event.rebalanced_checkpoint_fields();
    assert_eq!(id, replay.vault_id);
    assert_eq!(vector[reserve, cash, supply], vector[replay.maintenance_reserve, replay.admin_cash, replay.supply]);
    replay.checkpoint = option::some(checkpoint);
    assert_replay(&replay, vault);

    let dirty = checkpoint_with_market_imr(10, ALLOCATED_FIXED - ATOM_FIXED, 10, 20, 10, 20, 2);
    apply_connected_change(vault, dirty, snapshot::unexpected_change(), 1_025, true);
    replay_health(&mut replay, events::collect<events::HealthSynchronized<Tag>>()[0]);
    assert_replay(&replay, vault);
    apply_connected_change(vault, dirty, snapshot::unexpected_change(), 1_025, true);
    assert_eq!(events::collect<events::HealthSynchronized<Tag>>().length(), 1);
    assert_replay(&replay, vault);
    apply_connected_change(vault, checkpoint, snapshot::unchanged_change(), 1_025, true);
    replay_health(&mut replay, events::collect<events::HealthSynchronized<Tag>>()[1]);
    assert_replay(&replay, vault);

    let before = checkpoint_with_market_imr(10, ALLOCATED_FIXED - ATOM_FIXED, 10, 20, 11, 21, 1);
    let after = checkpoint_with_market_imr(10, ALLOCATED_FIXED, 11, 21, 11, 21, 1);
    let change = operations::classify_sync_change_for_testing(&checkpoint, &before, &after, false, ATOM_FIXED);
    apply_connected_change(vault, after, change, 1_026, true);
    replay_funding(&mut replay, events::collect_one<events::FundingSettled<Tag>>(0));
    assert_replay(&replay, vault);
    apply_connected_change(vault, after, snapshot::unchanged_change(), 1_026, true);
    assert_eq!(events::collect<events::FundingSettled<Tag>>().length(), 1);
    assert_eq!(events::collect<events::HealthSynchronized<Tag>>().length(), 2);
    assert_replay(&replay, vault);
}

fun rebalance_position(equity: u64, base: u64, notional: u64): observation::PositionObservation {
    observation::new_position(equity, base, notional, LOT_SIZE, policy::long(), 0, true, true, true,
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
    let (deposit, shares, contribution, fee, admin, buffer, rate, allocation, reserve, cash, supply) = event.minted_amounts();
    assert_eq!(id, replay.vault_id);
    assert_eq!(fee, (deposit * rate + 9_999) / 10_000);
    assert_eq!(admin, fee * allocation / 10_000);
    assert_eq!(fee, admin + buffer);
    assert_eq!(vector[deposit, shares, contribution, rate, allocation], vector[10_000, 9_989_000, 9_989, 10, 2_000]);
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
    assert_eq!(fee, ((net + fee) * amounts[5] + 9_999) / 10_000);
    assert_eq!(admin, fee * amounts[6] / 10_000);
    assert_eq!(fee, admin + buffer);
    assert_eq!(vector[shares, net, amounts[5], amounts[6]], vector[9_989_000, 9_978, replay.fees[1], replay.fees[2]]);
    assert_eq!(vector[amounts[7], amounts[8], amounts[9]], vector[replay.maintenance_reserve + buffer, replay.admin_cash + admin, replay.supply - shares]);
    replay.maintenance_reserve = amounts[7];
    replay.admin_cash = amounts[8];
    replay.supply = amounts[9];
    replay.checkpoint = option::some(checkpoint);
}

fun assert_replay<Tag>(replay: &ReplayState, vault: &Vault<Tag>) {
    assert_eq!(replay.vault_id, vault.id());
    assert_eq!(replay.maintenance_reserve, vault.maintenance_reserve());
    assert_eq!(replay.admin_cash, vault.admin_cash_balance<_, Collateral>());
    assert_eq!(replay.supply, vault.share_supply());
    let (locked, funder) = vault.seed_facts();
    assert_eq!(replay.locked_shares, locked);
    assert_eq!(replay.seed_funder, funder);
    let (mint, redeem, admin) = vault.fee_settings_for_testing();
    assert_eq!(replay.fees, vector[mint, redeem, admin]);
    assert_eq!(*replay.checkpoint.borrow(), *vault.venue_checkpoint());
    let digest = replay.unresolved_checkpoint.map!(|checkpoint| sui::hash::blake2b256(&std::bcs::to_bytes(&checkpoint)));
    assert_eq!(digest, vault.unresolved_checkpoint_digest_for_testing());
    assert_eq!(replay.lifecycle, 1);
    assert!(!vault.is_uninitialized_for_testing() && !vault.is_unwinding_for_testing());
}

fun replay_issued<Tag>(event: events::VaultIssued<Tag>): ReplayState {
    let (
        vault_id,
        _,
        _,
        risk_module_witness,
        vault_policy,
        max_order_notional,
        _,
        maintenance_reserve,
    ) = event.vault_issued_fields();
    let (mint, redeem) = vault_policy.initial_fee_rates_for_testing();

    ReplayState {
        vault_id,
        account_object_id: @0x0.to_id(),
        account_number: 0,
        registry_id: @0x0.to_id(),
        clearing_house_id: @0x0.to_id(),
        base_oracle_id: @0x0.to_id(),
        collateral_oracle_id: @0x0.to_id(),
        collateral_type: type_name::with_original_ids<u8>(),
        maintenance_reserve,
        lifecycle: 0,
        risk_module_witness,
        max_order_notional,
        checkpoint: option::none(),
        unresolved_checkpoint: option::none(),
        supply: 0,
        admin_cash: 0,
        locked_shares: 0,
        seed_funder: @0x0,
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
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        _,
        _,
        maintenance_reserve,
        _,
        locked_shares,
        _,
        _,
        _,
        _,
        _,
        checkpoint,
    ) = event.vault_initialized_fields();
    assert_eq!(vault_id, replay.vault_id);

    replay.account_object_id = account_object_id;
    replay.account_number = account_number;
    replay.registry_id = registry_id;
    replay.clearing_house_id = clearing_house_id;
    replay.base_oracle_id = base_oracle_id;
    replay.collateral_oracle_id = collateral_oracle_id;
    replay.collateral_type = collateral_type;
    replay.maintenance_reserve = maintenance_reserve;
    replay.supply = locked_shares;
    replay.locked_shares = locked_shares;
    replay.seed_funder = event.vault_initialized_seed_funder();
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

fun replay_risk_rotation<Tag>(
    replay: &mut ReplayState,
    event: events::RiskModuleWitnessRotated<Tag>,
) {
    let (vault_id, previous, current) = event.risk_module_witness_rotated_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous, replay.risk_module_witness);
    replay.risk_module_witness = current;
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

fun replay_health<Tag>(
    replay: &mut ReplayState,
    event: events::HealthSynchronized<Tag>,
) {
    let (vault_id, reason, checkpoint) =
        event.health_synchronized_fields();
    assert_eq!(vault_id, replay.vault_id);
    if (reason == events::diagnostic_cleared_reason()) {
        replay.checkpoint = option::some(checkpoint);
        replay.unresolved_checkpoint = option::none();
    } else {
        replay.unresolved_checkpoint = option::some(checkpoint);
    };
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, SuperAdminCap};

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    domain_fixture,
    events,
    operations,
    protocol::{Self, Protocol},
    snapshot,
    vault::{Self as vault, Vault},
    venue_account,
};

use blast_boosts_core::{
    observation,
    policy,
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    test_risk_module::{Self, RiskModule, RiskModuleV2},
};

use std::{
    string::String,
    type_name,
    unit_test::{assert_eq, destroy},
};

use sui::{
    coin_registry::{Self, CoinRegistry},
    test_scenario::{Self, Scenario},
};
