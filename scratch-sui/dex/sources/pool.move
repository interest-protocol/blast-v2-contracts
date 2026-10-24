/// Interface sketch only. All function bodies abort.
/// This package must not be published.
/// Core owns operation phases and settlement; it imports no hook package.
module blast_fun_dex::pool;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

// Fields are intentionally unread while all interface bodies abort.
/// Intended shared pool. Economic storage is omitted; permissions are immutable.
#[allow(unused_field)]
public struct Pool<phantom Asset, phantom Quote> has key {
    id: UID,
    permissions: Permissions,
    hooks: vector<HookBinding>,
    nonce: u64,
    swap_fee: SwapFee,
}

/// No abilities. Owns the unfinished pool; only this type exposes hook registration.
public struct PoolInitializer<phantom Asset, phantom Quote> {
    pool: Pool<Asset, Quote>,
    params: InitializeParams,
}

/// One callback bit and its sealed witness type. At most ten distinct slots.
public struct HookBinding has store {
    callback: u16,
    witness_type: TypeName,
}

/// No abilities. Consuming the initializer seals its callback configuration.
public struct InitializeRequest<phantom Asset, phantom Quote> {
    initializer: PoolInitializer<Asset, Quote>,
    sender: address,
}

/// No abilities. Holds the pool after the before-initialize phase and core setup.
/// Only the configured after-initialize hook can authorize the ready pool.
public struct InitializeCompletion<phantom Asset, phantom Quote> {
    pool: Pool<Asset, Quote>,
    sender: address,
    params: InitializeParams,
    tick: I32,
}

/// A public skip witness, accepted only when the specific callback is disabled.
/// It must never be registered as a hook; it conveys no hook authority.
public struct NoHook() has drop;

// Fields are intentionally unread while all interface bodies abort.
/// Caller-owned liquidity authority; object ID distinguishes positions in a range.
#[allow(unused_field)]
public struct Position<phantom Asset, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
}

/// Phantom operation tags prevent cross-operation request/completion substitution.
public struct AddLiquidity()
public struct RemoveLiquidity()
public struct Swap()
public struct Donate()

// Fields are intentionally unread while all interface bodies abort.
/// No abilities. Immutable context and a snapshot of the current operation nonce.
/// Every consumer must check that nonce; overlapping operations stale earlier
/// obligations, whose mandatory consumption must then abort the whole PTB.
/// Params plus operation tag distinguish runtime operations without erasing types.
#[allow(unused_field)]
public struct Request<phantom Asset, phantom Quote, phantom Operation, Params: copy + drop + store> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    params: Params,
    hook_data: vector<u8>,
}

// Fields are intentionally unread while all interface bodies abort.
/// No abilities. Retains original context plus core results for the after hook.
/// Before-swap delta is retained for finish_swap to combine with the after delta.
/// Liquidity exposes caller delta and fees accrued; swap retains before-hook debts.
#[allow(unused_field)]
public struct Completion<phantom Asset, phantom Quote, phantom Operation, Params: copy + drop + store> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    params: Params,
    hook_data: vector<u8>,
    caller_delta: BalanceDelta,
    fees_accrued: BalanceDelta,
    before_swap_delta: BeforeSwapDelta,
    hook_balances: vector<HookBalance>,
    tick: I32,
}

// Fields are intentionally unread while all interface bodies abort.
/// No abilities. Caller and all recorded hook ledgers must reconcile exactly once.
/// Aggregate by witness type, at most two delta-producing hooks per operation.
#[allow(unused_field)]
public struct Settlement<phantom Asset, phantom Quote> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    caller_delta: BalanceDelta,
    hook_balances: vector<HookBalance>,
    caller_settled: bool,
}

/// A single hook's debt or claim; before/after contributions of one type net here.
/// Fields are private; only core may create, combine, or mark a ledger settled.
public struct HookBalance {
    witness_type: TypeName,
    delta: BalanceDelta,
    settled: bool,
}

// === Public Functions ===

// Construction and pool state.

