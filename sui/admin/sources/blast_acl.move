// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_admin::errors` centralizes the immutable package's shared abort codes through
// zero-cost macros. W04005 observes expanded literals, so suppress it at the raising module.
#[allow(lint(abort_without_constant))]
/// The one access-control list for every Blast package: one cold root and role-typed admins.
///
/// A role is a type that its consumer package declares. `AdminWitness<Role>` in a function
/// signature is that function's role check, and a role from one package can never satisfy
/// another package's signature.
module blast_admin::blast_acl;

// === Constants ===

const MAX_ADMINS: u64 = 32;

const MAX_ROLES_PER_ADMIN: u64 = 32;

/// The first super-admin transfer delay, and the fixed wait before any change to it applies.
const DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Public Types ===

/// One pending delayed replacement of the root capability.
public struct PendingSuperAdminTransfer has drop, store {
    recipient: address,
    execute_after_ms: u64,
}

/// The shared singleton that lists the active root and every live administrator's roles.
public struct ACL has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: VecMap<ID, VecSet<TypeName>>,
    super_admin_transfer_delay_ms: Timelocked<u64>,
    pending_super_admin: Option<PendingSuperAdminTransfer>,
}

/// Cold root authority for membership, roles, and delayed root replacement only.
public struct SuperAdminCap has key {
    id: UID,
}

/// Transferable, live-registry-checked administrator capability holding any granted roles.
public struct AdminCap has key, store {
    id: UID,
}

/// Transaction-local proof that a live `AdminCap` holding `Role` signed in.
public struct AdminWitness<phantom Role>() has drop;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let (root, acl) = new(ctx);

    transfer::share_object(acl);
    transfer::transfer(root, ctx.sender());
}

// === Public Functions ===

/// Creates and delivers one live administrator that holds no role yet.
public fun grant_admin(
    self: &mut ACL,
    root: &SuperAdminCap,
    recipient: address,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(root);
    assert!(recipient != @0x0, blast_admin::errors::invalid_admin_recipient!());
    assert!(self.admins.length() < MAX_ADMINS, blast_admin::errors::admin_capacity_reached!());

    let admin_cap = AdminCap { id: object::new(ctx) };
    let admin_cap_id = admin_cap.id.to_inner();

    self.admins.insert(admin_cap_id, vec_set::empty());
    transfer::public_transfer(admin_cap, recipient);

    blast_admin_events::admin_granted(admin_cap_id, recipient);
}

/// Revokes one live administrator and all its roles without requiring possession of its cap.
public fun revoke_admin(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let (_, roles) = self.admins.remove(&admin_cap_id);

    blast_admin_events::admin_revoked(admin_cap_id, roles.into_keys());
}

/// Adds `Role` to a live administrator.
public fun grant_role<Role>(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = &mut self.admins[&admin_cap_id];
    let role = type_name::with_defining_ids<Role>();
    assert!(!roles.contains(&role), blast_admin::errors::admin_role_already_granted!());
    assert!(
        roles.length() < MAX_ROLES_PER_ADMIN,
        blast_admin::errors::admin_role_capacity_reached!(),
    );

    roles.insert(role);

    blast_admin_events::admin_role_granted(admin_cap_id, role);
}

/// Removes `Role` from a live administrator; an administrator with no role signs in to nothing.
public fun revoke_role<Role>(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = &mut self.admins[&admin_cap_id];
    let role = type_name::with_defining_ids<Role>();
    assert!(roles.contains(&role), blast_admin::errors::admin_role_not_granted!());

    roles.remove(&role);

    blast_admin_events::admin_role_revoked(admin_cap_id, role);
}

/// Deletes an active or already-revoked administrator cap and reports what it still held.
public fun destroy_admin_cap(self: &mut ACL, admin_cap: AdminCap) {
    let AdminCap { id } = admin_cap;
    let admin_cap_id = id.to_inner();
    let was_active = self.admins.contains(&admin_cap_id);
    let roles = if (was_active) {
        let (_, roles) = self.admins.remove(&admin_cap_id);
        roles.into_keys()
    } else {
        vector[]
    };

    id.delete();

    blast_admin_events::admin_destroyed(admin_cap_id, roles, was_active);
}

