/// Interface sketch only. Hook policies and DEX execution still abort; do not publish.
/// Hooks receive the complete payload and actual coins, not accounting claims.
module blast_fun_dex_example_hook::example;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; hook logic is not provided.";

// === Public Types ===

/// Only this module constructs approval; no public witness issuer exists.
public struct HookWitness() has drop;

/// Private construction keeps the key and stored fields under this hook's policy.
public struct StateKey() has copy, drop, store;

public struct HookState has store {
    calls: u64,
}

// === Public Functions ===

/// Register selected non-overlapping callbacks before the initializer is sealed.
public fun register_hooks<Asset, Quote>(
    initializer: &mut PoolInitializer<Asset, Quote>,
    bitmap: u16,
) {
    initializer.register_hook(HookWitness(), permissions::new(bitmap))
}

/// Inspect the sealed initializer, then approve core initialization.
public fun before_initialize<Asset, Quote>(
    request: InitializeRequest<Asset, Quote>,
): InitializeCompletion<Asset, Quote> {
    before_initialize_policy(&request);

    pool::execute_initialize(HookWitness(), request)
}

/// Inspect core initialization results, then release the ready pool.
public fun after_initialize<Asset, Quote>(
    completion: InitializeCompletion<Asset, Quote>,
): Pool<Asset, Quote> {
    after_initialize_policy(&completion);

    pool::finalize(HookWitness(), completion)
}

/// One entry call forwards the hook's sealed request into execution and after policy.
public fun swap<Asset, Quote, Input>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    payment: Coin<Input>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let request = before_swap(
        pool, params, payment, ctx,
    );
    let (completion, asset_coin, quote_coin) = pool.execute_swap(request, ctx);

    after_swap(pool, completion, asset_coin, quote_coin, ctx)
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

/// Policy receives immutable execution facts and mutable actual output/change coins.
/// Core authenticates invocation; it does not enforce policy or post-hook coin amounts.
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

/// Policy receives immutable execution facts and mutable actual output/change coins.
/// Core authenticates invocation; it does not enforce policy or post-hook coin amounts.
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

/// Policy may change the price limit and split/retain coins before sealing the payment.
/// Input's type determines direction; the remaining balance determines the swap budget.
public fun before_swap<Asset, Quote, Input>(
    pool: &mut Pool<Asset, Quote>,
    mut params: SwapParams,
    payment: Coin<Input>,
    ctx: &mut TxContext,
): SwapRequest<Asset, Quote, Input> {
    let mut payment = payment.into_balance();
    let fee_override = before_swap_policy(
        pool, &mut params, &mut payment, ctx,
    );
    pool.prepare_swap(HookWitness(), params, payment, fee_override)
}

/// Policy receives immutable execution facts and mutable actual output/change coins.
/// Core authenticates invocation; it does not enforce policy or post-hook coin amounts.
public fun after_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, Swap, SwapParams>,
    mut asset_coin: Coin<Asset>,
    mut quote_coin: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    after_policy(pool, &completion, &mut asset_coin, &mut quote_coin, ctx);

    pool.finish_swap(HookWitness(), completion, asset_coin, quote_coin)
}

/// Policy may read its state, simulate, validate parameters and keep or replace coins.
/// Ask core to wrap the chosen parameters only after policy succeeds.
/// The request owns remaining payments as balances; execution accepts no replacement payload.
public fun before_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: DonateParams,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    ctx: &mut TxContext,
): Request<Asset, Quote, Donate, DonateParams> {
    let preview = pool.simulate_donate(params);
    before_policy(
        pool, &preview, &mut params,
        &mut asset_payment, &mut quote_payment, ctx,
    );
    pool.prepare_donate(
        HookWitness(), params,
        asset_payment.into_balance(), quote_payment.into_balance(),
    )
}

/// Policy receives immutable execution facts and mutable actual output/change coins.
/// Core authenticates invocation; it does not enforce policy or post-hook coin amounts.
public fun after_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, Donate, DonateParams>,
    mut asset_coin: Coin<Asset>,
    mut quote_coin: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    after_policy(pool, &completion, &mut asset_coin, &mut quote_coin, ctx);

    pool.finish_donate(HookWitness(), completion, asset_coin, quote_coin)
}

