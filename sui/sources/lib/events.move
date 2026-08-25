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

/// Emitted after the disabled, zero-share shared runtime configuration is created.
public struct RuntimeConfigCreated has copy, drop {
    runtime_config_id: ID,
    protocol_fee_share_bps: u64,
}

/// Emitted after the bounded cold launch configuration is created.
public struct LaunchConfigCreated has copy, drop {
    config_id: ID,
    max_quote_assets: u64,
    max_migration_witnesses: u64,
    quote_migration_fee_bps: u64,
    meme_graduation_allocation_bps: u64,
    meme_liquidity_provision_bps: u64,
}

/// Emitted after a quote and its initial migration target are admitted.
public struct QuoteAllowed has copy, drop {
    quote: TypeName,
    migration_quote_target: u64,
}

/// Emitted after the target used by future launches for one quote changes.
public struct QuoteMigrationTargetChanged has copy, drop {
    quote: TypeName,
    old_migration_quote_target: u64,
    new_migration_quote_target: u64,
}

/// Emitted after a quote is disallowed from future launch admission.
public struct QuoteDisallowed has copy, drop {
    quote: TypeName,
    previous_migration_quote_target: u64,
}

/// Emitted after the graduation defaults snapshotted by future launches change.
public struct GraduationDefaultsChanged has copy, drop {
    old_quote_migration_fee_bps: u64,
    old_meme_graduation_allocation_bps: u64,
    old_meme_liquidity_provision_bps: u64,
    new_quote_migration_fee_bps: u64,
    new_meme_graduation_allocation_bps: u64,
    new_meme_liquidity_provision_bps: u64,
}

/// Emitted after an external migrator witness type is admitted for future launches.
public struct MigrationWitnessAllowed has copy, drop {
    migration_witness: TypeName,
}

/// Emitted after an external migrator witness type is disallowed for future launches.
public struct MigrationWitnessDisallowed has copy, drop {
    migration_witness: TypeName,
}

/// Emitted after the live global protocol fee share is changed.
public struct ProtocolFeeShareChanged has copy, drop {
    old_protocol_fee_share_bps: u64,
    new_protocol_fee_share_bps: u64,
}

/// Emitted after routine protocol administration is granted and its cap is delivered.
public struct AdminGranted has copy, drop {
    admin_cap_id: ID,
    recipient: address,
}

/// Emitted after a routine protocol administrator is revoked.
public struct AdminRevoked has copy, drop {
    admin_cap_id: ID,
}

/// Emitted after a cap holder deletes an admin cap; records whether live membership was removed.
public struct AdminDestroyed has copy, drop {
    admin_cap_id: ID,
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

/// Emitted after the X claim signer is initially set or rotated.
public struct XClaimSignerSet has copy, drop {
    previous_public_key: vector<u8>,
    signer_public_key: vector<u8>,
}

/// Emitted after the current X claim signer is revoked.
public struct XClaimSignerRevoked has copy, drop {
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
    initial_supply: u64,
    metadata_cap_id: ID,
    launcher: address,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
}

/// Emitted after Blast's package capabilities are validated and placed in shared custody.
public struct PackageAdminCreated has copy, drop {
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    package_version: u64,
    policy: u8,
}

/// Emitted after an active protocol admin authorizes an exact package digest.
public struct UpgradeAuthorized has copy, drop {
    package_id: ID,
    package_version: u64,
    policy: u8,
    digest: vector<u8>,
}

/// Emitted after the native upgrade receipt advances the wrapped UpgradeCap.
public struct UpgradeCommitted has copy, drop {
    new_package_id: ID,
    previous_version: u64,
    new_version: u64,
}

/// Emitted after an active protocol admin irreversibly narrows upgrade policy.
public struct UpgradePolicyRestricted has copy, drop {
    previous_policy: u8,
    new_policy: u8,
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

public(package) fun runtime_config_created(
    runtime_config_id: ID,
    protocol_fee_share_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(RuntimeConfigCreated {
        runtime_config_id,
        protocol_fee_share_bps,
    });
}

public(package) fun launch_config_created(
    config_id: ID,
    max_quote_assets: u64,
    max_migration_witnesses: u64,
    quote_migration_fee_bps: u64,
    meme_graduation_allocation_bps: u64,
    meme_liquidity_provision_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchConfigCreated {
        config_id,
        max_quote_assets,
        max_migration_witnesses,
        quote_migration_fee_bps,
        meme_graduation_allocation_bps,
        meme_liquidity_provision_bps,
    });
}

public(package) fun quote_allowed<Quote>(migration_quote_target: u64) {
    blast_fun::events_wrapper::emit_event(QuoteAllowed {
        quote: type_name::with_original_ids<Quote>(),
        migration_quote_target,
    });
}

public(package) fun quote_migration_target_changed<Quote>(
    old_migration_quote_target: u64,
    new_migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteMigrationTargetChanged {
        quote: type_name::with_original_ids<Quote>(),
        old_migration_quote_target,
        new_migration_quote_target,
    });
}

