// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical Ed25519 authorization for one exact action; no deserialization or caller bytes are trusted.
module blast_market_maker::risk;

// === Public Types ===

/// The field order is the signing ABI. Atoms use the market maker's original asset types.
public struct Action has copy, drop, store {
    kind: u8,
    meme_input: u64,
    quote_input: u64,
    min_meme: u64,
    min_quote: u64,
    sqrt_price_limit: u128,
    position_id: Option<ID>,
    tick_lower: u32,
    tick_upper: u32,
    liquidity: u128,
}

/// Original-type provenance separates distinct deployments, together with the exact market maker ID.
public struct Domain() has drop;
public struct RiskMessage has drop {
    domain: TypeName,
    vault_id: ID,
    external_id: ID,
    meme: TypeName,
    quote: TypeName,
    pool_id: Option<ID>,
    operator_cap_id: ID,
    action: Action,
    nonce: u64,
    signer_epoch: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Constructors are inert values. Execution reconstructs the exact action from its arguments.
public fun curve_buy(quote_input: u64, min_meme: u64): Action {
    action(CURVE_BUY, 0, quote_input, min_meme, 0, 0, option::none(), 0, 0, 0)
}

public fun curve_sell(meme_input: u64, min_quote: u64): Action {
    action(CURVE_SELL, meme_input, 0, 0, min_quote, 0, option::none(), 0, 0, 0)
}

public fun pool_swap(
    meme_input: u64,
    quote_input: u64,
    min_meme: u64,
    min_quote: u64,
    sqrt_price_limit: u128,
): Action {
    action(
        POOL_SWAP,
        meme_input,
        quote_input,
        min_meme,
        min_quote,
        sqrt_price_limit,
        option::none(),
        0,
        0,
        0,
    )
}

public fun open(
    tick_lower: u32,
    tick_upper: u32,
    max_meme: u64,
    max_quote: u64,
    min_liquidity: u128,
): Action {
    action(
        OPEN_POSITION,
        max_meme,
        max_quote,
        0,
        0,
        0,
        option::none(),
        tick_lower,
        tick_upper,
        min_liquidity,
    )
}

public fun add(position_id: ID, meme_input: u64, quote_input: u64, min_liquidity: u128): Action {
    action(
        ADD_LIQUIDITY,
        meme_input,
        quote_input,
        0,
        0,
        0,
        option::some(position_id),
        0,
        0,
        min_liquidity,
    )
}

public fun remove(position_id: ID, liquidity: u128, min_meme: u64, min_quote: u64): Action {
    action(
        REMOVE_LIQUIDITY,
        0,
        0,
        min_meme,
        min_quote,
        0,
        option::some(position_id),
        0,
        0,
        liquidity,
    )
}

public fun unwind(position_id: ID, liquidity: u128, min_meme: u64, min_quote: u64): Action {
    action(UNWIND, 0, 0, min_meme, min_quote, 0, option::some(position_id), 0, 0, liquidity)
}

// === Package Functions ===

public(package) fun is_unwind(self: Action): bool { self.kind == UNWIND }

public(package) fun inputs(self: Action): (u64, u64) { (self.meme_input, self.quote_input) }

public(package) fun is_curve(self: Action): bool {
    self.kind == CURVE_BUY || self.kind == CURVE_SELL
}

public(package) fun message_bytes<Meme, Quote>(
    vault_id: ID,
    external_id: ID,
    pool_id: Option<ID>,
    operator_cap_id: ID,
    action: Action,
    nonce: u64,
    signer_epoch: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
): vector<u8> {
    std::bcs::to_bytes(
        &RiskMessage {
            domain: type_name::with_original_ids<Domain>(),
            vault_id,
            external_id,
            meme: type_name::with_original_ids<Meme>(),
            quote: type_name::with_original_ids<Quote>(),
            pool_id,
            operator_cap_id,
            action,
            nonce,
            signer_epoch,
            issued_at_ms,
            expires_at_ms,
        },
    )
}

public(package) fun verify(
    public_key: &vector<u8>,
    signature: &vector<u8>,
    message: &vector<u8>,
    issued_at_ms: u64,
    expires_at_ms: u64,
    clock: &Clock,
) {
    assert!(
        issued_at_ms <= expires_at_ms && expires_at_ms - issued_at_ms <= 15_000,
        EInvalidValidityWindow,
    );
    assert!(
        issued_at_ms <= clock.timestamp_ms() && clock.timestamp_ms() <= expires_at_ms,
        EAuthorizationExpired,
    );
    assert!(public_key.length() == 32 && signature.length() == 64, EInvalidSignatureShape);
    assert!(ed25519::ed25519_verify(signature, public_key, message), EInvalidSignature);
}

// === Private Functions ===

fun action(
    kind: u8,
    meme_input: u64,
    quote_input: u64,
    min_meme: u64,
    min_quote: u64,
    sqrt_price_limit: u128,
    position_id: Option<ID>,
    tick_lower: u32,
    tick_upper: u32,
    liquidity: u128,
): Action {
    Action {
        kind,
        meme_input,
        quote_input,
        min_meme,
        min_quote,
        sqrt_price_limit,
        position_id,
        tick_lower,
        tick_upper,
        liquidity,
    }
}

// === Constants ===

const CURVE_BUY: u8 = 0;
const CURVE_SELL: u8 = 1;
const POOL_SWAP: u8 = 2;
const OPEN_POSITION: u8 = 3;
const ADD_LIQUIDITY: u8 = 4;
const REMOVE_LIQUIDITY: u8 = 5;
const UNWIND: u8 = 6;

// === Errors ===

#[error(code = 0)]
const EInvalidValidityWindow: vector<u8> =
    b"Authorization validity must be ordered and no more than fifteen seconds.";
#[error(code = 1)]
const EAuthorizationExpired: vector<u8> =
    b"Authorization is not valid at the canonical Clock timestamp.";
#[error(code = 2)]
const EInvalidSignatureShape: vector<u8> =
    b"Ed25519 requires a 32-byte public key and a 64-byte signature.";
#[error(code = 3)]
const EInvalidSignature: vector<u8> =
    b"The independent risk signer did not authorize this exact action.";

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{clock::Clock, ed25519};