/// Before-only bundle. Core rejects this when after-swap is enabled.
public fun swap_without_after<Asset, Quote, Input>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    payment: Coin<Input>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let request = before_swap(
        pool, params, payment, ctx,
    );

    pool.execute_swap_without_after(request, ctx)
}

/// Policy must authenticate who may change the cached Dynamic LP fee.
public fun update_dynamic_lp_fee<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    lp_fee_ppm: u32,
    ctx: &mut TxContext,
) {
    fee_update_policy(pool, lp_fee_ppm, ctx);

    pool.update_dynamic_lp_fee(HookWitness(), lp_fee_ppm)
}

/// Read this hook's pool-local state without a second shared object input.
public fun call_count<Asset, Quote>(pool: &Pool<Asset, Quote>): u64 {
    let witness = HookWitness();
    if (!pool.has_hook_state(&witness, StateKey())) return 0;

    let state: &HookState = pool.hook_state(&witness, StateKey());
    state.calls
}

// === Private Functions ===

/// Called inside policy, while its mutable pool borrow is available.
/// The same sealed witness gates state access and callback approval.
fun record_call<Asset, Quote>(pool: &mut Pool<Asset, Quote>) {
    let witness = HookWitness();
    if (!pool.has_hook_state(&witness, StateKey())) {
        pool.add_hook_state(&witness, StateKey(), HookState { calls: 0 });
    };
    let state: &mut HookState = pool.hook_state_mut(&witness, StateKey());
    state.calls = state.calls + 1;
}

fun before_initialize_policy<Asset, Quote>(_request: &InitializeRequest<Asset, Quote>) {
    abort EInterfaceOnly
}

fun after_initialize_policy<Asset, Quote>(_completion: &InitializeCompletion<Asset, Quote>) {
    abort EInterfaceOnly
}

/// Example policy may read pool-local state and preview effects before making its decisions.
/// Ordinary tokens may be transferred/split; burning additionally requires coin authority.
fun before_swap_policy<Asset, Quote, Input>(
    pool: &mut Pool<Asset, Quote>,
    _params: &mut SwapParams,
    _payment: &mut Balance<Input>,
    _ctx: &mut TxContext,
): Option<u32> {
    let witness = HookWitness();
    if (pool.has_hook_state(&witness, StateKey())) {
        let _state: &HookState = pool.hook_state(&witness, StateKey());
    };
    let (_, _, _) = pool.pool_state();
    let preview = pool.simulate_swap(*_params, _payment, option::none());
    let (_, _, _, _) = preview.simulation_amounts();
    let (_, _, _, _, _, _, _) = preview.simulation_pool_state();
    // The preview itself never writes. Policy may update only its own hook state here.
    record_call(pool);
    abort EInterfaceOnly
}

fun before_policy<Asset, Quote, Operation, Params: copy + drop + store>(
    pool: &mut Pool<Asset, Quote>,
    _preview: &Simulation<Asset, Quote, Operation>,
    _params: &mut Params,
    _asset_payment: &mut Coin<Asset>,
    _quote_payment: &mut Coin<Quote>,
    _ctx: &mut TxContext,
) {
    record_call(pool);
    abort EInterfaceOnly
}

/// Receipt facts stay core-owned; the hook can mutate the entire returned coin pair.
fun after_policy<Asset, Quote, Operation, Params: copy + drop + store>(
    pool: &mut Pool<Asset, Quote>,
    _completion: &Completion<Asset, Quote, Operation, Params>,
    _asset_coin: &mut Coin<Asset>,
    _quote_coin: &mut Coin<Quote>,
    _ctx: &mut TxContext,
) {
    record_call(pool);
    abort EInterfaceOnly
}

fun fee_update_policy<Asset, Quote>(
    _pool: &mut Pool<Asset, Quote>,
    _lp_fee_ppm: u32,
    _ctx: &TxContext,
) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::{
    params::{LiquidityParams, SwapParams, DonateParams},
    permissions,
    pool::{
        Self, Pool, Position, PoolInitializer, InitializeRequest, InitializeCompletion,
        AddLiquidity, RemoveLiquidity, Swap, Donate, Completion, Request, SwapRequest, Simulation,
    },
};
use sui::{balance::Balance, coin::Coin};
