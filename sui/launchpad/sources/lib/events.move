// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Launchpad event payloads and their package-only emitters.
module blast_fun::events;

// === Public Types ===

/// Blast's one-time fee share of the Meme supply and final Quote reserve of launches finalized
/// from now on. Finalized launches keep the shares recorded in `LaunchCreated.allocation_plan`.
public struct ProtocolAllocationSet has copy, drop {
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

/// A Quote type was admitted to (`allowed = true`) or removed from (`allowed = false`) future
/// launches. Existing launches keep trading in it.
public struct QuoteSet has copy, drop {
    quote: TypeName,
    allowed: bool,
}

public struct MigrationWitnessSet has copy, drop {
    migration_witness: TypeName,
    allowed: bool,
}

/// Blast's live share of every curve trade fee.
public struct ProtocolFeeShareChanged(u64) has copy, drop;

/// The account-claim signer's public key; empty when revoked.
public struct CreatorClaimSignerSet(vector<u8>) has copy, drop;

/// The address every later protocol fee claim pays Blast's share to.
public struct TreasuryChanged(address) has copy, drop;

/// The SUI, in MIST, every launch created afterward pays.
public struct CreationFeeChanged(u64) has copy, drop;

/// New launches may name the partner from now on, or its pending removal was cancelled.
public struct PartnerAdded has copy, drop {
    partner_id: ID,
}

/// New launches may name the partner until `accepted_until_ms`; launches that name it keep paying it.
public struct PartnerRemoved has copy, drop {
    partner_id: ID,
    accepted_until_ms: u64,
}

public struct CreatorCapsClaimed has copy, drop {
    meme: TypeName,
    curve_fee_cap_id: ID,
    blast_metadata_cap_id: ID,
}

public struct CurveFeeCapReassigned has copy, drop {
    launch_id: ID,
    curve_fee_cap_id: ID,
    recipient: address,
}

public struct MetadataCapReassigned has copy, drop {
    launch_id: ID,
    blast_metadata_cap_id: ID,
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

/// A launch was created from `ticket_id` with these settings; a zero `opening_round_ms` has no
/// opening round. The creator paid `creation_fee` SUI, held with Blast's fees on the launch;
/// `partner_id` is the launch's partner for good, if it names one.
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
    opening_round_ms: u64,
    creation_fee: u64,
    partner_id: Option<ID>,
}

public struct LaunchShared has copy, drop {
    launch_id: ID,
    public_start_ms: u64,
}

/// Quote joined a launch's opening round from the sender; `bids` is the pot after it.
public struct OpeningRoundJoined has copy, drop {
    launch_id: ID,
    quote: u64,
    bids: u64,
}

/// The opening round closed: its `bids` bought `meme` from the curve, in the same transaction's
/// `Bought` when there is one, and left `quote` to refund. Both are delivered pro rata.
public struct OpeningRoundSettled has copy, drop {
    launch_id: ID,
    bids: u64,
    meme: u64,
    quote: u64,
}

/// `bidder`'s share of the opening round, for its `bid`, was sent to it.
public struct OpeningRoundDelivered has copy, drop {
    launch_id: ID,
    bidder: address,
    bid: u64,
    meme: u64,
    quote: u64,
}

/// A curve purchase; reserves are after the purchase. Purchases before `LaunchShared` are the
/// creator's, made in the transaction that creates the launch; the one beside
/// `OpeningRoundSettled` is the opening round's pot.
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
    total_supply_after: u64,
}

public struct CreatorFeesClaimed has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

/// `treasury` was paid Blast's `meme_amount` and `quote_amount` and the creation fee's
/// `sui_amount`; the launch's partner, if it names one, was paid the partner amounts in the same
/// claim. Anyone may claim, so the treasury need not be the sender.
public struct ProtocolFeesClaimed has copy, drop {
    launch_id: ID,
    treasury: address,
    meme_amount: u64,
    quote_amount: u64,
    sui_amount: u64,
    partner_meme_amount: u64,
    partner_quote_amount: u64,
    partner_sui_amount: u64,
}

/// Blast's one-time migration Meme and Quote fee joined the launch's protocol ledger.
public struct ProtocolFeesAccrued has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