/// Schedules a new super-admin transfer delay; it applies only after the fixed timelock.
///
/// Scheduling the delay in force cancels a pending change.
public fun schedule_super_admin_transfer_delay(
    self: &mut ACL,
    root: &SuperAdminCap,
    delay_ms: u64,
    clock: &Clock,
) {
    self.assert_super_admin(root);
    assert!(delay_ms > 0, blast_admin::errors::invalid_super_admin_transfer_delay!());

    self.super_admin_transfer_delay_ms.schedule(delay_ms, clock);

    blast_admin_events::super_admin_transfer_delay_scheduled(
        delay_ms,
        self.super_admin_transfer_delay_ms.scheduled_at_ms(),
    );
}

/// Starts or replaces a delayed transfer of the cold root authority.
public fun begin_super_admin_transfer(
    self: &mut ACL,
    root: &SuperAdminCap,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(root);
    assert!(
        recipient != @0x0 && recipient != ctx.sender(),
        blast_admin::errors::invalid_super_admin_recipient!(),
    );
    if (self.pending_super_admin.is_some()) {
        assert!(
            self.pending_super_admin.borrow().recipient != recipient,
            blast_admin::errors::super_admin_transfer_unchanged!(),
        );
    };
    let execute_after_ms = clock
        .timestamp_ms()
        .checked_add(self.super_admin_transfer_delay_ms.value(clock))
        .destroy_or!(abort blast_admin::errors::super_admin_transfer_time_overflow!());
    let mut previous = if (self.pending_super_admin.is_some()) {
        option::some(self.pending_super_admin.extract())
    } else {
        option::none()
    };

    self.pending_super_admin = option::some(PendingSuperAdminTransfer {
        recipient,
        execute_after_ms,
    });

    if (previous.is_some()) {
        let previous = previous.extract();
        blast_admin_events::super_admin_transfer_cancelled(
            previous.recipient,
            previous.execute_after_ms,
        );
    };
    blast_admin_events::super_admin_transfer_started(recipient, execute_after_ms);
}

/// Cancels one pending root transfer while the current root remains active.
public fun cancel_super_admin_transfer(self: &mut ACL, root: &SuperAdminCap) {
    self.assert_super_admin(root);
    assert!(
        self.pending_super_admin.is_some(),
        blast_admin::errors::no_pending_super_admin_transfer!(),
    );

    let previous = self.pending_super_admin.extract();

    blast_admin_events::super_admin_transfer_cancelled(
        previous.recipient,
        previous.execute_after_ms,
    );
}

/// Accepts a ready root transfer as its nominated recipient and invalidates the old cap.
public fun accept_super_admin_transfer(self: &mut ACL, clock: &Clock, ctx: &mut TxContext) {
    assert!(
        self.pending_super_admin.is_some(),
        blast_admin::errors::no_pending_super_admin_transfer!(),
    );
    let pending = self.pending_super_admin.borrow();
    assert!(
        pending.recipient == ctx.sender(),
        blast_admin::errors::not_pending_super_admin_recipient!(),
    );
    assert!(
        clock.timestamp_ms() >= pending.execute_after_ms,
        blast_admin::errors::super_admin_transfer_not_ready!(),
    );

    let recipient = pending.recipient;
    let previous_super_admin_cap_id = self.super_admin_cap_id;
    let new_root = SuperAdminCap { id: object::new(ctx) };
    let new_super_admin_cap_id = new_root.id.to_inner();
    let _ = self.pending_super_admin.extract();
    self.super_admin_cap_id = new_super_admin_cap_id;
    transfer::transfer(new_root, recipient);

    blast_admin_events::super_admin_transferred(
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    );
}

