// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Replay-complete event payloads and the package-only emitters that publish them.
module blast_fun::events;

// === Public Types ===

/// Immutable one-time Blast policy, including the stable identity and destination.
public struct ProtocolAllocationConfigured has copy, drop {
    channel_id: u64,
    destination: address,
    meme_bps: u64,
    quote_bps: u64,
}

/// One non-liquidity allocation paid to its immutable destination when migration completed.
public struct MigrationAllocationPaid has copy, drop {
    launch_id: ID,
    channel_id: u64,
    destination: address,
    meme: u64,
    quote: u64,
}

/// Emitted after one Meme decimal precision is admitted for launch intake.
public struct MemeDecimalsAllowed(u8) has copy, drop;

/// Emitted after one Meme decimal precision is disallowed at launch intake.
public struct MemeDecimalsDisallowed(u8) has copy, drop;

/// Emitted after the trade-fee pair snapshotted by future launches changes.
public struct LaunchTradeFeesChanged has copy, drop {
    quote_fee_bps: u64,
    meme_fee_bps: u64,
}

/// Emitted after a quote is admitted or its virtual reserve for future launches changes.
public struct QuoteAllowed has copy, drop {
    quote: TypeName,
    virtual_quote: u64,
}

/// Emitted after a quote is disallowed from future launch admission.
public struct QuoteDisallowed(TypeName) has copy, drop;

/// Emitted after an external migrator witness type is admitted for binding and intake.
public struct MigrationWitnessAllowed(TypeName) has copy, drop;

/// Emitted after an external migrator witness type is removed from binding and intake.
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

/// Emitted after the metadata-cap holder updates coin metadata through the launch.
public struct MemeMetadataUpdated has copy, drop {
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
}

/// Emitted after a generated package's one-time witness creates its currency and launch ticket.
public struct LaunchTicketCreated has copy, drop {
    ticket_id: ID,
    meme: TypeName,
    decimals: u8,
    atomic_supply: u64,
    metadata_cap_id: ID,
    creator_address: Option<address>,
    account_commitment: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
}

/// Emitted after one ticket is normalized into launch custody and immutable policy.
/// `meme_amounts` are the exact atomic Meme partition in the plan's Meme table order. The pool
/// tier and LP-fee split are the creator's settings the migration adapter receives.
public struct LaunchCreated has copy, drop {
    launch_id: ID,
    ticket_id: ID,
    decimals: u8,
    atomic_supply: u64,
    quote: TypeName,
    migration_witness: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: blast_fun::allocation::FeeSplit,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    allocation_plan: blast_fun::allocation::AllocationPlan,
    meme_amounts: vector<u64>,
}

/// Emitted after launch creation with its immutable public curve-purchase protection.
/// Limits are exact atomic Meme; a zero window with zero rates is the disabled form.
public struct ProtectionConfigured has copy, drop {
    launch_id: ID,
    window_ms: u64,
    cumulative_sender_bps: u64,
    cumulative_atomic_limit: u64,
    per_transaction_bps: u64,
    per_transaction_atomic_limit: u64,
}

/// Emitted after the launch becomes a public shared object.
public struct LaunchShared has copy, drop {
    launch_id: ID,
    public_start_ms: u64,
    pre_share_buy_completed: bool,
}

