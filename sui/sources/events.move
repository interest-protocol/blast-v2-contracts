module blast_fun::events;

use std::type_name::{Self, TypeName};

// === Public Structs ===

/// Emitted after the singleton protocol administration root is created.
public struct ProtocolAuthorityCreated has copy, drop {
    authority_id: ID,
    super_admin_cap_id: ID,
    super_admin_recipient: address,
    max_admins: u64,
    super_admin_transfer_delay_ms: u64,
}

/// Emitted after the disabled shared X backend signer configuration is created.
public struct XClaimConfigCreated has copy, drop {
    config_id: ID,
}

/// Emitted after a routine protocol administrator is created and delivered.
public struct AdminAdded has copy, drop {
    authority_id: ID,
    admin_cap_id: ID,
    recipient: address,
}

/// Emitted after a routine protocol administrator is revoked.
public struct AdminRevoked has copy, drop {
    authority_id: ID,
    admin_cap_id: ID,
}

/// Emitted after a cap holder deletes an admin cap; records whether live membership was removed.
public struct AdminDestroyed has copy, drop {
    authority_id: ID,
    admin_cap_id: ID,
    was_active: bool,
}

/// Emitted after a delayed root-authority transfer is scheduled.
public struct SuperAdminTransferStarted has copy, drop {
    authority_id: ID,
    current_super_admin_cap_id: ID,
    recipient: address,
    execute_after_ms: u64,
}

/// Emitted after a pending root-authority transfer is cancelled or replaced.
public struct SuperAdminTransferCancelled has copy, drop {
    authority_id: ID,
    current_super_admin_cap_id: ID,
    recipient: address,
}

/// Emitted after the proposed recipient accepts root authority.
public struct SuperAdminTransferred has copy, drop {
    authority_id: ID,
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
}

/// Emitted after the X claim signer is initially set or rotated.
public struct XClaimSignerSet has copy, drop {
    config_id: ID,
    previous_public_key: vector<u8>,
    signer_public_key: vector<u8>,
}

/// Emitted after the current X claim signer is revoked.
public struct XClaimSignerRevoked has copy, drop {
    config_id: ID,
    previous_public_key: vector<u8>,
}

/// Emitted after either creator identity claims the meme type's single creator capability.
public struct CreatorCapClaimed has copy, drop {
    meme: TypeName,
    x_identity_hash: Option<vector<u8>>,
    creator: address,
    x_claim_expiry_ms: Option<u64>,
}

// === Package Functions ===

public(package) fun protocol_authority_created(
    authority_id: ID,
    super_admin_cap_id: ID,
    super_admin_recipient: address,
    max_admins: u64,
    super_admin_transfer_delay_ms: u64,
) {
    blast_fun::events_wrapper::emit_event(ProtocolAuthorityCreated {
        authority_id,
        super_admin_cap_id,
        super_admin_recipient,
        max_admins,
        super_admin_transfer_delay_ms,
    });
}

public(package) fun x_claim_config_created(config_id: ID) {
    blast_fun::events_wrapper::emit_event(XClaimConfigCreated { config_id });
}

public(package) fun admin_added(authority_id: ID, admin_cap_id: ID, recipient: address) {
    blast_fun::events_wrapper::emit_event(AdminAdded { authority_id, admin_cap_id, recipient });
}

public(package) fun admin_revoked(authority_id: ID, admin_cap_id: ID) {
    blast_fun::events_wrapper::emit_event(AdminRevoked { authority_id, admin_cap_id });
}

public(package) fun admin_destroyed(authority_id: ID, admin_cap_id: ID, was_active: bool) {
    blast_fun::events_wrapper::emit_event(AdminDestroyed {
        authority_id,
        admin_cap_id,
        was_active,
    });
}

public(package) fun super_admin_transfer_started(
    authority_id: ID,
    current_super_admin_cap_id: ID,
    recipient: address,
    execute_after_ms: u64,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferStarted {
        authority_id,
        current_super_admin_cap_id,
        recipient,
        execute_after_ms,
    });
}

