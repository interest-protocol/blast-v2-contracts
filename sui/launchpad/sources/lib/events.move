module blast_fun::events;

use std::type_name::{Self, TypeName};

// === Public Structs ===

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

// === Package Functions ===

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

