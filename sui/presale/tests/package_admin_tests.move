// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::package_admin_tests;

// === Constants ===

const DIGEST: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000001";

// === Tests ===

#[test]
/// Sealing narrows the cap to dependency-only upgrades, so presale logic can never change.
fun wrapping_restricts_upgrades_to_dependency_relinks() {
    let mut ctx = tx_context::dummy();
    let admin = package_admin::new_for_testing(&mut ctx);

    assert_eq!(admin.policy_for_testing(), sui::package::dep_only_policy());
    admin.destroy_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = sui::package::EAlreadyAuthorized, location = sui::package)]
/// The presale upgrade-admin role reaches the sealed cap. A unit-test cap belongs to package
/// `0x0`, which the framework reads as an authorization already in flight, so reaching the cap
/// shows as the framework's own abort.
fun the_upgrade_admin_reaches_the_sealed_upgrade_cap() {
    let mut ctx = tx_context::dummy();
    let mut admin = package_admin::new_for_testing(&mut ctx);

    let ticket = admin.authorize_upgrade(&blast_acl::witness_for_testing<UpgradeAdmin>(), DIGEST);
    destroy(ticket);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidPackagePublisher,
    location = blast_admin::upgrade_custody,
)]
/// Custody accepts only this package's Publisher, here one claimed for `std::string`.
fun a_foreign_publisher_cannot_seal_the_package_custody() {
    let mut ctx = tx_context::dummy();
    let publisher = sui::package::test_claim(b"".to_string(), &mut ctx);
    let upgrade_cap = sui::package::test_publish(
        std::type_name::original_id<BLAST_PRESALE_PACKAGE>().to_id(),
        &mut ctx,
    );

    package_admin::wrap(publisher, upgrade_cap, &mut ctx);
    abort
}

// === Imports ===

use blast_admin::blast_acl;

use blast_presale::{
    blast_presale_domain::UpgradeAdmin,
    blast_presale_package::BLAST_PRESALE_PACKAGE,
    package_admin,
};

use std::unit_test::{assert_eq, destroy};
