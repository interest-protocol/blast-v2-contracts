// `blast_admin::errors` centralizes the immutable package's shared abort codes through
// zero-cost macros. W04005 observes expanded literals, so suppress it at the raising module.
#[allow(lint(abort_without_constant))]
/// Typed, bounded administration membership and delayed cold-root rotation.
module blast_admin::acl;

use blast_admin::events;
use sui::{clock::Clock, types, vec_map::{Self, VecMap}};

// === Public Structs ===

/// One pending delayed replacement of a domain's active root capability.
public struct PendingSuperAdminTransfer has drop, store {
    recipient: address,
    execute_after_ms: u64,
}

/// Canonical shared registry for one compile-time administration domain.
public struct Authority<phantom Domain: drop> has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: VecMap<ID, u64>,
    max_admins: u64,
    root_transfer_delay_ms: u64,
    pending_super_admin: Option<PendingSuperAdminTransfer>,
}

/// Cold root authority for membership, roles, and delayed root replacement only.
public struct SuperAdminCap<phantom Domain: drop> has key {
    id: UID,
}

/// Transferable, live-registry-checked routine administration capability.
public struct AdminCap<phantom Domain: drop> has key, store {
    id: UID,
}

/// Transaction-local snapshot of one live administrator's complete role bitmap.
public struct AdminWitness<phantom Domain: drop> has drop {
    roles: u64,
}

// === Public Functions ===

/// Creates, shares, and delivers the only authority state constructible from a domain OTW.
public fun bootstrap<Domain: drop>(
    otw: Domain,
    max_admins: u64,
    root_transfer_delay_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(types::is_one_time_witness(&otw), blast_admin::errors::invalid_domain_witness!());
    assert!(max_admins > 0, blast_admin::errors::invalid_max_admins!());
    assert!(root_transfer_delay_ms > 0, blast_admin::errors::invalid_root_transfer_delay!());

    let (root, authority) = new<Domain>(max_admins, root_transfer_delay_ms, ctx);
    let authority_id = authority.id.to_inner();
    let super_admin_cap_id = root.id.to_inner();
    let recipient = ctx.sender();

    transfer::share_object(authority);
    transfer::transfer(root, recipient);

    events::authority_created<Domain>(
        authority_id,
        super_admin_cap_id,
        recipient,
        max_admins,
        root_transfer_delay_ms,
    );
}

/// Creates and delivers one routine administrator with any complete `u64` role bitmap.
public fun grant_admin<Domain: drop>(
    self: &mut Authority<Domain>,
    root: &SuperAdminCap<Domain>,
    roles: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(root);
    assert!(recipient != @0x0, blast_admin::errors::invalid_admin_recipient!());
    assert!(self.admins.length() < self.max_admins, blast_admin::errors::admin_capacity_reached!());

    let admin_cap = AdminCap<Domain> { id: object::new(ctx) };
    let admin_cap_id = admin_cap.id.to_inner();
    let authority_id = self.id.to_inner();

    self.admins.insert(admin_cap_id, roles);
    transfer::public_transfer(admin_cap, recipient);

    events::admin_granted<Domain>(authority_id, admin_cap_id, roles, recipient);
}

/// Revokes one live administrator without requiring possession of its cap.
public fun revoke_admin<Domain: drop>(
    self: &mut Authority<Domain>,
    root: &SuperAdminCap<Domain>,
    admin_cap_id: ID,
) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let (_, previous_roles) = self.admins.remove(&admin_cap_id);

    events::admin_revoked<Domain>(self.id.to_inner(), admin_cap_id, previous_roles);
}

/// Adds exactly one role bit to a live administrator.
public fun grant_role<Domain: drop>(
    self: &mut Authority<Domain>,
    root: &SuperAdminCap<Domain>,
    admin_cap_id: ID,
    role: u64,
) {
    self.assert_super_admin(root);
    assert_valid_role(role);
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = &mut self.admins[&admin_cap_id];
    let previous_roles = *roles;
    assert!(!has_role(previous_roles, role), blast_admin::errors::admin_role_already_granted!());
    let new_roles = previous_roles | role;
    *roles = new_roles;

    events::admin_role_granted<Domain>(
        self.id.to_inner(),
        admin_cap_id,
        role,
        previous_roles,
        new_roles,
    );
}

