// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Launchpad event payloads and their package-only emitters.
module blast_fun::events;

// === Public Types ===

/// Blast's one-time share of every launch's Meme supply and final Quote reserve.
public struct ProtocolAllocationSet has copy, drop {
    destination: address,
    meme_bps: u64,
    quote_bps: u64,
}

public struct MemeDecimalsSet has copy, drop {
    decimals: u8,
    allowed: bool,
}

/// Trade fees future launches snapshot.
public struct LaunchTradeFeesChanged has copy, drop {
    quote_fee_bps: u64,
    meme_fee_bps: u64,
}

/// A Quote's virtual reserve for future launches; zero means disallowed.
public struct QuoteSet has copy, drop {
    quote: TypeName,
    virtual_quote: u64,
}

public struct MigrationWitnessSet has copy, drop {
    migration_witness: TypeName,
    allowed: bool,
}

/// Blast's live share of every curve trade fee.
public struct ProtocolFeeShareChanged(u64) has copy, drop;

/// The account-claim signer's public key; empty when revoked.
public struct CreatorClaimSignerSet(vector<u8>) has copy, drop;

public struct CreatorCapsClaimed has copy, drop {
    meme: TypeName,
    curve_fee_cap_id: ID,
    metadata_cap_id: ID,
}

public struct CurveFeeCapReassigned has copy, drop {
    launch_id: ID,
    curve_fee_cap_id: ID,
    recipient: address,
}

public struct MetadataCapReassigned has copy, drop {
    launch_id: ID,
    metadata_cap_id: ID,
    recipient: address,
}

public struct MemeMetadataUpdated has copy, drop {
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
}

/// A generated package created its currency and launch ticket. The supply is one billion whole
/// tokens at `decimals`.
public struct LaunchTicketCreated has copy, drop {
    ticket_id: ID,
    meme: TypeName,
    decimals: u8,
    metadata_cap_id: ID,
    creator: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
}

/// A launch was created from `ticket_id` with these settings. Protection limits are the rates
/// applied to the supply, rounded down.
public struct LaunchCreated has copy, drop {
    launch_id: ID,
    ticket_id: ID,
    quote: TypeName,
    migration_witness: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: FeeSplit,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    allocation_plan: AllocationPlan,
    protection_window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
}

public struct LaunchShared has copy, drop {
    launch_id: ID,
    public_start_ms: u64,
}

/// A curve purchase; reserves are after the purchase. Purchases before `LaunchShared` are the
/// creator's, made in the transaction that creates the launch.
public struct Bought has copy, drop {
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    meme_out_net: u64,
    quote_refund: u64,
    protocol_meme_fee: u64,
    creator_meme_fee: u64,
    protocol_quote_fee: u64,
    creator_quote_fee: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
}

/// A curve sale; reserves are after the sale.
public struct Sold has copy, drop {
    launch_id: ID,
    meme_in_gross: u64,
    pending_burn: u64,
    quote_out_gross: u64,
    protocol_meme_fee: u64,
    creator_meme_fee: u64,
    protocol_quote_fee: u64,
    creator_quote_fee: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
}

/// One recipient's allocation, paid when migration begins.
public struct MigrationAllocationPaid has copy, drop {
    launch_id: ID,
    destination: address,
    meme: u64,
    quote: u64,
}

/// Migration committed: the adapter received `meme` and `quote` for the pool, and `disposed_meme`
/// was burned (or sent to `@0x0` under a fixed supply).
public struct Migrated has copy, drop {
    launch_id: ID,
    meme: u64,
    quote: u64,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
}

public struct CreatorFeesClaimed has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

public struct ProtocolFeesClaimed has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

// === Package Functions ===

public(package) fun protocol_allocation_set(destination: address, meme_bps: u64, quote_bps: u64) {
    emit(ProtocolAllocationSet { destination, meme_bps, quote_bps });
}

public(package) fun meme_decimals_set(decimals: u8, allowed: bool) {
    emit(MemeDecimalsSet { decimals, allowed });
}

public(package) fun launch_trade_fees_changed(quote_fee_bps: u64, meme_fee_bps: u64) {
    emit(LaunchTradeFeesChanged { quote_fee_bps, meme_fee_bps });
}

public(package) fun quote_set<Quote>(virtual_quote: u64) {
    emit(QuoteSet { quote: type_name::with_original_ids<Quote>(), virtual_quote });
}

