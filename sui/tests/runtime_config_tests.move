#[test_only]
module blast_fun::runtime_config_tests;

use blast_fun::{acl, events, runtime_config};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self, Scenario}};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    config: runtime_config::RuntimeConfig,
}

// === Tests ===

#[test]
fun package_init_creates_disabled_zero_share_runtime_config() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());
    let created = events::collect_one<events::RuntimeConfigCreated>(0);
    let (emitted_config_id, protocol_fee_share_bps) =
        created.runtime_config_created_fields();

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();
    let config_id = object::id(&config);

    assert_eq!(config.protocol_fee_share_bps(), 0);
    assert_eq!(emitted_config_id, config_id);
    assert_eq!(protocol_fee_share_bps, 0);
    assert!(event::events_by_type<events::RuntimeConfigCreated>().is_empty());

    destroy(config);
    destroy(scenario);
}

#[test]
fun active_admin_updates_live_share_and_emits_old_and_new_values() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_protocol_fee_share(&admin_witness, 7_000);

    let changed = events::collect_one<events::ProtocolFeeShareChanged>(0);
    let (old_share_bps, new_share_bps) = changed.protocol_fee_share_changed_fields();
    assert_eq!(fixture.config.protocol_fee_share_bps(), 7_000);
    assert_eq!(old_share_bps, 0);
    assert_eq!(new_share_bps, 7_000);
    assert!(event::events_by_type<events::ProtocolFeeShareChanged>().is_empty());

    fixture.end();
}

#[test]
fun one_runtime_config_and_admin_witness_update_both_live_settings() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let signer_public_key =
        x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211";

    fixture.config.set_x_claim_signer(&admin_witness, signer_public_key);
    fixture.config.set_protocol_fee_share(&admin_witness, 2_500);

    let signer_set = events::collect_one<events::XClaimSignerSet>(0);
    let (previous_public_key, emitted_public_key) =
        signer_set.x_claim_signer_set_fields();
    let fee_share_changed = events::collect_one<events::ProtocolFeeShareChanged>(0);
    let (old_share_bps, new_share_bps) =
        fee_share_changed.protocol_fee_share_changed_fields();

    assert!(previous_public_key.is_empty());
    assert_eq!(emitted_public_key, signer_public_key);
    assert_eq!(old_share_bps, 0);
    assert_eq!(new_share_bps, 2_500);
    assert_eq!(fixture.config.protocol_fee_share_bps(), 2_500);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 40)]
fun protocol_fee_share_rejects_above_one_hundred_percent() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_protocol_fee_share(&admin_witness, 10_001);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 41)]
fun protocol_fee_share_rejects_unchanged_value() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_protocol_fee_share(&admin_witness, 0);

    fixture.end();
}

#[test]
fun protocol_fee_share_accepts_both_percentage_boundaries() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_protocol_fee_share(&admin_witness, 10_000);
    assert_eq!(fixture.config.protocol_fee_share_bps(), 10_000);

    fixture.config.set_protocol_fee_share(&admin_witness, 0);
    assert_eq!(fixture.config.protocol_fee_share_bps(), 0);

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

    fixture.end();
}

// === Private Functions ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    runtime_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();

    Fixture { scenario, super_admin_cap, authority, admin_cap, config }
}

fun end(self: Fixture) {
    destroy(self);
}
