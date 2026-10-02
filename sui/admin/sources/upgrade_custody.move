// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// Sealed custody and native transitions for one consumer package's framework capabilities.
module blast_admin::upgrade_custody;

// === Constants ===

const PACKAGE_DIGEST_LENGTH: u64 = 32;

/// The framework stamps a freshly published package's `UpgradeCap` with version one.
const INITIAL_NATIVE_VERSION: u64 = 1;

// === Public Types ===

/// Storable custody value whose capabilities never leave it: the Publisher is readable by
/// reference and the UpgradeCap acts only through the named transitions below.
public struct UpgradeCustody<phantom PackageMarker: drop> has store {
    publisher: Publisher,
    upgrade_cap: Option<UpgradeCap>,
}

// === Public Functions ===

/// Validates an original package's Publisher and never-upgraded cap before sealing both.
public fun new<PackageMarker: drop>(
    custodian_id: ID,
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
): UpgradeCustody<PackageMarker> {
    assert!(
        publisher.from_package<PackageMarker>(),
        blast_admin::errors::invalid_package_publisher!(),
    );
    let package_id = upgrade_cap.package();
    assert!(
        package_id.to_address() == type_name::original_id<PackageMarker>()
            && upgrade_cap.version() == INITIAL_NATIVE_VERSION,
        blast_admin::errors::invalid_upgrade_cap!(),
    );

    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    let native_version = upgrade_cap.version();
    let policy = upgrade_cap.policy();
    let custody = UpgradeCustody<PackageMarker> {
        publisher,
        upgrade_cap: option::some(upgrade_cap),
    };

    blast_admin_events::upgrade_custody_created<PackageMarker>(
        custodian_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        native_version,
        policy,
    );

    custody
}

/// Reports whether native upgrade authority remains sealed in custody.
public fun has_upgrade_cap<PackageMarker: drop>(
    self: &UpgradeCustody<PackageMarker>,
): bool {
    self.upgrade_cap.is_some()
}

/// Borrows the sealed Publisher for provenance-gated framework features such as Display and
/// TransferPolicy. Every framework path that moves or burns a Publisher takes it by value, so a
/// reference cannot end custody; the consumer wrapper decides who may call this.
public fun publisher<PackageMarker: drop>(self: &UpgradeCustody<PackageMarker>): &Publisher {
    &self.publisher
}

/// Authorizes exactly one 32-byte package digest under the cap's current policy.
public fun authorize_upgrade<PackageMarker: drop>(
    self: &mut UpgradeCustody<PackageMarker>,
    custodian_id: ID,
    digest: vector<u8>,
): UpgradeTicket {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());
    assert!(
        digest.length() == PACKAGE_DIGEST_LENGTH,
        blast_admin::errors::invalid_package_digest!(),
    );

    let cap = self.upgrade_cap.borrow_mut();
    let upgrade_cap_id = object::id(cap);
    let package_id = cap.package();
    let native_version = cap.version();
    let policy = cap.policy();

    let ticket = cap.authorize(policy, digest);

    blast_admin_events::upgrade_authorized<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        package_id,
        native_version,
        policy,
        *ticket.digest(),
    );

    ticket
}

/// Commits a native receipt into the same sealed capability that authorized it.
public fun commit_upgrade<PackageMarker: drop>(
    self: &mut UpgradeCustody<PackageMarker>,
    custodian_id: ID,
    receipt: UpgradeReceipt,
) {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());

    let cap = self.upgrade_cap.borrow_mut();
    let upgrade_cap_id = object::id(cap);
    let previous_native_version = cap.version();
    let new_package_id = receipt.package();

    cap.commit(receipt);

    blast_admin_events::upgrade_committed<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        type_name::original_id<PackageMarker>(),
        new_package_id,
        previous_native_version,
        cap.version(),
    );
}

/// Irreversibly narrows compatible policy to additive-only upgrades.
public fun restrict_to_additive<PackageMarker: drop>(
    self: &mut UpgradeCustody<PackageMarker>,
    custodian_id: ID,
) {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());

    let cap = self.upgrade_cap.borrow_mut();
    let previous_policy = cap.policy();
    assert!(
        package::additive_policy() > previous_policy,
        blast_admin::errors::upgrade_policy_not_more_restrictive!(),
    );

    let upgrade_cap_id = object::id(cap);
    let native_version = cap.version();

    cap.only_additive_upgrades();

    blast_admin_events::upgrade_policy_restricted<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        type_name::original_id<PackageMarker>(),
        native_version,
        previous_policy,
        cap.policy(),
    );
}

/// Irreversibly narrows compatible or additive policy to dependency-only upgrades.
public fun restrict_to_dependency_only<PackageMarker: drop>(
    self: &mut UpgradeCustody<PackageMarker>,
    custodian_id: ID,
) {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());

    let cap = self.upgrade_cap.borrow_mut();
    let previous_policy = cap.policy();
    assert!(
        package::dep_only_policy() > previous_policy,
        blast_admin::errors::upgrade_policy_not_more_restrictive!(),
    );

    let upgrade_cap_id = object::id(cap);
    let native_version = cap.version();

    cap.only_dep_upgrades();

    blast_admin_events::upgrade_policy_restricted<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        type_name::original_id<PackageMarker>(),
        native_version,
        previous_policy,
        cap.policy(),
    );
}

/// Irreversibly destroys native upgrade authority while preserving Publisher custody.
public fun make_immutable<PackageMarker: drop>(
    self: &mut UpgradeCustody<PackageMarker>,
    custodian_id: ID,
) {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());

    let cap = self.upgrade_cap.extract();
    let upgrade_cap_id = object::id(&cap);
    let final_native_version = cap.version();
    let final_policy = cap.policy();

    package::make_immutable(cap);

    blast_admin_events::upgrade_cap_destroyed<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        type_name::original_id<PackageMarker>(),
        final_native_version,
        final_policy,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun publisher_id_for_testing<PackageMarker: drop>(
    self: &UpgradeCustody<PackageMarker>,
): ID {
    object::id(&self.publisher)
}

#[test_only]
public fun upgrade_cap_id_for_testing<PackageMarker: drop>(
    self: &UpgradeCustody<PackageMarker>,
): ID {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());
    object::id(self.upgrade_cap.borrow())
}

#[test_only]
public fun current_package_id_for_testing<PackageMarker: drop>(
    self: &UpgradeCustody<PackageMarker>,
): ID {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());
    self.upgrade_cap.borrow().package()
}

#[test_only]
public fun native_version_for_testing<PackageMarker: drop>(
    self: &UpgradeCustody<PackageMarker>,
): u64 {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());
    self.upgrade_cap.borrow().version()
}

#[test_only]
public fun policy_for_testing<PackageMarker: drop>(
    self: &UpgradeCustody<PackageMarker>,
): u8 {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());
    self.upgrade_cap.borrow().policy()
}

// === Imports ===

use blast_admin::blast_admin_events;

use std::type_name;

use sui::package::{Self, Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket};
