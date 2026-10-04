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
/// The accepted AdminCap authorizes the exact digest under the sealed dependency-only policy. The
/// cap names a fixed non-zero package: the framework reads package `0x0` as an authorization
/// already in flight, and this package's ID is `0x0` until `Published.toml` assigns one.
fun the_admin_cap_reaches_the_sealed_upgrade_cap() {
    let mut ctx = tx_context::dummy();
    let package = @0xB1A57.to_id();
    let upgrade_cap = sui::package::test_publish(package, &mut ctx);
    let mut package_admin = package_admin::seal_any_dependency_only_for_testing(
        upgrade_cap,
        &mut ctx,
    );
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);

    let ticket = package_admin.authorize_upgrade(&admin_registry, &admin_cap, DIGEST);

    assert_eq!(ticket.ticket_package(), package);
    assert_eq!(ticket.ticket_policy(), sui::package::dep_only_policy());
    assert_eq!(*ticket.ticket_digest(), DIGEST);

    destroy(ticket);
    package_admin.destroy_for_testing();
    destroy(admin_registry);
    destroy(admin_cap);
    destroy(ctx);
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::EInvalidAdminCap,
    location = blast_presale::blast_presale_admin,
)]
/// An AdminCap the registry no longer accepts cannot authorize an upgrade.
fun a_replaced_admin_cap_cannot_authorize_an_upgrade() {
    let mut ctx = tx_context::dummy();
    let upgrade_cap = presale_upgrade_cap(&mut ctx);
    let mut package_admin = package_admin::seal_dependency_only_for_testing(upgrade_cap, &mut ctx);
    let (admin_registry, _accepted_admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let (_other_registry, stale_admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);

    let ticket = package_admin.authorize_upgrade(&admin_registry, &stale_admin_cap, DIGEST);
    destroy(ticket);
    abort
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

// === Imports ===

use blast_presale::{blast_presale_admin, package_admin::{Self, PackageAdmin}};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::package::UpgradeCap;
