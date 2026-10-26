/// Compile-only cross-package composition. Runtime policies still abort; do not publish.
module blast_fun_dex_coin_flow_tests::composition;

// === Public Functions ===

/// A bundled swap returns actual coins available to a subsequent operation.
public fun bundled_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    hook_data: vector<u8>,
    asset: Coin<Asset>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    example::swap(pool, params, hook_data, asset, quote, ctx)
}

/// A before-only swap has the same terminal coin types and no leaked obligation.
public fun before_only_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    hook_data: vector<u8>,
    asset: Coin<Asset>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    example::swap_without_after(pool, params, hook_data, asset, quote, ctx)
}

/// Pre-hook seals payments in the request; post-execution coin mutation needs no signed amounts.
/// This fixture establishes types only, not entitlement or runtime safety.
public fun split_swap_results<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    hook_data: vector<u8>,
    asset: Coin<Asset>,
    quote: Coin<Quote>,
    fee_recipient: address,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let request = example::before_swap(
        pool, params, hook_data, asset, quote, ctx,
    );
    let (completion, mut asset_coin, quote_coin) = pool.execute_swap(request, ctx);
    let fee = asset_coin.split(1, ctx);
    transfer::public_transfer(fee, fee_recipient);

    example::after_swap(pool, completion, asset_coin, quote_coin, ctx)
}

/// The two hook packages compose without depending on each other.
public fun mixed_liquidity_hooks<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    params: LiquidityParams,
    asset: Coin<Asset>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let request = liquidity::before_add_liquidity(
        pool, params, vector[], asset, quote, position, ctx,
    );
    let (completion, asset_coin, quote_coin) = pool.execute_add_liquidity(
        request, position, ctx,
    );

    example::after_add_liquidity(pool, completion, asset_coin, quote_coin, ctx)
}

/// Disabled callbacks use core directly; proof issuance rejects an enabled callback.
public fun disabled_swap_hooks<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    asset: Coin<Asset>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let request = pool.prepare_swap(
        pool::no_hook(), params, vector[], asset.into_balance(), quote.into_balance(),
        option::none(), ctx,
    );
    let (completion, asset_coin, quote_coin) = pool.execute_swap(request, ctx);

    pool.finish_swap(pool::no_hook(), completion, asset_coin, quote_coin)
}

/// Wrapped parameters may be inspected, but no API exposes mutable request fields.
public fun inspect_swap_request<Asset, Quote>(
    request: Request<Asset, Quote, Swap, SwapParams>,
): Request<Asset, Quote, Swap, SwapParams> {
    let (_, _, _, _, _, _, _, _) = request.request_context();
    request
}

/// Pure simulation takes only immutable inputs and returns values, never a swap approval.
public fun read_swap_projection<Asset, Quote>(
    pool: &Pool<Asset, Quote>,
    params: SwapParams,
): Simulation<Asset, Quote, Swap> {
    pool.simulate_swap(params, option::none())
}

// === Imports ===

use blast_fun_dex::{
    params::{LiquidityParams, SwapParams},
    pool::{Self, Pool, Position, Simulation, Swap, Request},
};
use blast_fun_dex_example_hook::example;
use blast_fun_dex_example_liquidity_hook::liquidity;
use sui::coin::Coin;
