// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Launchpad event payloads and their package-only emitters. Pauses and versions emit from
/// `blast_admin`, delayed settings from its delayed modules, and Blast's fee payments from
/// `blast_core`.
module blast_fun::events;

// === Package Functions ===

public(package) fun meme_decimals_allowed(decimals: u8, allowed: bool) {
    sui::event::emit(MemeDecimalsAllowed { decimals, allowed });
}

public(package) fun quote_allowed<Quote>(allowed: bool) {
    sui::event::emit(QuoteAllowed<Quote> { allowed });
}

public(package) fun creator_caps_claimed<Meme, Quote>(
    curve_fee_cap_id: ID,
    creator_metadata_cap_id: ID,
) {
    sui::event::emit(CreatorCapsClaimed<Meme, Quote> {
        curve_fee_cap_id,
        creator_metadata_cap_id,
    });
}

public(package) fun curve_fee_cap_reassigned<Meme, Quote>(
    launch_id: ID,
    curve_fee_cap_id: ID,
    recipient: address,
) {
    sui::event::emit(CurveFeeCapReassigned<Meme, Quote> { launch_id, curve_fee_cap_id, recipient });
}

public(package) fun creator_metadata_cap_reassigned<Meme, Quote>(
    launch_id: ID,
    creator_metadata_cap_id: ID,
    recipient: address,
) {
    sui::event::emit(CreatorMetadataCapReassigned<Meme, Quote> {
        launch_id,
        creator_metadata_cap_id,
        recipient,
    });
}

public(package) fun meme_metadata_updated<Meme, Quote>(
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
) {
    sui::event::emit(MemeMetadataUpdated<Meme, Quote> { launch_id, name, description, icon_url });
}

public(package) fun launch_ticket_created<Meme>(
    ticket_id: ID,
    decimals: u8,
    metadata_cap_id: ID,
    creator: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
) {
    sui::event::emit(LaunchTicketCreated<Meme> {
        ticket_id,
        decimals,
        metadata_cap_id,
        creator,
        burnable,
        sell_burn_bps,
    });
}

public(package) fun launch_created<Meme, Quote>(
    launch_id: ID,
    ticket_id: ID,
    venue: TypeName,
    lp_fee_split: FeeSplit,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    allocation_plan: AllocationPlan,
    opening_round_duration_ms: u64,
    creation_fee: u64,
    partner_id: Option<ID>,
) {
    sui::event::emit(LaunchCreated<Meme, Quote> {
        launch_id,
        ticket_id,
        venue,
        lp_fee_split,
        virtual_quote,
        graduation_target,
        quote_fee_bps,
        meme_fee_bps,
        allocation_plan,
        opening_round_ms: opening_round_duration_ms,
        creation_fee,
        partner_id,
    });
}

public(package) fun launch_shared<Meme, Quote>(launch_id: ID, public_starts_at_ms: u64) {
    sui::event::emit(LaunchShared<Meme, Quote> { launch_id, public_start_ms: public_starts_at_ms });
}

public(package) fun opening_round_joined<Meme, Quote>(launch_id: ID, quote_amount: u64, bids: u64) {
    sui::event::emit(OpeningRoundJoined<Meme, Quote> { launch_id, quote_amount, bids });
}

public(package) fun opening_round_settled<Meme, Quote>(
    launch_id: ID,
    bids: u64,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(OpeningRoundSettled<Meme, Quote> {
        launch_id,
        bids,
        meme_amount,
        quote_amount,
    });
}

public(package) fun opening_round_delivered<Meme, Quote>(
    launch_id: ID,
    bidder: address,
    bid: u64,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(OpeningRoundDelivered<Meme, Quote> {
        launch_id,
        bidder,
        bid,
        meme_amount,
        quote_amount,
    });
}

