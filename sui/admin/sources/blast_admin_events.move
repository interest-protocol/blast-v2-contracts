// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Replay-complete typed facts for shared administration transitions.
module blast_admin::blast_admin_events;

// === Public Types ===

public struct AdminGranted has copy, drop {
    admin_cap_id: ID,
    recipient: address,
}

public struct AdminRevoked has copy, drop {
    admin_cap_id: ID,
    roles: vector<TypeName>,
}

public struct AdminRoleGranted has copy, drop {
    admin_cap_id: ID,
    role: TypeName,
}

public struct AdminRoleRevoked has copy, drop {
    admin_cap_id: ID,
    role: TypeName,
}

public struct AdminDestroyed has copy, drop {
    admin_cap_id: ID,
    roles: vector<TypeName>,
    was_active: bool,
}

public struct SuperAdminTransferStarted has copy, drop {
    recipient: address,
    execute_after_ms: u64,
}

public struct SuperAdminTransferCancelled has copy, drop {
    recipient: address,
    execute_after_ms: u64,
}

public struct SuperAdminTransferred has copy, drop {
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
}

public struct SuperAdminCapDestroyed has copy, drop {
    super_admin_cap_id: ID,
}

/// Emitted by a value that only its package's one-time witness could create; `container_id` is
/// the UID the advancing module held.
public struct OperationalVersionAdvanced<phantom PackageMarker: drop> has copy, drop {
    container_id: ID,
    package_id: address,
    previous_generation: u64,
    new_generation: u64,
}

public struct UpgradeCustodyCreated<phantom PackageMarker: drop> has copy, drop {
    custodian_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    native_version: u64,
    policy: u8,
}

public struct UpgradeAuthorized<phantom PackageMarker: drop> has copy, drop {
    custodian_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    native_version: u64,
    policy: u8,
    digest: vector<u8>,
}

public struct UpgradeCommitted<phantom PackageMarker: drop> has copy, drop {
    custodian_id: ID,
    upgrade_cap_id: ID,
    original_package_id: address,
    new_package_id: ID,
    previous_native_version: u64,
    new_native_version: u64,
}

public struct UpgradePolicyRestricted<phantom PackageMarker: drop> has copy, drop {
    custodian_id: ID,
    upgrade_cap_id: ID,
    package_id: address,
    native_version: u64,
    previous_policy: u8,
    new_policy: u8,
}

public struct UpgradeCapDestroyed<phantom PackageMarker: drop> has copy, drop {
    custodian_id: ID,
    upgrade_cap_id: ID,
    package_id: address,
    final_native_version: u64,
    final_policy: u8,
}

// === Package Functions ===

public(package) fun admin_granted(admin_cap_id: ID, recipient: address) {
    sui::event::emit(AdminGranted { admin_cap_id, recipient });
}

public(package) fun admin_revoked(admin_cap_id: ID, roles: vector<TypeName>) {
    sui::event::emit(AdminRevoked { admin_cap_id, roles });
}

public(package) fun admin_role_granted(admin_cap_id: ID, role: TypeName) {
    sui::event::emit(AdminRoleGranted { admin_cap_id, role });
}

public(package) fun admin_role_revoked(admin_cap_id: ID, role: TypeName) {
    sui::event::emit(AdminRoleRevoked { admin_cap_id, role });
}

public(package) fun admin_destroyed(admin_cap_id: ID, roles: vector<TypeName>, was_active: bool) {
    sui::event::emit(AdminDestroyed { admin_cap_id, roles, was_active });
}

public(package) fun super_admin_transfer_started(recipient: address, execute_after_ms: u64) {
    sui::event::emit(SuperAdminTransferStarted { recipient, execute_after_ms });
}

public(package) fun super_admin_transfer_cancelled(recipient: address, execute_after_ms: u64) {
    sui::event::emit(SuperAdminTransferCancelled { recipient, execute_after_ms });
}

public(package) fun super_admin_transferred(
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
) {
    sui::event::emit(SuperAdminTransferred {
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    });
}

public(package) fun super_admin_cap_destroyed(super_admin_cap_id: ID) {
    sui::event::emit(SuperAdminCapDestroyed { super_admin_cap_id });
}

public(package) fun operational_version_advanced<PackageMarker: drop>(
    container_id: ID,
    package_id: address,
    previous_generation: u64,
    new_generation: u64,
) {
    sui::event::emit(OperationalVersionAdvanced<PackageMarker> {
        container_id,
        package_id,
        previous_generation,
        new_generation,
    });
}

public(package) fun upgrade_custody_created<PackageMarker: drop>(
    custodian_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    native_version: u64,
    policy: u8,
) {
    sui::event::emit(UpgradeCustodyCreated<PackageMarker> {
        custodian_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        native_version,
        policy,
    });
}

public(package) fun upgrade_authorized<PackageMarker: drop>(
    custodian_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    native_version: u64,
    policy: u8,
    digest: vector<u8>,
) {
    sui::event::emit(UpgradeAuthorized<PackageMarker> {
        custodian_id,
        upgrade_cap_id,
        package_id,
        native_version,
        policy,
        digest,
    });
}

