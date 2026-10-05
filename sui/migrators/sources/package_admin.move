// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed custody for the migrators package's Publisher and UpgradeCap.
///
/// Migrators shares the Launchpad's administration roles, so its governed
/// transitions take `AdminWitness<UpgradeAdmin>`, the role Launchpad declares.
/// Custody itself stays package-local: advancing Migrators leaves Launchpad on
/// its own generation.
module blast_fun_migrators::package_admin;

// === Public Types ===

/// Shared custody for this package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_FUN_MIGRATORS>,
}

// === Public Functions ===

/// Validates and permanently seals the migrators Publisher and raw UpgradeCap.
///
/// `upgrade_custody::new` requires this package's Publisher and its never-upgraded cap, and at
/// version one `BLAST_FUN_MIGRATORS` is the package's only one-time witness, so no other module's
/// Publisher can exist.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
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
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
): UpgradeTicket {
    package_version.assert_current();
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
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    package_version.assert_next();
    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    package_version.advance();
}

// === Test-Only Functions ===

#[test_only]
/// Seals this package's test Publisher and a unit-test UpgradeCap, left unshared.
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

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_fun::blast_fun_domain::UpgradeAdmin;

use blast_fun_migrators::blast_fun_migrators::{BLAST_FUN_MIGRATORS, PackageVersion};

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
