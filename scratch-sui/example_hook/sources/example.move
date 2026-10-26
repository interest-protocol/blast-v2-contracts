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

/// One entry call: before policy, actual-coin execution, after policy, final coins.
/// Both callback slots must be registered to this module's sealed witness.
public fun swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    params: SwapParams,
    hook_data: vector<u8>,
    asset_payment: Coin<Asset>,
    quote_payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let (completion, asset_coin, quote_coin) = before_swap(
        pool, params, hook_data, asset_payment, quote_payment, ctx,
    );

    after_swap(pool, completion, asset_coin, quote_coin, ctx)
}

/// Full swap payload. Policy may validate/replace params and hook data, split fees,
/// burn under legitimate coin authority, or add funded coins before core execution.
/// Snapshot caller limits/budgets before mutation; policy must bound gross funding.
public fun before_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: SwapParams,
    mut hook_data: vector<u8>,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Completion<Asset, Quote, Swap, SwapParams>, Coin<Asset>, Coin<Quote>) {
    let original_params = params;
    let asset_budget = asset_payment.value();
    let quote_budget = quote_payment.value();
    let fee_override_ppm = before_swap_policy(
        pool, original_params, &mut params, &mut hook_data,
        &mut asset_payment, &mut quote_payment, ctx,
    );

    pool.execute_swap(
        HookWitness(), original_params, params, hook_data, asset_budget, quote_budget,
        asset_payment, quote_payment, fee_override_ppm, ctx,
    )
}

/// All execution results, including actual output/change coins, reach the after policy.
/// Policy may consume, split or augment coins; core then checks ORIGINAL final bounds.
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

/// Before-only bundle. Core must reject this path when the after callback is enabled.
/// It performs final coin checks directly and returns no completion obligation.
public fun swap_without_after<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: SwapParams,
    mut hook_data: vector<u8>,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let original_params = params;
    let asset_budget = asset_payment.value();
    let quote_budget = quote_payment.value();
    let fee_override_ppm = before_swap_policy(
        pool, original_params, &mut params, &mut hook_data,
        &mut asset_payment, &mut quote_payment, ctx,
    );

    pool.execute_swap_without_after(
        HookWitness(), original_params, params, hook_data, asset_budget, quote_budget,
        asset_payment, quote_payment, fee_override_ppm, ctx,
    )
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

/// Full before payload: validate original limits, then mutate inputs/coins by policy.
public fun before_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    mut params: DonateParams,
    mut hook_data: vector<u8>,
    mut asset_payment: Coin<Asset>,
    mut quote_payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Completion<Asset, Quote, Donate, DonateParams>, Coin<Asset>, Coin<Quote>) {
    let original_params = params;
    let asset_budget = asset_payment.value();
    let quote_budget = quote_payment.value();
    before_policy(
        pool, original_params, &mut params, &mut hook_data,
        &mut asset_payment, &mut quote_payment, ctx,
    );

    pool.execute_donate(
        HookWitness(), original_params, params, hook_data, asset_budget, quote_budget,
        asset_payment, quote_payment, ctx,
    )
}

/// Full after results: mutate actual coins, validate, and return final coins.
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

/// Validate gross user funding before taking coins; never weaken original bounds.
/// Ordinary tokens may be transferred/split; burning additionally requires coin authority.
fun before_swap_policy<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    _original_params: SwapParams,
    _params: &mut SwapParams,
    _hook_data: &mut vector<u8>,
    _asset_payment: &mut Coin<Asset>,
    _quote_payment: &mut Coin<Quote>,
    _ctx: &mut TxContext,
): Option<u32> {
    record_call(pool);
    abort EInterfaceOnly
}

fun before_policy<Asset, Quote, Params: copy + drop + store>(
    pool: &mut Pool<Asset, Quote>,
    _original_params: Params,
    _params: &mut Params,
    _hook_data: &mut vector<u8>,
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
        AddLiquidity, RemoveLiquidity, Swap, Donate, Completion,
    },
};
use sui::coin::Coin;
