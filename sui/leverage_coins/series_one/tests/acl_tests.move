#[test_only]
/// Stateful tests for Series1 root custody, role administration, and sign-in.
module blast_leverage_series_one::acl_tests;

use blast_leverage_series_one::{acl, constants, errors, events, package_version::{Self, PackageVersion}};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self, Scenario}};

use fun admin_end as AdminFixture.end;
use fun admin_next_tx as AdminFixture.next_tx;
use fun init_end as InitFixture.end;
use fun init_next_tx as InitFixture.next_tx;
use fun root_ctx as RootFixture.ctx;
use fun root_end as RootFixture.end;
use fun root_next_tx as RootFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const ADMIN: address = @0xAD;

// === Test-Only Types ===

/// Production initialization observed through its shared objects and delivered root cap.
public struct InitFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
}

/// Root-only administration state with no pre-created routine administrator.
public struct RootFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
}

/// One role-bearing routine administrator and its root-managed registry.
public struct AdminFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: Option<acl::AdminCap>,
}

// === Tests ===

#[test]
fun initialization_shares_singletons_and_delivers_only_root_without_events() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        assert_eq!(event::num_events(), 0);
        assert_eq!(
            f.super_admin_cap.super_admin_cap_id_for_testing(),
            f.authority.active_super_admin_cap_id_for_testing(),
        );
    });

    fixture.end();
}

#[test]
fun grant_delivers_multi_role_cap_and_emits_complete_initial_state() {
    let mut fixture = start_root();
    let roles = constants::vault_issuer_role!() + constants::risk_admin_role!();
    let granted_admin_cap_id;

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_admin(
            &f.package_version,
            &f.super_admin_cap,
            roles,
            ADMIN,
            f.ctx!(),
        );

        let granted = events::collect_one<events::AdminGranted>(0);
        let (admin_cap_id, emitted_roles, recipient) = granted.admin_granted_fields();
        assert_eq!(emitted_roles, roles);
        assert_eq!(recipient, ADMIN);
        granted_admin_cap_id = admin_cap_id;
    });

    fixture.next_tx!(ADMIN, |f| {
        let admin_cap = f.scenario.take_from_sender<acl::AdminCap>();
        assert_eq!(admin_cap.admin_cap_id_for_testing(), granted_admin_cap_id);
        assert_eq!(
            f.authority.admin_roles_for_testing(granted_admin_cap_id),
            roles,
        );
        destroy(admin_cap);
    });

    fixture.end();
}

#[test]
fun one_admin_cap_can_sign_in_to_every_assigned_role() {
    let mut fixture = start_admin(constants::all_admin_roles!());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        assert_eq!(
            witness.witness_roles_for_testing(),
            constants::all_admin_roles!(),
        );

        vector[
            constants::vault_issuer_role!(),
            constants::risk_admin_role!(),
            constants::adapter_admin_role!(),
            constants::shutdown_admin_role!(),
            constants::package_admin_role!(),
        ].do!(|role| {
            witness.assert_role(role);
        });
    });

    fixture.end();
}

#[test]
fun root_adds_and_removes_one_role_with_replay_complete_events() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_role(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
            constants::adapter_admin_role!(),
        );

        let granted = events::collect_one<events::AdminRoleGranted>(0);
        let (emitted_cap_id, role, roles_after) = granted.admin_role_granted_fields();
        assert_eq!(emitted_cap_id, admin_cap_id);
        assert_eq!(role, constants::adapter_admin_role!());
        assert_eq!(
            roles_after,
            constants::risk_admin_role!() + constants::adapter_admin_role!(),
        );
    });

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        assert_eq!(
            witness.witness_roles_for_testing(),
            constants::risk_admin_role!() + constants::adapter_admin_role!(),
        );
        witness.assert_role(constants::adapter_admin_role!());
    });

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_role(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
            constants::risk_admin_role!(),
        );

        let revoked = events::collect_one<events::AdminRoleRevoked>(0);
        let (emitted_cap_id, role, roles_after) = revoked.admin_role_revoked_fields();
        assert_eq!(emitted_cap_id, admin_cap_id);
        assert_eq!(role, constants::risk_admin_role!());
        assert_eq!(roles_after, constants::adapter_admin_role!());
    });

    fixture.end();
}

#[test]
fun removing_the_last_role_leaves_a_registered_but_inert_cap() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_role(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
            constants::risk_admin_role!(),
        );

        assert_eq!(f.authority.admin_roles_for_testing(admin_cap_id), 0);
    });

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_role(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
            constants::shutdown_admin_role!(),
        );
        assert_eq!(
            f.authority.admin_roles_for_testing(admin_cap_id),
            constants::shutdown_admin_role!(),
        );
    });

    fixture.end();
}

#[test]
fun complete_revocation_emits_the_removed_role_set() {
    let mut fixture = start_admin(constants::all_admin_roles!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_admin(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
        );

        let revoked = events::collect_one<events::AdminRevoked>(0);
        let (emitted_cap_id, previous_roles) = revoked.admin_revoked_fields();
        assert_eq!(emitted_cap_id, admin_cap_id);
        assert_eq!(previous_roles, constants::all_admin_roles!());
    });

    fixture.end();
}

#[test]
fun cap_holder_can_destroy_an_active_registration() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(ADMIN, |f| {
        f.authority.destroy_admin_cap(
            &f.package_version,
            f.admin_cap.extract(),
        );

        let destroyed = events::collect_one<events::AdminDestroyed>(0);
        let (emitted_cap_id, previous_roles, was_active) =
            destroyed.admin_destroyed_fields();
        assert_eq!(emitted_cap_id, admin_cap_id);
        assert_eq!(previous_roles, constants::risk_admin_role!());
        assert!(was_active);
    });

    fixture.end();
}

