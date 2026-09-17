#[test_only]
/// Focused wiring tests for the Launchpad-owned shared administration domain.
///
/// The complete reusable ACL matrix belongs to `blast_admin`. These tests prove
/// only that Launchpad creates exactly one typed domain from its own constants,
/// exports one role, and keeps generic administration role-free.
module blast_fun::blast_fun_domain_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// The live shared authority exactly as production initialization left it, plus
/// one delivered administrator.
public struct DomainFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    super_admin_cap: SuperAdminCap<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
}

// === Tests ===

#[test]
fun init_creates_one_launchpad_authority_with_its_module_constants() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(ROOT, |f| {
        assert_eq!(f.authority.max_admins_for_testing(), MAX_ADMINS);
        assert_eq!(
            f.authority.root_transfer_delay_ms_for_testing(),
            ROOT_TRANSFER_DELAY_MS,
        );
        assert_eq!(
            f.authority.active_super_admin_cap_id_for_testing(),
            f.super_admin_cap.super_admin_cap_id_for_testing(),
        );
    });

    fixture.end();
}

#[test]
fun package_admin_role_is_the_single_exported_launchpad_role_bit() {
    let role = blast_fun_domain::package_admin_role();

    assert_eq!(role, 1);
    assert!(role != 0 && role & (role - 1) == 0);
}

#[test]
fun a_zero_role_administrator_signs_in_for_generic_administration() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        assert_eq!(witness.roles_for_testing(), 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun a_zero_role_administrator_cannot_assert_the_package_admin_role() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        witness.assert_role(blast_fun_domain::package_admin_role());
    });

    fixture.end();
}

#[test]
fun a_package_administrator_remains_an_active_generic_administrator() {
    let mut fixture = start_with_roles(blast_fun_domain::package_admin_role());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        assert_eq!(witness.roles_for_testing(), blast_fun_domain::package_admin_role());
        witness.assert_role(blast_fun_domain::package_admin_role());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
fun a_revoked_administrator_can_no_longer_sign_in() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(ROOT, |f| {
        let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();

        f.authority.revoke_admin(&f.super_admin_cap, admin_cap_id);
    });

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        destroy(witness);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun domain_next_tx(
    $fixture: &mut DomainFixture,
    $sender: address,
    $fn: |&mut DomainFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

/// Runs production initialization, then delivers one administrator to ADMIN.
fun start_with_roles(roles: u64): DomainFixture {
    let mut scenario = test_scenario::begin(ROOT);
    blast_fun_domain::init_for_testing(scenario.ctx());

    scenario.next_tx(ROOT);
    let mut authority = scenario.take_shared<Authority<BLAST_FUN_DOMAIN>>();
    let super_admin_cap = scenario.take_from_sender<SuperAdminCap<BLAST_FUN_DOMAIN>>();
    authority.grant_admin(&super_admin_cap, roles, ADMIN, scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    DomainFixture { scenario, authority, super_admin_cap, admin_cap }
}

fun domain_sign_in(self: &DomainFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun domain_end(self: DomainFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Authority, SuperAdminCap, AdminCap, AdminWitness};

use blast_fun::blast_fun_domain::{Self, BLAST_FUN_DOMAIN};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};

use fun domain_end as DomainFixture.end;

use fun domain_next_tx as DomainFixture.next_tx;

use fun domain_sign_in as DomainFixture.sign_in;
