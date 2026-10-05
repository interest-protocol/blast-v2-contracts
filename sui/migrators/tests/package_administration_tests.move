// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Focused tests for the migrators package's own generation and sealed custody.
///
/// The reusable ACL, generation, and custody matrices belong to `blast_admin`.
/// These tests prove only that Migrators owns state independent of Launchpad,
/// gates its mutations on its own generation, and takes Launchpad's
/// upgrade-admin role for its own custody.
module blast_fun_migrators::package_administration_tests;

// === Test-Only Types ===

/// This package's own generation, custody, and LP-fee policy.
public struct AdminFixtureState {
    scenario: Scenario,
    package_version: PackageVersion,
    package_admin: PackageAdmin,
    policy: LpFeePolicy,
}

// === Tests ===

#[test]
/// Migrators starts at its own generation one, independent of Launchpad's.
fun the_package_owns_one_independent_operational_generation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
/// Advancing Migrators alone does not touch any other package's generation.
fun advancing_this_package_leaves_its_own_container_at_the_next_generation() {
    let mut fixture = start();

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
/// A Launchpad role witness cannot make a stale Migrators generation succeed.
fun a_stale_generation_rejects_an_lp_fee_policy_change() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();
        f.package_version.set_for_testing(2);

        f.policy.set_default_shares(&f.package_version, &admin_witness, bps::new(1), bps::new(2));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A retired generation cannot authorize an upgrade, even with the upgrade-admin role.
fun a_stale_generation_rejects_upgrade_authorization() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_version.set_for_testing(2);

        let ticket = f.package_admin.authorize_upgrade(&f.package_version, &admin_witness, DIGEST);
        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::package::EAlreadyAuthorized, location = sui::package)]
/// Launchpad's upgrade-admin role reaches this package's sealed UpgradeCap. A unit-test cap
/// belongs to package `0x0`, which the framework reads as an authorization already in flight, so
/// reaching the cap shows as the framework's own abort.
fun the_launchpad_upgrade_admin_reaches_this_packages_upgrade_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();

        let ticket = f.package_admin.authorize_upgrade(&f.package_version, &admin_witness, DIGEST);
        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidPackagePublisher,
    location = blast_admin::upgrade_custody,
)]
/// Custody accepts only this package's Publisher, not Launchpad's or any other package's.
fun a_publisher_from_another_package_cannot_seal_the_package_custody() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| f.wrap_with_foreign_package_publisher());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// The upgrade finalizer checks the generation before it touches the receipt.
fun commit_checks_the_generation_before_the_receipt() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();
        let receipt = f.foreign_receipt();
        f.package_version.set_for_testing(5);

        f.package_admin.commit_upgrade_and_advance(&mut f.package_version, &admin_witness, receipt);
    });

    fixture.end();
}

// === Test Helpers ===

macro fun admin_next_tx(
    $fixture: &mut AdminFixtureState,
    $sender: address,
    $fn: |&mut AdminFixtureState|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): AdminFixtureState {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());

    AdminFixtureState { scenario, package_version, package_admin, policy }
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin> {
    blast_acl::witness_for_testing()
}

/// A native receipt for another package: the unit-test build places this package at `0x0`, which
/// the framework cannot authorize, so no receipt can match the custodied cap here.
fun foreign_receipt(self: &mut AdminFixtureState): UpgradeReceipt {
    let mut cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), self.scenario.ctx());
    let receipt = cap.authorize_upgrade(package::compatible_policy(), DIGEST).test_upgrade();
    destroy(cap);

    receipt
}

/// Wraps this package's UpgradeCap with a Publisher claimed from a Launchpad module.
fun wrap_with_foreign_package_publisher(self: &mut AdminFixtureState) {
    let ctx = self.scenario.ctx();
    let publisher = package::test_claim(bps::new(0), ctx);
    let upgrade_cap = package::test_publish(
        type_name::original_id<BLAST_FUN_MIGRATORS>().to_id(),
        ctx,
    );

    package_admin::wrap(publisher, upgrade_cap, ctx);
}

fun admin_end(self: AdminFixtureState) {
    destroy(self);
}

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const OTHER_PACKAGE_ID: address = @0xBAD;

/// Any 32-byte package digest; custody rejects every other length before the cap is reached.
const DIGEST: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000000";

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_fun::{blast_fun_domain::{FeeAdmin, UpgradeAdmin}, bps};

use blast_fun_migrators::{
    blast_fun_migrators::{Self as package_version, BLAST_FUN_MIGRATORS, PackageVersion},
    lp_fee_policy::{Self, LpFeePolicy},
    package_admin::{Self, PackageAdmin},
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{package::{Self, UpgradeReceipt}, test_scenario::{Self, Scenario}};

use fun admin_end as AdminFixtureState.end;

use fun admin_next_tx as AdminFixtureState.next_tx;
