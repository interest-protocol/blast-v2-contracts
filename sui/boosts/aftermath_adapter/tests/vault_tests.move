#[test_only]
/// Stateful tests for multi-product issuance from one Aftermath adapter.
module blast_boosts_aftermath::vault_tests;

// === Constants ===

const SYSTEM: address = @0x0;
const ISSUER: address = @0xA11CE;
const MAX_ORDER_NOTIONAL: u64 = 250;
const NAV_CAP: u64 = 1_000_000_000;

// === Product Witnesses ===
/// Sealed product witness for the 2x currency.
public struct Sui2x() has drop;

/// Sealed product witness for the 5x currency.
public struct Sui5x() has drop;

/// Tag for a production-constructible 2x product witness.
public struct TaggedSui2x() has drop;

/// Tag for a production-constructible 5x product witness.
public struct TaggedSui5x() has drop;

public struct Sui2xShort() has drop;
public struct Sui4x() has drop;
public struct Sui6xShort() has drop;

// === Test Fixture ===

public struct Fixture {
    scenario: Scenario,
    registry: CoinRegistry,
    protocol: Protocol,
    authority: Authority<BLAST_BOOSTS_CORE>,
    super_admin_cap: SuperAdminCap<BLAST_BOOSTS_CORE>,
    admin_cap: AdminCap<BLAST_BOOSTS_CORE>,
}

// === Tests ===

#[test]
fun shutdown_admin_stops_an_active_vault_without_any_venue_or_oracle_input() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::shutdown_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    vault.set_active_for_testing();
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.begin_shutdown(&fixture.protocol, &witness, blast_boosts_core::lifecycle::emergency_reason());
    assert!(vault.is_unwinding_for_testing());
    assert_eq!(vault.share_supply_for_testing(), 0);
    assert!(!vault.has_venue_account_for_testing());
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = blast_boosts_aftermath::errors::EInvalidSeedFunder, location = blast_boosts_aftermath::vault)]
fun seed_funder_rejects_zero_before_activation() {
    vault::assert_seed_funder(@0x0);
}

#[test]
fun seed_funder_accepts_the_first_nonzero_address() {
    vault::assert_seed_funder(@0x1);
}

#[test]
fun distinct_issued_products_freeze_actual_long_short_2x_and_generic_4x_6x_policy() {
    let mut fixture = start(domain::vault_issuer_role());
    let long2 = configured_policy(policy::long(), 20_000);
    let short2 = configured_policy(policy::short(), 20_000);
    let long4 = configured_policy(policy::long(), 40_000);
    let short6 = configured_policy(policy::short(), 60_000);
    fixture.issue_and_share_with_policy<Sui2x>(b"LONG2".to_string(), long2);
    fixture.issue_and_share_with_policy<Sui2xShort>(b"SHORT2".to_string(), short2);
    fixture.issue_and_share_with_policy<Sui4x>(b"LONG4".to_string(), long4);
    fixture.issue_and_share_with_policy<Sui6xShort>(b"SHORT6".to_string(), short6);
    fixture.scenario.next_tx(ISSUER);
    fixture.assert_issued_policy<Sui2x>(long2);
    fixture.assert_issued_policy<Sui2xShort>(short2);
    fixture.assert_issued_policy<Sui4x>(long4);
    fixture.assert_issued_policy<Sui6xShort>(short6);
    destroy(fixture);
}

