/// Interface sketch only. All paths reach aborting DEX or policy stubs.
/// Ten v4-style lifecycle callbacks in a separate package; do not publish.
module blast_fun_dex_example_hook::example;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; hook logic is not provided.";

// === Public Types ===

/// Only this module constructs approval; no public witness issuer exists.
public struct HookWitness() has drop;

// === Public Functions ===

/// Register this package for any selected callbacks before the initializer is sealed.
/// Another hook package may register the remaining, non-overlapping callback slots.
public fun register_hooks<Asset, Quote>(
    initializer: &mut PoolInitializer<Asset, Quote>,
    bitmap: u16,
) {
    let permissions = permissions::new(bitmap);

    initializer.register_hook(HookWitness(), permissions)
}

/// Before initialize: inspect the sealed initializer, then approve core setup.
public fun before_initialize<Asset, Quote>(
    request: InitializeRequest<Asset, Quote>,
): InitializeCompletion<Asset, Quote> {
    before_initialize_policy(&request);

    pool::execute_initialize(HookWitness(), request)
}

/// After initialize: inspect core results, then release the ready pool.
public fun after_initialize<Asset, Quote>(
    completion: InitializeCompletion<Asset, Quote>,
): Pool<Asset, Quote> {
    after_initialize_policy(&completion);

    pool::finalize(HookWitness(), completion)
}

/// Before add liquidity: inspect authenticated context, then approve core execution.
public fun before_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: Request<Asset, Quote, AddLiquidity, LiquidityParams>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, AddLiquidity, LiquidityParams> {
    before_policy(pool, &request);

    pool.execute_add_liquidity(HookWitness(), request, position)
}

/// After add liquidity: inspect core results, then approve settlement.
public fun after_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, AddLiquidity, LiquidityParams>,
): Settlement<Asset, Quote> {
    let hook_delta = after_liquidity_policy(pool, &completion);

    pool.finish_add_liquidity(HookWitness(), completion, hook_delta)
}

/// Before remove liquidity: inspect authenticated context, then approve core execution.
public fun before_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: Request<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    before_policy(pool, &request);

    pool.execute_remove_liquidity(HookWitness(), request, position)
}

/// After remove liquidity: inspect core results, then approve settlement.
public fun after_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>,
): Settlement<Asset, Quote> {
    let hook_delta = after_liquidity_policy(pool, &completion);

    pool.finish_remove_liquidity(HookWitness(), completion, hook_delta)
}

/// Before swap: inspect authenticated context, then approve core execution.
public fun before_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: Request<Asset, Quote, Swap, SwapParams>,
): Completion<Asset, Quote, Swap, SwapParams> {
    let (before_delta, fee_override_ppm) = before_swap_policy(pool, &request);

    pool.execute_swap(HookWitness(), request, before_delta, fee_override_ppm)
}

/// After swap: inspect core results, then approve settlement.
public fun after_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, Swap, SwapParams>,
): Settlement<Asset, Quote> {
    let unspecified_delta = after_swap_policy(pool, &completion);

    pool.finish_swap(HookWitness(), completion, unspecified_delta)
}

/// Before donate: inspect authenticated context, then approve core execution.
public fun before_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    request: Request<Asset, Quote, Donate, DonateParams>,
): Completion<Asset, Quote, Donate, DonateParams> {
    before_policy(pool, &request);

    pool.execute_donate(HookWitness(), request)
}

/// After donate: inspect core results, then approve settlement.
public fun after_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    completion: Completion<Asset, Quote, Donate, DonateParams>,
): Settlement<Asset, Quote> {
    after_policy(pool, &completion);

    pool.finish_donate(HookWitness(), completion)
}

/// Hook policy must authorize funding and payout destinations before settlement.
/// Returned coins include any hook payout and payment change; caller consumes both.
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

/// Example policy must authenticate who may change its cached dynamic fee.
public fun update_dynamic_lp_fee<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    lp_fee_ppm: u32,
    ctx: &mut TxContext,
) {
    fee_update_policy(pool, lp_fee_ppm, ctx);

    pool.update_dynamic_lp_fee(HookWitness(), lp_fee_ppm)
}

// === Private Functions ===

fun before_initialize_policy<Asset, Quote>(
    _request: &InitializeRequest<Asset, Quote>,
) {
    abort EInterfaceOnly
}

fun after_initialize_policy<Asset, Quote>(
    _completion: &InitializeCompletion<Asset, Quote>,
) {
    abort EInterfaceOnly
}

fun before_policy<Asset, Quote, Operation, Params: copy + drop + store>(
    _pool: &Pool<Asset, Quote>,
    _context: &Request<Asset, Quote, Operation, Params>,
) {
    abort EInterfaceOnly
}

fun after_policy<Asset, Quote, Operation, Params: copy + drop + store>(
    _pool: &Pool<Asset, Quote>,
    _context: &Completion<Asset, Quote, Operation, Params>,
) {
    abort EInterfaceOnly
}

fun before_swap_policy<Asset, Quote>(
    _pool: &Pool<Asset, Quote>,
    _request: &Request<Asset, Quote, Swap, SwapParams>,
): (BeforeSwapDelta, Option<u32>) {
    abort EInterfaceOnly
}

fun after_swap_policy<Asset, Quote>(
    _pool: &Pool<Asset, Quote>,
    _completion: &Completion<Asset, Quote, Swap, SwapParams>,
): I128 {
    abort EInterfaceOnly
}

fun after_liquidity_policy<Asset, Quote, Operation>(
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

fun fee_update_policy<Asset, Quote>(
    _pool: &Pool<Asset, Quote>,
    _lp_fee_ppm: u32,
    _ctx: &TxContext,
) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::{
    delta::{BalanceDelta, BeforeSwapDelta},
    i128::I128,
    params::{LiquidityParams, SwapParams, DonateParams},
    permissions,
    pool::{
        Self, Pool, Position, PoolInitializer, InitializeRequest, InitializeCompletion,
        AddLiquidity, RemoveLiquidity, Swap, Donate, Request, Completion, Settlement,
    },
};
use sui::coin::Coin;
