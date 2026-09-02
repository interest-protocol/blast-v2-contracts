module blast_fun::events;

use std::type_name::{Self, TypeName};

// === Public Structs ===

/// Emitted after checked activation advances the shared bytecode cutover.
public struct PackageVersionAdvanced has copy, drop {
    previous_version: u64,
    new_version: u64,
}

/// Emitted after the trade-fee pair snapshotted by future launches changes.
public struct LaunchTradeFeesChanged has copy, drop {
    old_quote_fee_bps: u64,
    old_meme_fee_bps: u64,
    new_quote_fee_bps: u64,
    new_meme_fee_bps: u64,
}

/// Emitted after a quote and its initial curve parameters are admitted.
public struct QuoteAllowed has copy, drop {
    quote: TypeName,
    virtual_quote: u64,
    migration_quote_target: u64,
}

/// Emitted after either curve parameter used by future launches for one Quote changes.
public struct QuoteParametersChanged has copy, drop {
    quote: TypeName,
    old_virtual_quote: u64,
    old_migration_quote_target: u64,
    new_virtual_quote: u64,
    new_migration_quote_target: u64,
}

/// Emitted after a quote is disallowed from future launch admission.
public struct QuoteDisallowed has copy, drop {
    quote: TypeName,
    previous_virtual_quote: u64,
    previous_migration_quote_target: u64,
}

/// Emitted after the graduation defaults snapshotted by future launches change.
public struct GraduationDefaultsChanged has copy, drop {
    old_quote_migration_fee_bps: u64,
    old_protocol_meme_graduation_fee_bps: u64,
    old_meme_liquidity_provision_bps: u64,
    new_quote_migration_fee_bps: u64,
    new_protocol_meme_graduation_fee_bps: u64,
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
    sell_burn_bps: u64,
}

/// Emitted after one ticket is normalized into launch custody and immutable policy.
public struct LaunchCreated has copy, drop {
    launch_id: ID,
    ticket_id: ID,
    meme: TypeName,
    quote: TypeName,
    migration_witness: TypeName,
    launcher: address,
    metadata_cap_id: ID,
    sell_burn_bps: u64,
    initial_meme_supply: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
    pending_burn: u64,
    protocol_meme_graduation_fee: u64,
    meme_liquidity_provision: u64,
    protocol_meme_trade_fees: u64,
    creator_meme_trade_fees: u64,
    protocol_quote_trade_fees: u64,
    creator_quote_trade_fees: u64,
    virtual_quote: u64,
    migration_quote_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
}

/// Emitted after a completed Quote-for-Meme curve purchase.
public struct Bought has copy, drop {
    launch_id: ID,
    meme: TypeName,
    quote: TypeName,
    buyer: address,
    quote_supplied: u64,
    quote_in_gross: u64,
    quote_refund: u64,
    quote_fee: u64,
    quote_in_net: u64,
    meme_out_gross: u64,
    meme_fee: u64,
    meme_out_net: u64,
    protocol_fee_share_bps: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
    crossed_threshold: bool,
}

/// Emitted after a completed Meme-for-Quote curve sale.
public struct Sold has copy, drop {
    launch_id: ID,
    meme: TypeName,
    quote: TypeName,
    seller: address,
    meme_in_gross: u64,
    meme_fee: u64,
    meme_in_after_fee: u64,
    progress_bps: u64,
    burn_bps: u64,
    pending_burn_delta: u64,
    pending_burn_total: u64,
    meme_in_effective: u64,
    quote_out_gross: u64,
    quote_fee: u64,
    quote_out_net: u64,
    protocol_fee_share_bps: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
}

/// Emitted after terminal assets are atomically handed to a selected migrator.
public struct Migrated has copy, drop {
    launch_id: ID,
    meme: TypeName,
    quote: TypeName,
    migration_witness: TypeName,
    migrator: address,
    migration_meme: u64,
    migration_quote: u64,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
    protocol_meme_graduation_fee: u64,
    quote_migration_fee: u64,
    protocol_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
}

/// Emitted after a creator drains both accrued trade-fee balances.
public struct CreatorFeesClaimed has copy, drop {
    launch_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
}

/// Emitted after an administrator drains both accrued protocol balances.
public struct ProtocolFeesClaimed has copy, drop {
    launch_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
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

/// Emits an accepted operational package-generation advance.
public(package) fun package_version_advanced(previous_version: u64, new_version: u64) {
    blast_fun::events_wrapper::emit_event(PackageVersionAdvanced {
        previous_version,
        new_version,
    });
}

/// Emits replacement of the launch trade-fee defaults.
public(package) fun launch_trade_fees_changed(
    old_quote_fee_bps: u64,
    old_meme_fee_bps: u64,
    new_quote_fee_bps: u64,
    new_meme_fee_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchTradeFeesChanged {
        old_quote_fee_bps,
        old_meme_fee_bps,
        new_quote_fee_bps,
        new_meme_fee_bps,
    });
}