/// Intended construction of a no-ability initializer. Validate pair, fee, and range units.
public fun new<Asset, Quote>(
    _tick_spacing: u32,
    _swap_fee: SwapFee,
    _sqrt_price_x96: u256,
    _ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended registration of this witness for each selected callback bit.
/// Bind the original defining witness type, rejecting primitive/NoHook types,
/// duplicate slots and invalid delta flags. Hook packages must keep witnesses sealed;
/// core cannot detect a hook package that publicly exposes its own witness.
/// At most ten slots; final bindings must exactly match the aggregate bitmap.
public fun register_hook<Asset, Quote, Hook: drop>(
    _self: &mut PoolInitializer<Asset, Quote>,
    _hook: Hook,
    _permissions: Permissions,
) {
    abort EInterfaceOnly
}

/// Intended defining-module sink for the ready pool returned by finalize.
public fun share<Asset, Quote>(
    _self: Pool<Asset, Quote>,
) {
    abort EInterfaceOnly
}

/// Intended skip-witness issuer. Enabled callbacks must reject this witness.
public fun no_hook(): NoHook {
    abort EInterfaceOnly
}

/// Intended position constructor; validate int24 ticks, supported pool range, and spacing.
public fun new_position<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _tick_lower: I32,
    _tick_upper: I32,
    _ctx: &mut TxContext,
): Position<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended owner-authorized destruction, only with zero liquidity and no fee claims.
public fun destroy_position<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _position: Position<Asset, Quote>,
) {
    abort EInterfaceOnly
}

/// Intended copy of authenticated sender, parameters, and opaque hook data.
public fun request_context<Asset, Quote, Operation, Params: copy + drop + store>(
    _self: &Request<Asset, Quote, Operation, Params>,
): (address, Params, vector<u8>) {
    abort EInterfaceOnly
}

/// Intended original context, caller delta, fees accrued, and resulting tick.
public fun completion_context<Asset, Quote, Operation, Params: copy + drop + store>(
    _self: &Completion<Asset, Quote, Operation, Params>,
): (address, Params, vector<u8>, BalanceDelta, BalanceDelta, I32) {
    abort EInterfaceOnly
}

/// Intended live price, tick, and current LP fee in ppm from either SwapFee variant.
public fun pool_state<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
): (u256, I32, u32) {
    abort EInterfaceOnly
}

// Initialization. The unfinished pool never becomes a public Pool input.

/// Intended immutable configuration seal; validate all bindings before either hook.
public fun begin_initialize<Asset, Quote>(
    _initializer: PoolInitializer<Asset, Quote>,
    _ctx: &mut TxContext,
): InitializeRequest<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended before-initialize witness check and core price/tick initialization.
/// Require NoHook only when the before-initialize callback is disabled.
public fun execute_initialize<Asset, Quote, Hook: drop>(
    _hook: Hook,
    _request: InitializeRequest<Asset, Quote>,
): InitializeCompletion<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended after-initialize witness check; consume the last construction obligation.
/// Return the ready pool. There is no hook setter on Pool; NoHook is disabled-only.
public fun finalize<Asset, Quote, Hook: drop>(
    _hook: Hook,
    _completion: InitializeCompletion<Asset, Quote>,
): Pool<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended pending pool ID, original caller, and initial parameters for hook policy.
public fun initialize_request_context<Asset, Quote>(
    _self: &InitializeRequest<Asset, Quote>,
): (ID, address, InitializeParams) {
    abort EInterfaceOnly
}

/// Intended pending pool ID, original caller, initial parameters, and resulting tick.
public fun initialize_completion_context<Asset, Quote>(
    _self: &InitializeCompletion<Asset, Quote>,
): (ID, address, InitializeParams, I32) {
    abort EInterfaceOnly
}

// Add liquidity.

/// Intended validation, monotonic nonce advance, and authenticated context.
public fun begin_add_liquidity<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _liquidity: u128,
    _asset_bound: u64,
    _quote_bound: u64,
    _hook_data: vector<u8>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, AddLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended before-callback binding, pool/nonce, and economic checks, then core execution.
/// NoHook is accepted only for a disabled callback, with no hook delta.
public fun execute_add_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, AddLiquidity, LiquidityParams>,
    _position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, AddLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended after-callback binding and current nonce checks; create settlement.
/// NoHook is disabled-only; reject unpermitted deltas and preserve all hook ledgers.
/// Check final user bounds on combined deltas before issuing the settlement.
public fun finish_add_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, AddLiquidity, LiquidityParams>,
    _hook_delta: BalanceDelta,
): Settlement<Asset, Quote> {
    abort EInterfaceOnly
}

// Remove liquidity.

/// Intended validation, monotonic nonce advance, and authenticated context.
public fun begin_remove_liquidity<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _liquidity: u128,
    _asset_bound: u64,
    _quote_bound: u64,
    _hook_data: vector<u8>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended before-callback binding, pool/nonce, and economic checks, then core execution.
