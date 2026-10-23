// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast ACL-governed native Publisher/UpgradeCap custody, with explicit new-bytecode operational activation.
module blast_market_maker::package_admin;

// === Public Types ===

public struct BlastMarketMakerAdmin has key {
    id: UID,
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    activated_native_version: u64,
}

// === Public Functions ===

/// Consumes publication bootstrap and seals the Publisher/UpgradeCap in shared custody.
/// Creates and shares the initial operational version; no capability or owned admin escapes.
public fun activate_and_share_package(bootstrap: Bootstrap, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    let (
        publisher,
        initial_generation,
        treasury_id,
        policy_id,
    ) = bootstrap.destroy_bootstrap();
    assert!(publisher.from_module<BLAST_MARKET_MAKER>(), EWrongPublisher);
    assert!(
        upgrade_cap.package().to_address() == std::type_name::original_id<BLAST_MARKET_MAKER>(),
        EWrongUpgradeCap,
    );
    assert!(upgrade_cap.version() == 1, EAlreadyUpgraded);
    assert!(upgrade_cap.policy() == sui::package::compatible_policy(), ERestrictedUpgradePolicy);
    let id = object::new(ctx);
    let package_admin_id = id.to_inner();
    let upgrade_cap_id = object::id(&upgrade_cap);

    transfer::share_object(BlastMarketMakerAdmin {
        id,
        publisher,
        upgrade_cap,
        activated_native_version: 1,
    });
    package_version::create_and_share_version(initial_generation, treasury_id, policy_id, package_admin_id, ctx);
    sui::event::emit(BlastUpgradeCustodySealed { package_admin_id, upgrade_cap_id });
}

public fun authorize_upgrade(
    self: &mut BlastMarketMakerAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    version: &PackageVersion,
    digest: vector<u8>,
): UpgradeTicket {
    version.assert_package_admin(self.id.to_inner());
    assert!(digest.length() == 32, EInvalidDigest);
    let policy = self.upgrade_cap.policy();

    self.upgrade_cap.authorize(policy, digest)
}

/// Old active bytecode commits the native receipt without changing operational generation.
/// If the installed build has the wrong generation constant, the old build can authorize repair.
public fun commit_upgrade(
    self: &mut BlastMarketMakerAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    version: &PackageVersion,
    receipt: UpgradeReceipt,
) {
    version.assert_package_admin(self.id.to_inner());

    self.upgrade_cap.commit(receipt);
    sui::event::emit(BlastNativeUpgradeCommitted {
        package_admin_id: self.id.to_inner(),
        native_version: self.upgrade_cap.version(),
    });
}

/// Invoke through the newly installed bytecode. Its compiled generation must be the next one.
public fun activate_generation(
    self: &mut BlastMarketMakerAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    version: &mut PackageVersion,
) {
    self.assert_activation_authority(version);
    version.activate_generation();
    self.activated_native_version = self.upgrade_cap.version();
}

// === Private Functions ===

fun assert_activation_authority(self: &BlastMarketMakerAdmin, version: &PackageVersion) {
    version.assert_activation_custody(self.id.to_inner());
    assert!(self.upgrade_cap.version() > self.activated_native_version, ENoCommittedUpgrade);
}

// === Test-Only Functions ===

/// Native tests need a nonzero-origin cap: the all-zero unit-test package is not upgradeable.
#[test_only]
public fun new_for_testing(upgrade_cap: UpgradeCap, ctx: &mut TxContext): BlastMarketMakerAdmin {
    let publisher = sui::package::claim(
        sui::test_utils::create_one_time_witness<BLAST_MARKET_MAKER>(),
        ctx,
    );

    let activated_native_version = upgrade_cap.version();
    BlastMarketMakerAdmin {
        id: object::new(ctx),
        publisher,
        upgrade_cap,
        activated_native_version,
    }
}

/// Uses the exact production authority/fresh-native guard with a simulated newly compiled constant.
#[test_only]
public fun activate_generation_for_testing(
    self: &mut BlastMarketMakerAdmin,
    _: &AdminWitness<UpgradeAdmin>,
    version: &mut PackageVersion,
    compiled_generation: u64,
) {
    self.assert_activation_authority(version);
    version.activate_generation_for_testing(compiled_generation);
    self.activated_native_version = self.upgrade_cap.version();
}

// === Events ===

public struct BlastNativeUpgradeCommitted has copy, drop {
    package_admin_id: ID,
    native_version: u64,
}

public struct BlastUpgradeCustodySealed has copy, drop {
    package_admin_id: ID,
    upgrade_cap_id: ID,
}

// === Errors ===

#[error(code = 0)]
const EWrongPublisher: vector<u8> = b"The Publisher belongs to a different package.";
#[error(code = 1)]
const EWrongUpgradeCap: vector<u8> =
    b"The native UpgradeCap belongs to a different original package.";
#[error(code = 2)]
const EAlreadyUpgraded: vector<u8> =
    b"Custody intake requires the original native version-one cap.";
#[error(code = 3)]
const ERestrictedUpgradePolicy: vector<u8> =
    b"Only native compatible upgrade policy supports operational cutover.";
#[error(code = 4)]
const EInvalidDigest: vector<u8> = b"A native package digest must contain exactly 32 bytes.";

#[error(code = 5)]
const ENoCommittedUpgrade: vector<u8> = b"Activation requires a newly committed native upgrade.";

// === Imports ===

use blast_market_maker::{
    blast_market_maker::BLAST_MARKET_MAKER,
    package_version::{
        Self,
        BlastMarketMakerBootstrap as Bootstrap,
        BlastMarketMakerVersion as PackageVersion,
    },
    blast_market_maker_domain::UpgradeAdmin,
};
use blast_admin::blast_acl::AdminWitness;
use sui::package::{Publisher, UpgradeCap, UpgradeTicket, UpgradeReceipt};