/// Emits admission of one quote type and its initial curve parameters.
public(package) fun quote_allowed<Quote>(
    virtual_quote: u64,
    migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteAllowed {
        quote: type_name::with_original_ids<Quote>(),
        virtual_quote,
        migration_quote_target,
    });
}

/// Emits replacement of one admitted quote type's curve parameters.
public(package) fun quote_parameters_changed<Quote>(
    old_virtual_quote: u64,
    old_migration_quote_target: u64,
    new_virtual_quote: u64,
    new_migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteParametersChanged {
        quote: type_name::with_original_ids<Quote>(),
        old_virtual_quote,
        old_migration_quote_target,
        new_virtual_quote,
        new_migration_quote_target,
    });
}

/// Emits removal of one quote type and its previous curve parameters.
public(package) fun quote_disallowed<Quote>(
    previous_virtual_quote: u64,
    previous_migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteDisallowed {
        quote: type_name::with_original_ids<Quote>(),
        previous_virtual_quote,
        previous_migration_quote_target,
    });
}

/// Emits replacement of the launch graduation defaults.
public(package) fun graduation_defaults_changed(
    old_quote_migration_fee_bps: u64,
    old_protocol_meme_graduation_fee_bps: u64,
    old_meme_liquidity_provision_bps: u64,
    new_quote_migration_fee_bps: u64,
    new_protocol_meme_graduation_fee_bps: u64,
    new_meme_liquidity_provision_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(GraduationDefaultsChanged {
        old_quote_migration_fee_bps,
        old_protocol_meme_graduation_fee_bps,
        old_meme_liquidity_provision_bps,
        new_quote_migration_fee_bps,
        new_protocol_meme_graduation_fee_bps,
        new_meme_liquidity_provision_bps,
    });
}

/// Emits admission of one sealed migration-witness type.
public(package) fun migration_witness_allowed<MigrationWitness>() {
    blast_fun::events_wrapper::emit_event(MigrationWitnessAllowed {
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
    });
}

/// Emits removal of one sealed migration-witness type.
public(package) fun migration_witness_disallowed<MigrationWitness>() {
    blast_fun::events_wrapper::emit_event(MigrationWitnessDisallowed {
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
    });
}

/// Emits replacement of the runtime protocol fee share.
public(package) fun protocol_fee_share_changed(
    old_protocol_fee_share_bps: u64,
    new_protocol_fee_share_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(ProtocolFeeShareChanged {
        old_protocol_fee_share_bps,
        new_protocol_fee_share_bps,
    });
}

/// Emits delivery of one newly active routine-admin capability.
public(package) fun admin_granted(admin_cap_id: ID, recipient: address) {
    blast_fun::events_wrapper::emit_event(AdminGranted { admin_cap_id, recipient });
}

/// Emits revocation of one routine-admin capability.
public(package) fun admin_revoked(admin_cap_id: ID) {
    blast_fun::events_wrapper::emit_event(AdminRevoked { admin_cap_id });
}

/// Emits destruction of a routine-admin capability and its prior registry state.
public(package) fun admin_destroyed(admin_cap_id: ID, was_active: bool) {
    blast_fun::events_wrapper::emit_event(AdminDestroyed {
        admin_cap_id,
        was_active,
    });
}

/// Emits the staged super-admin recipient and execution boundary.
public(package) fun super_admin_transfer_started(
    recipient: address,
    execute_after_ms: u64,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferStarted {
        recipient,
        execute_after_ms,
    });
}

/// Emits cancellation of the staged super-admin transfer.
public(package) fun super_admin_transfer_cancelled(
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(SuperAdminTransferCancelled { recipient });
}

/// Emits the completed replacement of the root capability.
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

/// Emits installation or rotation of the X-claim signer key.
public(package) fun x_claim_signer_set(
    previous_public_key: vector<u8>,
    signer_public_key: vector<u8>,
) {
    blast_fun::events_wrapper::emit_event(XClaimSignerSet {
        previous_public_key,
        signer_public_key,
    });
}

/// Emits revocation of the X-claim signer key.
public(package) fun x_claim_signer_revoked(
    previous_public_key: vector<u8>,
) {
    blast_fun::events_wrapper::emit_event(XClaimSignerRevoked {
        previous_public_key,
    });
}

/// Emits the one-time creator-cap claim and its resolved identity facts.
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

/// Emits creation of one generated-coin launch ticket.
public(package) fun launch_ticket_created<Meme>(
    ticket_id: ID,
    initial_supply: u64,
    metadata_cap_id: ID,
    launcher: address,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
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
        sell_burn_bps,
    });
}