/// Deletes a root capability only after an accepted replacement made it inert.
public fun destroy_retired_super_admin_cap(self: &ACL, root: SuperAdminCap) {
    let super_admin_cap_id = root.id.to_inner();
    assert!(
        super_admin_cap_id != self.super_admin_cap_id,
        blast_admin::errors::super_admin_cap_still_active!(),
    );

    let SuperAdminCap { id } = root;
    id.delete();

    blast_admin_events::super_admin_cap_destroyed(super_admin_cap_id);
}

/// Proves that `admin_cap` is live and holds `Role`; the witness type is what consumers require.
public fun sign_in<Role>(self: &ACL, admin_cap: &AdminCap): AdminWitness<Role> {
    let admin_cap_id = admin_cap.id.to_inner();
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());
    assert!(
        self.admins[&admin_cap_id].contains(&type_name::with_defining_ids<Role>()),
        blast_admin::errors::admin_role_not_granted!(),
    );

    AdminWitness()
}

// === Private Functions ===

fun new(ctx: &mut TxContext): (SuperAdminCap, ACL) {
    let root = SuperAdminCap { id: object::new(ctx) };
    let acl = ACL {
        id: object::new(ctx),
        super_admin_cap_id: root.id.to_inner(),
        admins: vec_map::empty(),
        super_admin_transfer_delay_ms: blast_fun_timelock::new(DELAY_MS, DELAY_MS),
        pending_super_admin: option::none(),
    };

    (root, acl)
}

fun assert_super_admin(self: &ACL, root: &SuperAdminCap) {
    assert!(
        root.id.to_inner() == self.super_admin_cap_id,
        blast_admin::errors::invalid_super_admin_cap!(),
    );
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): (SuperAdminCap, ACL) {
    new(ctx)
}

#[test_only]
/// Stands in for a live sign-in so consumer tests exercise only their own role signatures.
public fun witness_for_testing<Role>(): AdminWitness<Role> {
    AdminWitness()
}

#[test_only]
public fun max_admins_for_testing(): u64 {
    MAX_ADMINS
}

#[test_only]
public fun max_roles_per_admin_for_testing(): u64 {
    MAX_ROLES_PER_ADMIN
}

#[test_only]
public fun delay_ms_for_testing(): u64 {
    DELAY_MS
}

#[test_only]
public fun super_admin_transfer_delay_ms_for_testing(self: &ACL, clock: &Clock): u64 {
    self.super_admin_transfer_delay_ms.value(clock)
}

#[test_only]
public fun super_admin_cap_id_for_testing(self: &SuperAdminCap): ID {
    self.id.to_inner()
}

#[test_only]
public fun admin_cap_id_for_testing(self: &AdminCap): ID {
    self.id.to_inner()
}

#[test_only]
public fun active_super_admin_cap_id_for_testing(self: &ACL): ID {
    self.super_admin_cap_id
}

#[test_only]
public fun admin_count_for_testing(self: &ACL): u64 {
    self.admins.length()
}

#[test_only]
public fun admin_roles_for_testing(self: &ACL, admin_cap_id: ID): vector<TypeName> {
    self.admins[&admin_cap_id].into_keys()
}

#[test_only]
public fun has_pending_transfer_for_testing(self: &ACL): bool {
    self.pending_super_admin.is_some()
}

#[test_only]
public fun pending_recipient_for_testing(self: &ACL): address {
    self.pending_super_admin.borrow().recipient
}

#[test_only]
public fun pending_execute_after_ms_for_testing(self: &ACL): u64 {
    self.pending_super_admin.borrow().execute_after_ms
}

// === Imports ===

use blast_admin::blast_admin_events;

use blast_fun_timelock::blast_fun_timelock::{Self, Timelocked};

use std::type_name::{Self, TypeName};

use sui::{clock::Clock, vec_map::{Self, VecMap}, vec_set::{Self, VecSet}};
