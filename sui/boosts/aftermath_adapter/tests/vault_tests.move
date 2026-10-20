// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Stateful tests for multi-product issuance from one Aftermath adapter.
module blast_boosts_aftermath::vault_tests;

// === Constants ===

const SYSTEM: address = @0x0;
const ISSUER: address = @0xA11CE;
const MAX_ORDER_NOTIONAL: u64 = 250;
const NAV_CAP: u64 = 1_000_000_000;
const REFERENCE_AT_MS: u64 = 1_000;
/// The standard seed at the unit price: 1,100 of equity less a 100 reserve is 1,000 of NAV.
const SEED_EQUITY: u64 = 1_100;
const SEED_RESERVE: u64 = 100;
const SEED_NAV: u64 = 1_000;
/// Nine-decimal base atoms per six-decimal collateral atom at the unit price.
const BASE_PER_NOTIONAL: u64 = 1_000;
const LOT_SIZE: u64 = 1;
const PRICE: u64 = 1_000_000_000;

// === Test-Only Types ===

// --- Product Tags ---

/// Tag for the 2x currency.
public struct Sui2x() has drop;

/// Tag for the 5x currency.
public struct Sui5x() has drop;

/// A second 2x tag, to prove two tags never share a currency.
public struct TaggedSui2x() has drop;

/// A second 5x tag.
public struct TaggedSui5x() has drop;

public struct Sui2xShort() has drop;
public struct Sui4x() has drop;
public struct Sui6xShort() has drop;

// --- Fixture ---

/// One adapter issuing into a shared registry.
public struct Fixture {
    scenario: Scenario,
    registry: CoinRegistry,
    protocol: Protocol,
}

// === Tests ===

#[test]
fun distinct_issued_products_freeze_actual_long_short_2x_and_generic_4x_6x_policy() {
    let mut fixture = start();
    let long2 = configured_policy(policy::long(), 20_000);
    let short2 = configured_policy(policy::short(), 20_000);
    let long4 = configured_policy(policy::long(), 40_000);
    let short6 = configured_policy(policy::short(), 60_000);
    fixture.issue_and_share_with_policy<Sui2x>(b"LONG2".to_string(), long2, 20_000);
    fixture.issue_and_share_with_policy<Sui2xShort>(b"SHORT2".to_string(), short2, 20_000);
    fixture.issue_and_share_with_policy<Sui4x>(b"LONG4".to_string(), long4, 40_000);
    fixture.issue_and_share_with_policy<Sui6xShort>(b"SHORT6".to_string(), short6, 60_000);

    fixture.next_tx!(ISSUER, |fixture| {
        fixture.assert_issued_policy<Sui2x>(long2);
        fixture.assert_issued_policy<Sui2xShort>(short2);
        fixture.assert_issued_policy<Sui4x>(long4);
        fixture.assert_issued_policy<Sui6xShort>(short6);
    });

    fixture.end();
}

#[test]
fun risk_admin_updates_live_fees_with_a_completed_event_and_no_asset_movement() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let witness = risk_admin();
        vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
        let event = events::collect_one<events::FeesUpdated<Sui2x>>(0);
        let (id, old_mint, old_redeem, old_admin, mint, redeem, admin) = event.fees_updated_fields();
        assert_eq!(id, vault.id());
        assert_eq!(vector[old_mint, old_redeem, old_admin, mint, redeem, admin], vector[10, 10, 0, 0, 0, 0]);
        assert_eq!(vault.total_share_supply(), SEED_NAV * 1_000);
        assert_eq!(vault.state().maintenance_reserve(), SEED_RESERVE);
        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
