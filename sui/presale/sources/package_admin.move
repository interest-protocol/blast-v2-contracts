// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the admin's abort location.
#[allow(lint(abort_without_constant))]
/// Shared custody of this package's Publisher and UpgradeCap, driven by package administrators.
module blast_presale::package_admin;

// === Public Types ===

/// Shared custody for the package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_PRESALE_PACKAGE>,
}

// === Public Functions ===

/// Consumes publication bootstrap, seals native custody, and enables the initial generation.
public fun wrap(bootstrap: Bootstrap, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    let (publisher, generation) = bootstrap.destroy();
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_PRESALE_PACKAGE>(
        id.to_inner(),
        publisher,
        upgrade_cap,
    );

    transfer::share_object(PackageAdmin { id, custody });
    generation.share_version(ctx);
}

/// Authorizes the exact package digest under the wrapped cap's current policy.
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

/// Commits the upgrade and advances the package version together.
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
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_PRESALE_PACKAGE>(
        id.to_inner(),
        blast_presale::blast_presale_package::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_PRESALE_PACKAGE>().to_id(),
            ctx,
        ),
    );

    PackageAdmin { id, custody }
}

#[test_only]
public fun id_for_testing(self: &PackageAdmin): ID {
    self.id.to_inner()
}

#[test_only]
public fun publisher_id_for_testing(self: &PackageAdmin): ID {
    self.custody.publisher_id_for_testing()
}

#[test_only]
public fun upgrade_cap_id_for_testing(self: &PackageAdmin): ID {
    self.custody.upgrade_cap_id_for_testing()
}

#[test_only]
public fun package_id_for_testing(self: &PackageAdmin): ID {
    self.custody.current_package_id_for_testing()
}

#[test_only]
public fun version_for_testing(self: &PackageAdmin): u64 {
    self.custody.native_version_for_testing()
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.custody.policy_for_testing()
}

#[test_only]
/// Reports whether native upgrade authority remains sealed in this package's custody.
public fun has_upgrade_cap_for_testing(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    operational_version::OperationalVersion,
    upgrade_custody::{Self, UpgradeCustody}
};

use blast_presale::{
    blast_presale_domain::UpgradeAdmin,
    blast_presale_package::{BLAST_PRESALE_PACKAGE, Bootstrap, PackageVersion}
};

use sui::package::{UpgradeCap, UpgradeReceipt, UpgradeTicket};

use fun blast_presale::blast_presale_package::share_version as OperationalVersion.share_version;
