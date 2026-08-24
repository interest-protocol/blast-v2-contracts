#[test_only]
module blast_fun::trade_fee_config_tests;

use blast_fun::{acl, events, trade_fee_config};
use sui::{event, test_scenario::{Self, Scenario}};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Tests ===

#[test]
fun package_init_creates_zero_share_config_and_replay_complete_event() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    trade_fee_config::init_for_testing(scenario.ctx());
    let created = events::collect_one<events::TradeFeeConfigCreated>(0);
    let (emitted_config_id, protocol_fee_share_bps) =
        created.trade_fee_config_created_fields();

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<trade_fee_config::TradeFeeConfig>();
    let config_id = object::id(&config);

    std::unit_test::assert_eq!(config.protocol_fee_share_bps(), 0);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(protocol_fee_share_bps, 0);
    assert!(event::events_by_type<events::TradeFeeConfigCreated>().is_empty());

    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun active_admin_updates_live_share_and_emits_old_and_new_values() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.set_protocol_fee_share(&admin_witness, 7_000);

    let changed = events::collect_one<events::ProtocolFeeShareChanged>(0);
    let (emitted_config_id, old_share_bps, new_share_bps) =
        changed.protocol_fee_share_changed_fields();
    std::unit_test::assert_eq!(config.protocol_fee_share_bps(), 7_000);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(old_share_bps, 0);
    std::unit_test::assert_eq!(new_share_bps, 7_000);
    assert!(event::events_by_type<events::ProtocolFeeShareChanged>().is_empty());

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 40)]
fun protocol_fee_share_rejects_above_one_hundred_percent() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_protocol_fee_share(&admin_witness, 10_001);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 41)]
fun protocol_fee_share_rejects_unchanged_value() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_protocol_fee_share(&admin_witness, 0);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun protocol_fee_share_accepts_both_percentage_boundaries() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.set_protocol_fee_share(&admin_witness, 10_000);
    std::unit_test::assert_eq!(config.protocol_fee_share_bps(), 10_000);

    config.set_protocol_fee_share(&admin_witness, 0);
    std::unit_test::assert_eq!(config.protocol_fee_share_bps(), 0);

    let mut changes = events::collect<events::ProtocolFeeShareChanged>();
    std::unit_test::assert_eq!(changes.length(), 2);
    let second = changes.pop_back();
    let first = changes.pop_back();
    let (first_config_id, first_old, first_new) =
        first.protocol_fee_share_changed_fields();
    let (second_config_id, second_old, second_new) =
        second.protocol_fee_share_changed_fields();

    std::unit_test::assert_eq!(first_config_id, config_id);
    std::unit_test::assert_eq!(first_old, 0);
    std::unit_test::assert_eq!(first_new, 10_000);
    std::unit_test::assert_eq!(second_config_id, config_id);
    std::unit_test::assert_eq!(second_old, 10_000);
    std::unit_test::assert_eq!(second_new, 0);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

// === Private Functions ===

fun new_config_with_admin(
    scenario: &mut Scenario,
): (
    acl::SuperAdminCap,
    acl::ProtocolAuthority,
    acl::AdminCap,
    trade_fee_config::TradeFeeConfig,
) {
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.add_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    trade_fee_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let config = scenario.take_shared<trade_fee_config::TradeFeeConfig>();

    (super_admin_cap, authority, admin_cap, config)
}
