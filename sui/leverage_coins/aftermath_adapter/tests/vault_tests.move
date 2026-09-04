#[test_only]
/// Stateful tests for multi-product issuance from one Aftermath adapter.
module blast_leverage_aftermath::vault_tests;

use blast_leverage_aftermath::{events, protocol::{Self, Protocol}, vault::{Self, Vault}};
use blast_leverage_series_one::{
    acl::{Self, AdminCap, ProtocolAuthority, SuperAdminCap},
    policy::{Self, TierPolicy},
};
use std::{
    string::String,
    type_name::{Self, TypeName},
    unit_test::{assert_eq, destroy},
};
use sui::{
    coin_registry::{Self, CoinRegistry, Currency},
    test_scenario::{Self, Scenario},
};

// === Constants ===

const SYSTEM: address = @0x0;
const ISSUER: address = @0xA11CE;
const MAX_ORDER_NOTIONAL_MINIMUM: u64 = 100;
const MAX_ORDER_NOTIONAL_CURRENT: u64 = 250;
const MAX_ORDER_NOTIONAL_MAXIMUM: u64 = 1_000;

// === Product Witnesses ===

/// Sealed product witness for the 2x currency.
public struct Sui2x() has drop;

/// Sealed product witness for the 5x currency.
public struct Sui5x() has drop;

/// Initially selected risk implementation.
public struct RiskModule() has drop;

/// Later risk implementation used by rotation tests.
public struct RiskModuleV2() has drop;

// === Test Fixture ===

public struct Fixture {
    scenario: Scenario,
    registry: CoinRegistry,
    protocol: Protocol,
    authority: ProtocolAuthority,
    super_admin_cap: SuperAdminCap,
    admin_cap: AdminCap,
}

// === Tests ===

