#[test_only]
/// Focused tests for the migrators package's own generation and sealed custody.
///
/// The reusable ACL, generation, and custody matrices belong to `blast_admin`.
/// These tests prove only that Migrators owns state independent of Launchpad,
/// gates its mutations on its own generation, and reuses the Launchpad domain
/// for membership and the exported package-admin role.
module blast_fun_migrators::package_administration_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// Launchpad-domain membership plus this package's own generation and custody.
public struct AdminFixtureState {
    scenario: Scenario,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    super_admin_cap: SuperAdminCap<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    package_version: PackageVersion,
    package_admin: PackageAdmin,
    config: VenueConfig,
}

// === Tests ===

#[test]
/// Migrators starts at its own generation one, independent of Launchpad's.
fun the_package_owns_one_independent_operational_generation() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
/// Advancing Migrators alone does not touch any other package's generation.
fun advancing_this_package_leaves_its_own_container_at_the_next_generation() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.advance_for_testing();

        assert_eq!(f.package_version.version_for_testing(), 2);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A live Launchpad witness cannot make a stale Migrators generation succeed.
fun a_stale_generation_rejects_a_venue_tier_pin() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.set_cetus_tier(&f.package_version, &admin_witness, 220, 20_000);
    });

    fixture.end();
}

#[test]
/// Generic Launchpad-domain administration needs no role in this package.
fun a_zero_role_launchpad_admin_pins_a_venue_tier() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_cetus_tier(&f.package_version, &admin_witness, 220, 20_000);

        let (tick_spacing, fee_rate) = f.config.cetus_tier_for_testing();
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
/// Package custody requires the role Launchpad exports, not mere membership.
fun a_zero_role_launchpad_admin_cannot_reach_package_custody() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);
    });

    fixture.end();
}

#[test]
/// The exported Launchpad role authorizes this package's own custody.
fun the_exported_launchpad_role_governs_this_packages_custody() {
    let mut fixture = start_with_roles(launchpad_domain::package_admin_role());

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);

        assert_eq!(f.package_admin.policy_for_testing(), sui::package::additive_policy());
        assert!(f.package_admin.has_upgrade_cap());
    });

    fixture.end();
}

#[test]
/// Immutability destroys native upgrade authority for this package only.
fun package_custody_can_be_made_permanently_immutable() {
    let mut fixture = start_with_roles(launchpad_domain::package_admin_role());

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.make_immutable(&f.package_version, &admin_witness);

        assert!(!f.package_admin.has_upgrade_cap());
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// Revoking in the Launchpad authority immediately blocks Migrators sign-in.
fun a_revocation_in_the_shared_authority_blocks_this_packages_sign_in() {
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

macro fun admin_next_tx(
    $fixture: &mut AdminFixtureState,
    $sender: address,
    $fn: |&mut AdminFixtureState|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_with_roles(roles: u64): AdminFixtureState {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_for_testing<LAUNCHPAD_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&super_admin_cap, roles, PROTOCOL_ADMIN, scenario.ctx());
    venue_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let config = scenario.take_shared<VenueConfig>();

    AdminFixtureState {
        scenario,
        authority,
        super_admin_cap,
        admin_cap,
        package_version,
        package_admin,
        config,
    }
}

fun admin_sign_in(self: &AdminFixtureState): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun admin_end(self: AdminFixtureState) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, SuperAdminCap, AdminCap, AdminWitness};

use blast_fun::launchpad_domain::{Self, LAUNCHPAD_DOMAIN};

use blast_fun_migrators::{
    cetus,
    package_admin::{Self, PackageAdmin},
    package_version::{Self, PackageVersion},
    venue_config::{Self, VenueConfig},
};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};

use fun admin_end as AdminFixtureState.end;

use fun admin_next_tx as AdminFixtureState.next_tx;

use fun admin_sign_in as AdminFixtureState.sign_in;

use fun cetus::effective_tier_for_testing as VenueConfig.cetus_tier_for_testing;

use fun cetus::set_tier as VenueConfig.set_cetus_tier;
