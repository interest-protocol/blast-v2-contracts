// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Focused wiring tests for the core administration domain.
///
/// The complete reusable ACL matrix belongs to `blast_admin`. These tests prove
/// only that this package creates exactly one typed domain of its own, keeps
/// its four role meanings at their historical bit values, keeps generic
/// administration role-free, and cannot be reached by another product's
/// capability.
module blast_boosts_core::blast_boosts_core_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// A second, unrelated domain used to prove compile-time separation.
public struct OTHER_DOMAIN has drop {}

/// The live shared authority exactly as production initialization left it.
public struct DomainFixture {
    scenario: Scenario,
    authority: Authority<BLAST_BOOSTS_CORE>,
    super_admin_cap: SuperAdminCap<BLAST_BOOSTS_CORE>,
    admin_cap: AdminCap<BLAST_BOOSTS_CORE>,
}

// === Tests ===

#[test]
fun init_creates_one_core_authority_with_its_module_constants() {
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
/// The widened `u64` role bits keep the exact values Series1 published as `u8`.
fun the_four_core_role_bits_keep_their_historical_values() {
    assert_eq!(domain::vault_issuer_role(), 1);
    assert_eq!(domain::risk_admin_role(), 2);
    assert_eq!(domain::shutdown_admin_role(), 8);
    assert_eq!(domain::package_admin_role(), 16);
}

#[test]
/// Every exported role is a single bit and no two roles collide.
fun every_exported_core_role_is_one_distinct_bit() {
    let roles = vector[
        domain::vault_issuer_role(),
        domain::risk_admin_role(),
        domain::shutdown_admin_role(),
        domain::package_admin_role(),
    ];
    let mut seen = 0;

    roles.do!(|role| {
        assert!(role != 0 && role & (role - 1) == 0);
        assert_eq!(seen & role, 0);
        seen = seen | role;
    });

    assert_eq!(seen, 27);
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
fun a_zero_role_administrator_cannot_assert_the_vault_issuer_role() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        witness.assert_role(domain::vault_issuer_role());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun a_risk_administrator_does_not_carry_the_package_admin_role() {
    let mut fixture = start_with_roles(domain::risk_admin_role());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        witness.assert_role(domain::package_admin_role());
    });

    fixture.end();
}

#[test]
/// One capability may carry several Series1 roles at once.
fun a_multi_role_administrator_carries_every_granted_core_role() {
    let roles =
        domain::vault_issuer_role() | domain::shutdown_admin_role();
    let mut fixture = start_with_roles(roles);

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();

        assert_eq!(witness.roles_for_testing(), roles);
        witness.assert_role(domain::vault_issuer_role());
        witness.assert_role(domain::shutdown_admin_role());
    });

    fixture.end();
}

#[test]
/// A capability minted in another domain is a different type and cannot be
/// registered in, or checked against, this package's authority.
fun another_domains_capability_cannot_administer_this_package() {
    let mut fixture = start_with_roles(0);

    fixture.next_tx!(ROOT, |f| {
        let (other_root, mut other_authority) = acl::new_for_testing<OTHER_DOMAIN>(
            MAX_ADMINS,
            ROOT_TRANSFER_DELAY_MS,
            f.ctx!(),
        );
        other_authority.grant_admin(
            &other_root,
            domain::vault_issuer_role(),
            ADMIN,
            f.ctx!(),
        );

        // The foreign admin is live in its own authority, and its witness type
        // is `AdminWitness<OTHER_DOMAIN>`, which `state::new` does not take.
        assert_eq!(other_authority.max_admins_for_testing(), MAX_ADMINS);

        destroy(other_root);
        destroy(other_authority);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
fun a_revoked_administrator_can_no_longer_sign_in() {
    let mut fixture = start_with_roles(domain::vault_issuer_role());

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

// === Test Helpers ===

macro fun domain_ctx($self: &mut DomainFixture): &mut TxContext {
    let fixture = $self;

    fixture.scenario.ctx()
}

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
    domain::init_for_testing(scenario.ctx());

    scenario.next_tx(ROOT);
    let mut authority = scenario.take_shared<Authority<BLAST_BOOSTS_CORE>>();
    let super_admin_cap = scenario.take_from_sender<SuperAdminCap<BLAST_BOOSTS_CORE>>();
    authority.grant_admin(&super_admin_cap, roles, ADMIN, scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_BOOSTS_CORE>>();

    DomainFixture { scenario, authority, super_admin_cap, admin_cap }
}

fun domain_sign_in(self: &DomainFixture): AdminWitness<BLAST_BOOSTS_CORE> {
    self.authority.sign_in(&self.admin_cap)
}

fun domain_end(self: DomainFixture) {
    let DomainFixture { scenario, authority, super_admin_cap, admin_cap } = self;
    test_scenario::return_shared(authority);
    destroy(super_admin_cap);
    destroy(admin_cap);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, Authority, SuperAdminCap, AdminCap, AdminWitness};

use blast_boosts_core::blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};

use fun domain_ctx as DomainFixture.ctx;

use fun domain_end as DomainFixture.end;

use fun domain_next_tx as DomainFixture.next_tx;

use fun domain_sign_in as DomainFixture.sign_in;
