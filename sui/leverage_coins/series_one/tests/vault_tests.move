#[test_only]
/// Stateful tests for authorized Series1 Vault and share-currency issuance.
module blast_leverage_series_one::vault_tests;

use blast_leverage_series_one::{
    acl,
    constants,
    errors,
    events,
    package_version::{Self, PackageVersion},
    policy::{Self, TierPolicy},
    vault::{Self, Vault},
};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{
    coin_registry::{Self, CoinRegistry, Currency},
    test_scenario::{Self, Scenario},
};

use fun issuance_ctx as IssuanceFixture.ctx;
use fun issuance_end as IssuanceFixture.end;
use fun issuance_issue as IssuanceFixture.issue;
use fun issuance_next_tx as IssuanceFixture.next_tx;

// === Constants ===

const SYSTEM: address = @0x0;
const ISSUER: address = @0xA11CE;
const SHARE_DECIMALS: u8 = 9;
const NOTIONAL_MINIMUM: u64 = 100;
const NOTIONAL_CURRENT: u64 = 250;
const NOTIONAL_MAXIMUM: u64 = 1_000;

// === Test-Only Types ===

/// Sealed test adapter root and initial adapter identity.
public struct AdapterRoot {}

/// Sealed test risk-module identity.
public struct RiskModule {}

/// Issuer, registry, and package authority used by Vault issuance tests.
public struct IssuanceFixture {
    scenario: Scenario,
    registry: CoinRegistry,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: Option<acl::AdminCap>,
}

// === Tests ===

#[test]
fun issuance_creates_the_inert_vault_currency_and_replay_complete_event() {
    let mut fixture = start(constants::vault_issuer_role!());
    let expected_policy = standard_tier_policy();

    fixture.next_tx!(ISSUER, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        vault::issue<AdapterRoot, RiskModule>(
            &mut f.registry,
            &f.package_version,
            &witness,
            expected_policy,
            NOTIONAL_MINIMUM,
            NOTIONAL_CURRENT,
            NOTIONAL_MAXIMUM,
            b"SUI2L".to_string(),
            b"SUI 2x Bull".to_string(),
            b"Targets approximately 2x long SUI exposure and can be liquidated."
                .to_string(),
            b"https://blast.fun/sui2l.png".to_string(),
            f.ctx!(),
        );

        let issued = events::collect_one<events::VaultIssued<AdapterRoot>>(0);
        let (
            vault_id,
            treasury_cap_id,
            metadata_cap_id,
            adapter_witness,
            risk_module_witness,
            emitted_policy,
            emitted_notional_cap,
            maintenance_reserve,
        ) = issued.vault_issued_fields();

        assert_eq!(adapter_witness, type_name::with_original_ids<AdapterRoot>());
        assert_eq!(
            risk_module_witness,
            type_name::with_original_ids<RiskModule>(),
        );
        assert_eq!(emitted_policy, expected_policy);
        assert_eq!(emitted_notional_cap.minimum(), NOTIONAL_MINIMUM);
        assert_eq!(emitted_notional_cap.current(), NOTIONAL_CURRENT);
        assert_eq!(emitted_notional_cap.maximum(), NOTIONAL_MAXIMUM);
        assert_eq!(maintenance_reserve, 0);

        f.next_tx!(ISSUER, |f| {
            let vault = f.scenario.take_shared<Vault<AdapterRoot>>();
            let currency = f.scenario.take_shared<Currency<Vault<AdapterRoot>>>();

            assert_eq!(vault.vault_id_for_testing(), vault_id);
            assert!(vault.is_uninitialized_for_testing());
            assert_eq!(vault.maintenance_reserve_for_testing(), 0);
            assert!(vault.adapter_storage_is_empty_for_testing());
            assert_eq!(vault.tier_policy_for_testing(), expected_policy);
            assert_eq!(
                vault.adapter_witness_for_testing(),
                type_name::with_original_ids<AdapterRoot>(),
            );
            assert_eq!(
                vault.risk_module_witness_for_testing(),
                type_name::with_original_ids<RiskModule>(),
            );
            assert_eq!(vault.treasury_cap_id_for_testing(), treasury_cap_id);
            assert_eq!(vault.metadata_cap_id_for_testing(), metadata_cap_id);
            assert_eq!(vault.share_supply_for_testing(), 0);

            assert!(f.registry.exists<Vault<AdapterRoot>>());
            assert_eq!(currency.decimals(), SHARE_DECIMALS);
            assert_eq!(currency.symbol(), b"SUI2L".to_string());
            assert_eq!(currency.name(), b"SUI 2x Bull".to_string());
            assert_eq!(
                currency.description(),
                b"Targets approximately 2x long SUI exposure and can be liquidated."
                    .to_string(),
            );
            assert_eq!(
                currency.icon_url(),
                b"https://blast.fun/sui2l.png".to_string(),
            );
            assert!(currency.is_metadata_cap_claimed());
            assert!(!currency.is_metadata_cap_deleted());
            assert_eq!(currency.metadata_cap_id().destroy_some(), metadata_cap_id);
            assert_eq!(currency.treasury_cap_id().destroy_some(), treasury_cap_id);
            assert!(currency.total_supply().is_none());

            test_scenario::return_shared(currency);
            test_scenario::return_shared(vault);
        });
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun stale_version_precedes_role_witness_and_notional_validation() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.next_tx!(ISSUER, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        f.package_version.set_for_testing(2);
        vault::issue<u64, u64>(
            &mut f.registry,
            &f.package_version,
            &witness,
            standard_tier_policy(),
            0,
            1,
            0,
            b"STALE".to_string(),
            b"Stale".to_string(),
            b"Stale version".to_string(),
            b"".to_string(),
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun issuer_role_precedes_witness_and_notional_validation() {
    let mut fixture = start(constants::risk_admin_role!());

    fixture.next_tx!(ISSUER, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        vault::issue<u64, u64>(
            &mut f.registry,
            &f.package_version,
            &witness,
            standard_tier_policy(),
            0,
            1,
            0,
            b"ROLE".to_string(),
            b"Role".to_string(),
            b"Wrong role".to_string(),
            b"".to_string(),
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdapterWitnessType,
    location = blast_leverage_series_one::vault,
)]
fun a_primitive_adapter_root_is_rejected() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.issue<u64, RiskModule>(
        NOTIONAL_MINIMUM,
        NOTIONAL_CURRENT,
        NOTIONAL_MAXIMUM,
    );
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdapterWitnessType,
    location = blast_leverage_series_one::vault,
)]
fun a_vector_adapter_root_is_rejected() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.issue<vector<u8>, RiskModule>(
        NOTIONAL_MINIMUM,
        NOTIONAL_CURRENT,
        NOTIONAL_MAXIMUM,
    );
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidRiskModuleWitnessType,
    location = blast_leverage_series_one::vault,
)]
fun a_primitive_risk_module_is_rejected() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.issue<AdapterRoot, u64>(
        NOTIONAL_MINIMUM,
        NOTIONAL_CURRENT,
        NOTIONAL_MAXIMUM,
    );
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidRiskModuleWitnessType,
    location = blast_leverage_series_one::vault,
)]
fun a_vector_risk_module_is_rejected() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.issue<AdapterRoot, vector<u8>>(
        NOTIONAL_MINIMUM,
        NOTIONAL_CURRENT,
        NOTIONAL_MAXIMUM,
    );
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNotionalCap,
    location = blast_leverage_series_one::vault,
)]
fun a_zero_notional_minimum_is_rejected() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.issue<AdapterRoot, RiskModule>(0, 0, NOTIONAL_MAXIMUM);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidBoundedValue,
    location = blast_leverage_series_one::bounded_value,
)]
fun malformed_notional_bounds_are_rejected_by_the_composed_value() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.issue<AdapterRoot, RiskModule>(2, 1, 3);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = sui::coin_registry::ECurrencyAlreadyExists,
    location = sui::coin_registry,
)]
fun the_same_adapter_root_cannot_issue_a_second_vault_currency() {
    let mut fixture = start(constants::vault_issuer_role!());

    fixture.next_tx!(ISSUER, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        issue_with_witness<AdapterRoot, RiskModule>(f, &witness);
        issue_with_witness<AdapterRoot, RiskModule>(f, &witness);
    });

    fixture.end();
}