/// Emits creation of normalized launch custody and its complete policy snapshot.
public(package) fun launch_created<Meme, Quote>(
    launch_id: ID,
    ticket_id: ID,
    migration_witness: TypeName,
    launcher: address,
    metadata_cap_id: ID,
    sell_burn_bps: u64,
    initial_meme_supply: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
    pending_burn: u64,
    protocol_meme_graduation_fee: u64,
    meme_liquidity_provision: u64,
    protocol_meme_trade_fees: u64,
    creator_meme_trade_fees: u64,
    protocol_quote_trade_fees: u64,
    creator_quote_trade_fees: u64,
    virtual_quote: u64,
    migration_quote_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchCreated {
        launch_id,
        ticket_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        migration_witness,
        launcher,
        metadata_cap_id,
        sell_burn_bps,
        initial_meme_supply,
        meme_reserve,
        real_quote_reserve,
        pending_burn,
        protocol_meme_graduation_fee,
        meme_liquidity_provision,
        protocol_meme_trade_fees,
        creator_meme_trade_fees,
        protocol_quote_trade_fees,
        creator_quote_trade_fees,
        virtual_quote,
        migration_quote_target,
        quote_fee_bps,
        meme_fee_bps,
        quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    });
}

/// Emits one completed Quote-for-Meme trade and resulting accounting state.
public(package) fun bought<Meme, Quote>(
    launch_id: ID,
    buyer: address,
    quote_supplied: u64,
    quote_in_gross: u64,
    quote_refund: u64,
    quote_fee: u64,
    quote_in_net: u64,
    meme_out_gross: u64,
    meme_fee: u64,
    meme_out_net: u64,
    protocol_fee_share_bps: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
    crossed_threshold: bool,
) {
    blast_fun::events_wrapper::emit_event(Bought {
        launch_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        buyer,
        quote_supplied,
        quote_in_gross,
        quote_refund,
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        protocol_fee_share_bps,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
        meme_reserve,
        real_quote_reserve,
        crossed_threshold,
    });
}

/// Emits one completed Meme-for-Quote trade and resulting accounting state.
public(package) fun sold<Meme, Quote>(
    launch_id: ID,
    seller: address,
    meme_in_gross: u64,
    meme_fee: u64,
    meme_in_after_fee: u64,
    progress_bps: u64,
    burn_bps: u64,
    pending_burn_delta: u64,
    pending_burn_total: u64,
    meme_in_effective: u64,
    quote_out_gross: u64,
    quote_fee: u64,
    quote_out_net: u64,
    protocol_fee_share_bps: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
) {
    blast_fun::events_wrapper::emit_event(Sold {
        launch_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        seller,
        meme_in_gross,
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        pending_burn_delta,
        pending_burn_total,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        protocol_fee_share_bps,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
        meme_reserve,
        real_quote_reserve,
    });
}

/// Emits terminal launch settlement and the adapter-bound migration handoff.
public(package) fun migrated<Meme, Quote, MigrationWitness>(
    launch_id: ID,
    migrator: address,
    native_supply_burned: bool,
    migration_meme: u64,
    migration_quote: u64,
    disposed_meme: u64,
    total_supply_after: u64,
    protocol_meme_graduation_fee: u64,
    quote_migration_fee: u64,
    protocol_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
) {
    blast_fun::events_wrapper::emit_event(Migrated {
        launch_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
        migrator,
        migration_meme,
        migration_quote,
        disposed_meme,
        native_supply_burned,
        total_supply_after,
        protocol_meme_graduation_fee,
        quote_migration_fee,
        protocol_meme_fee_total,
        protocol_quote_fee_total,
    });
}

