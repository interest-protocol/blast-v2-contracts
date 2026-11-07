// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Native UpgradeCap custody with an independent 48-hour notice per cap and action.
module blast_upgrade_cap_manager::blast_upgrade_cap_manager;

// === Public Types ===

/// Key-only custody for at most MAX_CAPS native caps, discoverable through the object table.
/// Each cap ID has at most one pending Request in a dynamic field on this manager.
public struct UpgradeCapManager has key {
    id: UID,
    caps: ObjectTable<ID, UpgradeCap>,
}

/// Transferable request, cancellation and enrollment authority for exactly one manager.
public struct ManagerCap has key, store {
    id: UID,
    manager_id: ID,
}

/// One cap's authorized action and inclusive execution timestamp, in Clock milliseconds.
public struct Request has copy, drop, store {
    action: Action,
    ready_at_ms: u64,
}

/// Mutually exclusive actions for one cap; other caps' requests remain independent.
public enum Action has copy, drop, store {
    Upgrade { digest: vector<u8> },
    MakeImmutable,
}

// === Public Functions ===

/// Creates a manager with its first native cap and an instance-bound controller.
/// Before valuable enrollment, independently verify destruction of this package's own cap.
public fun new(upgrade_cap: UpgradeCap, ctx: &mut TxContext): (UpgradeCapManager, ManagerCap) {
    // Native authorization clears this address until its receipt commits.
    assert!(upgrade_cap.package().to_address() != @0x0, EAlreadyAuthorized);

    let mut manager = UpgradeCapManager { id: object::new(ctx), caps: object_table::new(ctx) };
    let cap = ManagerCap { id: object::new(ctx), manager_id: manager.id.to_inner() };

    event::emit(ManagerCreated { manager_id: manager.id.to_inner(), controller_id: cap.id.to_inner() });

    manager.insert_cap(upgrade_cap);

    (manager, cap)
}

/// Shares a newly created manager; transfer its returned ManagerCap separately.
public fun share(self: UpgradeCapManager) {
    transfer::share_object(self);
}

/// Controller only: enrolls another native cap, up to MAX_CAPS active caps per manager.
/// The key is the original cap ID. No withdrawal path exists; native policy is preserved.
public fun add_upgrade_cap(self: &mut UpgradeCapManager, cap: &ManagerCap, upgrade_cap: UpgradeCap) {
    self.assert_controller(cap);
    assert!(upgrade_cap.package().to_address() != @0x0, EAlreadyAuthorized);
    assert!(self.caps.length() < MAX_CAPS, ECapacityReached);

    self.insert_cap(upgrade_cap);
}

/// Controller only: requests this cap's exact native digest after a full 48 hours.
/// Cancel this cap's existing request before replacement; other caps are unaffected.
public fun request_upgrade(
    self: &mut UpgradeCapManager,
    cap: &ManagerCap,
    upgrade_cap_id: ID,
    digest: vector<u8>,
    clock: &Clock,
) {
    self.request(cap, upgrade_cap_id, Action::Upgrade { digest }, clock);
}

/// Controller only: requests permanent immutability of this cap's target after 48 hours.
public fun request_make_immutable(
    self: &mut UpgradeCapManager,
    cap: &ManagerCap,
    upgrade_cap_id: ID,
    clock: &Clock,
) {
    self.request(cap, upgrade_cap_id, Action::MakeImmutable, clock);
}

/// Controller only: cancels this cap's pending action, including after maturity.
public fun cancel_request(self: &mut UpgradeCapManager, cap: &ManagerCap, upgrade_cap_id: ID) {
    self.assert_controller(cap);
    self.assert_managed(upgrade_cap_id);
    assert!(dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ENoRequest);

    let Request { action, ready_at_ms } = dynamic_field::remove<ID, Request>(&mut self.id, upgrade_cap_id);

    event::emit(RequestCancelled { manager_id: self.id.to_inner(), upgrade_cap_id, action, ready_at_ms });
}

