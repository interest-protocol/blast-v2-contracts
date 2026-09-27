// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Stateful tests for the singleton ACL's administrators and their typed roles.
module blast_admin::acl_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

const ADMIN: address = @0xAD;

const OTHER_ADMIN: address = @0xB0B;

const MAX_ADMINS: u64 = 32;

const MAX_ROLES_PER_ADMIN: u64 = 32;

// === Test-Only Types ===

public struct FeeAdmin()

public struct RiskAdmin()

public struct Role<phantom T>()

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
    assert_eq!(blast_acl::max_roles_per_admin_for_testing(), MAX_ROLES_PER_ADMIN);

    test_scenario::return_shared(acl);
    destroy(root);
    scenario.end();
}

#[test]
fun grant_delivers_a_roleless_cap_that_signs_in_to_each_granted_role() {
    let mut fixture = start();

    fixture.grant_admin(ADMIN);
    let granted = events::collect_one<events::AdminGranted>(0);
    let admin_cap = fixture.take_admin_cap(ADMIN);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    fixture.grant_role<FeeAdmin>(admin_cap_id);
    let fee_granted = events::collect_one<events::AdminRoleGranted>(0);
    fixture.grant_role<RiskAdmin>(admin_cap_id);
    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&admin_cap);
    let _: AdminWitness<RiskAdmin> = fixture.acl.sign_in(&admin_cap);
    let (emitted_cap_id, recipient) = granted.admin_granted_fields();
    let (role_cap_id, role) = fee_granted.admin_role_granted_fields();

    assert_eq!(emitted_cap_id, admin_cap_id);
    assert_eq!(recipient, ADMIN);
    assert_eq!(role_cap_id, admin_cap_id);
    assert_eq!(role, type_name::with_defining_ids<FeeAdmin>());
    assert_eq!(
        fixture.acl.admin_roles_for_testing(admin_cap_id),
        vector[type_name::with_defining_ids<FeeAdmin>(), type_name::with_defining_ids<RiskAdmin>()],
    );
    assert_eq!(fixture.acl.admin_count_for_testing(), 1);

    destroy(admin_cap);
    destroy(fixture);
}

#[test]
fun revoking_one_role_keeps_the_others() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    fixture.revoke_role<FeeAdmin>(admin_cap_id);
    let revoked = events::collect_one<events::AdminRoleRevoked>(0);
    let (revoked_cap_id, revoked_role) = revoked.admin_role_revoked_fields();
    let _: AdminWitness<RiskAdmin> = fixture.acl.sign_in(&admin_cap);

    assert_eq!(revoked_cap_id, admin_cap_id);
    assert_eq!(revoked_role, type_name::with_defining_ids<FeeAdmin>());
    assert_eq!(
        fixture.acl.admin_roles_for_testing(admin_cap_id),
        vector[type_name::with_defining_ids<RiskAdmin>()],
    );

    destroy(admin_cap);
    destroy(fixture);
}

#[test]
fun instantiations_of_a_generic_role_are_distinct_roles() {
    let mut fixture = start();
    fixture.grant_admin(ADMIN);
    let admin_cap = fixture.take_admin_cap(ADMIN);

    fixture.grant_role<Role<FeeAdmin>>(admin_cap.admin_cap_id_for_testing());
    fixture.grant_role<Role<RiskAdmin>>(admin_cap.admin_cap_id_for_testing());

    assert_eq!(fixture.acl.admin_roles_for_testing(admin_cap.admin_cap_id_for_testing()).length(), 2);

    destroy(admin_cap);
    destroy(fixture);
}

#[test]
fun revoking_an_admin_reports_every_role_it_held() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    fixture.revoke_admin(admin_cap_id);
    let revoked = events::collect_one<events::AdminRevoked>(0);
    let (revoked_cap_id, roles) = revoked.admin_revoked_fields();

    assert_eq!(revoked_cap_id, admin_cap_id);
    assert_eq!(
        roles,
        vector[type_name::with_defining_ids<FeeAdmin>(), type_name::with_defining_ids<RiskAdmin>()],
    );
    assert_eq!(fixture.acl.admin_count_for_testing(), 0);

    destroy(admin_cap);
    destroy(fixture);
}