public(package) fun quote_disallowed<Quote>(
    previous_migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteDisallowed {
        quote: type_name::with_original_ids<Quote>(),
        previous_migration_quote_target,
    });
}

public(package) fun graduation_defaults_changed(
    old_quote_migration_fee_bps: u64,
    old_meme_graduation_allocation_bps: u64,
    old_meme_liquidity_provision_bps: u64,
    new_quote_migration_fee_bps: u64,
    new_meme_graduation_allocation_bps: u64,
    new_meme_liquidity_provision_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(GraduationDefaultsChanged {
        old_quote_migration_fee_bps,
        old_meme_graduation_allocation_bps,
        old_meme_liquidity_provision_bps,
        new_quote_migration_fee_bps,
        new_meme_graduation_allocation_bps,
        new_meme_liquidity_provision_bps,
    });
}

public(package) fun migration_witness_allowed<MigrationWitness>() {
    blast_fun::events_wrapper::emit_event(MigrationWitnessAllowed {
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
    });
}

public(package) fun migration_witness_disallowed<MigrationWitness>() {
    blast_fun::events_wrapper::emit_event(MigrationWitnessDisallowed {
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
    });
}

public(package) fun protocol_fee_share_changed(
    old_protocol_fee_share_bps: u64,
    new_protocol_fee_share_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(ProtocolFeeShareChanged {
        old_protocol_fee_share_bps,
        new_protocol_fee_share_bps,
    });
}

public(package) fun admin_granted(admin_cap_id: ID, recipient: address) {
    blast_fun::events_wrapper::emit_event(AdminGranted { admin_cap_id, recipient });
}

public(package) fun admin_revoked(admin_cap_id: ID) {
    blast_fun::events_wrapper::emit_event(AdminRevoked { admin_cap_id });
}

public(package) fun admin_destroyed(admin_cap_id: ID, was_active: bool) {
    blast_fun::events_wrapper::emit_event(AdminDestroyed {
        admin_cap_id,
        was_active,
    });
}

public(package) fun super_admin_transfer_started(
    recipient: address,
    execute_after_ms: u64,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferStarted {
        recipient,
        execute_after_ms,
    });
}

public(package) fun super_admin_transfer_cancelled(
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferCancelled { recipient });
}

public(package) fun super_admin_transferred(
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferred {
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    });
}

public(package) fun x_claim_signer_set(
    previous_public_key: vector<u8>,
    signer_public_key: vector<u8>,
) {
    blast_fun::events_wrapper::emit_event(XClaimSignerSet {
        previous_public_key,
        signer_public_key,
    });
}

