// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The production administration path: the shared Blast ACL's root grants an administrator the
/// presale roles, and each role signs in to its own operations only.
module blast_presale::blast_presale_domain_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

const ADMIN: address = @0xAD;

const TREASURY: address = @0x7EA5;

const DIGEST: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000001";

// === Test-Only Types ===

public struct QUOTE() has drop;

public struct MIGRATOR() has drop;

public struct Fixture {
    scenario: Scenario,
    acl: ACL,
    root: SuperAdminCap,
    admin_cap: AdminCap,
}

// === Tests ===

#[test]
/// An administrator granted each presale role signs in to it and runs that role's operations.
fun each_presale_role_signs_in_to_its_own_operations() {
    let mut fixture = start();
    fixture.grant<FeeAdmin>();
    fixture.grant<TreasuryAdmin>();
    fixture.grant<ListingAdmin>();
    fixture.grant<AdapterAdmin>();
    fixture.grant<UpgradeAdmin>();
    let mut fee_policy = fee_policy::new_for_testing(fixture.scenario.ctx());
    let mut creation_policy = creation_policy::new_for_testing(fixture.scenario.ctx());
    let mut package_admin = package_admin::seal_any_dependency_only_for_testing(
        sui::package::test_publish(@0xB1A57.to_id(), fixture.scenario.ctx()),
        fixture.scenario.ctx(),
    );

    fee_policy.set_fees(
        &fixture.acl.sign_in<FeeAdmin>(&fixture.admin_cap),
        bps::new(100),
        bps::new(200),
        bps::new(300),
        bps::new(400),
    );
    fee_policy.set_destination(&fixture.acl.sign_in<TreasuryAdmin>(&fixture.admin_cap), TREASURY);
    creation_policy.set_quote_allowed<QUOTE>(
        &fixture.acl.sign_in<ListingAdmin>(&fixture.admin_cap),
        true,
    );
    creation_policy.set_migration_witness_allowed<MIGRATOR>(
        &fixture.acl.sign_in<AdapterAdmin>(&fixture.admin_cap),
        true,
    );
    let ticket = package_admin.authorize_upgrade(
        &fixture.acl.sign_in<UpgradeAdmin>(&fixture.admin_cap),
        DIGEST,
    );

    assert_eq!(fee_policy.fees(), fee_policy::protocol_fees_for_testing(100, 200, 300, 400));
    assert_eq!(fee_policy.destination(), TREASURY);
    creation_policy.assert_allowed<QUOTE, MIGRATOR>();
    assert_eq!(*ticket.ticket_digest(), DIGEST);

    destroy(ticket);
    package_admin.destroy_for_testing();
    creation_policy.destroy_for_testing();
    fee_policy.destroy_for_testing();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
/// Holding every other presale role, or the partners package's own administrator role, never
/// signs in as the presale `FeeAdmin`.
fun an_admin_without_the_presale_role_cannot_sign_in_to_it() {
    let mut fixture = start();
    fixture.grant<TreasuryAdmin>();
    fixture.grant<ListingAdmin>();
    fixture.grant<AdapterAdmin>();
    fixture.grant<RewardsAdmin>();
    fixture.grant<UpgradeAdmin>();
    fixture.grant<PartnerAdmin>();

    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&fixture.admin_cap);

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EInvalidAdminCap, location = blast_admin::blast_acl)]
/// Once the root revokes an administrator, its cap signs in to none of its presale roles.
fun a_revoked_admin_cannot_sign_in_to_a_presale_role() {
    let mut fixture = start();
    fixture.grant<FeeAdmin>();

    fixture.revoke_admin();

    let _: AdminWitness<FeeAdmin> = fixture.acl.sign_in(&fixture.admin_cap);

    abort
}

// === Test Helpers ===

/// A fresh ACL whose root has granted `ADMIN` one roleless administrator.
fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (root, mut acl) = blast_acl::new_for_testing(scenario.ctx());
    acl.grant_admin(&root, ADMIN, scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap>();

    Fixture { scenario, acl, root, admin_cap }
}

fun grant<Role>(self: &mut Fixture) {
    self.acl.grant_role<Role>(&self.root, self.admin_cap.admin_cap_id_for_testing());
}

fun revoke_admin(self: &mut Fixture) {
    self.acl.revoke_admin(&self.root, self.admin_cap.admin_cap_id_for_testing());
}

fun end(self: Fixture) {
    let Fixture { scenario, acl, root, admin_cap } = self;

    destroy(acl);
    destroy(root);
    destroy(admin_cap);
    scenario.end();
}

// === Imports ===

use blast_admin::blast_acl::{Self, ACL, AdminCap, AdminWitness, SuperAdminCap};

use blast_partners::blast_partners::PartnerAdmin;

use blast_presale::{
    blast_presale_domain::{
        AdapterAdmin,
        FeeAdmin,
        ListingAdmin,
        RewardsAdmin,
        TreasuryAdmin,
        UpgradeAdmin,
    },
    bps,
    creation_policy,
    fee_policy,
    package_admin,
};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};
