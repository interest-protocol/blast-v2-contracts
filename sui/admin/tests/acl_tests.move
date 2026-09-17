#[test_only]
/// Stateful tests for the reusable typed ACL lifecycle.
module blast_admin::acl_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const ADMIN: address = @0xAD;
const OTHER_ADMIN: address = @0xB0B;
const MAX_ADMINS: u64 = 2;
const TRANSFER_DELAY_MS: u64 = 100;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    authority: acl::Authority<test_domain::TEST_DOMAIN>,
    root: acl::SuperAdminCap<test_domain::TEST_DOMAIN>,
    admin_cap: Option<acl::AdminCap<test_domain::TEST_DOMAIN>>,
}

// === Tests ===

#[test]
fun new_shares_one_authority_delivers_one_root_and_emits_complete_identity() {
    let mut scenario = test_scenario::begin(ROOT);

    acl::new(test_domain::otw(), MAX_ADMINS, TRANSFER_DELAY_MS, scenario.ctx());

    let created = events::collect_one<events::AuthorityCreated<test_domain::TEST_DOMAIN>>(0);
    let (authority_id, root_cap_id, recipient, max_admins, root_transfer_delay_ms) =
        created.authority_created_fields();

    scenario.next_tx(ROOT);
    let root = scenario.take_from_sender<acl::SuperAdminCap<test_domain::TEST_DOMAIN>>();
    let authority = scenario.take_shared<acl::Authority<test_domain::TEST_DOMAIN>>();
    assert_eq!(authority_id, authority.authority_id_for_testing());
    assert_eq!(root_cap_id, root.super_admin_cap_id_for_testing());
    assert_eq!(recipient, ROOT);
    assert_eq!(max_admins, MAX_ADMINS);
    assert_eq!(root_transfer_delay_ms, TRANSFER_DELAY_MS);
    assert_eq!(
        authority.active_super_admin_cap_id_for_testing(),
        root.super_admin_cap_id_for_testing(),
    );
    assert_eq!(authority.max_admins_for_testing(), MAX_ADMINS);
    assert_eq!(authority.root_transfer_delay_ms_for_testing(), TRANSFER_DELAY_MS);
    assert_eq!(event::num_events(), 0);

    test_scenario::return_shared(authority);
    destroy(root);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDomainWitness, location = blast_admin::acl)]
fun new_rejects_a_non_otw_before_creating_state() {
    let mut scenario = test_scenario::begin(ROOT);

    acl::new(
        test_domain::invalid_witness(),
        MAX_ADMINS,
        TRANSFER_DELAY_MS,
        scenario.ctx(),
    );

    scenario.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidMaxAdmins, location = blast_admin::acl)]
fun new_rejects_zero_capacity() {
    let mut scenario = test_scenario::begin(ROOT);

    acl::new(test_domain::otw(), 0, TRANSFER_DELAY_MS, scenario.ctx());

    scenario.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRootTransferDelay, location = blast_admin::acl)]
fun new_rejects_zero_transfer_delay() {
    let mut scenario = test_scenario::begin(ROOT);

    acl::new(test_domain::otw(), MAX_ADMINS, 0, scenario.ctx());

    scenario.end();
}

#[test]
fun phantom_domain_parameters_produce_distinct_acl_types() {
    let canonical = type_name::with_defining_ids<acl::Authority<test_domain::TEST_DOMAIN>>();
    let foreign = type_name::with_defining_ids<acl::Authority<other_domain::OTHER_DOMAIN>>();

    assert_eq!(canonical == foreign, false);
}

#[test]
fun zero_role_admin_signs_in_and_grant_event_is_replay_complete() {
    let mut fixture = start_root();
    fixture.grant_admin(0, ADMIN);
    let granted = events::collect_one<events::AdminGranted<test_domain::TEST_DOMAIN>>(0);
    fixture.scenario.next_tx(ADMIN);
    let admin_cap = fixture
        .scenario
        .take_from_sender<acl::AdminCap<test_domain::TEST_DOMAIN>>();
    fixture.admin_cap.fill(admin_cap);
    let admin_cap = fixture.admin_cap.borrow();
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    let witness = fixture.authority.sign_in(admin_cap);
    let (authority_id, emitted_cap_id, roles, recipient) = granted.admin_granted_fields();

    assert_eq!(authority_id, fixture.authority.authority_id_for_testing());
    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(roles, 0);
    assert_eq!(recipient, ADMIN);
    assert_eq!(witness.roles_for_testing(), 0);
    assert!(event::events_by_type<events::AdminGranted<test_domain::TEST_DOMAIN>>().is_empty());

    destroy(fixture);
}

