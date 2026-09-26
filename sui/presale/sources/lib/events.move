// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Presale event payloads and their package-only emitters.
module blast_presale::events;

// === Public Types ===

/// Blast's fee on the Quote raised by presales created from now on.
public struct FeeSet(u64) has copy, drop;

/// Where Blast's fee on every later finalization is paid.
public struct FeeDestinationSet(address) has copy, drop;

/// The sender created a presale selling `Token` for `Quote` in `tranches`, at Blast's `fee_bps`.
/// It fails unless it raises `min_raise`; its tokens are claimable from `claim_ms`.
public struct PresaleCreated has copy, drop {
    presale_id: ID,
    token: TypeName,
    quote: TypeName,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
    fee_bps: u64,
}

/// The sender committed `quote` to tranche `tranche`, which has now accepted `tranche_committed`.
public struct Committed has copy, drop {
    presale_id: ID,
    tranche: u64,
    quote: u64,
    tranche_committed: u64,
}

/// The presale closed. When it succeeded, `raised` less `fee` went to its creator and `fee` to
/// `fee_destination`; `unsold` tokens went back to its creator either way.
public struct PresaleFinalized has copy, drop {
    presale_id: ID,
    succeeded: bool,
    raised: u64,
    fee: u64,
    fee_destination: address,
    unsold: u64,
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

public(package) fun presale_created<Token, Quote>(
    presale_id: ID,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
    fee_bps: u64,
) {
    emit(PresaleCreated {
        presale_id,
        token: type_name::with_original_ids<Token>(),
        quote: type_name::with_original_ids<Quote>(),
        tranches,
        min_raise,
        claim_ms,
        fee_bps,
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
    unsold: u64,
) {
    emit(PresaleFinalized { presale_id, succeeded, raised, fee, fee_destination, unsold });
}

public(package) fun claimed(presale_id: ID, tranche: u64, buyer: address, tokens: u64, quote: u64) {
    emit(Claimed { presale_id, tranche, buyer, tokens, quote });
}

// === Imports ===

use blast_presale::{blast_events::emit_event as emit, tranche::Tranche};

use std::type_name::{Self, TypeName};
