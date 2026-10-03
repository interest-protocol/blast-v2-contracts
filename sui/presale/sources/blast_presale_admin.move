// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The presale package's two-tier administration.
///
/// One `AdminCap` administers the package: protocol fee rates and their destination, the Quote
/// types and migrators new presales may use, holder-reward rounds, and dependency-only upgrades.
/// The shared `AdminRegistry` records the only cap the package accepts. A Sui owned object cannot
/// be taken from its owner, so the cold `SuperAdminCap` removes a cap by replacing or clearing
/// that record, and has no other power.
module blast_presale::blast_presale_admin;

// === Public Types ===

/// Cold authority that can only replace or revoke the `AdminCap`. Without `store` it moves only
/// through `transfer_super_admin`, so it cannot be wrapped or sent by a generic transfer.
public struct SuperAdminCap has key {
    id: UID,
}

/// The package's operational administrator, accepted only while `AdminRegistry` records it.
public struct AdminCap has key, store {
    id: UID,
}

/// Shared singleton recording the one `AdminCap` the package accepts, or none after a revocation.
public struct AdminRegistry has key {
    id: UID,
    admin_cap_id: Option<ID>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    let admin_registry = AdminRegistry {
        id: object::new(ctx),
        admin_cap_id: option::some(object::id(&admin_cap)),
    };

    transfer::transfer(SuperAdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::transfer(admin_cap, ctx.sender());
    transfer::share_object(admin_registry);
}

// === Public Functions ===

/// Mints a new `AdminCap` and records it as the only accepted cap, so the previous cap, if any,
/// stops working in the same transaction.
public fun replace_admin_cap(
    self: &mut AdminRegistry,
    _: &SuperAdminCap,
    ctx: &mut TxContext,
): AdminCap {
    let admin_cap = AdminCap { id: object::new(ctx) };
    let previous_admin_cap_id = self.admin_cap_id;
    self.admin_cap_id = option::some(object::id(&admin_cap));

    event::emit(AdminCapReplaced {
        previous_admin_cap_id,
        admin_cap_id: object::id(&admin_cap),
    });

    admin_cap
}

/// Clears the accepted cap, stopping every administrator operation until `replace_admin_cap`.
public fun revoke_admin_cap(self: &mut AdminRegistry, _: &SuperAdminCap) {
    assert!(self.admin_cap_id.is_some(), ENoAdminCap);

    let admin_cap_id = self.admin_cap_id.extract();

    event::emit(AdminCapRevoked { admin_cap_id });
}

/// Transfers the super administrator to `recipient`, the only way it can move.
public fun transfer_super_admin(self: SuperAdminCap, recipient: address) {
    assert!(recipient != @0x0, EInvalidRecipient);

    transfer::transfer(self, recipient);
}

// === Package Functions ===

/// Aborts unless `admin_cap` is the cap the registry accepts.
public(package) fun assert_admin_cap(self: &AdminRegistry, admin_cap: &AdminCap) {
    assert!(self.admin_cap_id == option::some(object::id(admin_cap)), EInvalidAdminCap);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
/// A registry accepting the returned cap, both left unshared for focused tests.
public fun new_for_testing(ctx: &mut TxContext): (AdminRegistry, AdminCap) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    let admin_registry = AdminRegistry {
        id: object::new(ctx),
        admin_cap_id: option::some(object::id(&admin_cap)),
    };

    (admin_registry, admin_cap)
}

#[test_only]
public fun super_admin_for_testing(ctx: &mut TxContext): SuperAdminCap {
    SuperAdminCap { id: object::new(ctx) }
}

#[test_only]
public fun destroy_for_testing(self: AdminRegistry, admin_cap: AdminCap) {
    std::unit_test::destroy(self);
    std::unit_test::destroy(admin_cap);
}

#[test_only]
public fun admin_cap_id_for_testing(self: &AdminRegistry): Option<ID> {
    self.admin_cap_id
}

#[test_only]
public fun admin_cap_replaced_fields(event: &AdminCapReplaced): (Option<ID>, ID) {
    (event.previous_admin_cap_id, event.admin_cap_id)
}

#[test_only]
public fun admin_cap_revoked_fields(event: &AdminCapRevoked): ID {
    event.admin_cap_id
}

// === Events ===

public struct AdminCapReplaced has copy, drop {
    previous_admin_cap_id: Option<ID>,
    admin_cap_id: ID,
}

public struct AdminCapRevoked has copy, drop {
    admin_cap_id: ID,
}

// === Errors ===

#[error(code = 0)]
const EInvalidAdminCap: vector<u8> = b"This AdminCap is not the one the presale package accepts.";

#[error(code = 1)]
const ENoAdminCap: vector<u8> = b"No AdminCap is accepted, so there is none to revoke.";

#[error(code = 2)]
const EInvalidRecipient: vector<u8> = b"The super administrator cannot go to the zero address.";

// === Imports ===

use sui::event;
