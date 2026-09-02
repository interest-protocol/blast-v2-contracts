// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Package-local administration with one transferable root and revocable routine admins.
///
/// This registry is independent of the launchpad ACL. The same offchain
/// maintainer may hold both root capabilities, but they are separate onchain
/// objects in separate packages and neither affects the other.
module blast_sui::acl;

use blast_sui::{constants, events, package_version::PackageVersion};
use sui::{clock::Clock, vec_set::{Self, VecSet}};

// === Public Structs ===

/// A pending delayed handoff of the singleton super-admin authority.
public struct PendingSuperAdminTransfer has drop, store {
    recipient: address,
    execute_after_ms: u64,
}

/// Singleton registry for the active root, routine admins, and delayed handoff.
public struct ProtocolAuthority has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: VecSet<ID>,
    pending_super_admin: Option<PendingSuperAdminTransfer>,
}

/// Cold root authority that creates and revokes routine administrators.
public struct SuperAdminCap has key {
    id: UID,
}

/// Revocable authority for routine protocol administration.
public struct AdminCap has key, store {
    id: UID,
}

/// Ephemeral proof that an AdminCap was active when it signed in.
public struct AdminWitness() has drop;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let (super_admin_cap, authority) = new_protocol(ctx);

    transfer::share_object(authority);
    super_admin_cap.keep(ctx);
}

// === Public Functions ===

/// Keeps a returned root capability in the transaction sender's account.
public fun keep(self: SuperAdminCap, ctx: &mut TxContext) {
    transfer::transfer(self, ctx.sender());
}

/// Creates and delivers one routine administrator.
public fun grant_admin(
    self: &mut ProtocolAuthority,
    package_version: &PackageVersion,
    super_admin_cap: &SuperAdminCap,
    recipient: address,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    self.assert_super_admin(super_admin_cap);
    assert!(recipient != @0x0, blast_sui::errors::invalid_admin_recipient!());
    assert!(
        self.admins.length() < constants::max_admins!(),
        blast_sui::errors::admin_capacity_reached!(),
    );

    let admin_cap = AdminCap { id: object::new(ctx) };
    let admin_cap_id = admin_cap.id.to_inner();
    self.admins.insert(admin_cap_id);
    transfer::public_transfer(admin_cap, recipient);

    events::admin_granted(admin_cap_id, recipient);
}

/// Revokes one routine administrator without requiring possession of its cap.
public fun revoke_admin(
    self: &mut ProtocolAuthority,
    package_version: &PackageVersion,
    super_admin_cap: &SuperAdminCap,
    admin_cap_id: ID,
) {
    package_version.assert_current();
    self.assert_super_admin(super_admin_cap);
    assert!(
        self.admins.contains(&admin_cap_id),
        blast_sui::errors::invalid_admin_cap!(),
    );

    self.admins.remove(&admin_cap_id);
    events::admin_revoked(admin_cap_id);
}

/// Removes and deletes a caller-owned AdminCap, active or already revoked.
public fun destroy_admin_cap(
    self: &mut ProtocolAuthority,
    package_version: &PackageVersion,
    admin_cap: AdminCap,
) {
    package_version.assert_current();
    let AdminCap { id } = admin_cap;
    let admin_cap_id = id.to_inner();
    let was_active = self.admins.contains(&admin_cap_id);
    if (was_active) self.admins.remove(&admin_cap_id);
    id.delete();

    events::admin_destroyed(admin_cap_id, was_active);
}

/// Authenticates one active routine administrator for this transaction.
public fun sign_in(
    self: &ProtocolAuthority,
    package_version: &PackageVersion,
    admin_cap: &AdminCap,
): AdminWitness {
    package_version.assert_current();
    assert!(
        self.admins.contains(&admin_cap.id.to_inner()),
        blast_sui::errors::invalid_admin_cap!(),
    );

    AdminWitness()
}