#[test]
fun witness_keeps_its_full_role_snapshot_after_later_changes() {
    let mut fixture = start_admin(1);
    let Fixture { authority, root, admin_cap, .. } = &mut fixture;
    let admin_cap = admin_cap.borrow();
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    let original_witness = authority.sign_in(admin_cap);

    authority.grant_role(root, admin_cap_id, 2);
    let current_witness = authority.sign_in(admin_cap);

    original_witness.assert_role(1);
    assert_eq!(original_witness.roles_for_testing(), 1);
    assert_eq!(current_witness.roles_for_testing(), 3);
    current_witness.assert_role(1);
    current_witness.assert_role(2);

    authority.revoke_role(root, admin_cap_id, 1);
    assert_eq!(authority.admin_roles_for_testing(admin_cap_id), 2);

    destroy(fixture);
}

#[test]
fun role_changes_and_revocation_emit_replay_complete_facts() {
    let mut fixture = start_admin(1);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();
    let authority_id = fixture.authority.authority_id_for_testing();

    fixture.grant_role(admin_cap_id, 2);
    let granted = events::collect_one<
        events::AdminRoleGranted<test_domain::TEST_DOMAIN>,
    >(0);
    let (emitted_authority_id, emitted_cap_id, role, previous_roles, new_roles) =
        granted.admin_role_granted_fields();
    assert_eq!(emitted_authority_id, authority_id);
    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(role, 2);
    assert_eq!(previous_roles, 1);
    assert_eq!(new_roles, 3);

    fixture.revoke_role(admin_cap_id, 1);
    let revoked_role = events::collect_one<
        events::AdminRoleRevoked<test_domain::TEST_DOMAIN>,
    >(0);
    let (emitted_authority_id, emitted_cap_id, role, previous_roles, new_roles) =
        revoked_role.admin_role_revoked_fields();
    assert_eq!(emitted_authority_id, authority_id);
    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(role, 1);
    assert_eq!(previous_roles, 3);
    assert_eq!(new_roles, 2);

    fixture.revoke_admin(admin_cap_id);
    let revoked = events::collect_one<events::AdminRevoked<test_domain::TEST_DOMAIN>>(0);
    let (emitted_authority_id, emitted_cap_id, previous_roles) =
        revoked.admin_revoked_fields();
    assert_eq!(emitted_authority_id, authority_id);
    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(previous_roles, 2);

    destroy(fixture);
}

#[test]
fun destroying_live_and_revoked_caps_reports_their_previous_state() {
    let mut live = start_admin(3);
    let live_cap = live.admin_cap.extract();
    let live_cap_id = live_cap.admin_cap_id_for_testing();
    live.authority.destroy_admin_cap(live_cap);
    let live_event = events::collect_one<events::AdminDestroyed<test_domain::TEST_DOMAIN>>(0);
    let (authority_id, cap_id, roles, was_active) = live_event.admin_destroyed_fields();
    assert_eq!(authority_id, live.authority.authority_id_for_testing());
    assert_eq!(cap_id, live_cap_id);
    assert_eq!(roles, 3);
    assert!(was_active);
    destroy(live);

    let mut revoked = start_admin(7);
    let revoked_cap_id = revoked.admin_cap.borrow().admin_cap_id_for_testing();
    revoked.revoke_admin(revoked_cap_id);
    let revoked_cap = revoked.admin_cap.extract();
    revoked.authority.destroy_admin_cap(revoked_cap);
    let revoked_event = events::collect_one<events::AdminDestroyed<test_domain::TEST_DOMAIN>>(0);
    let (_, cap_id, roles, was_active) = revoked_event.admin_destroyed_fields();
    assert_eq!(cap_id, revoked_cap_id);
    assert_eq!(roles, 0);
    assert!(!was_active);
    destroy(revoked);
}

#[test]
#[expected_failure(abort_code = errors::EAdminCapacityReached, location = blast_admin::acl)]
fun grant_rejects_the_first_admin_over_capacity() {
    let mut fixture = start_root();

    fixture.grant_admin(0, ADMIN);
    fixture.grant_admin(0, OTHER_ADMIN);
    fixture.grant_admin(0, @0xCAFE);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminRecipient, location = blast_admin::acl)]
fun grant_rejects_the_zero_recipient_before_capacity() {
    let mut fixture = start_root();

    fixture.grant_admin(0, @0x0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::acl)]
fun revoked_cap_cannot_sign_in() {
    let mut fixture = start_admin(0);
    let Fixture { authority, root, admin_cap, .. } = &mut fixture;
    let admin_cap = admin_cap.borrow();
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.revoke_admin(root, admin_cap_id);
    let _ = authority.sign_in(admin_cap);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::acl)]
