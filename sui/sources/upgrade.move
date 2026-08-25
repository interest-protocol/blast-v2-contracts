// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
/// Custodies the package UpgradeCap and authorizes exact upgrades.
module blast_fun::upgrade;

use blast_fun::{acl::AdminWitness, blast::BLAST, constants, events};
use std::type_name;
use sui::package::{Self, UpgradeCap, UpgradeReceipt, UpgradeTicket};

// === Public Structs ===

/// Shared custody for the package's unique framework UpgradeCap.
public struct UpgradeManager has key {
    id: UID,
    cap: UpgradeCap,
    admin_authorization_enabled: bool,
}

// === Public Functions ===

/// Validates and permanently wraps the raw Blast UpgradeCap in shared custody.
public fun wrap(upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    let package_id = upgrade_cap.package();
    assert!(
        package_id.to_address() == type_name::original_id<BLAST>(),
        blast_fun::errors::invalid_upgrade_cap!(),
    );

    let upgrade_cap_id = object::id(&upgrade_cap);
    let package_version = package::version(&upgrade_cap);
    let policy = upgrade_cap.policy();
    let manager = new(upgrade_cap, true, ctx);
    let manager_id = object::id(&manager);

    transfer::share_object(manager);

    events::upgrade_manager_created(
        manager_id,
        upgrade_cap_id,
        package_id,
        package_version,
        policy,
        true,
    );
}

/// Authorizes the exact package digest under the wrapped cap's current policy.
public fun authorize_upgrade(
    self: &mut UpgradeManager,
    _: &AdminWitness,
    digest: vector<u8>,
): UpgradeTicket {
    assert!(
        self.admin_authorization_enabled,
        blast_fun::errors::admin_upgrade_authorization_disabled!(),
    );
    assert!(
        digest.length() == constants::package_digest_length!(),
        blast_fun::errors::invalid_package_digest!(),
    );

    let package_id = self.cap.package();
    let package_version = self.version();
    let policy = self.cap.policy();
    let ticket = self.cap.authorize(policy, digest);

    events::upgrade_authorized(
        package_id,
        package_version,
        policy,
        *ticket.digest(),
    );

    ticket
}

/// Commits the native upgrade receipt into the same wrapped framework cap.
public fun commit_upgrade(self: &mut UpgradeManager, receipt: UpgradeReceipt) {
    let new_package_id = receipt.package();
    let previous_version = self.version();

    self.cap.commit(receipt);

    events::upgrade_committed(
        new_package_id,
        previous_version,
        self.version(),
    );
}

// === Private Functions ===

fun new(cap: UpgradeCap, admin_authorization_enabled: bool, ctx: &mut TxContext): UpgradeManager {
    UpgradeManager {
        id: object::new(ctx),
        cap,
        admin_authorization_enabled,
    }
}

fun version(self: &UpgradeManager): u64 {
    package::version(&self.cap)
}

// === Test-Only Functions ===

#[test_only]
/// Creates unshared upgrade custody around a simulated published package.
public fun new_for_testing(
    package_id: ID,
    admin_authorization_enabled: bool,
    ctx: &mut TxContext,
): UpgradeManager {
    new(
        package::test_publish(package_id, ctx),
        admin_authorization_enabled,
        ctx,
    )
}

#[test_only]
public fun upgrade_cap_id_for_testing(self: &UpgradeManager): ID {
    object::id(&self.cap)
}

#[test_only]
public fun package_id_for_testing(self: &UpgradeManager): ID {
    self.cap.package()
}

#[test_only]
public fun version_for_testing(self: &UpgradeManager): u64 {
    self.version()
}

#[test_only]
public fun policy_for_testing(self: &UpgradeManager): u8 {
    self.cap.policy()
}

#[test_only]
public fun admin_authorization_enabled_for_testing(self: &UpgradeManager): bool {
    self.admin_authorization_enabled
}
