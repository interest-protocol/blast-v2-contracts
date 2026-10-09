// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::package_admin_tests;

// === Constants ===

const DIGEST: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000001";

// === Tests ===

#[test]
/// Sealing narrows the cap to dependency-only upgrades, so presale logic can never change.
fun sealing_restricts_upgrades_to_dependency_relinks() {
    let mut ctx = tx_context::dummy();
    let upgrade_cap = presale_upgrade_cap(&mut ctx);
    let package_admin = package_admin::seal_dependency_only_for_testing(upgrade_cap, &mut ctx);

    assert_eq!(package_admin.policy_for_testing(), sui::package::dep_only_policy());

    package_admin.destroy_for_testing();
    destroy(ctx);
}

#[test]
/// The upgrade administrator authorizes the exact digest under the sealed dependency-only policy. The
/// cap names a fixed non-zero package: the framework reads package `0x0` as an authorization
/// already in flight, and this package's ID is `0x0` until `Published.toml` assigns one.
fun the_upgrade_admin_reaches_the_sealed_upgrade_cap() {
    let mut ctx = tx_context::dummy();
    let package = @0xB1A57.to_id();
    let upgrade_cap = sui::package::test_publish(package, &mut ctx);
    let mut package_admin = package_admin::seal_any_dependency_only_for_testing(
        upgrade_cap,
        &mut ctx,
    );

    let ticket = package_admin.authorize_upgrade(&upgrade_admin(), DIGEST);

    assert_eq!(ticket.ticket_package(), package);
    assert_eq!(ticket.ticket_policy(), sui::package::dep_only_policy());
    assert_eq!(*ticket.ticket_digest(), DIGEST);

    destroy(ticket);
    package_admin.destroy_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(
    abort_code = package_admin::EInvalidUpgradeCap,
    location = blast_presale::package_admin,
)]
/// Custody accepts only this package's UpgradeCap, not one for another package.
fun a_foreign_upgrade_cap_cannot_be_sealed() {
    let mut ctx = tx_context::dummy();
    let upgrade_cap = sui::package::test_publish(@0xF0E.to_id(), &mut ctx);

    package_admin::wrap(upgrade_cap, &mut ctx);
    abort
}

// === Test Helpers ===

/// The never-upgraded UpgradeCap publication returns for this package.
fun presale_upgrade_cap(ctx: &mut TxContext): UpgradeCap {
    sui::package::test_publish(type_name::original_id<PackageAdmin>().to_id(), ctx)
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_presale::{blast_presale_domain::UpgradeAdmin, package_admin::{Self, PackageAdmin}};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::package::UpgradeCap;