public(package) fun bought<Meme, Quote>(
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
    sui::event::emit(Bought<Meme, Quote> {
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

public(package) fun sold<Meme, Quote>(
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
    sui::event::emit(Sold<Meme, Quote> {
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

public(package) fun migration_allocation_paid<Meme, Quote>(
    launch_id: ID,
    destination: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_vesting_id: Option<ID>,
    quote_vesting_id: Option<ID>,
) {
    sui::event::emit(MigrationAllocationPaid<Meme, Quote> {
        launch_id,
        destination,
        meme_amount,
        quote_amount,
        meme_vesting_id,
        quote_vesting_id,
    });
}

public(package) fun migrated<Meme, Quote>(
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    disposed_meme: u64,
    total_supply_after: u64,
) {
    sui::event::emit(Migrated<Meme, Quote> {
        launch_id,
        meme_amount,
        quote_amount,
        disposed_meme,
        total_supply_after,
    });
}

public(package) fun creator_fees_claimed<Meme, Quote>(
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(CreatorFeesClaimed<Meme, Quote> { launch_id, meme_amount, quote_amount });
}

public(package) fun protocol_fees_accrued<Meme, Quote>(
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(ProtocolFeesAccrued<Meme, Quote> { launch_id, meme_amount, quote_amount });
}

// === Events ===

public struct MemeDecimalsAllowed has copy, drop {
    decimals: u8,
    allowed: bool,
}

/// A Quote type was admitted to (`allowed = true`) or removed from (`allowed = false`) future
/// launches. Existing launches keep trading in it.
public struct QuoteAllowed<phantom Quote> has copy, drop {
    allowed: bool,
}

public struct CreatorCapsClaimed<phantom Meme, phantom Quote> has copy, drop {
    curve_fee_cap_id: ID,
    creator_metadata_cap_id: ID,
}

public struct CurveFeeCapReassigned<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    curve_fee_cap_id: ID,
    recipient: address,
}

public struct CreatorMetadataCapReassigned<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    creator_metadata_cap_id: ID,
    recipient: address,
}

public struct MemeMetadataUpdated<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    name: String,
    description: String,
    icon_url: String,
}

/// A generated package created its currency and launch ticket. The supply is one billion whole
/// tokens at `decimals`.
public struct LaunchTicketCreated<phantom Meme> has copy, drop {
    ticket_id: ID,
    decimals: u8,
    metadata_cap_id: ID,
    creator: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
}

/// A launch was created from `ticket_id` with these settings; a zero `opening_round_ms` has no
/// opening round. The creator paid `creation_fee` SUI, held with Blast's fees on the launch;
/// `partner_id` is the launch's partner for good, if it names one.
public struct LaunchCreated<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    ticket_id: ID,
    venue: TypeName,
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

public struct LaunchShared<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    public_start_ms: u64,
}

/// `quote_amount` joined a launch's opening round from the sender; `bids` is the pot after it.
public struct OpeningRoundJoined<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    quote_amount: u64,
    bids: u64,
}

/// The opening round closed: its `bids` bought `meme_amount` from the curve, in the same
/// transaction's `Bought` when there is one, and left `quote_amount` to refund. Both are delivered
/// pro rata.
public struct OpeningRoundSettled<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    bids: u64,
    meme_amount: u64,
    quote_amount: u64,
}

/// `bidder`'s share of the opening round, for its `bid`, was sent to it.
public struct OpeningRoundDelivered<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    bidder: address,
    bid: u64,
    meme_amount: u64,
    quote_amount: u64,
}

/// A curve purchase; reserves are after the purchase. Purchases before `LaunchShared` are the
/// creator's, made in the transaction that creates the launch; the one beside
/// `OpeningRoundSettled` is the opening round's pot.
public struct Bought<phantom Meme, phantom Quote> has copy, drop {
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
public struct Sold<phantom Meme, phantom Quote> has copy, drop {
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

/// One recipient's allocation, paid when migration begins: as coins to `destination`, or into the
/// vesting schedules named here when the recipient vests.
public struct MigrationAllocationPaid<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    destination: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_vesting_id: Option<ID>,
    quote_vesting_id: Option<ID>,
}

/// Migration committed: the adapter received `meme_amount` and `quote_amount` for the pool, and
/// `disposed_meme` was burned (or sent to `@0x0` under a fixed supply).
public struct Migrated<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    disposed_meme: u64,
    total_supply_after: u64,
}

public struct CreatorFeesClaimed<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

/// Blast's one-time migration Meme and Quote fee joined the launch's protocol ledger.
public struct ProtocolFeesAccrued<phantom Meme, phantom Quote> has copy, drop {
    launch_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

// === Imports ===

use blast_core::fee_split::FeeSplit;

use blast_fun::{allocation::AllocationPlan, creator_authority::CreatorRecipient};

use std::{string::String, type_name::TypeName};