/// Anyone: consumes this cap's mature request and authorizes its exact digest and native policy.
/// Consume the native ticket and commit its receipt in the same PTB; failures roll back atomically.
public fun authorize_upgrade(
    self: &mut UpgradeCapManager,
    upgrade_cap_id: ID,
    clock: &Clock,
): UpgradeTicket {
    self.assert_managed(upgrade_cap_id);
    assert!(dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ENoRequest);

    let request = dynamic_field::borrow<ID, Request>(&self.id, upgrade_cap_id);
    let digest = match (&request.action) {
        Action::Upgrade { digest } => *digest,
        Action::MakeImmutable => abort EWrongAction,
    };
    let ready_at_ms = request.ready_at_ms;
    assert!(clock.timestamp_ms() >= ready_at_ms, ETooEarly);

    dynamic_field::remove<ID, Request>(&mut self.id, upgrade_cap_id);
    let upgrade_cap = &mut self.caps[upgrade_cap_id];
    let policy = upgrade_cap.policy();
    let ticket = upgrade_cap.authorize(policy, digest);

    event::emit(UpgradeAuthorized { manager_id: self.id.to_inner(), upgrade_cap_id, digest, ready_at_ms });

    ticket
}

/// Anyone: commits to the cap identified by the native receipt; callers cannot redirect it.
public fun commit_upgrade(self: &mut UpgradeCapManager, receipt: UpgradeReceipt) {
    let upgrade_cap_id = receipt.cap();
    self.assert_managed(upgrade_cap_id);

    let upgrade_cap = &mut self.caps[upgrade_cap_id];
    upgrade_cap.commit(receipt);

    let package_id = upgrade_cap.package();
    let version = upgrade_cap.version();

    event::emit(UpgradeCommitted { manager_id: self.id.to_inner(), upgrade_cap_id, package_id, version });
}

/// Anyone: executes this cap's mature immutability request and permanently destroys that cap.
/// Other caps, their requests and the shared manager survive. Application objects are not frozen.
public fun make_immutable(self: &mut UpgradeCapManager, upgrade_cap_id: ID, clock: &Clock) {
    self.assert_managed(upgrade_cap_id);
    assert!(dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ENoRequest);

    let request = dynamic_field::borrow<ID, Request>(&self.id, upgrade_cap_id);
    assert!(request.action == Action::MakeImmutable, EWrongAction);
    let ready_at_ms = request.ready_at_ms;
    assert!(clock.timestamp_ms() >= ready_at_ms, ETooEarly);

    dynamic_field::remove<ID, Request>(&mut self.id, upgrade_cap_id);
    let upgrade_cap = self.caps.remove(upgrade_cap_id);
    let package_id = upgrade_cap.package();
    package::make_immutable(upgrade_cap);

    event::emit(PackageMadeImmutable { manager_id: self.id.to_inner(), upgrade_cap_id, package_id, ready_at_ms });
}

/// Holder only: permanently renounces enrollment, request and cancellation authority.
/// All pending actions remain executable; this does not cancel them or destroy native caps.
public fun destroy_cap(cap: ManagerCap) {
    let ManagerCap { id, manager_id: _ } = cap;

    id.delete();
}

/// This cap's pending action and deadline, or none when idle or no longer managed.
public fun pending_request(self: &UpgradeCapManager, upgrade_cap_id: ID): Option<Request> {
    if (dynamic_field::exists<ID>(&self.id, upgrade_cap_id)) {
        option::some(*dynamic_field::borrow<ID, Request>(&self.id, upgrade_cap_id))
    } else {
        option::none()
    }
}

/// The exact upgrade digest or terminal immutability action authorized by the request.
public fun action(self: &Request): &Action {
    &self.action
}

/// Inclusive Clock timestamp when the request becomes executable.
public fun ready_at_ms(self: &Request): u64 {
    self.ready_at_ms
}

// === Private Functions ===

fun assert_controller(self: &UpgradeCapManager, cap: &ManagerCap) {
    assert!(cap.manager_id == self.id.to_inner(), EWrongController);
}

fun assert_managed(self: &UpgradeCapManager, upgrade_cap_id: ID) {
    assert!(self.caps.contains(upgrade_cap_id), EUnknownCap);
}

fun insert_cap(self: &mut UpgradeCapManager, upgrade_cap: UpgradeCap) {
    let upgrade_cap_id = object::id(&upgrade_cap);
    let package_id = upgrade_cap.package();
    let policy = upgrade_cap.policy();

    self.caps.add(upgrade_cap_id, upgrade_cap);

    event::emit(UpgradeCapAdded { manager_id: self.id.to_inner(), upgrade_cap_id, package_id, policy });
}