#[test]
fun cap_holder_can_destroy_a_root_revoked_cap() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_admin(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
        );
    });

    fixture.next_tx!(ADMIN, |f| {
        f.authority.destroy_admin_cap(
            &f.package_version,
            f.admin_cap.extract(),
        );

        let destroyed = events::collect_one<events::AdminDestroyed>(0);
        let (emitted_cap_id, previous_roles, was_active) =
            destroyed.admin_destroyed_fields();
        assert_eq!(emitted_cap_id, admin_cap_id);
        assert_eq!(previous_roles, 0);
        assert!(!was_active);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun witness_cannot_authorize_an_unassigned_role() {
    let mut fixture = start_admin(constants::risk_admin_role!());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        witness.assert_role(constants::adapter_admin_role!());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminRole,
    location = blast_leverage_series_one::acl,
)]
fun witness_rejects_a_composite_required_role() {
    let mut fixture = start_admin(constants::all_admin_roles!());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        witness.assert_role(
            constants::vault_issuer_role!() + constants::risk_admin_role!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleAlreadyGranted,
    location = blast_leverage_series_one::acl,
)]
fun root_cannot_grant_an_assigned_role_again() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_role(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
            constants::risk_admin_role!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun root_cannot_revoke_an_unassigned_role() {
    let mut fixture = start_admin(constants::risk_admin_role!());
    let admin_cap_id = fixture.admin_cap.borrow().admin_cap_id_for_testing();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_role(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
            constants::adapter_admin_role!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminRoles,
    location = blast_leverage_series_one::acl,
)]
fun root_cannot_grant_an_admin_without_roles() {
    let mut fixture = start_root();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_admin(
            &f.package_version,
            &f.super_admin_cap,
            0,
            ADMIN,
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminRoles,
    location = blast_leverage_series_one::acl,
)]
fun root_cannot_grant_an_admin_with_an_unknown_role_bit() {
    let mut fixture = start_root();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_admin(
            &f.package_version,
            &f.super_admin_cap,
            32,
            ADMIN,
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminRecipient,
    location = blast_leverage_series_one::acl,
)]
fun root_cannot_grant_an_admin_to_zero_address() {
    let mut fixture = start_root();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.grant_admin(
            &f.package_version,
            &f.super_admin_cap,
            constants::risk_admin_role!(),
            @0x0,
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminCapacityReached,
    location = blast_leverage_series_one::acl,
)]
fun live_admin_registry_is_bounded() {
    let mut fixture = start_root();

    fixture.next_tx!(PUBLISHER, |f| {
        let mut index = 0;
        while (index < constants::max_admins!()) {
            f.authority.grant_admin(
                &f.package_version,
                &f.super_admin_cap,
                constants::risk_admin_role!(),
                ADMIN,
                f.ctx!(),
            );
            index = index + 1;
        };
        f.authority.grant_admin(
            &f.package_version,
            &f.super_admin_cap,
            constants::risk_admin_role!(),
            ADMIN,
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidAdminCap,
    location = blast_leverage_series_one::acl,
)]
fun admin_cap_from_another_registry_is_rejected() {
    let mut fixture = start_admin(constants::risk_admin_role!());

    fixture.next_tx!(ADMIN, |f| {
        let (other_root, other_authority) =
            acl::new_protocol_for_testing(f.scenario.ctx());
        let _ = other_authority.sign_in(
            &f.package_version,
            f.admin_cap.borrow(),
        );
        destroy(other_authority);
        destroy(other_root);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun stale_version_rejects_acl_before_role_and_recipient_validation() {
    let mut fixture = start_root();

    fixture.next_tx!(PUBLISHER, |f| {
        f.package_version.set_for_testing(2);
        f.authority.grant_admin(
            &f.package_version,
            &f.super_admin_cap,
            0,
            @0x0,
            f.ctx!(),
        );
    });

    fixture.end();
}

// === Fixture Transaction Macros ===

macro fun init_next_tx($fixture: &mut InitFixture, $sender: address, $fn: |&mut InitFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun root_next_tx($fixture: &mut RootFixture, $sender: address, $fn: |&mut RootFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun admin_next_tx(
    $fixture: &mut AdminFixture,
    $sender: address,
    $fn: |&mut AdminFixture|,
) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun root_ctx($fixture: &mut RootFixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

// === Fixture Setup ===

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    acl::init_for_testing(scenario.ctx());
    package_version::init_for_testing(scenario.ctx());
    assert_eq!(event::num_events(), 0);

    scenario.next_tx(PUBLISHER);
    assert!(scenario.has_most_recent_for_sender<acl::SuperAdminCap>());
    assert!(!scenario.has_most_recent_for_sender<acl::AdminCap>());
    let authority = scenario.take_shared<acl::ProtocolAuthority>();
    let package_version = scenario.take_shared<PackageVersion>();
    let super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();

    InitFixture { scenario, package_version, authority, super_admin_cap }
}

fun start_root(): RootFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, authority) = acl::new_protocol_for_testing(scenario.ctx());

    RootFixture { scenario, package_version, authority, super_admin_cap }
}

fun start_admin(roles: u8): AdminFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        roles,
        ADMIN,
        scenario.ctx(),
    );

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    AdminFixture {
        scenario,
        package_version,
        authority,
        super_admin_cap,
        admin_cap: option::some(admin_cap),
    }
}

fun init_end(self: InitFixture) {
    let InitFixture { scenario, package_version, authority, super_admin_cap } = self;

    test_scenario::return_shared(authority);
    test_scenario::return_shared(package_version);
    destroy(super_admin_cap);
    scenario.end();
}

fun root_end(self: RootFixture) {
    destroy(self);
}

fun admin_end(self: AdminFixture) {
    destroy(self);
}
