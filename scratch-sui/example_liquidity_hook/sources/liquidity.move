/// Interface sketch only. Hook policies and DEX execution still abort; do not publish.
/// Hooks receive the complete payload and actual coins, not accounting claims.
module blast_fun_dex_example_liquidity_hook::liquidity;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; hook logic is not provided.";

// === Public Types ===

/// Only this module constructs approval; no public witness issuer exists.
public struct HookWitness() has drop;

// === Public Functions ===

/// The four liquidity lifecycle callbacks, independently registered from swap hooks.
macro public fun hook_flags(): u16 {
    permissions::before_add_liquidity_flag!() | permissions::after_add_liquidity_flag!() |
    permissions::before_remove_liquidity_flag!() | permissions::after_remove_liquidity_flag!()
}

/// Configure only the liquidity slots while the unfinished pool is still owned.
public fun register_hooks<Asset, Quote>(
    initializer: &mut PoolInitializer<Asset, Quote>,
) {
    initializer.register_hook(HookWitness(), permissions::new(hook_flags!()))
}

/// Policy may read its state, simulate, validate parameters and keep or replace coins.
/// Ask core to wrap the chosen parameters only after policy succeeds.
/// The request owns remaining payments as balances; execution accepts no replacement payload.
public fun before_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: LiquidityParams,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    position: &Position<Asset, Quote>,
    ctx: &mut TxContext,
): Request<Asset, Quote, AddLiquidity, LiquidityParams> {
    let preview = pool.simulate_add_liquidity(position, params);
    before_policy(
        pool, &preview, &mut params,
        &mut asset_payment, &mut quote_payment, ctx,
    );
    pool.prepare_add_liquidity(
        HookWitness(), params,
        asset_payment.into_balance(), quote_payment.into_balance(),
    )
}

/// Policy receives the pool-bound execution proof and mutable actual output/change coins.
/// Core authenticates invocation; it does not enforce policy or post-hook coin amounts.
public fun after_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, AddLiquidity>,
    mut asset_coin: Coin<Asset>,
    mut quote_coin: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    after_policy(pool, &completion, &mut asset_coin, &mut quote_coin, ctx);

    pool.finish_add_liquidity(HookWitness(), completion, asset_coin, quote_coin)
}

/// Policy may read its state, simulate, validate parameters and keep or replace coins.
/// Ask core to wrap the chosen parameters only after policy succeeds.
/// The request owns remaining payments as balances; execution accepts no replacement payload.
public fun before_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: LiquidityParams,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    position: &Position<Asset, Quote>,
    ctx: &mut TxContext,
): Request<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    let preview = pool.simulate_remove_liquidity(position, params);
    before_policy(
        pool, &preview, &mut params,
        &mut asset_payment, &mut quote_payment, ctx,
    );
    pool.prepare_remove_liquidity(
        HookWitness(), params,
        asset_payment.into_balance(), quote_payment.into_balance(),
    )
}

/// Policy receives the pool-bound execution proof and mutable actual output/change coins.
/// Core authenticates invocation; it does not enforce policy or post-hook coin amounts.
public fun after_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, RemoveLiquidity>,
    mut asset_coin: Coin<Asset>,
    mut quote_coin: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    after_policy(pool, &completion, &mut asset_coin, &mut quote_coin, ctx);

    pool.finish_remove_liquidity(HookWitness(), completion, asset_coin, quote_coin)
}

// === Private Functions ===

fun before_policy<Asset, Quote, Operation, Params: copy + drop + store>(
    _pool: &mut Pool<Asset, Quote>,
    _preview: &Simulation<Asset, Quote, Operation>,
    _params: &mut Params,
    _asset_payment: &mut Coin<Asset>,
    _quote_payment: &mut Coin<Quote>,
    _ctx: &mut TxContext,
) {
    abort EInterfaceOnly
}

/// The execution proof stays core-owned; the hook can mutate the entire returned coin pair.
fun after_policy<Asset, Quote, Operation>(
    _pool: &mut Pool<Asset, Quote>,
    _completion: &Completion<Asset, Quote, Operation>,
    _asset_coin: &mut Coin<Asset>,
    _quote_coin: &mut Coin<Quote>,
    _ctx: &mut TxContext,
) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::{
    params::LiquidityParams,
    permissions,
    pool::{Pool, Position, PoolInitializer, AddLiquidity, RemoveLiquidity, Completion, Request, Simulation},
};
use sui::coin::Coin;