// === Package Functions ===

public(package) fun protocol_allocation_set(meme_bps: u64, quote_bps: u64) {
    emit(ProtocolAllocationSet { meme_bps, quote_bps });
}

public(package) fun meme_decimals_set(decimals: u8, allowed: bool) {
    emit(MemeDecimalsSet { decimals, allowed });
}

public(package) fun launch_trade_fees_changed(quote_fee_bps: u64, meme_fee_bps: u64) {
    emit(LaunchTradeFeesChanged { quote_fee_bps, meme_fee_bps });
}

public(package) fun quote_set<Quote>(allowed: bool) {
    emit(QuoteSet { quote: type_name::with_original_ids<Quote>(), allowed });
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

public(package) fun treasury_changed(treasury: address) {
    emit(TreasuryChanged(treasury));
}

public(package) fun creation_fee_changed(creation_fee: u64) {
    emit(CreationFeeChanged(creation_fee));
}

public(package) fun partner_added(partner_id: ID) {
    emit(PartnerAdded { partner_id });
}

public(package) fun partner_removed(partner_id: ID, accepted_until_ms: u64) {
    emit(PartnerRemoved { partner_id, accepted_until_ms });
}

public(package) fun creator_caps_claimed<Meme>(curve_fee_cap_id: ID, blast_metadata_cap_id: ID) {
    emit(CreatorCapsClaimed {
        meme: type_name::with_original_ids<Meme>(),
        curve_fee_cap_id,
        blast_metadata_cap_id,
    });
}

public(package) fun curve_fee_cap_reassigned(launch_id: ID, curve_fee_cap_id: ID, recipient: address) {
    emit(CurveFeeCapReassigned { launch_id, curve_fee_cap_id, recipient });
}

public(package) fun metadata_cap_reassigned(launch_id: ID, blast_metadata_cap_id: ID, recipient: address) {
    emit(MetadataCapReassigned { launch_id, blast_metadata_cap_id, recipient });
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
    opening_round_ms: u64,
    creation_fee: u64,
    partner_id: Option<ID>,
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
        opening_round_ms,
        creation_fee,
        partner_id,
    });
}

public(package) fun launch_shared(launch_id: ID, public_start_ms: u64) {
    emit(LaunchShared { launch_id, public_start_ms });
}

public(package) fun opening_round_joined(launch_id: ID, quote: u64, bids: u64) {
    emit(OpeningRoundJoined { launch_id, quote, bids });
}

public(package) fun opening_round_settled(launch_id: ID, bids: u64, meme: u64, quote: u64) {
    emit(OpeningRoundSettled { launch_id, bids, meme, quote });
}

public(package) fun opening_round_delivered(
    launch_id: ID,
    bidder: address,
    bid: u64,
    meme: u64,
    quote: u64,
) {
    emit(OpeningRoundDelivered { launch_id, bidder, bid, meme, quote });
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
    total_supply_after: u64,
) {
    emit(Migrated {
        launch_id,
        meme,
        quote,
        disposed_meme,
        total_supply_after,
    });
}

public(package) fun creator_fees_claimed(launch_id: ID, meme_amount: u64, quote_amount: u64) {
    emit(CreatorFeesClaimed { launch_id, meme_amount, quote_amount });
}

public(package) fun protocol_fees_claimed(
    launch_id: ID,
    treasury: address,
    meme_amount: u64,
    quote_amount: u64,
    sui_amount: u64,
    partner_meme_amount: u64,
    partner_quote_amount: u64,
    partner_sui_amount: u64,
) {
    emit(ProtocolFeesClaimed {
        launch_id,
        treasury,
        meme_amount,
        quote_amount,
        sui_amount,
        partner_meme_amount,
        partner_quote_amount,
        partner_sui_amount,
    });
}

public(package) fun protocol_fees_accrued(
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
) {
    emit(ProtocolFeesAccrued { launch_id, meme_amount, quote_amount });
}

// === Imports ===

use blast_fun::{
    allocation::{AllocationPlan, FeeSplit},
    blast_events::emit_event as emit,
    creator_authority::CreatorRecipient,
};

use std::{string::String, type_name::{Self, TypeName}};