/// NoHook is accepted only for a disabled callback, with no hook delta.
public fun execute_remove_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    _position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended after-callback binding and current nonce checks; create settlement.
/// NoHook is disabled-only; reject unpermitted deltas and preserve all hook ledgers.
/// Check final user bounds on combined deltas before issuing the settlement.
public fun finish_remove_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    _hook_delta: BalanceDelta,
): Settlement<Asset, Quote> {
    abort EInterfaceOnly
}

// Swap.

/// Intended validation, monotonic nonce advance, and authenticated context.
public fun begin_swap<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _params: SwapParams,
    _hook_data: vector<u8>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Swap, SwapParams> {
    abort EInterfaceOnly
}

/// Intended before-swap binding and pool/nonce checks, then core execution.
/// NoHook is disabled-only and requires zero delta/no override. A real override
/// requires SwapFee::Dynamic and never changes its stored rate; before delta
/// cannot change exact-in/out mode.
public fun execute_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, Swap, SwapParams>,
    _before_delta: BeforeSwapDelta,
    _lp_fee_override_ppm: Option<u32>,
): Completion<Asset, Quote, Swap, SwapParams> {
    abort EInterfaceOnly
}

/// Intended after-callback binding and current nonce checks; create settlement.
/// NoHook is disabled-only; reject unpermitted deltas and preserve all hook ledgers.
/// Check final user bounds on combined deltas before issuing the settlement.
public fun finish_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Swap, SwapParams>,
    _unspecified_hook_delta: I128,
): Settlement<Asset, Quote> {
    abort EInterfaceOnly
}

// Donate.

/// Intended validation, monotonic nonce advance, and authenticated context.
public fun begin_donate<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _asset_amount: u64,
    _quote_amount: u64,
    _hook_data: vector<u8>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Donate, DonateParams> {
    abort EInterfaceOnly
}

/// Intended before-callback binding, pool/nonce, and economic checks, then core execution.
/// NoHook is accepted only for a disabled callback, with no hook delta.
public fun execute_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, Donate, DonateParams>,
): Completion<Asset, Quote, Donate, DonateParams> {
    abort EInterfaceOnly
}

/// Intended after-callback binding and current nonce checks; create settlement.
/// NoHook is disabled-only; reject unpermitted deltas and preserve all hook ledgers.
/// Donation amounts must match the caller debt, with no minted liquidity.
public fun finish_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Donate, DonateParams>,
): Settlement<Asset, Quote> {
    abort EInterfaceOnly
}

// Settlement and dynamic fees.

/// Intended original caller and its final delta, for settlement policy.
public fun settlement_context<Asset, Quote>(
    _self: &Settlement<Asset, Quote>,
): (address, BalanceDelta) {
    abort EInterfaceOnly
}

/// Intended lookup of the exact witness type's operation ledger for hook policy.
public fun hook_delta<Asset, Quote, Hook: drop>(
    _self: &Settlement<Asset, Quote>,
    _hook: &Hook,
): BalanceDelta {
    abort EInterfaceOnly
}

/// Intended current-nonce, exact-once original-caller settlement. Return payouts/change.
/// Consume actual coins for debts; a positive delta alone never mints value.
public fun settle_caller<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _settlement: &mut Settlement<Asset, Quote>,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended current-nonce, exact-once settlement of this witness type's ledger.
/// NoHook is never a ledger owner. Return hook payouts and payment change.
/// Consume actual coins for debts; a positive delta alone never mints value.
public fun settle_hook<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _settlement: &mut Settlement<Asset, Quote>,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended final sink: require current nonce, caller and every hook ledger paid,
/// and per-asset conservation. No stale obligation may ever be discarded.
public fun finish_settlement<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _settlement: Settlement<Asset, Quote>,
) {
    abort EInterfaceOnly
}

/// Intended before-swap-hook-only current-rate update; require SwapFee::Dynamic.
/// Enforce <= 1,000,000 ppm, reject Fixed, and preserve the Dynamic variant.
public fun update_dynamic_lp_fee<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _lp_fee_ppm: u32,
) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::{
    delta::{BalanceDelta, BeforeSwapDelta},
    i32::I32,
    i128::I128,
    params::{InitializeParams, LiquidityParams, SwapParams, DonateParams},
    permissions::Permissions,
    swap_fee::SwapFee,
};

use std::type_name::TypeName;
use sui::coin::Coin;
