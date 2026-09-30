// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed custody for the presale package's Publisher and dependency-only UpgradeCap.
///
/// Bluefin and Cetus gate callers by their own package version, so a presale linked to a
/// retired venue generation could never migrate or collect fees again. Custody keeps the
/// package relinkable, and `wrap` narrows the cap to dependency-only upgrades in the same call
/// that seals it: presale logic can never change, so every callable generation runs identical
/// code and needs no operational version gate.
module blast_presale::package_admin;

// === Public Types ===

/// Shared custody for this package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_PRESALE_PACKAGE>,
}

// === Public Functions ===

/// Validates and permanently seals the presale Publisher and raw UpgradeCap, restricted to
/// dependency-only upgrades.
///
/// `upgrade_custody::new` requires this package's Publisher and its never-upgraded cap, and at
/// version one `BLAST_PRESALE_PACKAGE` is the package's only one-time witness, so no other
/// module's Publisher can exist.
public fun wrap(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    let id = object::new(ctx);
    let custodian_id = id.to_inner();
    let mut custody = upgrade_custody::new<BLAST_PRESALE_PACKAGE>(
        custodian_id,
        publisher,
        upgrade_cap,
    );
    custody.restrict_to_dependency_only(custodian_id);

    transfer::share_object(PackageAdmin { id, custody });
}

/// Authorizes the exact package digest under the sealed cap's dependency-only policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
): UpgradeTicket {
    let custodian_id = self.id.to_inner();

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the native receipt into the same sealed cap that authorized it.
public fun commit_upgrade(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custodian_id = id.to_inner();
    let mut custody = upgrade_custody::new<BLAST_PRESALE_PACKAGE>(
        custodian_id,
        blast_presale::blast_presale_package::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_PRESALE_PACKAGE>().to_id(),
            ctx,
        ),
    );
    custody.restrict_to_dependency_only(custodian_id);

    PackageAdmin { id, custody }
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.custody.policy_for_testing()
}

#[test_only]
public fun destroy_for_testing(self: PackageAdmin) {
    std::unit_test::destroy(self)
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, upgrade_custody::{Self, UpgradeCustody}};

use blast_presale::{blast_presale_domain::UpgradeAdmin, blast_presale_package::BLAST_PRESALE_PACKAGE};

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
