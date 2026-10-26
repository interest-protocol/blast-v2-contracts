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

/// Full before payload: validate original limits, then mutate inputs/coins by policy.
public fun before_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: LiquidityParams,
    mut hook_data: vector<u8>,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    position: &mut Position<Asset, Quote>,
    ctx: &mut TxContext,
): (Completion<Asset, Quote, AddLiquidity, LiquidityParams>, Coin<Asset>, Coin<Quote>) {
    let original_params = params;
    let asset_budget = asset_payment.value();
    let quote_budget = quote_payment.value();
    before_policy(
        pool, original_params, &mut params, &mut hook_data,
        &mut asset_payment, &mut quote_payment, ctx,
    );

    pool.execute_add_liquidity(
        HookWitness(), original_params, params, hook_data, asset_budget, quote_budget,
        asset_payment, quote_payment, position, ctx,
    )
}

/// Full after results: mutate actual coins, validate, and return final coins.
public fun after_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, AddLiquidity, LiquidityParams>,
    mut asset_coin: Coin<Asset>,
    mut quote_coin: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    after_policy(pool, &completion, &mut asset_coin, &mut quote_coin, ctx);

    pool.finish_add_liquidity(HookWitness(), completion, asset_coin, quote_coin)
}

/// Full before payload: validate original limits, then mutate inputs/coins by policy.
public fun before_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: LiquidityParams,
    mut hook_data: vector<u8>,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    position: &mut Position<Asset, Quote>,
    ctx: &mut TxContext,
): (Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>, Coin<Asset>, Coin<Quote>) {
    let original_params = params;
    let asset_budget = asset_payment.value();
    let quote_budget = quote_payment.value();
    before_policy(
        pool, original_params, &mut params, &mut hook_data,
        &mut asset_payment, &mut quote_payment, ctx,
    );

    pool.execute_remove_liquidity(
        HookWitness(), original_params, params, hook_data, asset_budget, quote_budget,
        asset_payment, quote_payment, position, ctx,
    )
}

/// Full after results: mutate actual coins, validate, and return final coins.
public fun after_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    mut asset_coin: Coin<Asset>,
    mut quote_coin: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    after_policy(pool, &completion, &mut asset_coin, &mut quote_coin, ctx);

    pool.finish_remove_liquidity(HookWitness(), completion, asset_coin, quote_coin)
}

// === Private Functions ===

fun before_policy<Asset, Quote, Params: copy + drop + store>(
    _pool: &mut Pool<Asset, Quote>,
    _original_params: Params,
    _params: &mut Params,
    _hook_data: &mut vector<u8>,
    _asset_payment: &mut Coin<Asset>,
    _quote_payment: &mut Coin<Quote>,
    _ctx: &mut TxContext,
) {
    abort EInterfaceOnly
}

/// Receipt facts stay core-owned; the hook can mutate the entire returned coin pair.
fun after_policy<Asset, Quote, Operation, Params: copy + drop + store>(
    _pool: &mut Pool<Asset, Quote>,
    _completion: &Completion<Asset, Quote, Operation, Params>,
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
    pool::{Pool, Position, PoolInitializer, AddLiquidity, RemoveLiquidity, Completion},
};
use sui::coin::Coin;