public(package) fun upgrade_committed<PackageMarker: drop>(
    custodian_id: ID,
    upgrade_cap_id: ID,
    original_package_id: address,
    new_package_id: ID,
    previous_native_version: u64,
    new_native_version: u64,
) {
    sui::event::emit(UpgradeCommitted<PackageMarker> {
        custodian_id,
        upgrade_cap_id,
        original_package_id,
        new_package_id,
        previous_native_version,
        new_native_version,
    });
}

public(package) fun upgrade_policy_restricted<PackageMarker: drop>(
    custodian_id: ID,
    upgrade_cap_id: ID,
    package_id: address,
    native_version: u64,
    previous_policy: u8,
    new_policy: u8,
) {
    sui::event::emit(UpgradePolicyRestricted<PackageMarker> {
        custodian_id,
        upgrade_cap_id,
        package_id,
        native_version,
        previous_policy,
        new_policy,
    });
}

public(package) fun upgrade_cap_destroyed<PackageMarker: drop>(
    custodian_id: ID,
    upgrade_cap_id: ID,
    package_id: address,
    final_native_version: u64,
    final_policy: u8,
) {
    sui::event::emit(UpgradeCapDestroyed<PackageMarker> {
        custodian_id,
        upgrade_cap_id,
        package_id,
        final_native_version,
        final_policy,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun collect_one<Event: copy + drop>(abort_code: u64): Event {
    let mut events = sui::event::events_by_type<Event>();
    assert!(events.length() == 1, abort_code);
    events.pop_back()
}

#[test_only]
public fun admin_granted_fields(self: &AdminGranted): (ID, address) {
    (self.admin_cap_id, self.recipient)
}

#[test_only]
public fun admin_revoked_fields(self: &AdminRevoked): (ID, vector<TypeName>) {
    (self.admin_cap_id, self.roles)
}

#[test_only]
public fun admin_role_granted_fields(self: &AdminRoleGranted): (ID, TypeName) {
    (self.admin_cap_id, self.role)
}

#[test_only]
public fun admin_role_revoked_fields(self: &AdminRoleRevoked): (ID, TypeName) {
    (self.admin_cap_id, self.role)
}

#[test_only]
public fun admin_destroyed_fields(self: &AdminDestroyed): (ID, vector<TypeName>, bool) {
    (self.admin_cap_id, self.roles, self.was_active)
}

#[test_only]
public fun super_admin_transfer_started_fields(self: &SuperAdminTransferStarted): (address, u64) {
    (self.recipient, self.execute_after_ms)
}

#[test_only]
public fun super_admin_transfer_cancelled_fields(
    self: &SuperAdminTransferCancelled,
): (address, u64) {
    (self.recipient, self.execute_after_ms)
}

#[test_only]
public fun super_admin_transferred_fields(self: &SuperAdminTransferred): (ID, ID, address) {
    (self.previous_super_admin_cap_id, self.new_super_admin_cap_id, self.recipient)
}

#[test_only]
public fun super_admin_cap_destroyed_fields(self: &SuperAdminCapDestroyed): ID {
    self.super_admin_cap_id
}

#[test_only]
public fun operational_version_advanced_fields<PackageMarker: drop>(
    self: &OperationalVersionAdvanced<PackageMarker>,
): (ID, address, u64, u64) {
    (
        self.container_id,
        self.package_id,
        self.previous_generation,
        self.new_generation,
    )
}

#[test_only]
public fun upgrade_custody_created_fields<PackageMarker: drop>(
    self: &UpgradeCustodyCreated<PackageMarker>,
): (ID, ID, ID, ID, u64, u8) {
    (
        self.custodian_id,
        self.publisher_id,
        self.upgrade_cap_id,
        self.package_id,
        self.native_version,
        self.policy,
    )
}

#[test_only]
public fun upgrade_authorized_fields<PackageMarker: drop>(
    self: &UpgradeAuthorized<PackageMarker>,
): (ID, ID, ID, u64, u8, vector<u8>) {
    (
        self.custodian_id,
        self.upgrade_cap_id,
        self.package_id,
        self.native_version,
        self.policy,
        self.digest,
    )
}

#[test_only]
public fun upgrade_committed_fields<PackageMarker: drop>(
    self: &UpgradeCommitted<PackageMarker>,
): (ID, ID, address, ID, u64, u64) {
    (
        self.custodian_id,
        self.upgrade_cap_id,
        self.original_package_id,
        self.new_package_id,
        self.previous_native_version,
        self.new_native_version,
    )
}

#[test_only]
public fun upgrade_policy_restricted_fields<PackageMarker: drop>(
    self: &UpgradePolicyRestricted<PackageMarker>,
): (ID, ID, address, u64, u8, u8) {
    (
        self.custodian_id,
        self.upgrade_cap_id,
        self.package_id,
        self.native_version,
        self.previous_policy,
        self.new_policy,
    )
}

#[test_only]
public fun upgrade_cap_destroyed_fields<PackageMarker: drop>(
    self: &UpgradeCapDestroyed<PackageMarker>,
): (ID, ID, address, u64, u8) {
    (
        self.custodian_id,
        self.upgrade_cap_id,
        self.package_id,
        self.final_native_version,
        self.final_policy,
    )
}

// === Imports ===

use std::type_name::TypeName;
