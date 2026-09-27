// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Stateful tests for the singleton ACL's one-role administrators.
module blast_admin::acl_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

const ADMIN: address = @0xAD;

const OTHER_ADMIN: address = @0xB0B;

const MAX_ADMINS: u64 = 64;

// === Test-Only Types ===

public struct FeeAdmin()

public struct RiskAdmin()

public struct Fixture {
    scenario: Scenario,
    acl: ACL,
    root: SuperAdminCap,
}

// === Tests ===

#[test]
fun init_shares_one_acl_and_delivers_its_root_without_events() {
    let mut scenario = test_scenario::begin(ROOT);

    blast_acl::init_for_testing(scenario.ctx());

    let effects = scenario.next_tx(ROOT);
    assert_eq!(effects.shared().length(), 1);
    assert_eq!(effects.num_user_events(), 0);
    let root = scenario.take_from_sender<SuperAdminCap>();
    let acl = scenario.take_shared<ACL>();
    assert_eq!(acl.active_super_admin_cap_id_for_testing(), root.super_admin_cap_id_for_testing());
    assert_eq!(acl.admin_count_for_testing(), 0);
    assert!(!acl.has_pending_transfer_for_testing());
    assert_eq!(blast_acl::max_admins_for_testing(), MAX_ADMINS);

    test_scenario::return_shared(acl);
    destroy(root);
    scenario.end();
}

#[test]
fun grant_delivers_a_role_typed_cap_that_signs_in_and_names_its_role() {
    let mut fixture = start();

    fixture.grant_admin<FeeAdmin>(ADMIN);
    let granted = events::collect_one<events::AdminGranted>(0);
    let admin_cap = fixture.take_admin_cap<FeeAdmin>(ADMIN);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&admin_cap);
    let (emitted_cap_id, role, recipient) = granted.admin_granted_fields();

    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(role, type_name::with_defining_ids<FeeAdmin>());
    assert_eq!(recipient, ADMIN);
    assert_eq!(fixture.acl.admin_role_for_testing(admin_cap_id), role);
    assert_eq!(fixture.acl.admin_count_for_testing(), 1);

    destroy(admin_cap);
    destroy(fixture);
}

#[test]
fun each_role_is_its_own_cap_and_revoking_one_keeps_the_other() {
    let mut fixture = start();
    fixture.grant_admin<FeeAdmin>(ADMIN);
    fixture.grant_admin<RiskAdmin>(ADMIN);
    let fee_cap = fixture.take_admin_cap<FeeAdmin>(ADMIN);
    let risk_cap = fixture.take_admin_cap<RiskAdmin>(ADMIN);
    let fee_cap_id = fee_cap.admin_cap_id_for_testing();

    fixture.revoke_admin(fee_cap_id);
    let revoked = events::collect_one<events::AdminRevoked>(0);
    let (revoked_cap_id, revoked_role) = revoked.admin_revoked_fields();
    let _: AdminWitness<RiskAdmin> = fixture.acl.sign_in(&risk_cap);

    assert_eq!(revoked_cap_id, fee_cap_id);
    assert_eq!(revoked_role, type_name::with_defining_ids<FeeAdmin>());
    assert_eq!(fixture.acl.admin_count_for_testing(), 1);

    destroy(fee_cap);
    destroy(risk_cap);
    destroy(fixture);
}