#[test]
fun one_adapter_issues_distinct_2x_and_5x_currencies_from_witnesses() {
    let mut fixture = start(1);
    let expected_policy = standard_tier_policy();

    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.issue_and_share<Sui5x, RiskModule>(Sui5x(), b"SUI5X".to_string());

    assert!(fixture.registry.exists<Vault<Sui2x>>());
    assert!(fixture.registry.exists<Vault<Sui5x>>());

    let issued_2x = events::collect_one<events::VaultIssued<Sui2x>>(0);
    let issued_5x = events::collect_one<events::VaultIssued<Sui5x>>(0);
    let (
        vault_2x_id,
        treasury_2x_id,
        metadata_2x_id,
        risk_2x,
        policy_2x,
        minimum_2x,
        current_2x,
        maximum_2x,
        reserve_2x,
    ) = issued_2x.vault_issued_fields();
    let (
        vault_5x_id,
        treasury_5x_id,
        metadata_5x_id,
        risk_5x,
        policy_5x,
        minimum_5x,
        current_5x,
        maximum_5x,
        reserve_5x,
    ) = issued_5x.vault_issued_fields();

    assert!(vault_2x_id != vault_5x_id);
    assert!(treasury_2x_id != treasury_5x_id);
    assert!(metadata_2x_id != metadata_5x_id);
    assert_eq!(risk_2x, type_name::with_original_ids<RiskModule>());
    assert_eq!(risk_5x, type_name::with_original_ids<RiskModule>());
    assert_eq!(policy_2x, expected_policy);
    assert_eq!(policy_5x, expected_policy);
    assert_eq!(minimum_2x, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(minimum_5x, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(current_2x, MAX_ORDER_NOTIONAL_CURRENT);
    assert_eq!(current_5x, MAX_ORDER_NOTIONAL_CURRENT);
    assert_eq!(maximum_2x, MAX_ORDER_NOTIONAL_MAXIMUM);
    assert_eq!(maximum_5x, MAX_ORDER_NOTIONAL_MAXIMUM);
    assert_eq!(reserve_2x, 0);
    assert_eq!(reserve_5x, 0);

    fixture.scenario.next_tx(ISSUER);
    let vault_2x = fixture.scenario.take_shared<Vault<Sui2x>>();
    let vault_5x = fixture.scenario.take_shared<Vault<Sui5x>>();
    let currency_2x = fixture.scenario.take_shared<Currency<Vault<Sui2x>>>();
    let currency_5x = fixture.scenario.take_shared<Currency<Vault<Sui5x>>>();

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
fun a_global_series_admin_rotates_risk_after_shutdown_starts() {
    let mut fixture = start(1 | 2);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    vault.set_shutdown_pending_for_testing();
    vault.rotate_risk_module<Sui2x, RiskModuleV2>(
        &fixture.protocol,
        &admin_witness,
    );
    vault.set_max_order_notional(
        &fixture.protocol,
        RiskModuleV2(),
        MAX_ORDER_NOTIONAL_MINIMUM,
    );

    assert!(vault.is_shutdown_pending_for_testing());
    assert_eq!(
        vault.risk_module_witness_for_testing(),
        type_name::with_original_ids<RiskModuleV2>(),
    );
    let (minimum, current, maximum) = vault.max_order_notional_for_testing();
    assert_eq!(minimum, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(current, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(maximum, MAX_ORDER_NOTIONAL_MAXIMUM);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun selected_risk_module_updates_max_order_notional_and_emits_the_change() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let vault_id = vault.id_for_testing();

    vault.set_max_order_notional(
        &fixture.protocol,
        RiskModule(),
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    let (minimum, current, maximum) = vault.max_order_notional_for_testing();
    assert_eq!(minimum, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(current, MAX_ORDER_NOTIONAL_MAXIMUM);
    assert_eq!(maximum, MAX_ORDER_NOTIONAL_MAXIMUM);
    let updated = events::collect_one<events::MaxOrderNotionalUpdated<Sui2x>>(0);
    let (event_vault_id, previous, current) = updated.max_order_notional_updated_fields();
    assert_eq!(event_vault_id, vault_id);
    assert_eq!(previous, MAX_ORDER_NOTIONAL_CURRENT);
    assert_eq!(current, MAX_ORDER_NOTIONAL_MAXIMUM);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 10,
    location = blast_leverage_aftermath::vault,
)]
fun unselected_risk_module_cannot_update_max_order_notional() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        RiskModuleV2(),
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 2,
    location = blast_leverage_aftermath::vault,
)]
fun primitive_risk_module_cannot_update_max_order_notional() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        0u64,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 74,
    location = blast_leverage_series_one::state,
)]
fun risk_module_cannot_repeat_the_current_max_order_notional() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        RiskModule(),
        MAX_ORDER_NOTIONAL_CURRENT,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 34,
    location = blast_leverage_series_one::bounded_value,
)]
fun risk_module_cannot_exceed_the_frozen_max_order_notional_bounds() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();

    vault.set_max_order_notional(
        &fixture.protocol,
        RiskModule(),
        MAX_ORDER_NOTIONAL_MAXIMUM + 1,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 0,
    location = blast_leverage_aftermath::protocol,
)]
fun stale_adapter_version_precedes_risk_witness_and_max_order_notional_validation() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    fixture.protocol.set_version_for_testing(2);

    vault.set_max_order_notional(
        &fixture.protocol,
        0u64,
        MAX_ORDER_NOTIONAL_MAXIMUM + 1,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 10,
    location = blast_leverage_aftermath::vault,
)]
fun rotated_out_risk_module_cannot_update_max_order_notional() {
    let mut fixture = start(1 | 2);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.rotate_risk_module<Sui2x, RiskModuleV2>(
        &fixture.protocol,
        &admin_witness,
    );

    vault.set_max_order_notional(
        &fixture.protocol,
        RiskModule(),
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
fun global_risk_admin_moves_an_active_vault_to_reduce_only() {
    let mut fixture = start(1 | 2);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let vault_id = vault.id_for_testing();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_active_for_testing();

    vault.enter_reduce_only(&fixture.protocol, &admin_witness);

    assert!(vault.is_reduce_only_for_testing());
    let entered = events::collect_one<events::ReduceOnlyEntered<Sui2x>>(0);
    assert_eq!(entered.reduce_only_entered_vault_id(), vault_id);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 47,
    location = blast_leverage_series_one::acl,
)]
fun issuer_without_risk_role_cannot_enter_reduce_only() {
    let mut fixture = start(1);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    vault.set_active_for_testing();

    vault.enter_reduce_only(&fixture.protocol, &admin_witness);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 17,
    location = blast_leverage_series_one::lifecycle,
)]
fun global_risk_admin_cannot_reduce_an_uninitialized_vault() {
    let mut fixture = start(1 | 2);
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2X".to_string());
    fixture.scenario.next_tx(ISSUER);
    let mut vault = fixture.scenario.take_shared<Vault<Sui2x>>();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    vault.enter_reduce_only(&fixture.protocol, &admin_witness);

    test_scenario::return_shared(vault);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = sui::coin_registry::ECurrencyAlreadyExists,
    location = sui::coin_registry,
)]
fun one_product_witness_cannot_issue_twice() {
    let mut fixture = start(1);

    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2XA".to_string());
    fixture.issue_and_share<Sui2x, RiskModule>(Sui2x(), b"SUI2XB".to_string());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 8,
    location = blast_leverage_aftermath::vault,
)]
fun primitive_product_witness_is_rejected() {
    let mut fixture = start(1);

    fixture.issue_and_share<u64, RiskModule>(0, b"BAD".to_string());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 9,
    location = blast_leverage_aftermath::vault,
)]
fun foreign_product_witness_is_rejected() {
    let mut fixture = start(1);

    fixture.issue_and_share<TypeName, RiskModule>(
        type_name::with_original_ids<u64>(),
        b"BAD".to_string(),
    );

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 19,
    location = blast_leverage_aftermath::vault,
)]
fun second_venue_account_installation_is_rejected() {
    vault::assert_venue_account_installable_for_testing(true);
}

// === Fixture Setup ===

fun start(roles: u8): Fixture {
    let mut scenario = test_scenario::begin(SYSTEM);
    let registry = coin_registry::create_coin_data_registry_for_testing(
        scenario.ctx(),
    );
    let protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());

    authority.grant_admin(
        &super_admin_cap,
        roles,
        ISSUER,
        scenario.ctx(),
    );
    scenario.next_tx(ISSUER);
    let admin_cap = scenario.take_from_sender<AdminCap>();

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

fun issue_and_share<Product: drop, RiskModule: drop>(
    self: &mut Fixture,
    product_witness: Product,
    symbol: String,
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
        product_witness,
        registry,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
        symbol,
        b"Test Vault".to_string(),
        b"Series1 leverage coin".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    vault.share();
}

fun standard_tier_policy(): TierPolicy {
    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(
            16_000,
            18_000,
            20_000,
            22_000,
            26_000,
            30_000,
            100,
            500,
            10,
        ),
        policy::new_valuation(30_000, 2_000, 100, 500),
        10,
        10,
        100,
        100,
        100,
        1_000_000_000,
    )
}
