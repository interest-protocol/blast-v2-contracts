// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed custody for the migrators package's Publisher and UpgradeCap.
///
/// Migrators shares the Launchpad administration domain, so its governed
/// transitions accept `AdminWitness<BLAST_FUN_DOMAIN>` and assert the role that
/// Launchpad exports. Custody itself stays package-local: advancing Migrators
/// leaves Launchpad and Distributor on their own generations.
module blast_fun_migrators::package_admin;

// === Errors ===

#[error(code = 0)]
const EInvalidPackagePublisher: vector<u8> =
    b"Publisher must be claimed by the canonical migrators package module.";

// === Public Types ===

/// Shared custody for this package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_FUN_MIGRATORS>,
}

// === Public Functions ===

/// Validates and permanently seals the migrators Publisher and raw UpgradeCap.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    // from_module compares both the package address and the canonical module name.
    assert!(publisher.from_module<BLAST_FUN_MIGRATORS>(), EInvalidPackagePublisher);

    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_FUN_MIGRATORS>(id.to_inner(), publisher, upgrade_cap);

    transfer::share_object(PackageAdmin { id, custody });
}

/// Authorizes the exact package digest under the sealed cap's compatible policy.
///
/// No path narrows that policy: every upgrade commits through `commit_upgrade_and_advance`,
/// whose new bytecode must compile the next generation constants.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
    admin_witness.assert_role(blast_fun_domain::package_admin_role());
    let custodian_id = self.id.to_inner();

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the native receipt and advances one operational generation at once.
///
/// Every commit advances, so each upgrade must bump both constants in `package_version`: bytecode
/// that still compiles the old generation fails every generation check, `authorize_upgrade`
/// included, and would freeze the package.
public fun commit_upgrade_and_advance(
    self: &mut PackageAdmin,
    package_version: &mut PackageVersion,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    receipt: UpgradeReceipt,
) {
    admin_witness.assert_role(blast_fun_domain::package_admin_role());
    package_version.assert_next();
    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    package_version.advance();
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_FUN_MIGRATORS>(
        id.to_inner(),
        blast_fun_migrators::blast_fun_migrators::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_FUN_MIGRATORS>().to_id(),
            ctx,
        ),
    );

    PackageAdmin { id, custody }
}

#[test_only]
public fun id_for_testing(self: &PackageAdmin): ID {
    self.id.to_inner()
}

// === Imports ===

use blast_admin::{
    acl::AdminWitness,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_fun::blast_fun_domain::{Self, BLAST_FUN_DOMAIN};

use blast_fun_migrators::{blast_fun_migrators::BLAST_FUN_MIGRATORS, package_version::PackageVersion};

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