#[test]
fun risk_admin_updates_live_fees_with_a_completed_event_and_no_asset_movement() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::risk_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    let event = events::collect_one<events::FeesUpdated<Sui2x>>(0);
    let (id, old_mint, old_redeem, old_admin, mint, redeem, admin) = event.fees_updated_fields();
    assert_eq!(id, vault.id_for_testing());
    assert_eq!(vector[old_mint, old_redeem, old_admin, mint, redeem, admin], vector[10, 10, 0, 0, 0, 0]);
    assert_eq!(vault.share_supply_for_testing(), 0);
    assert_eq!(vault.maintenance_reserve_for_testing(), 0);
    assert!(!vault.has_venue_account_for_testing());
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun risk_admin_updates_the_nav_cap_with_a_completed_event() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::risk_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_nav_cap(&fixture.protocol, &witness, 2_000_000_000);
    let (id, previous, current) =
        events::collect_one<events::NavCapUpdated<Sui2x>>(0).nav_cap_updated_fields();
    assert_eq!(id, vault.id_for_testing());
    assert_eq!(vector[previous, current], vector[1_000_000_000, 2_000_000_000]);
    assert_eq!(vault.nav_cap_for_testing(), 2_000_000_000);
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun issuer_without_risk_role_cannot_change_the_nav_cap() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_nav_cap(&fixture.protocol, &witness, 2_000_000_000);
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun issuer_without_risk_role_cannot_change_fees_even_to_zero() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_fees(&fixture.protocol, &witness, 0, 0, 0);
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun one_adapter_issues_distinct_2x_and_5x_currencies_from_witnesses() {
    let mut fixture = start(domain::vault_issuer_role());
    let expected_policy = standard_vault_policy();

    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.issue_and_share<Sui5x>(b"SUI5X".to_string());

    assert!(fixture.registry.exists<BlastBoost<Sui2x>>());
    assert!(fixture.registry.exists<BlastBoost<Sui5x>>());

    let issued_2x = events::collect_one<events::VaultIssued<Sui2x>>(0);
    let issued_5x = events::collect_one<events::VaultIssued<Sui5x>>(0);
    let (
        vault_2x_id,
        treasury_2x_id,
        metadata_2x_id,
        risk_2x,
        policy_2x,
        order_notional_2x,
        _,
        reserve_2x,
    ) = issued_2x.vault_issued_fields();
    let (
        vault_5x_id,
        treasury_5x_id,
        metadata_5x_id,
        risk_5x,
        policy_5x,
        order_notional_5x,
        _,
        reserve_5x,
    ) = issued_5x.vault_issued_fields();

    assert!(vault_2x_id != vault_5x_id);
    assert!(treasury_2x_id != treasury_5x_id);
    assert!(metadata_2x_id != metadata_5x_id);
    assert_eq!(risk_2x, type_name::with_original_ids<RiskModule>());
    assert_eq!(risk_5x, type_name::with_original_ids<RiskModule>());
    assert_eq!(policy_2x, expected_policy);
    assert_eq!(policy_5x, expected_policy);
    assert_eq!(order_notional_2x, MAX_ORDER_NOTIONAL);
    assert_eq!(order_notional_5x, MAX_ORDER_NOTIONAL);
    assert_eq!(reserve_2x, 0);
    assert_eq!(reserve_5x, 0);

    fixture.scenario.next_tx(ISSUER);
    let vault_2x = fixture.scenario.take_shared<Vault<Sui2x>>();
    let vault_5x = fixture.scenario.take_shared<Vault<Sui5x>>();
    let currency_2x = fixture.scenario.take_shared<Currency<BlastBoost<Sui2x>>>();
    let currency_5x = fixture.scenario.take_shared<Currency<BlastBoost<Sui5x>>>();

    assert_eq!(vault_2x.id_for_testing(), vault_2x_id);
    assert_eq!(vault_5x.id_for_testing(), vault_5x_id);
    assert_eq!(vault_2x.treasury_cap_id_for_testing(), treasury_2x_id);
    assert_eq!(vault_5x.treasury_cap_id_for_testing(), treasury_5x_id);
    assert_eq!(vault_2x.metadata_cap_id_for_testing(), metadata_2x_id);
    assert_eq!(vault_5x.metadata_cap_id_for_testing(), metadata_5x_id);
    assert_eq!(vault_2x.share_supply_for_testing(), 0);
    assert_eq!(vault_5x.share_supply_for_testing(), 0);
    assert!(!vault_2x.has_venue_account_for_testing());
    assert!(!vault_5x.has_venue_account_for_testing());
    assert_eq!(currency_2x.symbol(), b"SUI2X".to_string());
    assert_eq!(currency_5x.symbol(), b"SUI5X".to_string());
    assert_eq!(currency_2x.treasury_cap_id().destroy_some(), treasury_2x_id);
    assert_eq!(currency_5x.treasury_cap_id().destroy_some(), treasury_5x_id);
    assert_eq!(currency_2x.metadata_cap_id().destroy_some(), metadata_2x_id);
    assert_eq!(currency_5x.metadata_cap_id().destroy_some(), metadata_5x_id);

    test_scenario::return_shared(vault_2x);
    test_scenario::return_shared(vault_5x);
    test_scenario::return_shared(currency_2x);
    test_scenario::return_shared(currency_5x);
    destroy(fixture);
}

