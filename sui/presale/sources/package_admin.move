// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed custody for the presale package's dependency-only UpgradeCap.
///
/// Bluefin and Cetus gate callers by their own package version, so a presale linked to a
/// retired venue generation could never migrate or collect fees again. Custody keeps the
/// package relinkable, and `wrap` narrows the cap to dependency-only upgrades in the same call
/// that seals it: presale logic can never change, so every callable generation runs identical
/// code and needs no operational version gate.
module blast_presale::package_admin;

// === Public Types ===

/// Shared custody for this package's framework UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    upgrade_cap: UpgradeCap,
}

// === Public Functions ===

/// Restricts this package's never-upgraded UpgradeCap to dependency-only upgrades and seals it in
/// a shared `PackageAdmin`. Only the original publication's cap names this package, and requiring
/// version one proves no upgrade changed presale logic before the seal.
public fun wrap(upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    transfer::share_object(seal_dependency_only(upgrade_cap, ctx));
}

/// Authorizes the exact package digest under the sealed cap's dependency-only policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
): UpgradeTicket {
    let policy = self.upgrade_cap.policy();

    self.upgrade_cap.authorize(policy, digest)
}

/// Commits the native receipt into the same sealed cap that authorized it.
public fun commit_upgrade(
    self: &mut PackageAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    self.upgrade_cap.commit(receipt);
}

// === Private Functions ===

fun seal_dependency_only(mut upgrade_cap: UpgradeCap, ctx: &mut TxContext): PackageAdmin {
    assert!(
        upgrade_cap.package().to_address() == type_name::original_id<PackageAdmin>()
            && upgrade_cap.version() == INITIAL_VERSION,
        EInvalidUpgradeCap,
    );

    upgrade_cap.only_dep_upgrades();

    PackageAdmin { id: object::new(ctx), upgrade_cap }
}

// === Test-Only Functions ===

#[test_only]
public fun seal_dependency_only_for_testing(
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin {
    seal_dependency_only(upgrade_cap, ctx)
}

#[test_only]
/// Seals a cap for any package, so tests can authorize under a non-zero package ID whether or not
/// `Published.toml` assigns this package its published address.
public fun seal_any_dependency_only_for_testing(
    mut upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin {
    upgrade_cap.only_dep_upgrades();

    PackageAdmin { id: object::new(ctx), upgrade_cap }
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.upgrade_cap.policy()
}

#[test_only]
public fun destroy_for_testing(self: PackageAdmin) {
    std::unit_test::destroy(self)
}

// === Constants ===

/// The framework stamps a freshly published package's UpgradeCap with version one.
const INITIAL_VERSION: u64 = 1;

// === Errors ===

#[error(code = 0)]
const EInvalidUpgradeCap: vector<u8> = b"Only this package's never-upgraded UpgradeCap can be sealed.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_presale::blast_presale_domain::UpgradeAdmin;

use std::type_name;

use sui::package::{UpgradeCap, UpgradeReceipt, UpgradeTicket};