/// Starts or replaces a delayed transfer of the singleton root authority.
public fun begin_super_admin_transfer(
    self: &mut ProtocolAuthority,
    package_version: &PackageVersion,
    super_admin_cap: &SuperAdminCap,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    self.assert_super_admin(super_admin_cap);
    assert!(
        recipient != @0x0 && recipient != ctx.sender(),
        blast_sui::errors::invalid_super_admin_recipient!(),
    );
    let has_pending_transfer = self.pending_super_admin.is_some();
    if (has_pending_transfer) {
        assert!(
            self.pending_super_admin.borrow().recipient != recipient,
            blast_sui::errors::super_admin_transfer_unchanged!(),
        );
    };

    let execute_after_ms = clock
        .timestamp_ms()
        .checked_add(constants::super_admin_transfer_delay_ms!())
        .destroy_or!(abort blast_sui::errors::super_admin_transfer_time_overflow!());

    if (has_pending_transfer) {
        let previous = self.pending_super_admin.extract();

        events::super_admin_transfer_cancelled(previous.recipient);
    };
    self.pending_super_admin =
        option::some(PendingSuperAdminTransfer { recipient, execute_after_ms });

    events::super_admin_transfer_started(recipient, execute_after_ms);
}

/// Cancels a pending root transfer while the current root remains active.
public fun cancel_super_admin_transfer(
    self: &mut ProtocolAuthority,
    package_version: &PackageVersion,
    super_admin_cap: &SuperAdminCap,
) {
    package_version.assert_current();
    self.assert_super_admin(super_admin_cap);
    assert!(
        self.pending_super_admin.is_some(),
        blast_sui::errors::no_pending_super_admin_transfer!(),
    );

    let pending = self.pending_super_admin.extract();

    events::super_admin_transfer_cancelled(pending.recipient);
}

/// Accepts a root transfer after its delay and invalidates the previous root cap.
public fun accept_super_admin_transfer(
    self: &mut ProtocolAuthority,
    package_version: &PackageVersion,
    clock: &Clock,
    ctx: &mut TxContext,
): SuperAdminCap {
    package_version.assert_current();
    assert!(
        self.pending_super_admin.is_some(),
        blast_sui::errors::no_pending_super_admin_transfer!(),
    );
    let (recipient, execute_after_ms) = {
        let pending = self.pending_super_admin.borrow();
        (pending.recipient, pending.execute_after_ms)
    };
    assert!(
        recipient == ctx.sender(),
        blast_sui::errors::not_pending_super_admin_recipient!(),
    );
    assert!(
        clock.timestamp_ms() >= execute_after_ms,
        blast_sui::errors::super_admin_transfer_not_ready!(),
    );

    let previous_super_admin_cap_id = self.super_admin_cap_id;
    let new_super_admin_cap = SuperAdminCap { id: object::new(ctx) };
    let new_super_admin_cap_id = new_super_admin_cap.id.to_inner();
    let _ = self.pending_super_admin.extract();
    self.super_admin_cap_id = new_super_admin_cap_id;

    events::super_admin_transferred(
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    );
    new_super_admin_cap
}

/// Deletes a root cap only after a successful replacement made it inert.
///
/// Like `deposit_receipt::cancel`, this deliberately skips the package
/// version gate: it consumes only the caller's own inert object against
/// the live registry, so cleanup stays possible mid-cutover.
public fun destroy_retired_super_admin_cap(
    self: &ProtocolAuthority,
    super_admin_cap: SuperAdminCap,
) {
    assert!(
        super_admin_cap.id.to_inner() != self.super_admin_cap_id,
        blast_sui::errors::super_admin_cap_still_active!(),
    );

    let SuperAdminCap { id } = super_admin_cap;
    id.delete();
}

// === Package Functions ===

/// Validates the singleton capability against the current registry entry.
public(package) fun assert_super_admin(
    self: &ProtocolAuthority,
    super_admin_cap: &SuperAdminCap,
) {
    assert!(
        super_admin_cap.id.to_inner() == self.super_admin_cap_id,
        blast_sui::errors::invalid_super_admin_cap!(),
    );
}

// === Private Functions ===

fun new_protocol(ctx: &mut TxContext): (SuperAdminCap, ProtocolAuthority) {
    let super_admin_cap = SuperAdminCap { id: object::new(ctx) };
    let authority = ProtocolAuthority {
        id: object::new(ctx),
        super_admin_cap_id: super_admin_cap.id.to_inner(),
        admins: vec_set::empty(),
        pending_super_admin: option::none(),
    };

    (super_admin_cap, authority)
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared protocol authority state for focused tests.
public fun new_protocol_for_testing(ctx: &mut TxContext): (SuperAdminCap, ProtocolAuthority) {
    new_protocol(ctx)
}

#[test_only]
public fun super_admin_cap_id_for_testing(self: &ProtocolAuthority): ID {
    self.super_admin_cap_id
}

#[test_only]
public fun admin_cap_id_for_testing(self: &AdminCap): ID {
    self.id.to_inner()
}
