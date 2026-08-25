#[test_only]
module blast_fun::launch_config_capacity_tests;

use blast_fun::{acl, constants, launch_config};
use std::unit_test::{assert_eq, destroy};
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

/// Cold-policy administration through the ACL sign-in seam.
public struct ConfigFixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    config: launch_config::LaunchConfig,
}

// === Tests ===

#[test]
fun migration_witness_registry_allows_replacement_at_capacity() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.allow_sixteen_migration_witnesses(&admin_witness);
        f.config.disallow_migration_witness<MIGRATION_WITNESS<R0>>(&admin_witness);
        f.config.allow_migration_witness<MIGRATION_WITNESS<R16>>(&admin_witness);

        assert_eq!(
            f.config.allowed_migration_witness_count_for_testing(),
            constants::max_migration_witnesses!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 51, location = blast_fun::launch_config)]
fun migration_witness_registry_rejects_seventeenth_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.allow_sixteen_migration_witnesses(&admin_witness);
        f.config.allow_migration_witness<MIGRATION_WITNESS<R16>>(&admin_witness);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun allow_sixteen_migration_witnesses(
    self: &mut ConfigFixture,
    admin_witness: &acl::AdminWitness,
) {
    self.config.allow_migration_witness<MIGRATION_WITNESS<R0>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R1>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R2>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R3>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R4>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R5>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R6>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R7>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R8>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R9>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R10>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R11>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R12>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R13>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R14>>(admin_witness);
    self.config.allow_migration_witness<MIGRATION_WITNESS<R15>>(admin_witness);
}

fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let config = scenario.take_shared<launch_config::LaunchConfig>();

    ConfigFixture { scenario, authority, admin_cap, config }
}

fun sign_in(self: &ConfigFixture): acl::AdminWitness {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: ConfigFixture) {
    destroy(self);
}
