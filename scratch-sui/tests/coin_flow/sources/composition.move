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

/// Both phases expose their whole coin pair; coin mutation needs no signed amounts.
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
    let (completion, mut asset_coin, quote_coin) = example::before_swap(
        pool, params, hook_data, asset, quote, ctx,
    );
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
    let (completion, asset_coin, quote_coin) = liquidity::before_add_liquidity(
        pool, params, vector[], asset, quote, position, ctx,
    );

    example::after_add_liquidity(pool, completion, asset_coin, quote_coin, ctx)
}

/// Disabled callbacks use core directly, with exactly the original payment budgets.
public fun disabled_swap_hooks<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    asset: Coin<Asset>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let asset_budget = asset.value();
    let quote_budget = quote.value();
    let (completion, asset_coin, quote_coin) = pool.execute_swap(
        pool::no_hook(), params, params, vector[], asset_budget, quote_budget,
        asset, quote, option::none(), ctx,
    );

    pool.finish_swap(pool::no_hook(), completion, asset_coin, quote_coin)
}

// === Imports ===

use blast_fun_dex::{params::{LiquidityParams, SwapParams}, pool::{Self, Pool, Position}};
use blast_fun_dex_example_hook::example;
use blast_fun_dex_example_liquidity_hook::liquidity;
use sui::coin::Coin;
