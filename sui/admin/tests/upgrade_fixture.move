// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Minimal consumer wrapper proving the shared custody/version composition boundary.
module blast_admin::upgrade_fixture;

// === Constants ===

const COMPILED_GENERATION: u64 = 1;

// === Test-Only Types ===

public struct UpgradeAdmin()

public struct PackageAdmin has key {
    id: UID,
    operational_version: operational_version::OperationalVersion<package_marker::PACKAGE_MARKER>,
    custody: upgrade_custody::UpgradeCustody<package_marker::PACKAGE_MARKER>,
}

// === Test Helpers ===

public fun new(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin {
    assert!(
        publisher.from_module<package_marker::PACKAGE_MARKER>(),
        blast_admin::errors::invalid_package_publisher!(),
    );

    let id = object::new(ctx);
    let custodian_id = id.to_inner();
    let custody = upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        custodian_id,
        publisher,
        upgrade_cap,
    );

    PackageAdmin {
        id,
        operational_version: operational_version::new(&package_marker::marker()),
        custody,
    }
}

public fun authorize_upgrade(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
): UpgradeTicket {
    self.operational_version.assert_current(COMPILED_GENERATION);
    let custodian_id = self.id.to_inner();
    self.custody.authorize_upgrade(custodian_id, digest)
}

public fun commit_and_advance(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
    next_compiled_generation: u64,
) {
    self.operational_version.assert_next(next_compiled_generation);
    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    self.operational_version.advance(&self.id, next_compiled_generation);
}

public fun custodian_id(self: &PackageAdmin): ID {
    self.id.to_inner()
}

public fun custody(self: &PackageAdmin): &upgrade_custody::UpgradeCustody<package_marker::PACKAGE_MARKER> {
    &self.custody
}

public fun generation(self: &PackageAdmin): u64 {
    self.operational_version.generation_for_testing()
}

public fun set_generation(self: &mut PackageAdmin, generation: u64) {
    self.operational_version.set_generation_for_testing(generation);
}

// === Imports ===

use 0xa::package_marker;

use blast_admin::{blast_acl::AdminWitness, operational_version, upgrade_custody};

use sui::package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