#[test]
fun destroying_live_and_revoked_caps_reports_their_previous_state() {
    let mut fixture = start();
    let live_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    fixture.grant_admin(OTHER_ADMIN);
    let revoked_cap = fixture.take_admin_cap(OTHER_ADMIN);
    let live_cap_id = live_cap.admin_cap_id_for_testing();
    let revoked_cap_id = revoked_cap.admin_cap_id_for_testing();
    fixture.revoke_admin(revoked_cap_id);

    fixture.acl.destroy_admin_cap(live_cap);
    let live = events::collect_one<events::AdminDestroyed>(0);
    let (live_id, live_roles, live_was_active) = live.admin_destroyed_fields();
    fixture.scenario.next_tx(OTHER_ADMIN);
    fixture.acl.destroy_admin_cap(revoked_cap);
    let revoked = events::collect_one<events::AdminDestroyed>(0);
    let (revoked_id, revoked_roles, revoked_was_active) = revoked.admin_destroyed_fields();

    assert_eq!(live_id, live_cap_id);
    assert_eq!(live_roles.length(), 2);
    assert!(live_was_active);
    assert_eq!(revoked_id, revoked_cap_id);
    assert!(revoked_roles.is_empty());
    assert!(!revoked_was_active);
    assert_eq!(fixture.acl.admin_count_for_testing(), 0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_roleless_admin_signs_in_to_nothing() {
    let mut fixture = start();
    fixture.grant_admin(ADMIN);
    let admin_cap = fixture.take_admin_cap(ADMIN);

    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun an_admin_cannot_sign_in_to_a_role_it_does_not_hold() {
    let mut fixture = start();
    fixture.grant_admin(ADMIN);
    let admin_cap = fixture.take_admin_cap(ADMIN);
    fixture.grant_role<RiskAdmin>(admin_cap.admin_cap_id_for_testing());

    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun a_revoked_role_no_longer_signs_in() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    fixture.revoke_role<FeeAdmin>(admin_cap.admin_cap_id_for_testing());

    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleAlreadyGranted, location = blast_admin::blast_acl)]
fun granting_a_held_role_aborts() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);

    fixture.grant_role<FeeAdmin>(admin_cap.admin_cap_id_for_testing());

    abort
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun revoking_an_absent_role_aborts() {
    let mut fixture = start();
    fixture.grant_admin(ADMIN);
    let admin_cap = fixture.take_admin_cap(ADMIN);

    fixture.revoke_role<FeeAdmin>(admin_cap.admin_cap_id_for_testing());

    abort
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleCapacityReached, location = blast_admin::blast_acl)]
fun grant_role_rejects_the_first_role_over_capacity() {
    let mut fixture = start();
    fixture.grant_admin(ADMIN);
    let admin_cap = fixture.take_admin_cap(ADMIN);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    fixture.grant_thirty_two_roles(admin_cap_id);

    fixture.grant_role<FeeAdmin>(admin_cap_id);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
fun grant_role_rejects_an_unknown_cap() {
    let mut fixture = start();

    fixture.grant_role<FeeAdmin>(object::id_from_address(@0xDEAD));

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
fun revoke_role_rejects_an_unknown_cap() {
    let mut fixture = start();

    fixture.revoke_role<FeeAdmin>(object::id_from_address(@0xDEAD));

    abort
}

#[test]
#[expected_failure(abort_code = errors::EAdminCapacityReached, location = blast_admin::blast_acl)]
fun grant_rejects_the_first_admin_over_capacity() {
    let mut fixture = start();
    MAX_ADMINS.do!(|_| fixture.grant_admin(ADMIN));

    fixture.grant_admin(ADMIN);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminRecipient, location = blast_admin::blast_acl)]
fun grant_rejects_the_zero_recipient_before_capacity() {
    let mut fixture = start();
    MAX_ADMINS.do!(|_| fixture.grant_admin(ADMIN));

    fixture.grant_admin(@0x0);

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
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    fixture.revoke_admin(admin_cap.admin_cap_id_for_testing());

    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
fun cap_from_another_acl_cannot_sign_in() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    let (_other_root, other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    let _: AdminWitness<FeeAdmin> = other_acl.sign_in(&admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::blast_acl)]
fun root_cap_from_another_acl_cannot_grant() {
    let mut fixture = start();
    let (other_root, _other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    fixture.acl.grant_admin(&other_root, ADMIN, fixture.scenario.ctx());

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::blast_acl)]
fun root_cap_from_another_acl_cannot_grant_a_role() {
    let mut fixture = start();
    fixture.grant_admin(ADMIN);
    let admin_cap = fixture.take_admin_cap(ADMIN);
    let (other_root, _other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    fixture.acl.grant_role<FeeAdmin>(&other_root, admin_cap.admin_cap_id_for_testing());

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::blast_acl)]
fun root_cap_from_another_acl_cannot_revoke_a_role() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
    let (other_root, _other_acl) = blast_acl::new_for_testing(fixture.scenario.ctx());

    fixture.acl.revoke_role<FeeAdmin>(&other_root, admin_cap.admin_cap_id_for_testing());

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_admin::blast_acl)]
fun root_cap_from_another_acl_cannot_revoke() {
    let mut fixture = start();
    let admin_cap = fixture.start_admin_with_fee_and_risk(ADMIN);
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

fun start_admin_with_fee_and_risk(self: &mut Fixture, owner: address): AdminCap {
    self.grant_admin(owner);
    let admin_cap = self.take_admin_cap(owner);
    self.grant_role<FeeAdmin>(admin_cap.admin_cap_id_for_testing());
    self.grant_role<RiskAdmin>(admin_cap.admin_cap_id_for_testing());
    admin_cap
}

fun grant_admin(self: &mut Fixture, recipient: address) {
    let Fixture { scenario, acl, root } = self;
    acl.grant_admin(root, recipient, scenario.ctx());
}

fun revoke_admin(self: &mut Fixture, admin_cap_id: ID) {
    let Fixture { acl, root, .. } = self;
    acl.revoke_admin(root, admin_cap_id);
}

fun grant_role<Role>(self: &mut Fixture, admin_cap_id: ID) {
    let Fixture { acl, root, .. } = self;
    acl.grant_role<Role>(root, admin_cap_id);
}

fun revoke_role<Role>(self: &mut Fixture, admin_cap_id: ID) {
    let Fixture { acl, root, .. } = self;
    acl.revoke_role<Role>(root, admin_cap_id);
}

fun take_admin_cap(self: &mut Fixture, owner: address): AdminCap {
    self.scenario.next_tx(owner);
    self.scenario.take_from_sender<AdminCap>()
}

/// Fills one administrator to capacity with 32 distinct role types.
fun grant_thirty_two_roles(self: &mut Fixture, admin_cap_id: ID) {
    self.grant_eight_roles<u8>(admin_cap_id);
    self.grant_eight_roles<u16>(admin_cap_id);
    self.grant_eight_roles<u32>(admin_cap_id);
    self.grant_eight_roles<u64>(admin_cap_id);
}

fun grant_eight_roles<T>(self: &mut Fixture, admin_cap_id: ID) {
    self.grant_role<Role<Role<T>>>(admin_cap_id);
    self.grant_role<Role<Role<Role<T>>>>(admin_cap_id);
    self.grant_role<Role<vector<T>>>(admin_cap_id);
    self.grant_role<Role<vector<vector<T>>>>(admin_cap_id);
    self.grant_role<Role<Role<vector<T>>>>(admin_cap_id);
    self.grant_role<Role<vector<Role<T>>>>(admin_cap_id);
    self.grant_role<Role<T>>(admin_cap_id);
    self.grant_role<vector<Role<T>>>(admin_cap_id);
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, ACL, AdminCap, AdminWitness, SuperAdminCap},
    blast_admin_events as events,
    errors,
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::test_scenario::{Self, Scenario};