fun risk_admin_updates_the_nav_cap_with_a_completed_event() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let witness = risk_admin();
        vault.set_nav_cap(&fixture.protocol, &witness, 2_000_000_000);
        let (id, previous, current) =
            events::collect_one<events::NavCapUpdated<Sui2x>>(0).nav_cap_updated_fields();
        assert_eq!(id, vault.id());
        assert_eq!(vector[previous, current], vector[1_000_000_000, 2_000_000_000]);
        assert_eq!(vault.nav_cap_for_testing(), 2_000_000_000);
        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_fee_validation() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();
        fixture.protocol.set_version_for_testing(3);

        vault.set_fees(&fixture.protocol, &admin_witness, 10_000, 10_000, 10_001);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle,
    location = blast_boosts_core::lifecycle,
)]
fun fees_cannot_change_once_shutdown_has_begun() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        vault.begin_shutdown(&fixture.protocol, &shutdown_admin(), blast_boosts_core::lifecycle::emergency_reason());

        vault.set_fees(&fixture.protocol, &risk_admin(), 0, 0, 0);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_nav_cap_validation() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();
        fixture.protocol.set_version_for_testing(3);

        vault.set_nav_cap(&fixture.protocol, &admin_witness, 0);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::ENavCapUnchanged,
    location = blast_boosts_core::state,
)]
fun the_risk_admin_cannot_repeat_the_current_nav_cap() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();

        vault.set_nav_cap(&fixture.protocol, &admin_witness, NAV_CAP);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
fun issuer_updates_the_currency_metadata_with_a_completed_event() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let vault = fixture.take_vault<Sui2x>();
        let mut currency = fixture.take_currency<Sui2x>();
        let witness = vault_issuer();
        vault.update_metadata(
            &fixture.protocol, &witness, &mut currency,
            b"SUI 2x Bull".to_string(), b"Two times SUI".to_string(), b"https://blast.fun/sui2x.png".to_string(),
        );
        let (id, name, description, icon_url) =
            events::collect_one<events::MetadataUpdated<Sui2x>>(0).metadata_updated_fields();
        assert_eq!(id, vault.id());
        assert_eq!(name, b"SUI 2x Bull".to_string());
        assert_eq!(description, b"Two times SUI".to_string());
        assert_eq!(icon_url, b"https://blast.fun/sui2x.png".to_string());
        assert_eq!(currency.name(), b"SUI 2x Bull".to_string());
        assert_eq!(currency.description(), b"Two times SUI".to_string());
        assert_eq!(currency.icon_url(), b"https://blast.fun/sui2x.png".to_string());
        assert_eq!(currency.symbol(), b"SUI2X".to_string());
        fixture.return_vault(vault);
        fixture.return_currency(currency);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EMetadataUnchanged, location = blast_boosts_aftermath::vault)]
