/// Replay-complete event payloads and the package-only emitters that publish them.
module blast_fun::events;

// === Public Structs ===

/// Emitted after the trade-fee pair snapshotted by future launches changes.
public struct LaunchTradeFeesChanged has copy, drop {
    quote_fee_bps: u64,
    meme_fee_bps: u64,
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
    virtual_quote: u64,
    migration_quote_target: u64,
}

/// Emitted after a quote is disallowed from future launch admission.
public struct QuoteDisallowed(TypeName) has copy, drop;

/// Emitted after the graduation defaults snapshotted by future launches change.
public struct GraduationDefaultsChanged has copy, drop {
    protocol_quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
}

/// Emitted after an external migrator witness type is admitted for future launches.
public struct MigrationWitnessAllowed(TypeName) has copy, drop;

/// Emitted after an external migrator witness type is disallowed for future launches.
public struct MigrationWitnessDisallowed(TypeName) has copy, drop;

/// Emitted after the live bonding-curve trade protocol fee share is changed.
public struct ProtocolFeeShareChanged(u64) has copy, drop;

/// Emitted after the creator-claim signer is initially set or rotated.
public struct CreatorClaimSignerSet(vector<u8>) has copy, drop;

/// Emitted after the current creator-claim signer is revoked.
public struct CreatorClaimSignerRevoked has copy, drop {}

/// Emitted after either recipient kind claims the launch's curve-fee and metadata capabilities.
public struct CreatorCapsClaimed has copy, drop {
    meme: TypeName,
    curve_fee_cap_id: ID,
    metadata_cap_id: ID,
}

/// Emitted after an administrator retires curve-fee authority and issues a new capability.
public struct CurveFeeCapReassigned has copy, drop {
    launch_id: ID,
    revoked_curve_fee_cap_id: Option<ID>,
    curve_fee_cap_id: ID,
    recipient: address,
}

/// Emitted after an administrator retires metadata authority and issues a new capability.
public struct MetadataCapReassigned has copy, drop {
    launch_id: ID,
    revoked_metadata_cap_id: Option<ID>,
    metadata_cap_id: ID,
    recipient: address,
}

/// Emitted after a curve-fee cap is destroyed and curve fees are bound to a custodian forever.
public struct CreatorFeesLocked has copy, drop {
    launch_id: ID,
    curve_fee_cap_id: ID,
    custodian: TypeName,
}

/// Emitted after the metadata-cap holder updates coin metadata through the launch.
public struct MemeMetadataUpdated has copy, drop {
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
}

/// Emitted after a generated OTW currency and its launch ticket are created.
public struct LaunchTicketCreated has copy, drop {
    ticket_id: ID,
    meme: TypeName,
    initial_supply: u64,
    metadata_cap_id: ID,
    creator_address: Option<address>,
    account_commitment: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
}

/// Emitted after one ticket is normalized into launch custody and immutable policy.
public struct LaunchCreated has copy, drop {
    launch_id: ID,
    ticket_id: ID,
    quote: TypeName,
    migration_witness: TypeName,
    meme_reserve: u64,
    protocol_meme_graduation_fee: u64,
    meme_liquidity_provision: u64,
    virtual_quote: u64,
    migration_quote_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    protocol_quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
}

/// Emitted after a completed Quote-for-Meme curve purchase.
public struct Bought has copy, drop {
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
}

/// Emitted after a completed Meme-for-Quote curve sale.
public struct Sold has copy, drop {
    launch_id: ID,
    meme_in_gross: u64,
    pending_burn_delta: u64,
    pending_burn_total: u64,
    quote_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
}

/// Emitted after terminal assets are atomically handed to a selected migrator.
public struct Migrated has copy, drop {
    launch_id: ID,
    migration_meme: u64,
    migration_quote: u64,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
    protocol_meme_graduation_fee: u64,
    protocol_quote_migration_fee: u64,
}

/// Emitted after a creator claims both accrued trade-fee balances.
public struct CreatorFeesClaimed has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

/// Emitted after an administrator claims both accrued protocol balances.
public struct ProtocolFeesClaimed has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

// === Package Functions ===