/// Removes exactly one role bit while keeping zero-role membership valid.
public fun revoke_role<Domain: drop>(
    self: &mut Authority<Domain>,
    root: &SuperAdminCap<Domain>,
    admin_cap_id: ID,
    role: u64,
) {
    self.assert_super_admin(root);
    assert_valid_role(role);
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = &mut self.admins[&admin_cap_id];
    let previous_roles = *roles;
    assert!(has_role(previous_roles, role), blast_admin::errors::admin_role_not_granted!());
    let new_roles = previous_roles & role.bitwise_not();
    *roles = new_roles;

    events::admin_role_revoked<Domain>(
        self.id.to_inner(),
        admin_cap_id,
        role,
        previous_roles,
        new_roles,
    );
}

/// Deletes an active or already-revoked routine capability and reports its prior state.
public fun destroy_admin_cap<Domain: drop>(
    self: &mut Authority<Domain>,
    admin_cap: AdminCap<Domain>,
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

    events::admin_destroyed<Domain>(
        self.id.to_inner(),
        admin_cap_id,
        previous_roles,
        was_active,
    );
}

/// Starts or replaces a delayed transfer of the domain's cold root authority.
public fun begin_super_admin_transfer<Domain: drop>(
    self: &mut Authority<Domain>,
    root: &SuperAdminCap<Domain>,
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
        .checked_add(self.root_transfer_delay_ms)
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
        events::super_admin_transfer_cancelled<Domain>(
            self.id.to_inner(),
            previous.recipient,
            previous.execute_after_ms,
        );
    };
    events::super_admin_transfer_started<Domain>(self.id.to_inner(), recipient, execute_after_ms);
}

/// Cancels one pending root transfer while the current root remains active.
public fun cancel_super_admin_transfer<Domain: drop>(
    self: &mut Authority<Domain>,
    root: &SuperAdminCap<Domain>,
) {
    self.assert_super_admin(root);
    assert!(
        self.pending_super_admin.is_some(),
        blast_admin::errors::no_pending_super_admin_transfer!(),
    );

    let previous = self.pending_super_admin.extract();

    events::super_admin_transfer_cancelled<Domain>(
        self.id.to_inner(),
        previous.recipient,
        previous.execute_after_ms,
    );
}

/// Accepts a ready root transfer as its nominated recipient and invalidates the old cap.
public fun accept_super_admin_transfer<Domain: drop>(
    self: &mut Authority<Domain>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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
    let new_root = SuperAdminCap<Domain> { id: object::new(ctx) };
    let new_super_admin_cap_id = new_root.id.to_inner();
    let _ = self.pending_super_admin.extract();
    self.super_admin_cap_id = new_super_admin_cap_id;
    transfer::transfer(new_root, recipient);

    events::super_admin_transferred<Domain>(
        self.id.to_inner(),
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    );
}

/// Deletes a root capability only after an accepted replacement made it inert.
public fun destroy_retired_super_admin_cap<Domain: drop>(
    self: &Authority<Domain>,
    root: SuperAdminCap<Domain>,
) {
    let super_admin_cap_id = root.id.to_inner();
    assert!(
        super_admin_cap_id != self.super_admin_cap_id,
        blast_admin::errors::super_admin_cap_still_active!(),
    );

    let SuperAdminCap { id } = root;
    id.delete();

    events::super_admin_cap_destroyed<Domain>(self.id.to_inner(), super_admin_cap_id);
}

