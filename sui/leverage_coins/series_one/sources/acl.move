// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Series1-wide role state and capability validation.
///
/// One shared authority is created when Series1 is published. Its AdminCaps
/// authorize every adapter built on this Series1 package.
module blast_leverage_series_one::acl;

use blast_leverage_series_one::{constants, events};
use sui::{clock::Clock, vec_map::{Self, VecMap}};

// === Public Structs ===

/// A pending delayed handoff of the singleton super-admin authority.
public struct PendingSuperAdminTransfer has drop, store {
    recipient: address,
    execute_after_ms: u64,
}

/// Singleton Series1 registry for the active root and routine administrators.
public struct ProtocolAuthority has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: VecMap<ID, u8>,
    pending_super_admin: Option<PendingSuperAdminTransfer>,
}

/// Cold root authority that creates, configures, and revokes routine admins.
public struct SuperAdminCap has key {
    id: UID,
}

/// Revocable Series1-wide authority carrying one or more roles.
public struct AdminCap has key, store {
    id: UID,
}

/// Ephemeral snapshot of one live AdminCap's complete role bitmap.
public struct AdminWitness(u8) has drop;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let (super_admin_cap, authority) = new_protocol(ctx);

    transfer::share_object(authority);
    transfer::transfer(super_admin_cap, ctx.sender());
}

// === Public Functions ===

/// Creates and deliberately delivers one role-bearing routine administrator.
public fun grant_admin(
    self: &mut ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
    roles: u8,
    recipient: address,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(super_admin_cap);
    assert_valid_roles(roles);

    assert!(
        recipient != @0x0,
        blast_leverage_series_one::errors::invalid_admin_recipient!(),
    );
    assert!(
        self.admins.length() < constants::max_admins!(),
        blast_leverage_series_one::errors::admin_capacity_reached!(),
    );

    let admin_cap = AdminCap { id: object::new(ctx) };
    let admin_cap_id = admin_cap.id.to_inner();

    self.admins.insert(admin_cap_id, roles);
    transfer::public_transfer(admin_cap, recipient);
    events::admin_granted(admin_cap_id, roles, recipient);
}

/// Revokes one complete administrator registration without possessing its cap.
public fun revoke_admin(
    self: &mut ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
    admin_cap_id: ID,
) {
    self.assert_super_admin(super_admin_cap);

    assert!(
        self.admins.contains(&admin_cap_id),
        blast_leverage_series_one::errors::invalid_admin_cap!(),
    );

    let (_, previous_roles) = self.admins.remove(&admin_cap_id);
    events::admin_revoked(admin_cap_id, previous_roles);
}

/// Adds one exact role to a live administrator.
public fun grant_role(
    self: &mut ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
    admin_cap_id: ID,
    role: u8,
) {
    self.assert_super_admin(super_admin_cap);
    assert_valid_role(role);

    assert!(
        self.admins.contains(&admin_cap_id),
        blast_leverage_series_one::errors::invalid_admin_cap!(),
    );

    let roles = &mut self.admins[&admin_cap_id];
    assert!(
        !has_role(*roles, role),
        blast_leverage_series_one::errors::admin_role_already_granted!(),
    );

    *roles = *roles | role;
    events::admin_role_granted(admin_cap_id, role, *roles);
}

/// Removes one exact role while leaving the admin registration live.
public fun revoke_role(
    self: &mut ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
    admin_cap_id: ID,
    role: u8,
) {
    self.assert_super_admin(super_admin_cap);
    assert_valid_role(role);

    assert!(
        self.admins.contains(&admin_cap_id),
        blast_leverage_series_one::errors::invalid_admin_cap!(),
    );

    let roles = &mut self.admins[&admin_cap_id];
    assert!(
        has_role(*roles, role),
        blast_leverage_series_one::errors::admin_role_not_granted!(),
    );

    *roles = *roles & role.bitwise_not();
    events::admin_role_revoked(admin_cap_id, role, *roles);
}

/// Renounces administration and deletes the caller-owned cap.
public fun destroy_admin_cap(
    self: &mut ProtocolAuthority,
    admin_cap: AdminCap,
) {
    let AdminCap { id } = admin_cap;
    let admin_cap_id = id.to_inner();
    let was_active = self.admins.contains(&admin_cap_id);
    let previous_roles = if (was_active) {
        let (_, roles) = self.admins.remove(&admin_cap_id);
        roles
    } else {
        0
    };

    id.delete();
    events::admin_destroyed(admin_cap_id, previous_roles, was_active);
}

/// Starts or replaces a delayed transfer of the singleton root authority.
public fun begin_super_admin_transfer(
    self: &mut ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(super_admin_cap);

    assert!(
        recipient != @0x0 && recipient != ctx.sender(),
        blast_leverage_series_one::errors::invalid_super_admin_recipient!(),
    );

    let has_pending_transfer = self.pending_super_admin.is_some();
    if (has_pending_transfer) {
        assert!(
            self.pending_super_admin.borrow().recipient != recipient,
            blast_leverage_series_one::errors::super_admin_transfer_unchanged!(),
        );
    };

    let execute_after_ms = clock
        .timestamp_ms()
        .checked_add(constants::super_admin_transfer_delay_ms!())
        .destroy_or!(
            abort blast_leverage_series_one::errors::super_admin_transfer_time_overflow!(),
        );

    if (has_pending_transfer) {
        events::super_admin_transfer_cancelled(
            self.pending_super_admin.extract().recipient,
        );
    };

    self.pending_super_admin = option::some(PendingSuperAdminTransfer {
        recipient,
        execute_after_ms,
    });
    events::super_admin_transfer_started(recipient, execute_after_ms);
}

