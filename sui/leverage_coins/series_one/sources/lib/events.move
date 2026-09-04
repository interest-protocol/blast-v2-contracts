/// Replay-complete Series1 ACL events.
module blast_leverage_series_one::events;

// === Public Structs ===

/// Emitted after a role-bearing admin capability is created and delivered.
public struct AdminGranted has copy, drop {
    admin_cap_id: ID,
    roles: u8,
    recipient: address,
}

/// Emitted after a complete admin registration is revoked.
public struct AdminRevoked has copy, drop {
    admin_cap_id: ID,
    previous_roles: u8,
}

/// Emitted after one role is added to a live admin capability.
public struct AdminRoleGranted has copy, drop {
    admin_cap_id: ID,
    role: u8,
    roles_after: u8,
}

/// Emitted after one role is removed from a live admin capability.
public struct AdminRoleRevoked has copy, drop {
    admin_cap_id: ID,
    role: u8,
    roles_after: u8,
}

/// Emitted after a cap holder deletes an admin cap and its registration.
public struct AdminDestroyed has copy, drop {
    admin_cap_id: ID,
    previous_roles: u8,
    was_active: bool,
}

/// Emitted after a delayed root-authority transfer is scheduled.
public struct SuperAdminTransferStarted has copy, drop {
    recipient: address,
    execute_after_ms: u64,
}

/// Emitted after a pending root-authority transfer is cancelled or replaced.
public struct SuperAdminTransferCancelled has copy, drop {
    recipient: address,
}

/// Emitted after the proposed recipient accepts root authority.
public struct SuperAdminTransferred has copy, drop {
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
}

// === Package Functions ===

/// Emits delivery of one newly registered role-bearing admin capability.
public(package) fun admin_granted(
    admin_cap_id: ID,
    roles: u8,
    recipient: address,
) {
    blast_leverage_series_one::events_wrapper::emit_event(AdminGranted {
        admin_cap_id,
        roles,
        recipient,
    });
}

/// Emits complete removal of one admin registration.
public(package) fun admin_revoked(admin_cap_id: ID, previous_roles: u8) {
    blast_leverage_series_one::events_wrapper::emit_event(AdminRevoked {
        admin_cap_id,
        previous_roles,
    });
}

/// Emits addition of one role and the resulting complete role set.
public(package) fun admin_role_granted(
    admin_cap_id: ID,
    role: u8,
    roles_after: u8,
) {
    blast_leverage_series_one::events_wrapper::emit_event(AdminRoleGranted {
        admin_cap_id,
        role,
        roles_after,
    });
}

/// Emits removal of one role and the resulting complete role set.
public(package) fun admin_role_revoked(
    admin_cap_id: ID,
    role: u8,
    roles_after: u8,
) {
    blast_leverage_series_one::events_wrapper::emit_event(AdminRoleRevoked {
        admin_cap_id,
        role,
        roles_after,
    });
}

/// Emits destruction of one admin capability and its prior registry state.
public(package) fun admin_destroyed(
    admin_cap_id: ID,
    previous_roles: u8,
    was_active: bool,
) {
    blast_leverage_series_one::events_wrapper::emit_event(AdminDestroyed {
        admin_cap_id,
        previous_roles,
        was_active,
    });
}

/// Emits the staged super-admin recipient and execution boundary.
public(package) fun super_admin_transfer_started(
    recipient: address,
    execute_after_ms: u64,
) {
    blast_leverage_series_one::events_wrapper::emit_event(
        SuperAdminTransferStarted {
            recipient,
            execute_after_ms,
        },
    );
}

/// Emits cancellation of the staged super-admin transfer.
public(package) fun super_admin_transfer_cancelled(recipient: address) {
    blast_leverage_series_one::events_wrapper::emit_event(
        SuperAdminTransferCancelled { recipient },
    );
}

/// Emits the completed replacement of the root capability.
public(package) fun super_admin_transferred(
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
) {
    blast_leverage_series_one::events_wrapper::emit_event(SuperAdminTransferred {
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    });
}

// === Test-Only Functions ===

#[test_only]
/// Returns all emitted payloads of type `T` from the Series1 envelope.
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_leverage_series_one::events_wrapper::Event<T>>().do!(
        |event| out.push_back(event.unwrap()),
    );

    out
}

#[test_only]
/// Returns exactly one emitted payload of type `T`.
public fun collect_one<T: copy + drop>(abort_code: u64): T {
    let mut events = collect<T>();

    assert!(events.length() == 1, abort_code);

    events.pop_back()
}

#[test_only]
public fun admin_granted_fields(
    self: &AdminGranted,
): (ID, u8, address) {
    (self.admin_cap_id, self.roles, self.recipient)
}

#[test_only]
public fun admin_revoked_fields(
    self: &AdminRevoked,
): (ID, u8) {
    (self.admin_cap_id, self.previous_roles)
}

#[test_only]
public fun admin_role_granted_fields(
    self: &AdminRoleGranted,
): (ID, u8, u8) {
    (self.admin_cap_id, self.role, self.roles_after)
}

#[test_only]
public fun admin_role_revoked_fields(
    self: &AdminRoleRevoked,
): (ID, u8, u8) {
    (self.admin_cap_id, self.role, self.roles_after)
}

#[test_only]
public fun admin_destroyed_fields(
    self: &AdminDestroyed,
): (ID, u8, bool) {
    (self.admin_cap_id, self.previous_roles, self.was_active)
}

#[test_only]
public fun super_admin_transfer_started_fields(
    self: &SuperAdminTransferStarted,
): (address, u64) {
    (self.recipient, self.execute_after_ms)
}

#[test_only]
public fun super_admin_transfer_cancelled_fields(
    self: &SuperAdminTransferCancelled,
): address {
    self.recipient
}

#[test_only]
public fun super_admin_transferred_fields(
    self: &SuperAdminTransferred,
): (ID, ID, address) {
    (
        self.previous_super_admin_cap_id,
        self.new_super_admin_cap_id,
        self.recipient,
    )
}
