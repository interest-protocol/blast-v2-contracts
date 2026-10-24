/// Interface sketch only. Shows a separately packaged hook calling inward to DEX.
/// Hook behavior is omitted and stubbed with aborts; do not publish this package.
module blast_fun_dex_example_hook::example;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; hook logic is not provided.";

// === Public Types ===

/// Ephemeral approval. Only this module constructs it; no public issuer exists.
public struct HookWitness has drop {}

// === Public Functions ===

/// Calls the DEX constructor with this hook's sealed witness.
public fun new_pool<Asset, Quote>(ctx: &mut TxContext): Pool<Asset, Quote> {
    pool::new(HookWitness {}, ctx)
}

/// Runs hook-specific checks and fee calculation, then authorizes execution.
public fun before_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: SwapRequest<Asset, Quote>,
    ctx: &mut TxContext,
): SwapCompletion<Asset, Quote> {
    let fee_bps = calculate_fee(pool, &request);

    pool.execute_swap(HookWitness {}, request, fee_bps, ctx)
}

/// Runs hook-specific completion checks, then authorizes output release.
public fun after_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: SwapCompletion<Asset, Quote>,
): Coin<Quote> {
    check_after_swap(pool, &completion);

    pool.finish_swap(HookWitness {}, completion)
}

// === Private Functions ===

fun calculate_fee<Asset, Quote>(
    _pool: &Pool<Asset, Quote>,
    _request: &SwapRequest<Asset, Quote>,
): u64 {
    abort EInterfaceOnly
}

fun check_after_swap<Asset, Quote>(
    _pool: &Pool<Asset, Quote>,
    _completion: &SwapCompletion<Asset, Quote>,
) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::pool::{Self, Pool, SwapRequest, SwapCompletion};
use sui::coin::Coin;
