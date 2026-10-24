/// Interface sketch only. Stub bodies abort; this package must not be published.
/// Core owns the linear swap obligations and depends on no hook package.
module blast_fun_dex::pool;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

// Fields are intentionally unread until the interface receives an implementation.
/// Intended shared pool. Reserves, fees, and policy storage are omitted.
#[allow(unused_field)]
public struct Pool<phantom Asset, phantom Quote> has key {
    id: UID,
    hook_type: TypeName,
    nonce: u64,
    in_flight: bool,
}

// Fields are intentionally unread in this interface-only sketch.
/// No abilities: the before-swap hook must consume this transaction's request.
#[allow(unused_field)]
public struct SwapRequest<phantom Asset, phantom Quote> {
    pool_id: ID,
    nonce: u64,
    input: Balance<Asset>,
    minimum_output: u64,
}

// Fields are intentionally unread in this interface-only sketch.
/// No abilities: the after-swap hook must authorize release of the output.
#[allow(unused_field)]
public struct SwapCompletion<phantom Asset, phantom Quote> {
    pool_id: ID,
    nonce: u64,
    output: Balance<Quote>,
}

// === Public Functions ===

/// Intended to bind the pool to the original type identity of a sealed Hook witness.
public fun new<Asset, Quote, Hook: drop>(
    _hook: Hook,
    _ctx: &mut TxContext,
): Pool<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended defining-module sink for the key-only pool returned by new.
public fun share<Asset, Quote>(_self: Pool<Asset, Quote>) {
    abort EInterfaceOnly
}

/// Intended to lock the idle pool, advance its nonce, and escrow the exact input.
public fun begin_swap<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _input: Coin<Asset>,
    _minimum_output: u64,
): SwapRequest<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended to verify Hook, pool ID, nonce, fee bounds, and minimum output.
/// Consumes the request and executes the swap, keeping output in the completion.
public fun execute_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: SwapRequest<Asset, Quote>,
    _fee_bps: u64,
    _ctx: &mut TxContext,
): SwapCompletion<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended to verify Hook, pool ID, nonce, and settlement before unlocking.
/// Only this module can unpack the completion and release its output coin.
public fun finish_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: SwapCompletion<Asset, Quote>,
): Coin<Quote> {
    abort EInterfaceOnly
}

// === Imports ===

use std::type_name::TypeName;
use sui::{balance::Balance, coin::Coin};