fun a_metadata_update_that_repeats_every_current_value_is_refused() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let vault = fixture.take_vault<Sui2x>();
        let mut currency = fixture.take_currency<Sui2x>();
        let witness = vault_issuer();
        let (name, description, icon_url) = (currency.name(), currency.description(), currency.icon_url());

        vault.update_metadata(&fixture.protocol, &witness, &mut currency, name, description, icon_url);

        fixture.return_vault(vault);
        fixture.return_currency(currency);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_metadata_validation() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let vault = fixture.take_vault<Sui2x>();
        let mut currency = fixture.take_currency<Sui2x>();
        let admin_witness = vault_issuer();
        let (name, description, icon_url) = (currency.name(), currency.description(), currency.icon_url());
        fixture.protocol.set_version_for_testing(3);

        vault.update_metadata(&fixture.protocol, &admin_witness, &mut currency, name, description, icon_url);

        fixture.return_vault(vault);
        fixture.return_currency(currency);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_admin_fee_validation() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();
        fixture.protocol.set_version_for_testing(3);

        destroy(vault.withdraw_admin_fees(&fixture.protocol, &admin_witness, 1, fixture.ctx!()));

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInsufficientAdminCash, location = blast_boosts_aftermath::vault)]
fun admin_fee_withdrawal_one_atom_above_earnings_is_rejected() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();
        vault.retain_admin_cash(sui::balance::create_for_testing<SUI>(25));

        destroy(vault.withdraw_admin_fees(&fixture.protocol, &admin_witness, 26, fixture.ctx!()));

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
fun one_adapter_issues_distinct_2x_and_5x_currencies_from_witnesses() {
    let mut fixture = start();
    let expected_policy = standard_vault_policy();

    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.issue_and_share<Sui5x>(b"SUI5X".to_string());

    assert!(fixture.registry.exists<BlastBoost<Sui2x>>());
    assert!(fixture.registry.exists<BlastBoost<Sui5x>>());

    let issued_2x = events::collect_one<events::VaultIssued<Sui2x>>(0);
    let issued_5x = events::collect_one<events::VaultIssued<Sui5x>>(0);
    let (treasury_2x_id, metadata_2x_id, policy_2x, order_notional_2x, nav_cap_2x) = issued_2x.vault_issued_fields();
    let (treasury_5x_id, metadata_5x_id, policy_5x, order_notional_5x, nav_cap_5x) = issued_5x.vault_issued_fields();

    assert!(treasury_2x_id != treasury_5x_id);
    assert!(metadata_2x_id != metadata_5x_id);
    assert_eq!(policy_2x, expected_policy);
    assert_eq!(policy_5x, expected_policy);
    assert_eq!(order_notional_2x, MAX_ORDER_NOTIONAL);
    assert_eq!(order_notional_5x, MAX_ORDER_NOTIONAL);
    assert_eq!(nav_cap_2x, NAV_CAP);
    assert_eq!(nav_cap_5x, NAV_CAP);

    fixture.next_tx!(ISSUER, |fixture| {
        let vault_2x = fixture.take_vault<Sui2x>();
        let vault_5x = fixture.take_vault<Sui5x>();
        let currency_2x = fixture.take_currency<Sui2x>();
        let currency_5x = fixture.take_currency<Sui5x>();

        assert!(vault_2x.id() != vault_5x.id());
        assert_eq!(vault_2x.treasury_cap_id_for_testing(), treasury_2x_id);
        assert_eq!(vault_5x.treasury_cap_id_for_testing(), treasury_5x_id);
        assert_eq!(vault_2x.metadata_cap_id_for_testing(), metadata_2x_id);
        assert_eq!(vault_5x.metadata_cap_id_for_testing(), metadata_5x_id);
        assert_eq!(vault_2x.total_share_supply(), SEED_NAV * 1_000);
        assert_eq!(vault_5x.total_share_supply(), SEED_NAV * 1_000);
        assert_eq!(vault_2x.nav_cap_for_testing(), nav_cap_2x);
        assert_eq!(vault_5x.nav_cap_for_testing(), nav_cap_5x);
        assert_eq!(currency_2x.symbol(), b"SUI2X".to_string());
        assert_eq!(currency_5x.symbol(), b"SUI5X".to_string());
        assert_eq!(currency_2x.decimals(), 9);
        assert_eq!(currency_5x.decimals(), 9);
        assert_eq!(currency_2x.treasury_cap_id().destroy_some(), treasury_2x_id);
        assert_eq!(currency_5x.treasury_cap_id().destroy_some(), treasury_5x_id);
        assert_eq!(currency_2x.metadata_cap_id().destroy_some(), metadata_2x_id);
        assert_eq!(currency_5x.metadata_cap_id().destroy_some(), metadata_5x_id);

        fixture.return_vault(vault_2x);
        fixture.return_vault(vault_5x);
        fixture.return_currency(currency_2x);
        fixture.return_currency(currency_5x);
    });

    fixture.end();
}

#[test]
fun generic_product_tags_issue_distinct_currencies() {
    let mut fixture = start();

    fixture.issue_and_share<TaggedSui2x>(
        b"SUI2XT".to_string(),
    );
    fixture.issue_and_share<TaggedSui5x>(
        b"SUI5XT".to_string(),
    );

    assert!(fixture.registry.exists<BlastBoost<TaggedSui2x>>());
    assert!(fixture.registry.exists<BlastBoost<TaggedSui5x>>());

    fixture.end();
}