#[test]
fun destroying_live_and_revoked_caps_reports_their_previous_state() {
    let mut fixture = start();
    fixture.grant_admin<FeeAdmin>(ADMIN);
    fixture.grant_admin<RiskAdmin>(OTHER_ADMIN);
    let live_cap = fixture.take_admin_cap<FeeAdmin>(ADMIN);
    let revoked_cap = fixture.take_admin_cap<RiskAdmin>(OTHER_ADMIN);
    let live_cap_id = live_cap.admin_cap_id_for_testing();
    let revoked_cap_id = revoked_cap.admin_cap_id_for_testing();
    fixture.revoke_admin(revoked_cap_id);

    fixture.acl.destroy_admin_cap(live_cap);
    let live = events::collect_one<events::AdminDestroyed>(0);
    let (live_id, live_role, live_was_active) = live.admin_destroyed_fields();
    fixture.scenario.next_tx(OTHER_ADMIN);
    fixture.acl.destroy_admin_cap(revoked_cap);
    let revoked = events::collect_one<events::AdminDestroyed>(0);
    let (revoked_id, revoked_role, revoked_was_active) = revoked.admin_destroyed_fields();

    assert_eq!(live_id, live_cap_id);
    assert_eq!(live_role, type_name::with_defining_ids<FeeAdmin>());
    assert!(live_was_active);
    assert_eq!(revoked_id, revoked_cap_id);
    assert_eq!(revoked_role, type_name::with_defining_ids<RiskAdmin>());
    assert!(!revoked_was_active);
    assert_eq!(fixture.acl.admin_count_for_testing(), 0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EAdminCapacityReached, location = blast_admin::blast_acl)]
fun grant_rejects_the_first_admin_over_capacity() {
    let mut fixture = start();
    MAX_ADMINS.do!(|_| fixture.grant_admin<FeeAdmin>(ADMIN));

    fixture.grant_admin<FeeAdmin>(ADMIN);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminRecipient, location = blast_admin::blast_acl)]
fun grant_rejects_the_zero_recipient_before_capacity() {
    let mut fixture = start();
    MAX_ADMINS.do!(|_| fixture.grant_admin<FeeAdmin>(ADMIN));

    fixture.grant_admin<FeeAdmin>(@0x0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
fun revoke_rejects_an_unknown_cap() {
    let mut fixture = start();

    fixture.revoke_admin(object::id_from_address(@0xDEAD));

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
fun revoked_cap_cannot_sign_in() {
    let mut fixture = start();
    fixture.grant_admin<FeeAdmin>(ADMIN);
    let admin_cap = fixture.take_admin_cap<FeeAdmin>(ADMIN);
    fixture.revoke_admin(admin_cap.admin_cap_id_for_testing());

    let _ = fixture.acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
fun cap_from_another_acl_cannot_sign_in() {
    let mut fixture = start();
    fixture.grant_admin<FeeAdmin>(ADMIN);
    let admin_cap = fixture.take_admin_cap<FeeAdmin>(ADMIN);
    let (_other_root, other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    let _ = other_acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::blast_acl)]
fun root_cap_from_another_acl_cannot_grant() {
    let mut fixture = start();
    let (other_root, _other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    fixture.acl.grant_admin<FeeAdmin>(&other_root, ADMIN, fixture.scenario.ctx());

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::blast_acl)]
fun root_cap_from_another_acl_cannot_revoke() {
    let mut fixture = start();
    fixture.grant_admin<FeeAdmin>(ADMIN);
    let admin_cap = fixture.take_admin_cap<FeeAdmin>(ADMIN);
    let (other_root, _other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    fixture.acl.revoke_admin(&other_root, admin_cap.admin_cap_id_for_testing());

    abort
}

// === Test Helpers ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (root, acl) = blast_acl::new_for_testing(scenario.ctx());

    Fixture { scenario, acl, root }
}

fun grant_admin<Role>(self: &mut Fixture, recipient: address) {
    let Fixture { scenario, acl, root } = self;
    acl.grant_admin<Role>(root, recipient, scenario.ctx());
}

fun revoke_admin(self: &mut Fixture, admin_cap_id: ID) {
    let Fixture { acl, root, .. } = self;
    acl.revoke_admin(root, admin_cap_id);
}

fun take_admin_cap<Role>(self: &mut Fixture, owner: address): AdminCap<Role> {
    self.scenario.next_tx(owner);
    self.scenario.take_from_sender<AdminCap<Role>>()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, ACL, AdminCap, AdminWitness, SuperAdminCap},
    blast_admin_events as events,
    errors,
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::test_scenario::{Self, Scenario};