/// Emits a creator-owned fee withdrawal.
public(package) fun creator_fees_claimed<Meme, Quote>(
    launch_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    blast_fun::events_wrapper::emit_event(CreatorFeesClaimed {
        launch_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

/// Emits a protocol-owned fee withdrawal.
public(package) fun protocol_fees_claimed<Meme, Quote>(
    launch_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    blast_fun::events_wrapper::emit_event(ProtocolFeesClaimed {
        launch_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

/// Emits creation of permanent package-capability custody.
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

/// Emits authorization of one exact package digest under the current policy.
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

/// Emits commitment of an authorized package upgrade.
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

/// Emits an irreversible narrowing of the package upgrade policy.
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
public fun package_version_advanced_fields(
    self: &PackageVersionAdvanced,
): (u64, u64) {
    (self.previous_version, self.new_version)
}

#[test_only]
public fun launch_trade_fees_changed_fields(
    self: &LaunchTradeFeesChanged,
): (u64, u64, u64, u64) {
    (
        self.old_quote_fee_bps,
        self.old_meme_fee_bps,
        self.new_quote_fee_bps,
        self.new_meme_fee_bps,
    )
}

#[test_only]
public fun quote_allowed_fields(self: &QuoteAllowed): (TypeName, u64, u64) {
    (self.quote, self.virtual_quote, self.migration_quote_target)
}

#[test_only]
public fun quote_parameters_changed_fields(
    self: &QuoteParametersChanged,
): (TypeName, u64, u64, u64, u64) {
    (
        self.quote,
        self.old_virtual_quote,
        self.old_migration_quote_target,
        self.new_virtual_quote,
        self.new_migration_quote_target,
    )
}

#[test_only]
public fun quote_disallowed_fields(self: &QuoteDisallowed): (TypeName, u64, u64) {
    (
        self.quote,
        self.previous_virtual_quote,
        self.previous_migration_quote_target,
    )
}

#[test_only]
public fun graduation_defaults_changed_fields(
    self: &GraduationDefaultsChanged,
): (u64, u64, u64, u64, u64, u64) {
    (
        self.old_quote_migration_fee_bps,
        self.old_protocol_meme_graduation_fee_bps,
        self.old_meme_liquidity_provision_bps,
        self.new_quote_migration_fee_bps,
        self.new_protocol_meme_graduation_fee_bps,
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
): (ID, TypeName, u64, ID, address, Option<address>, Option<vector<u8>>, bool, u64) {
    (
        self.ticket_id,
        self.meme,
        self.initial_supply,
        self.metadata_cap_id,
        self.launcher,
        self.creator,
        self.x_identity_hash,
        self.burnable,
        self.sell_burn_bps,
    )
}

#[test_only]
public fun launch_created_sell_burn_bps(self: &LaunchCreated): u64 {
    self.sell_burn_bps
}

#[test_only]
public fun launch_created_identity_fields(
    self: &LaunchCreated,
): (ID, ID, TypeName, TypeName, TypeName, address, ID) {
    (
        self.launch_id,
        self.ticket_id,
        self.meme,
        self.quote,
        self.migration_witness,
        self.launcher,
        self.metadata_cap_id,
    )
}

#[test_only]
public fun launch_created_balance_fields(
    self: &LaunchCreated,
): (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    (
        self.initial_meme_supply,
        self.meme_reserve,
        self.real_quote_reserve,
        self.pending_burn,
        self.protocol_meme_graduation_fee,
        self.meme_liquidity_provision,
        self.protocol_meme_trade_fees,
        self.creator_meme_trade_fees,
        self.protocol_quote_trade_fees,
        self.creator_quote_trade_fees,
    )
}

#[test_only]
public fun launch_created_policy_fields(
    self: &LaunchCreated,
): (u64, u64, u64, u64, u64, u64, u64) {
    (
        self.virtual_quote,
        self.migration_quote_target,
        self.quote_fee_bps,
        self.meme_fee_bps,
        self.quote_migration_fee_bps,
        self.protocol_meme_graduation_fee_bps,
        self.meme_liquidity_provision_bps,
    )
}

#[test_only]
public fun bought_trade_fields(
    self: &Bought,
): (ID, address, u64, u64, u64, u64, u64, u64, u64, u64, bool) {
    (
        self.launch_id,
        self.buyer,
        self.quote_supplied,
        self.quote_in_gross,
        self.quote_refund,
        self.quote_fee,
        self.quote_in_net,
        self.meme_out_gross,
        self.meme_fee,
        self.meme_out_net,
        self.crossed_threshold,
    )
}

#[test_only]
public fun sold_trade_fields(
    self: &Sold,
): (ID, address, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    (
        self.launch_id,
        self.seller,
        self.meme_in_gross,
        self.meme_fee,
        self.meme_in_after_fee,
        self.progress_bps,
        self.burn_bps,
        self.pending_burn_delta,
        self.pending_burn_total,
        self.quote_out_gross,
        self.quote_fee,
        self.quote_out_net,
    )
}

#[test_only]
public fun migrated_balance_fields(
    self: &Migrated,
): (ID, u64, u64, u64, bool, u64, u64, u64) {
    (
        self.launch_id,
        self.migration_meme,
        self.migration_quote,
        self.disposed_meme,
        self.native_supply_burned,
        self.total_supply_after,
        self.protocol_meme_graduation_fee,
        self.quote_migration_fee,
    )
}

#[test_only]
public fun creator_fees_claimed_fields(
    self: &CreatorFeesClaimed,
): (ID, address, u64, u64) {
    (self.launch_id, self.claimant, self.meme_amount, self.quote_amount)
}

#[test_only]
public fun protocol_fees_claimed_fields(
    self: &ProtocolFeesClaimed,
): (ID, address, u64, u64) {
    (self.launch_id, self.claimant, self.meme_amount, self.quote_amount)
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