fun cap_from_another_authority_cannot_sign_in() {
    let mut fixture = start_admin(0);
    let (other_root, other_authority) = acl::new_for_testing<test_domain::TEST_DOMAIN>(
        MAX_ADMINS,
        TRANSFER_DELAY_MS,
        fixture.scenario.ctx(),
    );

    let _ = other_authority.sign_in(fixture.admin_cap.borrow());

    destroy(fixture);
    destroy(other_root);
    destroy(other_authority);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::acl)]
fun root_cap_from_another_authority_cannot_administer() {
    let mut fixture = start_root();
    let (other_root, other_authority) = acl::new_for_testing<test_domain::TEST_DOMAIN>(
        MAX_ADMINS,
        TRANSFER_DELAY_MS,
        fixture.scenario.ctx(),
    );

    fixture.authority.grant_admin(&other_root, 0, ADMIN, fixture.scenario.ctx());

    destroy(fixture);
    destroy(other_root);
    destroy(other_authority);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRole, location = blast_admin::acl)]
fun role_assertion_rejects_zero() {
    let fixture = start_admin(1);
    let witness = fixture.authority.sign_in(fixture.admin_cap.borrow());

    witness.assert_role(0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRole, location = blast_admin::acl)]
fun role_assertion_rejects_a_multi_bit_value() {
    let fixture = start_admin(3);
    let witness = fixture.authority.sign_in(fixture.admin_cap.borrow());

    witness.assert_role(3);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun role_assertion_rejects_an_absent_one_hot_role() {
    let fixture = start_admin(1);
    let witness = fixture.authority.sign_in(fixture.admin_cap.borrow());

    witness.assert_role(2);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun a_two_role_gate_rejects_a_witness_with_only_one_role() {
    let fixture = start_admin(1);
    let witness = fixture.authority.sign_in(fixture.admin_cap.borrow());

    witness.assert_role(1);
    witness.assert_role(2);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRole, location = blast_admin::acl)]
fun role_grant_rejects_zero() {
    let mut fixture = start_admin(0);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.grant_role(admin_cap_id, 0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRole, location = blast_admin::acl)]
fun role_grant_rejects_a_multi_bit_value() {
    let mut fixture = start_admin(0);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.grant_role(admin_cap_id, 3);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRole, location = blast_admin::acl)]
fun role_revoke_rejects_zero() {
    let mut fixture = start_admin(1);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.revoke_role(admin_cap_id, 0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRole, location = blast_admin::acl)]
fun role_revoke_rejects_a_multi_bit_value() {
    let mut fixture = start_admin(3);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.revoke_role(admin_cap_id, 3);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleAlreadyGranted, location = blast_admin::acl)]
fun role_grant_rejects_an_existing_role() {
    let mut fixture = start_admin(1);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.grant_role(admin_cap_id, 1);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun role_revoke_rejects_an_absent_role() {
    let mut fixture = start_admin(1);
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.revoke_role(admin_cap_id, 2);

    destroy(fixture);
}

// === Fixture Setup ===

fun start_root(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (root, authority) = acl::new_for_testing<test_domain::TEST_DOMAIN>(
        MAX_ADMINS,
        TRANSFER_DELAY_MS,
        scenario.ctx(),
    );

    Fixture {
        scenario,
        authority,
        root,
        admin_cap: option::none(),
    }
}

fun start_admin(roles: u64): Fixture {
    let mut fixture = start_root();

    fixture.grant_admin(roles, ADMIN);
    fixture.scenario.next_tx(ADMIN);
    let admin_cap = fixture
        .scenario
        .take_from_sender<acl::AdminCap<test_domain::TEST_DOMAIN>>();
    fixture.admin_cap.fill(admin_cap);

    fixture
}

// === Fixture Helpers ===

fun grant_admin(self: &mut Fixture, roles: u64, recipient: address) {
    let Fixture { scenario, authority, root, admin_cap: _ } = self;
    authority.grant_admin(root, roles, recipient, scenario.ctx());
}

fun revoke_admin(self: &mut Fixture, admin_cap_id: ID) {
    let Fixture { authority, root, .. } = self;
    authority.revoke_admin(root, admin_cap_id);
}

fun grant_role(self: &mut Fixture, admin_cap_id: ID, role: u64) {
    let Fixture { authority, root, .. } = self;
    authority.grant_role(root, admin_cap_id, role);
}

fun revoke_role(self: &mut Fixture, admin_cap_id: ID, role: u64) {
    let Fixture { authority, root, .. } = self;
    authority.revoke_role(root, admin_cap_id, role);
}

// === Imports ===

use blast_admin::{acl, errors, events, other_domain, test_domain};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};