public(package) fun super_admin_transfer_cancelled(
    authority_id: ID,
    current_super_admin_cap_id: ID,
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferCancelled {
        authority_id,
        current_super_admin_cap_id,
        recipient,
    });
}

public(package) fun super_admin_transferred(
    authority_id: ID,
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferred {
        authority_id,
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    });
}

public(package) fun x_claim_signer_set(
    config_id: ID,
    previous_public_key: vector<u8>,
    signer_public_key: vector<u8>,
) {
    blast_fun::events_wrapper::emit_event(XClaimSignerSet {
        config_id,
        previous_public_key,
        signer_public_key,
    });
}

public(package) fun x_claim_signer_revoked(config_id: ID, previous_public_key: vector<u8>) {
    blast_fun::events_wrapper::emit_event(XClaimSignerRevoked {
        config_id,
        previous_public_key,
    });
}

public(package) fun creator_cap_claimed<Meme>(
    creator: address,
    x_identity_hash: Option<vector<u8>>,
    x_claim_expiry_ms: Option<u64>,
) {
    blast_fun::events_wrapper::emit_event(CreatorCapClaimed {
        meme: type_name::with_original_ids<Meme>(),
        x_identity_hash,
        creator,
        x_claim_expiry_ms,
    });
}

// === Test-Only Functions ===

/// Every `T` payload emitted so far, unwrapped from the package `Event<T>` envelope.
#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_fun::events_wrapper::Event<T>>().do!(
        |event| out.push_back(event.unwrap()),
    );

    out
}

/// Exactly one `T` payload emitted so far.
#[test_only]
public fun collect_one<T: copy + drop>(abort_code: u64): T {
    let mut events = collect<T>();

    assert!(events.length() == 1, abort_code);

    events.pop_back()
}

#[test_only]
public fun protocol_authority_created_fields(
    self: &ProtocolAuthorityCreated,
): (ID, ID, address, u64, u64) {
    (
        self.authority_id,
        self.super_admin_cap_id,
        self.super_admin_recipient,
        self.max_admins,
        self.super_admin_transfer_delay_ms,
    )
}

#[test_only]
public fun x_claim_config_created_fields(self: &XClaimConfigCreated): ID {
    self.config_id
}

#[test_only]
public fun admin_added_fields(self: &AdminAdded): (ID, ID, address) {
    (self.authority_id, self.admin_cap_id, self.recipient)
}

#[test_only]
public fun admin_revoked_fields(self: &AdminRevoked): (ID, ID) {
    (self.authority_id, self.admin_cap_id)
}

#[test_only]
public fun admin_destroyed_fields(self: &AdminDestroyed): (ID, ID, bool) {
    (self.authority_id, self.admin_cap_id, self.was_active)
}

#[test_only]
public fun super_admin_transfer_started_fields(
    self: &SuperAdminTransferStarted,
): (ID, ID, address, u64) {
    (
        self.authority_id,
        self.current_super_admin_cap_id,
        self.recipient,
        self.execute_after_ms,
    )
}

#[test_only]
public fun super_admin_transfer_cancelled_fields(
    self: &SuperAdminTransferCancelled,
): (ID, ID, address) {
    (self.authority_id, self.current_super_admin_cap_id, self.recipient)
}

#[test_only]
public fun super_admin_transferred_fields(
    self: &SuperAdminTransferred,
): (ID, ID, ID, address) {
    (
        self.authority_id,
        self.previous_super_admin_cap_id,
        self.new_super_admin_cap_id,
        self.recipient,
    )
}

#[test_only]
public fun x_claim_signer_set_fields(
    self: &XClaimSignerSet,
): (ID, vector<u8>, vector<u8>) {
    (self.config_id, self.previous_public_key, self.signer_public_key)
}

#[test_only]
public fun x_claim_signer_revoked_fields(self: &XClaimSignerRevoked): (ID, vector<u8>) {
    (self.config_id, self.previous_public_key)
}

#[test_only]
public fun creator_cap_claimed_fields(
    self: &CreatorCapClaimed,
): (TypeName, Option<vector<u8>>, address, Option<u64>) {
    (
        self.meme,
        self.x_identity_hash,
        self.creator,
        self.x_claim_expiry_ms,
    )
}