#[test]
fun the_risk_admin_updates_max_order_notional_and_emits_the_change() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let vault_id = vault.id();
        let admin_witness = risk_admin();

        vault.set_max_order_notional(&fixture.protocol, &admin_witness, MAX_ORDER_NOTIONAL * 4);

        assert_eq!(vault.max_order_notional_for_testing(), MAX_ORDER_NOTIONAL * 4);
        let updated = events::collect_one<events::MaxOrderNotionalUpdated<Sui2x>>(0);
        let (event_vault_id, previous, current) = updated.max_order_notional_updated_fields();
        assert_eq!(event_vault_id, vault_id);
        assert_eq!(previous, MAX_ORDER_NOTIONAL);
        assert_eq!(current, MAX_ORDER_NOTIONAL * 4);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
fun max_order_notional_can_change_while_unwinding() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        vault.begin_shutdown(&fixture.protocol, &shutdown_admin(), blast_boosts_core::lifecycle::emergency_reason());

        vault.set_max_order_notional(&fixture.protocol, &risk_admin(), MAX_ORDER_NOTIONAL * 4);

        assert!(vault.is_unwinding_for_testing());
        assert_eq!(vault.max_order_notional_for_testing(), MAX_ORDER_NOTIONAL * 4);
        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
fun activation_locks_the_seed_shares_as_the_whole_supply() {
    let mut fixture = start();
    let issuance = fixture.issue<Sui2x>(b"SUI2X".to_string());

    let (vault, seed_nav) = fixture.activate(issuance);

    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(vault.total_share_supply(), SEED_NAV * 1_000);
    assert_eq!(vault.locked_shares(), SEED_NAV * 1_000);
    destroy(vault);
    fixture.end();
}