/// Cancels a pending root transfer while the current root remains active.
public fun cancel_super_admin_transfer(
    self: &mut ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
) {
    self.assert_super_admin(super_admin_cap);

    assert!(
        self.pending_super_admin.is_some(),
        blast_leverage_series_one::errors::no_pending_super_admin_transfer!(),
    );

    events::super_admin_transfer_cancelled(
        self.pending_super_admin.extract().recipient,
    );
}

/// Accepts a root transfer after its delay and invalidates the previous root cap.
public fun accept_super_admin_transfer(
    self: &mut ProtocolAuthority,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        self.pending_super_admin.is_some(),
        blast_leverage_series_one::errors::no_pending_super_admin_transfer!(),
    );

    let pending = self.pending_super_admin.borrow();
    assert!(
        pending.recipient == ctx.sender(),
        blast_leverage_series_one::errors::not_pending_super_admin_recipient!(),
    );
    assert!(
        clock.timestamp_ms() >= pending.execute_after_ms,
        blast_leverage_series_one::errors::super_admin_transfer_not_ready!(),
    );

    let recipient = self.pending_super_admin.extract().recipient;
    let previous_super_admin_cap_id = self.super_admin_cap_id;
    let new_super_admin_cap = SuperAdminCap { id: object::new(ctx) };
    let new_super_admin_cap_id = new_super_admin_cap.id.to_inner();

    self.super_admin_cap_id = new_super_admin_cap_id;
    transfer::transfer(new_super_admin_cap, recipient);
    events::super_admin_transferred(
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    );
}

/// Deletes a root cap only after a successful replacement made it inert.
public fun destroy_retired_super_admin_cap(
    self: &ProtocolAuthority,
    super_admin_cap: SuperAdminCap,
) {
    assert!(
        super_admin_cap.id.to_inner() != self.super_admin_cap_id,
        blast_leverage_series_one::errors::super_admin_cap_still_active!(),
    );

    let SuperAdminCap { id } = super_admin_cap;
    id.delete();
}

/// Authenticates a live administrator and snapshots its complete role bitmap.
public fun sign_in(
    self: &ProtocolAuthority,
    admin_cap: &AdminCap,
): AdminWitness {
    let admin_cap_id = admin_cap.id.to_inner();
    assert!(
        self.admins.contains(&admin_cap_id),
        blast_leverage_series_one::errors::invalid_admin_cap!(),
    );

    AdminWitness(self.admins[&admin_cap_id])
}

/// Checks the risk-administrator role shared by every Series1 adapter.
public fun assert_risk_admin(self: &AdminWitness) {
    self.assert_role(constants::risk_admin_role!());
}

/// Checks the package-administrator role shared by every Series1 adapter.
public fun assert_package_admin(self: &AdminWitness) {
    self.assert_role(constants::package_admin_role!());
}

// === Package Functions ===

/// Checks that an ephemeral admin proof contains the role required by Series1.
public(package) fun assert_role(self: &AdminWitness, role: u8) {
    assert_valid_role(role);
    assert!(
        has_role(self.0, role),
        blast_leverage_series_one::errors::admin_role_not_granted!(),
    );
}

// === Private Functions ===

fun new_protocol(ctx: &mut TxContext): (SuperAdminCap, ProtocolAuthority) {
    let super_admin_cap = SuperAdminCap { id: object::new(ctx) };
    let authority = ProtocolAuthority {
        id: object::new(ctx),
        super_admin_cap_id: super_admin_cap.id.to_inner(),
        admins: vec_map::empty(),
        pending_super_admin: option::none(),
    };

    (super_admin_cap, authority)
}

fun assert_super_admin(
    self: &ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
) {
    assert!(
        super_admin_cap.id.to_inner() == self.super_admin_cap_id,
        blast_leverage_series_one::errors::invalid_super_admin_cap!(),
    );
}

fun assert_valid_roles(roles: u8) {
    assert!(
        roles > 0 && roles & constants::all_admin_roles!() == roles,
        blast_leverage_series_one::errors::invalid_admin_roles!(),
    );
}

fun assert_valid_role(role: u8) {
    assert!(
        role == constants::vault_issuer_role!()
            || role == constants::risk_admin_role!()
            || role == constants::shutdown_admin_role!()
            || role == constants::package_admin_role!(),
        blast_leverage_series_one::errors::invalid_admin_role!(),
    );
}

fun has_role(roles: u8, role: u8): bool {
    roles & role != 0
}

// === Test-Only Functions ===

#[test_only]
/// Runs complete Series1 ACL initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates isolated Series1 ACL state without sharing or transferring it.
public fun new_protocol_for_testing(
    ctx: &mut TxContext,
): (SuperAdminCap, ProtocolAuthority) {
    new_protocol(ctx)
}

#[test_only]
public fun authority_id_for_testing(self: &ProtocolAuthority): ID {
    self.id.to_inner()
}

#[test_only]
public fun admin_cap_id_for_testing(self: &AdminCap): ID {
    self.id.to_inner()
}

#[test_only]
public fun super_admin_cap_id_for_testing(self: &SuperAdminCap): ID {
    self.id.to_inner()
}

#[test_only]
public fun active_super_admin_cap_id_for_testing(self: &ProtocolAuthority): ID {
    self.super_admin_cap_id
}

#[test_only]
public fun admin_roles_for_testing(
    self: &ProtocolAuthority,
    admin_cap_id: ID,
): u8 {
    self.admins[&admin_cap_id]
}

#[test_only]
public fun witness_roles_for_testing(self: &AdminWitness): u8 {
    self.0
}
