#[test_only]
/// Focused tests for the distributor's own generation, pause order, and sealed
/// framework custody.
///
/// The reusable ACL, generation, and custody matrices belong to `blast_admin`.
/// These tests prove Distributor's wiring: its generation is independent, its
/// version check precedes its pause check, and its framework custody is
/// separate from the product `PublisherCap`.
module blast_fun_distributor::package_administration_tests;

use blast_admin::acl::{Self, Authority, SuperAdminCap, AdminCap, AdminWitness};
use blast_fun::launchpad_domain::{Self, LAUNCHPAD_DOMAIN};
use blast_fun_distributor::{
    package_admin::{Self, PackageAdmin},
    package_version::{Self, PackageVersion},
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

use fun custody_end as CustodyFixture.end;
use fun custody_next_tx as CustodyFixture.next_tx;
use fun custody_sign_in as CustodyFixture.sign_in;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// Launchpad-domain membership plus this package's generation and custody.
public struct CustodyFixture {
    scenario: Scenario,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    super_admin_cap: SuperAdminCap<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    control: PackageVersion,
    package_admin: PackageAdmin,
}

// === Tests ===

#[test]
/// Distributor starts at its own generation one, unpaused.
fun the_package_owns_one_independent_generation_and_starts_unpaused() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.control.version_for_testing(), 1);
        assert!(!f.control.paused_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale generation aborts before the pause error can be reported.
fun a_stale_generation_rejects_a_pause_change_before_the_pause_guard() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.control.set_paused(&admin_witness, true);
        f.control.set_version_for_testing(2);

        // Stale code must not be able to report the unchanged-pause error.
        f.control.set_paused(&admin_witness, true);
    });

    fixture.end();
}

#[test]
/// Generic Launchpad-domain membership is enough to pause and resume.
fun a_zero_role_launchpad_admin_pauses_and_resumes_rewards() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.control.set_paused(&admin_witness, true);
        assert!(f.control.paused_for_testing());

        f.control.set_paused(&admin_witness, false);
        assert!(!f.control.paused_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
/// Pausing is generic, but package custody still requires the exported role.
fun a_zero_role_launchpad_admin_cannot_reach_package_custody() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&f.control, &admin_witness);
    });

    fixture.end();
}

#[test]
/// Package custody stays reachable while rewards are paused, so an emergency
/// stop never blocks the upgrade that fixes it.
fun package_custody_remains_available_while_rewards_are_paused() {
    let mut fixture = start_with_roles(launchpad_domain::package_admin_role());

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.control.set_paused(&admin_witness, true);

        f.package_admin.restrict_to_additive(&f.control, &admin_witness);

        assert_eq!(f.package_admin.policy_for_testing(), sui::package::additive_policy());
        assert!(f.control.paused_for_testing());
    });

    fixture.end();
}

#[test]
/// Immutability destroys native upgrade authority and preserves the pause value.
fun package_custody_can_be_made_permanently_immutable() {
    let mut fixture = start_with_roles(launchpad_domain::package_admin_role());

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.control.set_paused(&admin_witness, true);

        f.package_admin.make_immutable(&f.control, &admin_witness);

        assert!(!f.package_admin.has_upgrade_cap());
        assert!(f.control.paused_for_testing());
        assert_eq!(f.control.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// One Launchpad revocation immediately removes Distributor pause authority.
fun a_revocation_in_the_shared_authority_blocks_pause_authority() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PUBLISHER, |f| {
        let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();

        f.authority.revoke_admin(&f.super_admin_cap, admin_cap_id);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        destroy(admin_witness);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun custody_next_tx(
    $fixture: &mut CustodyFixture,
    $sender: address,
    $fn: |&mut CustodyFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_with_roles(roles: u64): CustodyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let control = package_version::new_for_testing(scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_for_testing<LAUNCHPAD_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&super_admin_cap, roles, PROTOCOL_ADMIN, scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();

    CustodyFixture {
        scenario,
        authority,
        super_admin_cap,
        admin_cap,
        control,
        package_admin,
    }
}

fun custody_sign_in(self: &CustodyFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun custody_end(self: CustodyFixture) {
    destroy(self);
}