fun request(
    self: &mut UpgradeCapManager,
    cap: &ManagerCap,
    upgrade_cap_id: ID,
    action: Action,
    clock: &Clock,
) {
    self.assert_controller(cap);
    self.assert_managed(upgrade_cap_id);
    assert!(!dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ERequestPending);
    assert!(self.caps[upgrade_cap_id].package().to_address() != @0x0, EAlreadyAuthorized);
    match (&action) {
        Action::Upgrade { digest } => assert!(digest.length() == DIGEST_LENGTH, EInvalidDigest),
        Action::MakeImmutable => (),
    };

    let requested_at_ms = clock.timestamp_ms();
    assert!(requested_at_ms <= MAX_TIMESTAMP_MS, ETimestampOverflow);

    let ready_at_ms = requested_at_ms + DELAY_MS;

    dynamic_field::add(&mut self.id, upgrade_cap_id, Request { action, ready_at_ms });

    match (action) {
        Action::Upgrade { digest } => event::emit(UpgradeRequested {
            manager_id: self.id.to_inner(), upgrade_cap_id, digest, requested_at_ms, ready_at_ms,
        }),
        Action::MakeImmutable => event::emit(ImmutabilityRequested {
            manager_id: self.id.to_inner(), upgrade_cap_id, requested_at_ms, ready_at_ms,
        }),
    };
}

// === Test-Only Functions ===

/// Read-only custody access for tests; excluded from production bytecode.
#[test_only]
public(package) fun caps_for_testing(self: &UpgradeCapManager): &ObjectTable<ID, UpgradeCap> {
    &self.caps
}

/// Snapshots an upgrade action's digest; immutability has no digest.
#[test_only]
public(package) fun upgrade_digest_for_testing(self: &Action): Option<vector<u8>> {
    match (self) {
        Action::Upgrade { digest } => option::some(*digest),
        Action::MakeImmutable => option::none(),
    }
}

// === Events ===

public struct ManagerCreated has copy, drop {
    manager_id: ID,
    controller_id: ID,
}

public struct UpgradeCapAdded has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    policy: u8,
}

public struct UpgradeRequested has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    digest: vector<u8>,
    requested_at_ms: u64,
    ready_at_ms: u64,
}

public struct RequestCancelled has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    action: Action,
    ready_at_ms: u64,
}

public struct UpgradeAuthorized has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    digest: vector<u8>,
    ready_at_ms: u64,
}

public struct UpgradeCommitted has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    version: u64,
}

public struct ImmutabilityRequested has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    requested_at_ms: u64,
    ready_at_ms: u64,
}

public struct PackageMadeImmutable has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    ready_at_ms: u64,
}

// === Constants ===

/// Maximum simultaneously custodied native caps; burning a cap frees a slot.
const MAX_CAPS: u64 = 256;
const DELAY_MS: u64 = 172_800_000;
const MAX_TIMESTAMP_MS: u64 = 18_446_744_073_709_551_615 - DELAY_MS;
const DIGEST_LENGTH: u64 = 32;

// === Errors ===

#[error(code = 0)]
const EAlreadyAuthorized: vector<u8> = b"An outstanding native upgrade ticket prevents enrollment or requests";
#[error(code = 1)]
const EWrongController: vector<u8> = b"Controller belongs to a different manager";
#[error(code = 2)]
const ERequestPending: vector<u8> = b"Cancel the existing request before requesting another";
#[error(code = 3)]
const EInvalidDigest: vector<u8> = b"A native upgrade digest must contain 32 bytes";
#[error(code = 4)]
const ETimestampOverflow: vector<u8> = b"The complete 48-hour delay exceeds the timestamp range";
#[error(code = 5)]
const ENoRequest: vector<u8> = b"No action has been requested";
#[error(code = 6)]
const EWrongAction: vector<u8> = b"The pending request authorizes a different action";
#[error(code = 7)]
const ETooEarly: vector<u8> = b"The request's full 48-hour delay has not elapsed";
#[error(code = 8)]
const EUnknownCap: vector<u8> = b"This UpgradeCap is not held by this manager";
#[error(code = 9)]
const ECapacityReached: vector<u8> = b"This manager already holds the maximum number of UpgradeCaps";

// === Imports ===

use sui::{
    clock::Clock,
    dynamic_field,
    event,
    object_table::{Self, ObjectTable},
    package::{Self, UpgradeCap, UpgradeReceipt, UpgradeTicket},
};
