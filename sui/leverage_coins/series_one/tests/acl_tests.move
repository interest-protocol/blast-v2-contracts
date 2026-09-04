#[test_only]
/// Stateful tests for the adapter-bound Series1 ACL value.
module blast_leverage_series_one::acl_tests;

use blast_leverage_series_one::{acl, constants, errors, events};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self, Scenario}};

// === Constants ===

const ROOT: address = @0xA11CE;
const ADMIN: address = @0xAD;

// === Test-Only Types ===

/// Root authority and optional routine administrator used by ACL tests.
public struct Fixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: Option<acl::AdminCap>,
}

// === Tests ===

#[test]
fun constructor_delivers_only_the_root_cap() {
    let fixture = start_root();

    assert_eq!(event::num_events(), 0);
    assert_eq!(
        fixture.super_admin_cap.super_admin_cap_id_for_testing(),
        fixture.authority.active_super_admin_cap_id_for_testing(),
    );
    assert!(!fixture.scenario.has_most_recent_for_sender<acl::AdminCap>());

    destroy(fixture);
}

#[test]
fun one_cap_signs_in_with_its_complete_role_bitmap() {
    let roles = constants::vault_issuer_role!() | constants::risk_admin_role!();
    let fixture = start_admin(roles);
    let admin_cap = fixture.admin_cap.borrow();
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    let witness = fixture.authority.sign_in(admin_cap);

    assert_eq!(witness.witness_roles_for_testing(), roles);
    assert_eq!(fixture.authority.admin_roles_for_testing(admin_cap_id), roles);
    witness.assert_risk_admin();

    destroy(fixture);
}

#[test]
fun root_adds_and_removes_individual_role_bits() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.grant_role(
        admin_cap_id,
        constants::package_admin_role!(),
    );
    assert_eq!(
        fixture.authority.admin_roles_for_testing(admin_cap_id),
        constants::risk_admin_role!() | constants::package_admin_role!(),
    );

    fixture.revoke_role(
        admin_cap_id,
        constants::risk_admin_role!(),
    );
    let witness = fixture.authority.sign_in(fixture.admin_cap.borrow());
    assert_eq!(
        witness.witness_roles_for_testing(),
        constants::package_admin_role!(),
    );
    witness.assert_package_admin();

    destroy(fixture);
}

#[test]
fun cap_holder_can_destroy_its_live_registration() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap = fixture.admin_cap.extract();
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    fixture.authority.destroy_admin_cap(admin_cap);

    let destroyed = events::collect_one<events::AdminDestroyed>(0);
    let (emitted_cap_id, previous_roles, was_active) =
        destroyed.admin_destroyed_fields();
    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(previous_roles, constants::risk_admin_role!());
    assert!(was_active);

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminRoles,
    location = blast_leverage_series_one::acl,
)]
fun unknown_gap_bit_is_not_a_valid_role_bitmap() {
    let mut fixture = start_root();

    fixture.grant_admin(4, ADMIN);

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminCap,
    location = blast_leverage_series_one::acl,
)]
fun revoked_cap_cannot_sign_in() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.revoke_admin(admin_cap_id);
    let _ = fixture.authority.sign_in(fixture.admin_cap.borrow());

    destroy(fixture);
}

// === Fixture Setup ===

fun start_root(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(scenario.ctx());

    Fixture {
        scenario,
        authority,
        super_admin_cap,
        admin_cap: option::none(),
    }
}

fun start_admin(roles: u8): Fixture {
    let mut fixture = start_root();

    fixture.grant_admin(roles, ADMIN);
    fixture.scenario.next_tx(ADMIN);
    let admin_cap = fixture
        .scenario
        .take_from_sender<acl::AdminCap>();
    fixture.admin_cap.fill(admin_cap);

    fixture
}

// === Fixture Helpers ===

fun grant_admin(self: &mut Fixture, roles: u8, recipient: address) {
    let Fixture { scenario, authority, super_admin_cap, admin_cap: _ } = self;
    authority.grant_admin(super_admin_cap, roles, recipient, scenario.ctx());
}

fun grant_role(self: &mut Fixture, admin_cap_id: ID, role: u8) {
    let Fixture { authority, super_admin_cap, .. } = self;
    authority.grant_role(super_admin_cap, admin_cap_id, role);
}

fun revoke_role(self: &mut Fixture, admin_cap_id: ID, role: u8) {
    let Fixture { authority, super_admin_cap, .. } = self;
    authority.revoke_role(super_admin_cap, admin_cap_id, role);
}

fun revoke_admin(self: &mut Fixture, admin_cap_id: ID) {
    let Fixture { authority, super_admin_cap, .. } = self;
    authority.revoke_admin(super_admin_cap, admin_cap_id);
}