// === Fixture Transaction Macros ===

macro fun issuance_next_tx(
    $fixture: &mut IssuanceFixture,
    $sender: address,
    $fn: |&mut IssuanceFixture|,
) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun issuance_ctx($fixture: &mut IssuanceFixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

// === Fixture Setup ===

fun start(roles: u8): IssuanceFixture {
    let mut scenario = test_scenario::begin(SYSTEM);
    let registry = coin_registry::create_coin_data_registry_for_testing(
        scenario.ctx(),
    );
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        roles,
        ISSUER,
        scenario.ctx(),
    );

    scenario.next_tx(ISSUER);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    IssuanceFixture {
        scenario,
        registry,
        package_version,
        authority,
        super_admin_cap,
        admin_cap: option::some(admin_cap),
    }
}

fun issuance_issue<AdapterRoot, RiskModule>(
    self: &mut IssuanceFixture,
    notional_minimum: u64,
    notional_current: u64,
    notional_maximum: u64,
) {
    self.next_tx!(ISSUER, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        vault::issue<AdapterRoot, RiskModule>(
            &mut f.registry,
            &f.package_version,
            &witness,
            standard_tier_policy(),
            notional_minimum,
            notional_current,
            notional_maximum,
            b"TEST".to_string(),
            b"Test Vault".to_string(),
            b"Test leverage Vault".to_string(),
            b"".to_string(),
            f.ctx!(),
        );
    });
}

fun issue_with_witness<AdapterRoot, RiskModule>(
    fixture: &mut IssuanceFixture,
    witness: &acl::AdminWitness,
) {
    vault::issue<AdapterRoot, RiskModule>(
        &mut fixture.registry,
        &fixture.package_version,
        witness,
        standard_tier_policy(),
        NOTIONAL_MINIMUM,
        NOTIONAL_CURRENT,
        NOTIONAL_MAXIMUM,
        b"TEST".to_string(),
        b"Test Vault".to_string(),
        b"Test leverage Vault".to_string(),
        b"".to_string(),
        fixture.ctx!(),
    );
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

fun issuance_end(self: IssuanceFixture) {
    destroy(self)
}
