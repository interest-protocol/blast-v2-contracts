#[test_only]
module blast_fun::runtime_config_tests;

use blast_fun::{acl, events, package_version, runtime_config};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;
use fun config_next_tx as ConfigFixture.next_tx;
use fun init_end as InitFixture.end;
use fun init_next_tx as InitFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

/// Package-initialization facts only; carries no ACL or admin state.
public struct InitFixture {
    scenario: Scenario,
    config: runtime_config::RuntimeConfig,
    created: events::RuntimeConfigCreated,
}

/// Live-settings administration through the ACL sign-in seam.
public struct ConfigFixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    package_version: package_version::PackageVersion,
    config: runtime_config::RuntimeConfig,
}

// === Tests ===

#[test]
fun package_init_creates_disabled_zero_share_runtime_config() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        let (emitted_config_id, protocol_fee_share_bps) =
            f.created.runtime_config_created_fields();

        assert_eq!(f.config.protocol_fee_share_bps().value(), 0);
        assert_eq!(emitted_config_id, object::id(&f.config));
        assert_eq!(protocol_fee_share_bps, 0);
        assert!(event::events_by_type<events::RuntimeConfigCreated>().is_empty());
    });

    fixture.end();
}

#[test]
fun active_admin_updates_live_share_and_emits_old_and_new_values() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, 7_000);

        let changed = events::collect_one<events::ProtocolFeeShareChanged>(0);
        let (old_share_bps, new_share_bps) =
            changed.protocol_fee_share_changed_fields();
        assert_eq!(f.config.protocol_fee_share_bps().value(), 7_000);
        assert_eq!(old_share_bps, 0);
        assert_eq!(new_share_bps, 7_000);
        assert!(event::events_by_type<events::ProtocolFeeShareChanged>().is_empty());
    });

    fixture.end();
}

#[test]
fun one_runtime_config_and_admin_witness_update_both_live_settings() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let signer_public_key =
            x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211";

        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            signer_public_key,
        );
        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, 2_500);

        let signer_set = events::collect_one<events::XClaimSignerSet>(0);
        let (previous_public_key, emitted_public_key) =
            signer_set.x_claim_signer_set_fields();
        let fee_share_changed =
            events::collect_one<events::ProtocolFeeShareChanged>(0);
        let (old_share_bps, new_share_bps) =
            fee_share_changed.protocol_fee_share_changed_fields();

        assert!(previous_public_key.is_empty());
        assert_eq!(emitted_public_key, signer_public_key);
        assert_eq!(old_share_bps, 0);
        assert_eq!(new_share_bps, 2_500);
        assert_eq!(f.config.protocol_fee_share_bps().value(), 2_500);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidBps,
    location = blast_fun::bps,
)]
fun protocol_fee_share_delegates_range_validation_to_bps() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, 10_001);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EPackageVersionMismatch,
    location = blast_fun::package_version,
)]
fun stale_package_version_rejects_runtime_config_before_value_validation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.set_protocol_fee_share(
            &f.package_version,
            &admin_witness,
            10_001,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EProtocolFeeShareUnchanged,
    location = blast_fun::runtime_config,
)]
fun protocol_fee_share_rejects_unchanged_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, 0);
    });

    fixture.end();
}

#[test]
fun protocol_fee_share_accepts_both_percentage_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, 10_000);
        assert_eq!(f.config.protocol_fee_share_bps().value(), 10_000);

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, 0);
        assert_eq!(f.config.protocol_fee_share_bps().value(), 0);

        let mut changes = events::collect<events::ProtocolFeeShareChanged>();
        assert_eq!(changes.length(), 2);
        let second = changes.pop_back();
        let first = changes.pop_back();
        let (first_old, first_new) = first.protocol_fee_share_changed_fields();
        let (second_old, second_new) = second.protocol_fee_share_changed_fields();

        assert_eq!(first_old, 0);
        assert_eq!(first_new, 10_000);
        assert_eq!(second_old, 10_000);
        assert_eq!(second_new, 0);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun init_next_tx(
    $fixture: &mut InitFixture,
    $sender: address,
    $fn: |&mut InitFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun config_next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());
    let created = events::collect_one<events::RuntimeConfigCreated>(0);

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();

    InitFixture { scenario, config, created }
}

fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    let config = runtime_config::new_disabled_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    ConfigFixture { scenario, authority, admin_cap, package_version, config }
}

fun sign_in(self: &ConfigFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}