/// Emitted after the launch's single pre-share purchase completes without graduating.
/// Amounts are atomic units; reserve fields are the post-purchase accounting snapshot.
public struct PreShareBought has copy, drop {
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    post_meme_reserve: u64,
    post_real_quote_reserve: u64,
    meme_out_net: u64,
    quote_refund: u64,
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

/// Emitted after one migration completed: exact reconciliation and disposal. The handoff is
/// `supplied + residual`; the adapter records its custody in the same transaction.
public struct Migrated has copy, drop {
    launch_id: ID,
    supplied_meme: u64,
    supplied_quote: u64,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
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

/// Records the only protocol-allocation configuration transition.
public(package) fun protocol_allocation_configured(
    channel_id: u64,
    destination: address,
    meme_bps: u64,
    quote_bps: u64,
) {
    blast_fun::blast_events::emit_event(ProtocolAllocationConfigured {
        channel_id,
        destination,
        meme_bps,
        quote_bps,
    });
}

/// Records one allocation payout after both coins left the launch.
public(package) fun migration_allocation_paid(
    launch_id: ID,
    channel_id: u64,
    destination: address,
    meme: u64,
    quote: u64,
) {
    blast_fun::blast_events::emit_event(MigrationAllocationPaid {
        launch_id,
        channel_id,
        destination,
        meme,
        quote,
    });
}

/// Emits admission of one Meme decimal precision for launch intake.
public(package) fun meme_decimals_allowed(decimals: u8) {
    blast_fun::blast_events::emit_event(MemeDecimalsAllowed(decimals));
}

/// Emits removal of one Meme decimal precision from launch intake.
public(package) fun meme_decimals_disallowed(decimals: u8) {
    blast_fun::blast_events::emit_event(MemeDecimalsDisallowed(decimals));
}

/// Emits replacement of the launch trade-fee defaults.
public(package) fun launch_trade_fees_changed(quote_fee_bps: u64, meme_fee_bps: u64) {
    blast_fun::blast_events::emit_event(LaunchTradeFeesChanged {
        quote_fee_bps,
        meme_fee_bps,
    });
}

/// Emits admission of one quote type or the replacement of its virtual reserve.
public(package) fun quote_allowed<Quote>(virtual_quote: u64) {
    blast_fun::blast_events::emit_event(QuoteAllowed {
        quote: type_name::with_original_ids<Quote>(),
        virtual_quote,
    });
}

/// Emits removal of one quote type.
public(package) fun quote_disallowed<Quote>() {
    blast_fun::blast_events::emit_event(
        QuoteDisallowed(
            type_name::with_original_ids<Quote>(),
        ),
    );
}

/// Emits admission of one sealed migration-witness type.
public(package) fun migration_witness_allowed<MigrationWitness>() {
    blast_fun::blast_events::emit_event(
        MigrationWitnessAllowed(
            type_name::with_original_ids<MigrationWitness>(),
        ),
    );
}

/// Emits removal of one sealed migration-witness type.
public(package) fun migration_witness_disallowed<MigrationWitness>() {
    blast_fun::blast_events::emit_event(
        MigrationWitnessDisallowed(
            type_name::with_original_ids<MigrationWitness>(),
        ),
    );
}

/// Emits replacement of the runtime protocol fee share.
public(package) fun protocol_fee_share_changed(protocol_fee_share_bps: u64) {
    blast_fun::blast_events::emit_event(
        ProtocolFeeShareChanged(
            protocol_fee_share_bps,
        ),
    );
}

/// Emits installation or rotation of the creator-claim signer key.
public(package) fun creator_claim_signer_set(signer_public_key: vector<u8>) {
    blast_fun::blast_events::emit_event(CreatorClaimSignerSet(signer_public_key));
}

/// Emits revocation of the creator-claim signer key.
public(package) fun creator_claim_signer_revoked() {
    blast_fun::blast_events::emit_event(CreatorClaimSignerRevoked {});
}

/// Emits a creator claim that consumed pending authority and issued both capabilities.
public(package) fun creator_caps_claimed<Meme>(curve_fee_cap_id: ID, metadata_cap_id: ID) {
    blast_fun::blast_events::emit_event(CreatorCapsClaimed {
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
    blast_fun::blast_events::emit_event(CurveFeeCapReassigned {
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
    blast_fun::blast_events::emit_event(MetadataCapReassigned {
        launch_id,
        revoked_metadata_cap_id,
        metadata_cap_id,
        recipient,
    });
}

/// Emits the complete coin metadata snapshot after a creator update.
public(package) fun meme_metadata_updated(
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
) {
    blast_fun::blast_events::emit_event(MemeMetadataUpdated {
        launch_id,
        name,
        description,
        icon_url,
    });
}

/// Emits creation of one generated-coin launch ticket.
public(package) fun launch_ticket_created<Meme>(
    ticket_id: ID,
    decimals: u8,
    atomic_supply: u64,
    metadata_cap_id: ID,
    creator_address: Option<address>,
    account_commitment: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
) {
    blast_fun::blast_events::emit_event(LaunchTicketCreated {
        ticket_id,
        meme: type_name::with_original_ids<Meme>(),
        decimals,
        atomic_supply,
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
    decimals: u8,
    atomic_supply: u64,
    migration_witness: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: blast_fun::allocation::FeeSplit,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    allocation_plan: blast_fun::allocation::AllocationPlan,
    meme_amounts: vector<u64>,
) {
    blast_fun::blast_events::emit_event(LaunchCreated {
        launch_id,
        ticket_id,
        decimals,
        atomic_supply,
        quote: type_name::with_original_ids<Quote>(),
        migration_witness,
        pool_tick_spacing,
        pool_fee_rate,
        lp_fee_split,
        virtual_quote,
        graduation_target,
        quote_fee_bps,
        meme_fee_bps,
        allocation_plan,
        meme_amounts,
    });
}

/// Emits the protection settings and exact limits fixed at launch creation.
public(package) fun protection_configured(
    launch_id: ID,
    window_ms: u64,
    cumulative_sender_bps: u64,
    cumulative_atomic_limit: u64,
    per_transaction_bps: u64,
    per_transaction_atomic_limit: u64,
) {
    blast_fun::blast_events::emit_event(ProtectionConfigured {
        launch_id,
        window_ms,
        cumulative_sender_bps,
        cumulative_atomic_limit,
        per_transaction_bps,
        per_transaction_atomic_limit,
    });
}

/// Emits terminal sharing of the launch.
public(package) fun launch_shared(launch_id: ID, public_start_ms: u64, pre_share_buy_completed: bool) {
    blast_fun::blast_events::emit_event(LaunchShared {
        launch_id,
        public_start_ms,
        pre_share_buy_completed,
    });
}

/// Emits one completed pre-share purchase, exact outputs, and resulting accounting state.
public(package) fun pre_share_bought(
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    post_meme_reserve: u64,
    post_real_quote_reserve: u64,
    meme_out_net: u64,
    quote_refund: u64,
) {
    blast_fun::blast_events::emit_event(PreShareBought {
        launch_id,
        quote_in,
        meme_out_gross,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        post_meme_reserve,
        post_real_quote_reserve,
        meme_out_net,
        quote_refund,
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
    blast_fun::blast_events::emit_event(Bought {
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
    blast_fun::blast_events::emit_event(Sold {
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

/// Emits the completed migration after the lifecycle committed.
public(package) fun migrated(
    launch_id: ID,
    supplied_meme: u64,
    supplied_quote: u64,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
) {
    blast_fun::blast_events::emit_event(Migrated {
        launch_id,
        supplied_meme,
        supplied_quote,
        residual_meme,
        residual_quote,
        liquidity,
        disposed_meme,
        native_supply_burned,
        total_supply_after,
    });
}

/// Emits a creator-owned fee withdrawal.
public(package) fun creator_fees_claimed(launch_id: ID, meme_amount: u64, quote_amount: u64) {
    blast_fun::blast_events::emit_event(CreatorFeesClaimed {
        launch_id,
        meme_amount,
        quote_amount,
    });
}

/// Emits a protocol-owned fee withdrawal.
public(package) fun protocol_fees_claimed(launch_id: ID, meme_amount: u64, quote_amount: u64) {
    blast_fun::blast_events::emit_event(ProtocolFeesClaimed {
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

    sui::event::events_by_type<blast_fun::blast_events::Event<T>>().do!(
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
public fun migrated_accounting_fields_for_testing(
    self: &Migrated,
): (ID, u64, u64, u64, u64, u128) {
    (
        self.launch_id,
        self.supplied_meme,
        self.supplied_quote,
        self.residual_meme,
        self.residual_quote,
        self.liquidity,
    )
}

// === Imports ===

use std::{string::String, type_name::{Self, TypeName}};