#[test]
fun activation_sends_the_locked_seed_shares_to_the_burn_address() {
    let mut fixture = start();
    let issuance = fixture.issue<Sui2x>(b"SUI2X".to_string());

    let (vault, _) = fixture.activate(issuance);

    fixture.next_tx!(SYSTEM, |fixture| {
        let burned = fixture.take_burned_shares<Sui2x>();
        assert_eq!(burned.value(), vault.locked_shares());
        assert_eq!(burned.value(), SEED_NAV * 1_000);
        assert_eq!(vault.terminal_cash_for_testing(), 0);
        assert_eq!(vault.admin_cash_balance(), 0);
        destroy(burned);
    });

    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle,
    location = blast_boosts_core::lifecycle,
)]
fun terminal_claim_during_unwinding_is_rejected_before_finalization() {
    let mut fixture = start();
    let issuance = fixture.issue<Sui2x>(b"SUI2X".to_string());
    let (mut vault, _) = fixture.activate(issuance);
    let admin_witness = shutdown_admin();
    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());
    let shares = vault.mint_shares(5, fixture.ctx!());
    let clock = clock::create_for_testing(fixture.ctx!());

    destroy(vault.redeem_shutdown(&fixture.protocol, shares, 0, 0, &clock, fixture.ctx!()));

    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EOperationNotPermittedInLifecycle,
    location = blast_boosts_core::lifecycle,
)]
fun unsettled_lifecycle_precedes_an_expired_deadline() {
    let mut fixture = start();
    let issuance = fixture.issue<Sui2x>(b"SUI2X".to_string());
    let (mut vault, _) = fixture.activate(issuance);
    let admin_witness = shutdown_admin();
    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());
    let shares = vault.mint_shares(5, fixture.ctx!());
    let mut clock = clock::create_for_testing(fixture.ctx!());
    clock.set_for_testing(REFERENCE_AT_MS + 1);

    destroy(vault.redeem_shutdown(&fixture.protocol, shares, 0, REFERENCE_AT_MS, &clock, fixture.ctx!()));

    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::ERedemptionOutputBelowMinimum,
    location = blast_boosts_core::state,
)]
fun terminal_claim_below_minimum_collateral_is_rejected() {
    let mut fixture = start();
    let issuance = fixture.issue<Sui2x>(b"SUI2X".to_string());
    let (mut vault, _) = fixture.activate(issuance);
    let shares = vault.mint_shares(5, fixture.ctx!());
    fixture.settle_with_cash(&mut vault, 13);
    let clock = clock::create_for_testing(fixture.ctx!());

    destroy(vault.redeem_shutdown(&fixture.protocol, shares, 14, 0, &clock, fixture.ctx!()));

    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EInvalidShareAmount,
    location = blast_boosts_core::state,
)]
fun terminal_claim_of_zero_shares_is_rejected() {
    let mut fixture = start();
    let issuance = fixture.issue<Sui2x>(b"SUI2X".to_string());
    let (mut vault, _) = fixture.activate(issuance);
    let eligible = vault.mint_shares(5, fixture.ctx!());
    let nothing = vault.mint_shares(0, fixture.ctx!());
    fixture.settle_with_cash(&mut vault, 13);
    let clock = clock::create_for_testing(fixture.ctx!());

    destroy(vault.redeem_shutdown(&fixture.protocol, nothing, 0, 0, &clock, fixture.ctx!()));

    destroy(eligible);
    destroy(clock);
    destroy(vault);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EMaxOrderNotionalUnchanged,
    location = blast_boosts_core::state,
)]
fun the_risk_admin_cannot_repeat_the_current_max_order_notional() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();

        vault.set_max_order_notional(&fixture.protocol, &admin_witness, MAX_ORDER_NOTIONAL);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EInvalidMaxOrderNotional,
    location = blast_boosts_core::state,
)]
fun the_risk_admin_cannot_zero_the_max_order_notional() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();

        vault.set_max_order_notional(&fixture.protocol, &admin_witness, 0);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_max_order_notional_validation() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = risk_admin();
        fixture.protocol.set_version_for_testing(3);

        vault.set_max_order_notional(&fixture.protocol, &admin_witness, 0);

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
/// Shutdown needs no venue or oracle object: the vault moves to unwinding, keeps its supply, and reports why.
fun shutdown_admin_moves_an_active_vault_to_unwinding() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let vault_id = vault.id();
        let admin_witness = shutdown_admin();

        vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

        assert!(vault.is_unwinding_for_testing());
        assert_eq!(vault.total_share_supply(), SEED_NAV * 1_000);
        let entered = events::collect_one<events::ShutdownBegun<Sui2x>>(0);
        assert_eq!(entered.shutdown_begun_vault_id(), vault_id);
        assert_eq!(entered.shutdown_reason(), blast_boosts_core::lifecycle::emergency_reason());

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_an_already_unwinding_vault() {
    let mut fixture = start();
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.next_tx!(ISSUER, |fixture| {
        let mut vault = fixture.take_vault<Sui2x>();
        let admin_witness = shutdown_admin();
        vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());
        fixture.protocol.set_version_for_testing(3);

        vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

        fixture.return_vault(vault);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = ECurrencyAlreadyExists,
    location = sui::coin_registry,
)]
fun one_product_witness_cannot_issue_twice() {
    let mut fixture = start();

    fixture.issue_and_share<Sui2x>(b"SUI2XA".to_string());
    fixture.issue_and_share<Sui2x>(b"SUI2XB".to_string());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = ECurrencyAlreadyExists,
    location = sui::coin_registry,
)]
fun one_generic_product_tag_cannot_issue_twice() {
    let mut fixture = start();

    fixture.issue_and_share<TaggedSui2x>(
        b"SUI2XTA".to_string(),
    );
    fixture.issue_and_share<TaggedSui2x>(
        b"SUI2XTB".to_string(),
    );

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidProductWitnessType, location = blast_boosts_aftermath::vault)]
fun primitive_product_witness_is_rejected() {
    let mut fixture = start();

    fixture.issue_and_share<u64>(b"BAD".to_string());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_primitive_witness_rejection() {
    let mut fixture = start();
    fixture.protocol.set_version_for_testing(3);

    fixture.issue_and_share<u64>(b"BAD".to_string());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidProductWitnessType, location = blast_boosts_aftermath::vault)]
