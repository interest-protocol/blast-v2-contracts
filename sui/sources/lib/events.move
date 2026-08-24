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

/// Emitted after the zero-share global trade-fee configuration is created.
public struct TradeFeeConfigCreated has copy, drop {
    config_id: ID,
    protocol_fee_share_bps: u64,
}

/// Emitted after the bounded cold launch configuration is created.
public struct LaunchConfigCreated has copy, drop {
    config_id: ID,
    max_quote_assets: u64,
    max_migration_witnesses: u64,
    quote_migration_fee_bps: u64,
    meme_graduation_allocation_bps: u64,
}

/// Emitted after a quote and its initial migration target are admitted.
public struct QuoteAllowed has copy, drop {
    config_id: ID,
    quote: TypeName,
    migration_quote_target: u64,
}

/// Emitted after the target used by future launches for one quote changes.
public struct QuoteMigrationTargetChanged has copy, drop {
    config_id: ID,
    quote: TypeName,
    old_migration_quote_target: u64,
    new_migration_quote_target: u64,
}

/// Emitted after a quote is removed from future launch admission.
public struct QuoteRemoved has copy, drop {
    config_id: ID,
    quote: TypeName,
    previous_migration_quote_target: u64,
}

/// Emitted after the graduation defaults snapshotted by future launches change.
public struct GraduationDefaultsChanged has copy, drop {
    config_id: ID,
    old_quote_migration_fee_bps: u64,
    old_meme_graduation_allocation_bps: u64,
    new_quote_migration_fee_bps: u64,
    new_meme_graduation_allocation_bps: u64,
}

/// Emitted after an external migrator witness type is admitted for future launches.
public struct MigrationWitnessAllowed has copy, drop {
    config_id: ID,
    migration_witness: TypeName,
}

/// Emitted after an external migrator witness type is removed from future launches.
public struct MigrationWitnessRemoved has copy, drop {
    config_id: ID,
    migration_witness: TypeName,
}

/// Emitted after the live global protocol fee share is changed.
public struct ProtocolFeeShareChanged has copy, drop {
    config_id: ID,
    old_protocol_fee_share_bps: u64,
    new_protocol_fee_share_bps: u64,
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

/// Emitted after a generated OTW currency and its launch ticket are created.
public struct LaunchTicketCreated has copy, drop {
    ticket_id: ID,
    meme: TypeName,
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    launcher: address,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
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

public(package) fun trade_fee_config_created(
    config_id: ID,
    protocol_fee_share_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(TradeFeeConfigCreated {
        config_id,
        protocol_fee_share_bps,
    });
}

public(package) fun launch_config_created(
    config_id: ID,
    max_quote_assets: u64,
    max_migration_witnesses: u64,
    quote_migration_fee_bps: u64,
    meme_graduation_allocation_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchConfigCreated {
        config_id,
        max_quote_assets,
        max_migration_witnesses,
        quote_migration_fee_bps,
        meme_graduation_allocation_bps,
    });
}

public(package) fun quote_allowed<Quote>(config_id: ID, migration_quote_target: u64) {
    blast_fun::events_wrapper::emit_event(QuoteAllowed {
        config_id,
        quote: type_name::with_original_ids<Quote>(),
        migration_quote_target,
    });
}

public(package) fun quote_migration_target_changed<Quote>(
    config_id: ID,
    old_migration_quote_target: u64,
    new_migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteMigrationTargetChanged {
        config_id,
        quote: type_name::with_original_ids<Quote>(),
        old_migration_quote_target,
        new_migration_quote_target,
    });
}

public(package) fun quote_removed<Quote>(
    config_id: ID,
    previous_migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteRemoved {
        config_id,
        quote: type_name::with_original_ids<Quote>(),
        previous_migration_quote_target,
    });
}