public(package) fun x_claim_signer_revoked(
    previous_public_key: vector<u8>,
) {
    blast_fun::events_wrapper::emit_event(XClaimSignerRevoked {
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
    initial_supply: u64,
    metadata_cap_id: ID,
    launcher: address,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
) {
    blast_fun::events_wrapper::emit_event(LaunchTicketCreated {
        ticket_id,
        meme: type_name::with_original_ids<Meme>(),
        initial_supply,
        metadata_cap_id,
        launcher,
        creator,
        x_identity_hash,
        burnable,
    });
}

public(package) fun package_admin_created(
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    package_version: u64,
    policy: u8,
) {
    blast_fun::events_wrapper::emit_event(PackageAdminCreated {
        package_admin_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        package_version,
        policy,
    });
}

public(package) fun upgrade_authorized(
    package_id: ID,
    package_version: u64,
    policy: u8,
    digest: vector<u8>,
) {
    blast_fun::events_wrapper::emit_event(UpgradeAuthorized {
        package_id,
        package_version,
        policy,
        digest,
    });
}

public(package) fun upgrade_committed(
    new_package_id: ID,
    previous_version: u64,
    new_version: u64,
) {
    blast_fun::events_wrapper::emit_event(UpgradeCommitted {
        new_package_id,
        previous_version,
        new_version,
    });
}

public(package) fun upgrade_policy_restricted(previous_policy: u8, new_policy: u8) {
    blast_fun::events_wrapper::emit_event(UpgradePolicyRestricted {
        previous_policy,
        new_policy,
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
public fun runtime_config_created_fields(
    self: &RuntimeConfigCreated,
): (ID, u64) {
    (self.runtime_config_id, self.protocol_fee_share_bps)
}

#[test_only]
public fun launch_config_created_fields(
    self: &LaunchConfigCreated,
): (ID, u64, u64, u64, u64, u64) {
    (
        self.config_id,
        self.max_quote_assets,
        self.max_migration_witnesses,
        self.quote_migration_fee_bps,
        self.meme_graduation_allocation_bps,
        self.meme_liquidity_provision_bps,
    )
}

#[test_only]
public fun quote_allowed_fields(self: &QuoteAllowed): (TypeName, u64) {
    (self.quote, self.migration_quote_target)
}

#[test_only]
public fun quote_migration_target_changed_fields(
    self: &QuoteMigrationTargetChanged,
): (TypeName, u64, u64) {
    (
        self.quote,
        self.old_migration_quote_target,
        self.new_migration_quote_target,
    )
}

#[test_only]
public fun quote_disallowed_fields(self: &QuoteDisallowed): (TypeName, u64) {
    (
        self.quote,
        self.previous_migration_quote_target,
    )
}

#[test_only]
public fun graduation_defaults_changed_fields(
    self: &GraduationDefaultsChanged,
): (u64, u64, u64, u64, u64, u64) {
    (
        self.old_quote_migration_fee_bps,
        self.old_meme_graduation_allocation_bps,
        self.old_meme_liquidity_provision_bps,
        self.new_quote_migration_fee_bps,
        self.new_meme_graduation_allocation_bps,
        self.new_meme_liquidity_provision_bps,
    )
}

#[test_only]
public fun migration_witness_allowed_fields(
    self: &MigrationWitnessAllowed,
): TypeName {
    self.migration_witness
}

#[test_only]
public fun migration_witness_disallowed_fields(
    self: &MigrationWitnessDisallowed,
): TypeName {
    self.migration_witness
}

#[test_only]
public fun protocol_fee_share_changed_fields(
    self: &ProtocolFeeShareChanged,
): (u64, u64) {
    (
        self.old_protocol_fee_share_bps,
        self.new_protocol_fee_share_bps,
    )
}

#[test_only]
public fun admin_granted_fields(self: &AdminGranted): (ID, address) {
    (self.admin_cap_id, self.recipient)
}

#[test_only]
public fun admin_revoked_fields(self: &AdminRevoked): ID {
    self.admin_cap_id
}

#[test_only]
public fun admin_destroyed_fields(self: &AdminDestroyed): (ID, bool) {
    (self.admin_cap_id, self.was_active)
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

#[test_only]
public fun x_claim_signer_set_fields(
    self: &XClaimSignerSet,
): (vector<u8>, vector<u8>) {
    (
        self.previous_public_key,
        self.signer_public_key,
    )
}

#[test_only]
public fun x_claim_signer_revoked_fields(self: &XClaimSignerRevoked): vector<u8> {
    self.previous_public_key
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
): (ID, TypeName, u64, ID, address, Option<address>, Option<vector<u8>>, bool) {
    (
        self.ticket_id,
        self.meme,
        self.initial_supply,
        self.metadata_cap_id,
        self.launcher,
        self.creator,
        self.x_identity_hash,
        self.burnable,
    )
}

#[test_only]
public fun package_admin_created_fields(
    self: &PackageAdminCreated,
): (ID, ID, ID, ID, u64, u8) {
    (
        self.package_admin_id,
        self.publisher_id,
        self.upgrade_cap_id,
        self.package_id,
        self.package_version,
        self.policy,
    )
}

#[test_only]
public fun upgrade_policy_restricted_fields(self: &UpgradePolicyRestricted): (u8, u8) {
    (self.previous_policy, self.new_policy)
}

#[test_only]
public fun upgrade_authorized_fields(
    self: &UpgradeAuthorized,
): (ID, u64, u8, vector<u8>) {
    (
        self.package_id,
        self.package_version,
        self.policy,
        self.digest,
    )
}

#[test_only]
public fun upgrade_committed_fields(
    self: &UpgradeCommitted,
): (ID, u64, u64) {
    (
        self.new_package_id,
        self.previous_version,
        self.new_version,
    )
}
