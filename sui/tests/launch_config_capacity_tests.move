#[test_only]
module blast_fun::launch_config_capacity_tests;

use blast_fun::{acl, constants, launch_config};
use sui::test_scenario::{Self, Scenario};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct MIGRATION_WITNESS<phantom Marker>() has drop;
public struct R0() has drop;
public struct R1() has drop;
public struct R2() has drop;
public struct R3() has drop;
public struct R4() has drop;
public struct R5() has drop;
public struct R6() has drop;
public struct R7() has drop;
public struct R8() has drop;
public struct R9() has drop;
public struct R10() has drop;
public struct R11() has drop;
public struct R12() has drop;
public struct R13() has drop;
public struct R14() has drop;
public struct R15() has drop;
public struct R16() has drop;

// === Tests ===

#[test]
fun migration_witness_registry_allows_replacement_at_capacity() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    allow_sixteen_migration_witnesses(&mut config, &admin_witness);
    config.remove_migration_witness<MIGRATION_WITNESS<R0>>(&admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R16>>(&admin_witness);

    std::unit_test::assert_eq!(
        config.migration_witness_count_for_testing(),
        constants::max_migration_witnesses!(),
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 51)]
fun migration_witness_registry_rejects_seventeenth_type() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    allow_sixteen_migration_witnesses(&mut config, &admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R16>>(&admin_witness);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

// === Private Test Helpers ===

fun allow_sixteen_migration_witnesses(
    config: &mut launch_config::LaunchConfig,
    admin_witness: &acl::AdminWitness,
) {
    config.allow_migration_witness<MIGRATION_WITNESS<R0>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R1>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R2>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R3>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R4>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R5>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R6>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R7>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R8>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R9>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R10>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R11>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R12>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R13>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R14>>(admin_witness);
    config.allow_migration_witness<MIGRATION_WITNESS<R15>>(admin_witness);
}

fun new_config_with_admin(
    scenario: &mut Scenario,
): (
    acl::SuperAdminCap,
    acl::ProtocolAuthority,
    acl::AdminCap,
    launch_config::LaunchConfig,
) {
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.add_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let config = scenario.take_shared<launch_config::LaunchConfig>();

    (super_admin_cap, authority, admin_cap, config)
}