/// A zero max order notional is the core's rejection; the adapter's witness check fires before it.
fun primitive_witness_precedes_core_issuance_validation() {
    let mut fixture = start();

    destroy(fixture.issue_with_order_cap<u64>(b"BAD".to_string(), standard_vault_policy(), 0));

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// Issuance is a protected mutation, so it stops serving the moment a governed
/// upgrade advances the adapter generation past this bytecode.
fun vault_issuance_stops_after_the_adapter_generation_advances() {
    let mut fixture = start();
    fixture.protocol.advance_for_testing();

    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    fixture.end();
}

// === Test Helpers ===

macro fun ctx($self: &mut Fixture): &mut TxContext {
    let fixture = $self;

    fixture.scenario.ctx()
}

macro fun next_tx($self: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $self;

    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(SYSTEM);
    let registry = coin_registry::create_coin_data_registry_for_testing(
        scenario.ctx(),
    );
    let protocol = protocol::new_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    Fixture { scenario, registry, protocol }
}

fun end(self: Fixture) {
    let Fixture { scenario, registry, protocol } = self;
    destroy(registry);
    destroy(protocol);
    scenario.end();
}

// --- Shared Object Custody ---

fun take_vault<Product>(self: &Fixture): Vault<Product, SUI> {
    self.scenario.take_shared<Vault<Product, SUI>>()
}

fun return_vault<Product>(_self: &Fixture, vault: Vault<Product, SUI>) {
    test_scenario::return_shared(vault);
}

fun take_currency<Product>(self: &Fixture): Currency<BlastBoost<Product>> {
    self.scenario.take_shared<Currency<BlastBoost<Product>>>()
}

fun return_currency<Product>(_self: &Fixture, currency: Currency<BlastBoost<Product>>) {
    test_scenario::return_shared(currency);
}

/// The locked seed shares activation sent to the burn address.
fun take_burned_shares<Product>(self: &Fixture): Coin<BlastBoost<Product>> {
    self.scenario.take_from_address<Coin<BlastBoost<Product>>>(SYSTEM)
}

fun assert_issued_policy<Product>(self: &Fixture, expected: VaultPolicy) {
    let vault = self.take_vault<Product>();
    assert_eq!(vault.vault_policy_for_testing(), expected);
    assert!(self.registry.exists<BlastBoost<Product>>());
    self.return_vault(vault);
}

// --- Administration ---

fun vault_issuer(): AdminWitness<VaultIssuer> {
    blast_acl::witness_for_testing()
}

fun risk_admin(): AdminWitness<RiskAdmin> {
    blast_acl::witness_for_testing()
}

fun shutdown_admin(): AdminWitness<ShutdownAdmin> {
    blast_acl::witness_for_testing()
}

/// Begins shutdown and finalizes it on `recovered` collateral atoms, keeping the current checkpoint.
fun settle_with_cash<Product>(self: &mut Fixture, vault: &mut Vault<Product, SUI>, recovered: u64) {
    let admin_witness = shutdown_admin();
    vault.begin_shutdown(&self.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());
    let checkpoint = *vault.venue().checkpoint();
    operations::complete_finalization_for_testing(
        vault, checkpoint, coin::mint_for_testing<SUI>(recovered, self.scenario.ctx()),
    );
}

// --- Issuance ---

fun issue_and_share<Product>(self: &mut Fixture, symbol: String) {
    self.issue_and_share_with_policy<Product>(symbol, standard_vault_policy(), 20_000);
}

/// Issues, activates on a seed at the policy's target leverage against a fixture venue account, and shares.
fun issue_and_share_with_policy<Product>(
    self: &mut Fixture,
    symbol: String,
    vault_policy: VaultPolicy,
    target_bps: u64,
) {
    let issuance = self.issue_with_policy<Product>(symbol, vault_policy);
    let (vault, _) = self.activate_at(issuance, target_bps);
    vault.share();
}

/// Activates on the standard 2x seed: 1,100 collateral of equity, a 100 reserve, 2,000 of notional held as base.
fun activate<Product>(self: &mut Fixture, issuance: VaultIssuance<Product, SUI>): (Vault<Product, SUI>, u64) {
    self.activate_at(issuance, 20_000)
}

/// Activates on a seed whose notional is `target_bps` of the seed NAV, at the unit price.
fun activate_at<Product>(self: &mut Fixture, issuance: VaultIssuance<Product, SUI>, target_bps: u64): (Vault<Product, SUI>, u64) {
    let seeded = observation::new_position(
        SEED_EQUITY, SEED_NAV * target_bps / 10_000 * BASE_PER_NOTIONAL, LOT_SIZE, issuance.issuance().seed_side(),
        observation::new_price(PRICE, 0, REFERENCE_AT_MS), observation::new_price(PRICE, 0, REFERENCE_AT_MS), PRICE,
    );
    let venue_account = fixture_venue_account(self.scenario.ctx());
    let (vault, seed_nav, _) = issuance.activate(
        seeded, SEED_RESERVE, venue_account, REFERENCE_AT_MS, self.scenario.ctx(),
    );
    (vault, seed_nav)
}

fun issue<Product>(self: &mut Fixture, symbol: String): VaultIssuance<Product, SUI> {
    self.issue_with_policy<Product>(symbol, standard_vault_policy())
}

fun issue_with_policy<Product>(
    self: &mut Fixture,
    symbol: String,
    vault_policy: VaultPolicy,
): VaultIssuance<Product, SUI> {
    self.issue_with_order_cap<Product>(symbol, vault_policy, MAX_ORDER_NOTIONAL)
}

/// Issues at an arbitrary per-order notional cap, to reach the core's own validation of it.
fun issue_with_order_cap<Product>(
    self: &mut Fixture,
    symbol: String,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
): VaultIssuance<Product, SUI> {
    let Fixture { scenario, registry, protocol } = self;
    vault::issue<Product, SUI>(
        protocol,
        &vault_issuer(),
        registry,
        vault_policy,
        max_order_notional,
        NAV_CAP,
        symbol,
        b"Test Vault".to_string(),
        b"Blast leverage coin".to_string(),
        b"".to_string(),
        scenario.ctx(),
    )
}

/// A bound account with a flat, order-free checkpoint and a minted admin cap; no test here reads the venue.
fun fixture_venue_account(ctx: &mut TxContext): VenueAccount {
    let binding = venue_account::new_binding(@0xB.to_id(), 7, @0xC.to_id(), @0xD.to_id());
    let admin_cap = authority::new_for_testing<ACCOUNT, AdminRole>(@0xB.to_id(), ctx);
    venue_account::new(
        binding, checkpoint::checkpoint_for_testing(0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, false, 0, 0, 0), admin_cap,
    )
}

// --- Policies ---

fun configured_policy(side: PositionSide, target: u64): VaultPolicy {
    policy::new_vault_policy(
        side, policy::new_rebalance_policy(target - 2_000, target, target + 2_000, target + 10_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500), 30, 30, 100, 100, 3_000, 100, 5_000,
    )
}

fun standard_vault_policy(): VaultPolicy {
    policy::new_vault_policy(
        policy::long(),
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
        10,
        10,
        0,
        100,
        5_000,
    )
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN as AdminRole};

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    errors,
    events,
    operations,
    blast_boosts_aftermath::{Self as protocol, Protocol},
    vault::{Self, Vault, VaultIssuance},
    checkpoint,
    venue_account::{Self, VenueAccount},
};

use blast_boosts_core::{
    observation,
    policy::{Self, PositionSide, VaultPolicy},
    blast_boosts_core::{RiskAdmin, ShutdownAdmin, VaultIssuer},
};

use perpetuals::authority::ACCOUNT;

use std::{
    string::String,
    unit_test::{assert_eq, destroy},
};

use sui::{
    clock,
    coin::{Self, Coin},
    coin_registry::{Self, CoinRegistry, Currency, ECurrencyAlreadyExists},
    sui::SUI,
    test_scenario::{Self, Scenario},
};
