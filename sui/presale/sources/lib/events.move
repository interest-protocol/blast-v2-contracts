// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Presale event payloads and their package-only emitters.
module blast_presale::events;

// === Public Types ===

/// Blast's fee on the Quote raised by presales created from now on.
public struct FeeSet(u64) has copy, drop;

/// Where Blast's fee on every later finalization is paid.
public struct FeeDestinationSet(address) has copy, drop;

/// Whether presales created from now on may hand their liquidity to `adapter`.
public struct AdapterSet has copy, drop {
    adapter: TypeName,
    allowed: bool,
}

/// The sender created a presale selling `Token` for `Quote` in `tranches`, at Blast's `fee_bps`.
/// It fails unless it raises `min_raise`; its tokens are claimable from `claim_ms`. After Blast's
/// fee its raise goes to `recipients` and any `liquidity`.
public struct PresaleCreated has copy, drop {
    presale_id: ID,
    token: TypeName,
    quote: TypeName,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
    fee_bps: u64,
    recipients: vector<Recipient>,
    liquidity: Option<Liquidity>,
}

/// The sender committed `quote` to tranche `tranche`, which has now accepted `tranche_committed`.
public struct Committed has copy, drop {
    presale_id: ID,
    tranche: u64,
    quote: u64,
    tranche_committed: u64,
}

/// The presale closed. When it succeeded, `fee` of the `raised` Quote went to `fee_destination`,
/// its recipients were paid, and `liquidity_quote` and `liquidity_tokens` wait for the adapter.
/// `returned` tokens went back to the creator either way: the unsold ones and the pool's unused
/// reserve, or after a failure every token.
public struct PresaleFinalized has copy, drop {
    presale_id: ID,
    succeeded: bool,
    raised: u64,
    fee: u64,
    fee_destination: address,
    returned: u64,
    liquidity_quote: u64,
    liquidity_tokens: u64,
}

/// `quote` of the raise was paid to `destination`, one of the presale's recipients.
public struct ProceedsPaid has copy, drop {
    presale_id: ID,
    destination: address,
    quote: u64,
}

/// The presale's liquidity, `tokens` and `quote`, was handed to its adapter.
public struct LiquidityTaken has copy, drop {
    presale_id: ID,
    tokens: u64,
    quote: u64,
}

/// `tokens` and a `quote` refund from `buyer`'s position in tranche `tranche` were sent to it.
public struct Claimed has copy, drop {
    presale_id: ID,
    tranche: u64,
    buyer: address,
    tokens: u64,
    quote: u64,
}

// === Package Functions ===

public(package) fun fee_set(fee_bps: u64) {
    emit(FeeSet(fee_bps));
}

public(package) fun fee_destination_set(destination: address) {
    emit(FeeDestinationSet(destination));
}

public(package) fun adapter_set(adapter: TypeName, allowed: bool) {
    emit(AdapterSet { adapter, allowed });
}

public(package) fun presale_created<Token, Quote>(
    presale_id: ID,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
    fee_bps: u64,
    recipients: vector<Recipient>,
    liquidity: Option<Liquidity>,
) {
    emit(PresaleCreated {
        presale_id,
        token: type_name::with_original_ids<Token>(),
        quote: type_name::with_original_ids<Quote>(),
        tranches,
        min_raise,
        claim_ms,
        fee_bps,
        recipients,
        liquidity,
    });
}

public(package) fun committed(presale_id: ID, tranche: u64, quote: u64, tranche_committed: u64) {
    emit(Committed { presale_id, tranche, quote, tranche_committed });
}

public(package) fun presale_finalized(
    presale_id: ID,
    succeeded: bool,
    raised: u64,
    fee: u64,
    fee_destination: address,
    returned: u64,
    liquidity_quote: u64,
    liquidity_tokens: u64,
) {
    emit(PresaleFinalized {
        presale_id,
        succeeded,
        raised,
        fee,
        fee_destination,
        returned,
        liquidity_quote,
        liquidity_tokens,
    });
}

public(package) fun proceeds_paid(presale_id: ID, destination: address, quote: u64) {
    emit(ProceedsPaid { presale_id, destination, quote });
}

public(package) fun liquidity_taken(presale_id: ID, tokens: u64, quote: u64) {
    emit(LiquidityTaken { presale_id, tokens, quote });
}

public(package) fun claimed(presale_id: ID, tranche: u64, buyer: address, tokens: u64, quote: u64) {
    emit(Claimed { presale_id, tranche, buyer, tokens, quote });
}

// === Imports ===

use blast_presale::{
    blast_events::emit_event as emit,
    payout::{Liquidity, Recipient},
    tranche::Tranche,
};

use std::type_name::{Self, TypeName};
