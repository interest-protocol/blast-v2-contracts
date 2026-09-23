// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Typed replay facts for vault custody, venue tiers, Cetus pool reservations, and residual claims.
module blast_fun_migrators::blast_events;

// === Public Types ===

/// Records one pinned venue tier replacing the previous values.
///
/// Zero old values mean the venue had no earlier pin: Cetus was on its compiled default, and
/// Bluefin had no tier.
public struct VenueTierUpdated has copy, drop {
    venue: TypeName,
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
}

/// Records discovery and typed position custody for one completed vault.
public struct VaultCreated has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
}

/// Records a protocol migration-residual claim.
public struct ProtocolFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
}

/// Records Cetus pool creation reserved for one pair at the tick spacing its migration uses.
public struct CetusPoolReserved has copy, drop {
    meme: TypeName,
    quote: TypeName,
    pool_creation_cap_id: ID,
    tick_spacing: u32,
}

// === Package Functions ===

/// Emits installation or replacement of one venue's effective tier override.
public(package) fun venue_tier_updated<Venue>(
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
) {
    sui::event::emit(VenueTierUpdated {
        venue: type_name::with_original_ids<Venue>(),
        old_tick_spacing,
        new_tick_spacing,
        old_fee_rate,
        new_fee_rate,
    });
}

/// Emits creation of one venue-sealed LP vault and attached position.
public(package) fun vault_created<Meme, Quote, Venue>(
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
) {
    sui::event::emit(VaultCreated {
        vault_id,
        pool_id,
        position_id,
        venue: type_name::with_original_ids<Venue>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
    });
}

/// Emits a protocol-owned migration-residual withdrawal.
public(package) fun protocol_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(ProtocolFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

/// Emits one Cetus pair reservation made while binding a launch ticket.
public(package) fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32) {
    sui::event::emit(CetusPoolReserved {
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        pool_creation_cap_id,
        tick_spacing,
    });
}

// === Imports ===

use std::type_name::{Self, TypeName};
