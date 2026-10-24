/// Interface sketch only. Independently packaged liquidity hook; do not publish.
/// Configures the same initializer as other hook packages and depends only on DEX.
module blast_fun_dex_example_liquidity_hook::liquidity;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; liquidity hook logic is not provided.";

// === Public Types ===

/// This package's sealed approval; independent of the swap hook's witness type.
public struct HookWitness() has drop;

// === Public Functions ===

/// Four liquidity callbacks and their two after-callback delta permissions.
macro public fun hook_flags(): u16 {
    permissions::before_add_liquidity_flag!() | permissions::after_add_liquidity_flag!() |
    permissions::before_remove_liquidity_flag!() | permissions::after_remove_liquidity_flag!() |
    permissions::after_add_liquidity_returns_delta_flag!() |
    permissions::after_remove_liquidity_returns_delta_flag!()
}

/// Configure only the liquidity slots while the unfinished pool is still owned.
public fun register_hooks<Asset, Quote>(
    initializer: &mut PoolInitializer<Asset, Quote>,
) {
    let permissions = permissions::new(hook_flags!());

    initializer.register_hook(HookWitness(), permissions)
}

/// Inspect liquidity parameters, then authorize the configured before callback.
public fun before_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: Request<Asset, Quote, AddLiquidity, LiquidityParams>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, AddLiquidity, LiquidityParams> {
    before_policy(pool, &request);

    pool.execute_add_liquidity(HookWitness(), request, position)
}

/// Inspect core results, then authorize this hook's accounting delta.
public fun after_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, AddLiquidity, LiquidityParams>,
): Settlement<Asset, Quote> {
    let hook_delta = after_policy(pool, &completion);

    pool.finish_add_liquidity(HookWitness(), completion, hook_delta)
}

/// Inspect liquidity parameters, then authorize the configured before callback.
public fun before_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: Request<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    before_policy(pool, &request);

    pool.execute_remove_liquidity(HookWitness(), request, position)
}

/// Inspect core results, then authorize this hook's accounting delta.
public fun after_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>,
): Settlement<Asset, Quote> {
    let hook_delta = after_policy(pool, &completion);

    pool.finish_remove_liquidity(HookWitness(), completion, hook_delta)
}

/// Policy must authorize this package's own funding and payout destinations.
public fun settle_hook<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    settlement: &mut Settlement<Asset, Quote>,
    asset_payment: Coin<Asset>,
    quote_payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    settlement_policy(pool, settlement);

    pool.settle_hook(HookWitness(), settlement, asset_payment, quote_payment, ctx)
}

// === Private Functions ===

fun before_policy<Asset, Quote, Operation>(
    _pool: &Pool<Asset, Quote>,
    _request: &Request<Asset, Quote, Operation, LiquidityParams>,
) {
    abort EInterfaceOnly
}

fun after_policy<Asset, Quote, Operation>(
    _pool: &Pool<Asset, Quote>,
    _completion: &Completion<Asset, Quote, Operation, LiquidityParams>,
): BalanceDelta {
    abort EInterfaceOnly
}

fun settlement_policy<Asset, Quote>(
    _pool: &Pool<Asset, Quote>,
    _settlement: &Settlement<Asset, Quote>,
) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::{
    delta::BalanceDelta,
    params::LiquidityParams,
    permissions,
    pool::{
        Pool, PoolInitializer, Position, AddLiquidity, RemoveLiquidity,
        Request, Completion, Settlement,
    },
};
use sui::coin::Coin;