#[test]
fun generic_product_tags_issue_distinct_currencies() {
    let mut fixture = start(domain::vault_issuer_role());

    fixture.issue_and_share<TaggedSui2x>(
        b"SUI2XT".to_string(),
    );
    fixture.issue_and_share<TaggedSui5x>(
        b"SUI5XT".to_string(),
    );

    assert!(fixture.registry.exists<BlastBoost<TaggedSui2x>>());
    assert!(fixture.registry.exists<BlastBoost<TaggedSui5x>>());

    destroy(fixture);
}

#[test]
fun a_global_series_admin_rotates_risk_after_shutdown_starts() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::risk_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    vault.set_unwinding_for_testing();
    vault.rotate_risk_module<Sui2x, RiskModuleV2>(
        &fixture.protocol,
        &admin_witness,
        test_risk_module::new_v2(),
    );
    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new_v2(),
        MAX_ORDER_NOTIONAL / 2,
    );

    assert!(vault.is_unwinding_for_testing());
    assert_eq!(
        vault.risk_module_witness_for_testing(),
        type_name::with_original_ids<RiskModuleV2>(),
    );
    assert_eq!(vault.max_order_notional_for_testing(), MAX_ORDER_NOTIONAL / 2);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun selected_risk_module_updates_max_order_notional_and_emits_the_change() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let vault_id = vault.id_for_testing();

    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new(),
        MAX_ORDER_NOTIONAL * 4,
    );

    assert_eq!(vault.max_order_notional_for_testing(), MAX_ORDER_NOTIONAL * 4);
    let updated = events::collect_one<events::MaxOrderNotionalUpdated<Sui2x>>(0);
    let (event_vault_id, previous, current) = updated.max_order_notional_updated_fields();
    assert_eq!(event_vault_id, vault_id);
    assert_eq!(previous, MAX_ORDER_NOTIONAL);
    assert_eq!(current, MAX_ORDER_NOTIONAL * 4);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun selected_risk_module_reads_uninitialized_seed_constraints() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    let (side, max_order_notional) = vault
        .initialization_constraints_for_testing(&test_risk_module::new());

    assert_eq!(side, policy::long());
    assert_eq!(max_order_notional, MAX_ORDER_NOTIONAL);
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 10,
    location = blast_boosts_aftermath::vault,
)]
fun unselected_risk_module_cannot_read_seed_constraints() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.initialization_constraints_for_testing(&test_risk_module::new_v2());

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun locked_seed_share_mint_updates_the_canonical_supply_once() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.mint_locked_shares_for_testing(1_000_000, ISSUER, fixture.scenario.ctx());

    assert_eq!(vault.share_supply_for_testing(), 1_000_000);
    let (locked, funder) = vault.seed_facts();
    assert_eq!(locked, 1_000_000);
    assert_eq!(funder, ISSUER);
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = 51, location = blast_boosts_aftermath::vault)]
fun locked_seed_funder_and_amount_cannot_be_replaced() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    vault.mint_locked_shares_for_testing(1_000_000, ISSUER, fixture.scenario.ctx());
    vault.mint_locked_shares_for_testing(1, @0xB, fixture.scenario.ctx());
    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 10,
    location = blast_boosts_aftermath::vault,
)]
fun unselected_risk_module_cannot_update_max_order_notional() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new_v2(),
        MAX_ORDER_NOTIONAL * 4,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 2,
    location = blast_boosts_aftermath::vault,
)]
fun primitive_risk_module_cannot_update_max_order_notional() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        0u64,
        MAX_ORDER_NOTIONAL * 4,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EMaxOrderNotionalUnchanged,
    location = blast_boosts_core::state,
)]
fun risk_module_cannot_repeat_the_current_max_order_notional() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new(),
        MAX_ORDER_NOTIONAL,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EInvalidMaxOrderNotional,
    location = blast_boosts_core::state,
)]
fun risk_module_cannot_zero_the_max_order_notional() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new(),
        0,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_adapter_version_precedes_risk_witness_and_max_order_notional_validation() {
    let mut fixture = start(domain::vault_issuer_role());
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    fixture.protocol.set_version_for_testing(2);

    vault.set_max_order_notional(
        &fixture.protocol,
        0u64,
        0,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 10,
    location = blast_boosts_aftermath::vault,
)]
fun rotated_out_risk_module_cannot_update_max_order_notional() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::risk_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.rotate_risk_module<Sui2x, RiskModuleV2>(
        &fixture.protocol,
        &admin_witness,
        test_risk_module::new_v2(),
    );

    vault.set_max_order_notional(
        &fixture.protocol,
        test_risk_module::new(),
        MAX_ORDER_NOTIONAL * 4,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun shutdown_admin_moves_an_active_vault_to_unwinding() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::shutdown_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let vault_id = vault.id_for_testing();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_active_for_testing();

    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

    assert!(vault.is_unwinding_for_testing());
    let entered = events::collect_one<events::ShutdownBegun<Sui2x>>(0);
    assert_eq!(entered.shutdown_begun_vault_id(), vault_id);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun issuer_and_risk_admin_without_shutdown_role_cannot_begin_shutdown() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::risk_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_active_for_testing();

    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_boosts_core::errors::EInvalidLifecycleTransition,
    location = blast_boosts_core::lifecycle,
)]
fun shutdown_admin_cannot_stop_an_uninitialized_vault() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::shutdown_admin_role(),
    );
    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    vault.begin_shutdown(&fixture.protocol, &admin_witness, blast_boosts_core::lifecycle::emergency_reason());

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = sui::coin_registry::ECurrencyAlreadyExists,
    location = sui::coin_registry,
)]
fun one_product_witness_cannot_issue_twice() {
    let mut fixture = start(domain::vault_issuer_role());

    fixture.issue_and_share<Sui2x>(b"SUI2XA".to_string());
    fixture.issue_and_share<Sui2x>(b"SUI2XB".to_string());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = sui::coin_registry::ECurrencyAlreadyExists,
    location = sui::coin_registry,
)]
fun one_generic_product_tag_cannot_issue_twice() {
    let mut fixture = start(domain::vault_issuer_role());

    fixture.issue_and_share<TaggedSui2x>(
        b"SUI2XTA".to_string(),
    );
    fixture.issue_and_share<TaggedSui2x>(
        b"SUI2XTB".to_string(),
    );

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 8,
    location = blast_boosts_aftermath::vault,
)]
fun primitive_product_witness_is_rejected() {
    let mut fixture = start(domain::vault_issuer_role());

    fixture.issue_and_share<u64>(b"BAD".to_string());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 2,
    location = blast_boosts_aftermath::vault,
)]
fun adapter_package_type_cannot_be_selected_as_a_risk_module() {
    let mut fixture = start(domain::vault_issuer_role());
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    let vault = vault::issue<TaggedSui2x, TaggedSui5x>(
        &fixture.protocol,
        &admin_witness,
        TaggedSui5x(),
        &mut fixture.registry,
        standard_vault_policy(),
        MAX_ORDER_NOTIONAL,
        NAV_CAP,
        b"BADRISK".to_string(),
        b"Bad Risk Vault".to_string(),
        b"Same-package public constructors are not risk authority".to_string(),
        b"".to_string(),
        fixture.scenario.ctx(),
    );
    vault.share();

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// Issuance is a protected mutation, so it stops serving the moment a governed
/// upgrade advances the adapter generation past this bytecode.
fun vault_issuance_stops_after_the_adapter_generation_advances() {
    let mut fixture = start(
        domain::vault_issuer_role() | domain::package_admin_role(),
    );
    fixture.protocol.advance_for_testing();

    fixture.issue_and_share<Sui2x>(b"SUI2X".to_string());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 19,
    location = blast_boosts_aftermath::vault,
)]
fun second_venue_account_installation_is_rejected() {
    vault::assert_venue_account_installable_for_testing(true);
}