public(package) fun graduation_defaults_changed(
    config_id: ID,
    old_quote_migration_fee_bps: u64,
    old_meme_graduation_allocation_bps: u64,
    new_quote_migration_fee_bps: u64,
    new_meme_graduation_allocation_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(GraduationDefaultsChanged {
        config_id,
        old_quote_migration_fee_bps,
        old_meme_graduation_allocation_bps,
        new_quote_migration_fee_bps,
        new_meme_graduation_allocation_bps,
    });
}

public(package) fun migration_witness_allowed<MigrationWitness>(config_id: ID) {
    blast_fun::events_wrapper::emit_event(MigrationWitnessAllowed {
        config_id,
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
    });
}

public(package) fun migration_witness_removed<MigrationWitness>(config_id: ID) {
    blast_fun::events_wrapper::emit_event(MigrationWitnessRemoved {
        config_id,
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
    });
}

public(package) fun protocol_fee_share_changed(
    config_id: ID,
    old_protocol_fee_share_bps: u64,
    new_protocol_fee_share_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(ProtocolFeeShareChanged {
        config_id,
        old_protocol_fee_share_bps,
        new_protocol_fee_share_bps,
    });
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

public(package) fun launch_ticket_created<Meme>(
    ticket_id: ID,
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    launcher: address,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
) {
    blast_fun::events_wrapper::emit_event(LaunchTicketCreated {
        ticket_id,
        meme: type_name::with_original_ids<Meme>(),
        treasury_cap_id,
        metadata_cap_id,
        launcher,
        creator,
        x_identity_hash,
        burnable,
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
public fun trade_fee_config_created_fields(
    self: &TradeFeeConfigCreated,
): (ID, u64) {
    (self.config_id, self.protocol_fee_share_bps)
}

#[test_only]
public fun launch_config_created_fields(
    self: &LaunchConfigCreated,
): (ID, u64, u64, u64, u64) {
    (
        self.config_id,
        self.max_quote_assets,
        self.max_migration_witnesses,
        self.quote_migration_fee_bps,
        self.meme_graduation_allocation_bps,
    )
}

#[test_only]
public fun quote_allowed_fields(self: &QuoteAllowed): (ID, TypeName, u64) {
    (self.config_id, self.quote, self.migration_quote_target)
}

#[test_only]
public fun quote_migration_target_changed_fields(
    self: &QuoteMigrationTargetChanged,
): (ID, TypeName, u64, u64) {
    (
        self.config_id,
        self.quote,
        self.old_migration_quote_target,
        self.new_migration_quote_target,
    )
}

#[test_only]
public fun quote_removed_fields(self: &QuoteRemoved): (ID, TypeName, u64) {
    (
        self.config_id,
        self.quote,
        self.previous_migration_quote_target,
    )
}

#[test_only]
public fun graduation_defaults_changed_fields(
    self: &GraduationDefaultsChanged,
): (ID, u64, u64, u64, u64) {
    (
        self.config_id,
        self.old_quote_migration_fee_bps,
        self.old_meme_graduation_allocation_bps,
        self.new_quote_migration_fee_bps,
        self.new_meme_graduation_allocation_bps,
    )
}

#[test_only]
public fun migration_witness_allowed_fields(
    self: &MigrationWitnessAllowed,
): (ID, TypeName) {
    (self.config_id, self.migration_witness)
}

#[test_only]
public fun migration_witness_removed_fields(
    self: &MigrationWitnessRemoved,
): (ID, TypeName) {
    (self.config_id, self.migration_witness)
}

#[test_only]
public fun protocol_fee_share_changed_fields(
    self: &ProtocolFeeShareChanged,
): (ID, u64, u64) {
    (
        self.config_id,
        self.old_protocol_fee_share_bps,
        self.new_protocol_fee_share_bps,
    )
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

#[test_only]
public fun launch_ticket_created_fields(
    self: &LaunchTicketCreated,
): (ID, TypeName, ID, ID, address, Option<address>, Option<vector<u8>>, bool) {
    (
        self.ticket_id,
        self.meme,
        self.treasury_cap_id,
        self.metadata_cap_id,
        self.launcher,
        self.creator,
        self.x_identity_hash,
        self.burnable,
    )
}