/// Emits replacement of the launch trade-fee defaults.
public(package) fun launch_trade_fees_changed(
    quote_fee_bps: u64,
    meme_fee_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchTradeFeesChanged {
        quote_fee_bps,
        meme_fee_bps,
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
    virtual_quote: u64,
    migration_quote_target: u64,
) {
    blast_fun::events_wrapper::emit_event(QuoteParametersChanged {
        quote: type_name::with_original_ids<Quote>(),
        virtual_quote,
        migration_quote_target,
    });
}

/// Emits removal of one quote type.
public(package) fun quote_disallowed<Quote>() {
    blast_fun::events_wrapper::emit_event(QuoteDisallowed(
        type_name::with_original_ids<Quote>(),
    ));
}

/// Emits replacement of the launch graduation defaults.
public(package) fun graduation_defaults_changed(
    protocol_quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(GraduationDefaultsChanged {
        protocol_quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    });
}

/// Emits admission of one sealed migration-witness type.
public(package) fun migration_witness_allowed<MigrationWitness>() {
    blast_fun::events_wrapper::emit_event(MigrationWitnessAllowed(
        type_name::with_original_ids<MigrationWitness>(),
    ));
}

/// Emits removal of one sealed migration-witness type.
public(package) fun migration_witness_disallowed<MigrationWitness>() {
    blast_fun::events_wrapper::emit_event(MigrationWitnessDisallowed(
        type_name::with_original_ids<MigrationWitness>(),
    ));
}

/// Emits replacement of the runtime protocol fee share.
public(package) fun protocol_fee_share_changed(protocol_fee_share_bps: u64) {
    blast_fun::events_wrapper::emit_event(ProtocolFeeShareChanged(
        protocol_fee_share_bps,
    ));
}

/// Emits installation or rotation of the creator-claim signer key.
public(package) fun creator_claim_signer_set(signer_public_key: vector<u8>) {
    blast_fun::events_wrapper::emit_event(CreatorClaimSignerSet(signer_public_key));
}

/// Emits revocation of the creator-claim signer key.
public(package) fun creator_claim_signer_revoked() {
    blast_fun::events_wrapper::emit_event(CreatorClaimSignerRevoked {});
}

/// Emits a creator claim that consumed pending authority and issued both capabilities.
public(package) fun creator_caps_claimed<Meme>(curve_fee_cap_id: ID, metadata_cap_id: ID) {
    blast_fun::events_wrapper::emit_event(CreatorCapsClaimed {
        meme: type_name::with_original_ids<Meme>(),
        curve_fee_cap_id,
        metadata_cap_id,
    });
}

/// Emits an administrative curve-fee reassignment and the newly live capability.
public(package) fun curve_fee_cap_reassigned(
    launch_id: ID,
    revoked_curve_fee_cap_id: Option<ID>,
    curve_fee_cap_id: ID,
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(CurveFeeCapReassigned {
        launch_id,
        revoked_curve_fee_cap_id,
        curve_fee_cap_id,
        recipient,
    });
}

/// Emits an administrative metadata reassignment and the newly live capability.
public(package) fun metadata_cap_reassigned(
    launch_id: ID,
    revoked_metadata_cap_id: Option<ID>,
    metadata_cap_id: ID,
    recipient: address,
) {
    blast_fun::events_wrapper::emit_event(MetadataCapReassigned {
        launch_id,
        revoked_metadata_cap_id,
        metadata_cap_id,
        recipient,
    });
}

/// Emits the permanent binding of creator fees to a custodian module.
public(package) fun creator_fees_locked(
    launch_id: ID,
    curve_fee_cap_id: ID,
    custodian: TypeName,
) {
    blast_fun::events_wrapper::emit_event(CreatorFeesLocked {
        launch_id,
        curve_fee_cap_id,
        custodian,
    });
}

/// Emits the complete coin metadata snapshot after a creator update.
public(package) fun meme_metadata_updated(
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
) {
    blast_fun::events_wrapper::emit_event(MemeMetadataUpdated {
        launch_id,
        name,
        description,
        icon_url,
    });
}

/// Emits creation of one generated-coin launch ticket.
public(package) fun launch_ticket_created<Meme>(
    ticket_id: ID,
    initial_supply: u64,
    metadata_cap_id: ID,
    creator_address: Option<address>,
    account_commitment: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchTicketCreated {
        ticket_id,
        meme: type_name::with_original_ids<Meme>(),
        initial_supply,
        metadata_cap_id,
        creator_address,
        account_commitment,
        burnable,
        sell_burn_bps,
    });
}

/// Emits creation of normalized launch custody and its complete policy snapshot.
public(package) fun launch_created<Quote>(
    launch_id: ID,
    ticket_id: ID,
    migration_witness: TypeName,
    meme_reserve: u64,
    protocol_meme_graduation_fee: u64,
    meme_liquidity_provision: u64,
    virtual_quote: u64,
    migration_quote_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    protocol_quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
) {
    blast_fun::events_wrapper::emit_event(LaunchCreated {
        launch_id,
        ticket_id,
        quote: type_name::with_original_ids<Quote>(),
        migration_witness,
        meme_reserve,
        protocol_meme_graduation_fee,
        meme_liquidity_provision,
        virtual_quote,
        migration_quote_target,
        quote_fee_bps,
        meme_fee_bps,
        protocol_quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    });
}

/// Emits one completed Quote-for-Meme trade and resulting accounting state.
public(package) fun bought(
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
) {
    blast_fun::events_wrapper::emit_event(Bought {
        launch_id,
        quote_in,
        meme_out_gross,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        meme_reserve,
        real_quote_reserve,
    });
}

/// Emits one completed Meme-for-Quote trade and resulting accounting state.
public(package) fun sold(
    launch_id: ID,
    meme_in_gross: u64,
    pending_burn_delta: u64,
    pending_burn_total: u64,
    quote_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
) {
    blast_fun::events_wrapper::emit_event(Sold {
        launch_id,
        meme_in_gross,
        pending_burn_delta,
        pending_burn_total,
        quote_out_gross,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        meme_reserve,
        real_quote_reserve,
    });
}

/// Emits terminal launch settlement and the adapter-bound migration handoff.
public(package) fun migrated(
    launch_id: ID,
    native_supply_burned: bool,
    migration_meme: u64,
    migration_quote: u64,
    disposed_meme: u64,
    total_supply_after: u64,
    protocol_meme_graduation_fee: u64,
    protocol_quote_migration_fee: u64,
) {
    blast_fun::events_wrapper::emit_event(Migrated {
        launch_id,
        migration_meme,
        migration_quote,
        disposed_meme,
        native_supply_burned,
        total_supply_after,
        protocol_meme_graduation_fee,
        protocol_quote_migration_fee,
    });
}

/// Emits a creator-owned fee withdrawal.
public(package) fun creator_fees_claimed(
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
) {
    blast_fun::events_wrapper::emit_event(CreatorFeesClaimed {
        launch_id,
        meme_amount,
        quote_amount,
    });
}

/// Emits a protocol-owned fee withdrawal.
public(package) fun protocol_fees_claimed(
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
) {
    blast_fun::events_wrapper::emit_event(ProtocolFeesClaimed {
        launch_id,
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

// === Imports ===

use std::{string::String, type_name::{Self, TypeName}};