#[test]
#[expected_failure(
    abort_code = 39,
    location = blast_boosts_aftermath::vault,
)]
fun venue_operations_before_initialization_use_the_stable_adapter_error() {
    vault::assert_venue_account_installed_for_testing(false);
}

// === Fixture Setup ===

fun start(roles: u64): Fixture {
    let mut scenario = test_scenario::begin(SYSTEM);
    let registry = coin_registry::create_coin_data_registry_for_testing(
        scenario.ctx(),
    );
    let protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        domain_fixture::new_authority(scenario.ctx());

    authority.grant_admin(
        &super_admin_cap,
        roles,
        ISSUER,
        scenario.ctx(),
    );
    scenario.next_tx(ISSUER);
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

// === Fixture Helpers ===

fun issue_and_share<Product: drop>(self: &mut Fixture, symbol: String) {
    self.issue_and_share_with_policy<Product>(symbol, standard_vault_policy());
}

fun issue_and_share_with_policy<Product: drop>(
    self: &mut Fixture, symbol: String, vault_policy: VaultPolicy,
) {
    let Fixture {
        scenario,
        registry,
        protocol,
        authority,
        admin_cap,
        ..
    } = self;
    let admin_witness = authority.sign_in(admin_cap);
    let vault = vault::issue<Product, RiskModule>(
        protocol,
        &admin_witness,
        test_risk_module::new(),
        registry,
        vault_policy,
        MAX_ORDER_NOTIONAL,
        NAV_CAP,
        symbol,
        b"Test Vault".to_string(),
        b"Blast leverage coin".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    vault.share();
}

fun assert_issued_policy<Product>(self: &Fixture, expected: VaultPolicy) {
    let vault = self.scenario.take_shared<Vault<Product>>();
    assert_eq!(vault.vault_policy_for_testing(), expected);
    assert!(self.registry.exists<BlastBoost<Product>>());
    test_scenario::return_shared(vault);
}

fun configured_policy(side: policy::PositionSide, target: u64): VaultPolicy {
    policy::new_vault_policy(
        side, policy::new_rebalance_policy(target - 2_000, target, target + 2_000, target + 10_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500), 30, 30, 100,
    ).with_fee_limits(100, 100, 3_000)
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
        100,
    )
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, SuperAdminCap};

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    domain_fixture,
    events,
    protocol::{Self, Protocol},
    vault::{Self, Vault},
};

use blast_boosts_core::{
    policy::{Self, VaultPolicy},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    test_risk_module::{Self, RiskModule, RiskModuleV2},
};

use std::{
    string::String,
    type_name::{Self, TypeName},
    unit_test::{assert_eq, destroy},
};

use sui::{
    coin_registry::{Self, CoinRegistry, Currency},
    package,
    test_scenario::{Self, Scenario},
};