/// Authenticates live membership and snapshots the complete role bitmap for this PTB.
public fun sign_in<Domain: drop>(
    self: &Authority<Domain>,
    admin_cap: &AdminCap<Domain>,
): AdminWitness<Domain> {
    let admin_cap_id = admin_cap.id.to_inner();
    assert!(self.admins.contains(&admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    AdminWitness<Domain> { roles: self.admins[&admin_cap_id] }
}

/// Requires exactly one nonzero role bit and proves that the snapshot contains it.
public fun assert_role<Domain: drop>(self: &AdminWitness<Domain>, role: u64) {
    assert_valid_role(role);
    assert!(has_role(self.roles, role), blast_admin::errors::admin_role_not_granted!());
}

// === Private Functions ===

fun new<Domain: drop>(
    max_admins: u64,
    root_transfer_delay_ms: u64,
    ctx: &mut TxContext,
): (SuperAdminCap<Domain>, Authority<Domain>) {
    let root = SuperAdminCap<Domain> { id: object::new(ctx) };
    let authority = Authority<Domain> {
        id: object::new(ctx),
        super_admin_cap_id: root.id.to_inner(),
        admins: vec_map::empty(),
        max_admins,
        root_transfer_delay_ms,
        pending_super_admin: option::none(),
    };

    (root, authority)
}

fun assert_super_admin<Domain: drop>(
    self: &Authority<Domain>,
    root: &SuperAdminCap<Domain>,
) {
    assert!(
        root.id.to_inner() == self.super_admin_cap_id,
        blast_admin::errors::invalid_super_admin_cap!(),
    );
}

fun assert_valid_role(role: u64) {
    assert!(role != 0 && role & (role - 1) == 0, blast_admin::errors::invalid_role!());
}

fun has_role(roles: u64, role: u64): bool {
    roles & role != 0
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing<Domain: drop>(
    max_admins: u64,
    root_transfer_delay_ms: u64,
    ctx: &mut TxContext,
): (SuperAdminCap<Domain>, Authority<Domain>) {
    assert!(max_admins > 0, blast_admin::errors::invalid_max_admins!());
    assert!(root_transfer_delay_ms > 0, blast_admin::errors::invalid_root_transfer_delay!());
    new<Domain>(max_admins, root_transfer_delay_ms, ctx)
}

#[test_only]
public fun authority_id_for_testing<Domain: drop>(self: &Authority<Domain>): ID {
    self.id.to_inner()
}

#[test_only]
public fun super_admin_cap_id_for_testing<Domain: drop>(self: &SuperAdminCap<Domain>): ID {
    self.id.to_inner()
}

#[test_only]
public fun admin_cap_id_for_testing<Domain: drop>(self: &AdminCap<Domain>): ID {
    self.id.to_inner()
}

#[test_only]
public fun active_super_admin_cap_id_for_testing<Domain: drop>(
    self: &Authority<Domain>,
): ID {
    self.super_admin_cap_id
}

#[test_only]
public fun max_admins_for_testing<Domain: drop>(self: &Authority<Domain>): u64 {
    self.max_admins
}

#[test_only]
public fun root_transfer_delay_ms_for_testing<Domain: drop>(
    self: &Authority<Domain>,
): u64 {
    self.root_transfer_delay_ms
}

#[test_only]
public fun admin_roles_for_testing<Domain: drop>(
    self: &Authority<Domain>,
    admin_cap_id: ID,
): u64 {
    self.admins[&admin_cap_id]
}

#[test_only]
public fun roles_for_testing<Domain: drop>(self: &AdminWitness<Domain>): u64 {
    self.roles
}

#[test_only]
public fun has_pending_transfer_for_testing<Domain: drop>(self: &Authority<Domain>): bool {
    self.pending_super_admin.is_some()
}

#[test_only]
public fun pending_recipient_for_testing<Domain: drop>(self: &Authority<Domain>): address {
    self.pending_super_admin.borrow().recipient
}

#[test_only]
public fun pending_execute_after_ms_for_testing<Domain: drop>(
    self: &Authority<Domain>,
): u64 {
    self.pending_super_admin.borrow().execute_after_ms
}