public(package) fun migration_witness_set<MigrationWitness>(allowed: bool) {
    emit(MigrationWitnessSet {
        migration_witness: type_name::with_original_ids<MigrationWitness>(),
        allowed,
    });
}

public(package) fun protocol_fee_share_changed(protocol_fee_share_bps: u64) {
    emit(ProtocolFeeShareChanged(protocol_fee_share_bps));
}

public(package) fun creator_claim_signer_set(signer_public_key: vector<u8>) {
    emit(CreatorClaimSignerSet(signer_public_key));
}

public(package) fun creator_caps_claimed<Meme>(curve_fee_cap_id: ID, metadata_cap_id: ID) {
    emit(CreatorCapsClaimed {
        meme: type_name::with_original_ids<Meme>(),
        curve_fee_cap_id,
        metadata_cap_id,
    });
}

public(package) fun curve_fee_cap_reassigned(launch_id: ID, curve_fee_cap_id: ID, recipient: address) {
    emit(CurveFeeCapReassigned { launch_id, curve_fee_cap_id, recipient });
}

public(package) fun metadata_cap_reassigned(launch_id: ID, metadata_cap_id: ID, recipient: address) {
    emit(MetadataCapReassigned { launch_id, metadata_cap_id, recipient });
}

public(package) fun meme_metadata_updated(
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
) {
    emit(MemeMetadataUpdated { launch_id, name, description, icon_url });
}

public(package) fun launch_ticket_created<Meme>(
    ticket_id: ID,
    decimals: u8,
    metadata_cap_id: ID,
    creator: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
) {
    emit(LaunchTicketCreated {
        ticket_id,
        meme: type_name::with_original_ids<Meme>(),
        decimals,
        metadata_cap_id,
        creator,
        burnable,
        sell_burn_bps,
    });
}

public(package) fun launch_created<Quote>(
    launch_id: ID,
    ticket_id: ID,
    migration_witness: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: FeeSplit,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    allocation_plan: AllocationPlan,
    protection_window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
) {
    emit(LaunchCreated {
        launch_id,
        ticket_id,
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
        protection_window_ms,
        cumulative_sender_bps,
        per_transaction_bps,
    });
}

public(package) fun launch_shared(launch_id: ID, public_start_ms: u64) {
    emit(LaunchShared { launch_id, public_start_ms });
}

public(package) fun bought(
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    meme_out_net: u64,
    quote_refund: u64,
    protocol_meme_fee: u64,
    creator_meme_fee: u64,
    protocol_quote_fee: u64,
    creator_quote_fee: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
) {
    emit(Bought {
        launch_id,
        quote_in,
        meme_out_gross,
        meme_out_net,
        quote_refund,
        protocol_meme_fee,
        creator_meme_fee,
        protocol_quote_fee,
        creator_quote_fee,
        meme_reserve,
        real_quote_reserve,
    });
}

public(package) fun sold(
    launch_id: ID,
    meme_in_gross: u64,
    pending_burn: u64,
    quote_out_gross: u64,
    protocol_meme_fee: u64,
    creator_meme_fee: u64,
    protocol_quote_fee: u64,
    creator_quote_fee: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
) {
    emit(Sold {
        launch_id,
        meme_in_gross,
        pending_burn,
        quote_out_gross,
        protocol_meme_fee,
        creator_meme_fee,
        protocol_quote_fee,
        creator_quote_fee,
        meme_reserve,
        real_quote_reserve,
    });
}

public(package) fun migration_allocation_paid(
    launch_id: ID,
    destination: address,
    meme: u64,
    quote: u64,
) {
    emit(MigrationAllocationPaid { launch_id, destination, meme, quote });
}

public(package) fun migrated(
    launch_id: ID,
    meme: u64,
    quote: u64,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
) {
    emit(Migrated {
        launch_id,
        meme,
        quote,
        disposed_meme,
        native_supply_burned,
        total_supply_after,
    });
}

public(package) fun creator_fees_claimed(launch_id: ID, meme_amount: u64, quote_amount: u64) {
    emit(CreatorFeesClaimed { launch_id, meme_amount, quote_amount });
}

public(package) fun protocol_fees_claimed(launch_id: ID, meme_amount: u64, quote_amount: u64) {
    emit(ProtocolFeesClaimed { launch_id, meme_amount, quote_amount });
}

// === Imports ===

use blast_fun::{
    allocation::{AllocationPlan, FeeSplit},
    blast_events::emit_event as emit,
    creator_authority::CreatorRecipient,
};

use std::{string::String, type_name::{Self, TypeName}};
