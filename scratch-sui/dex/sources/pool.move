/// Interface sketch only. All function bodies abort.
/// This package must not be published.
/// Core owns operation phases and actual-coin execution; it imports no hook package.
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
/// Execution with NoHook requires identical original/adjusted params, budgets equal
/// to actual payment values, and no LP override; there is no trusted pre-hook snapshot.
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
/// No abilities. Proves core execution and requires the configured after approval.
/// Actual output/change coins travel beside this receipt, never as debts or credits.
/// Original limits and gross budgets survive hook mutation; every consumer checks
/// pool, operation and current nonce. No receipt may be dropped or stored.
#[allow(unused_field)]
public struct Completion<phantom Asset, phantom Quote, phantom Operation, Params: copy + drop + store> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    original_params: Params,
    params: Params,
    hook_data: vector<u8>,
    asset_budget: u64,
    quote_budget: u64,
    asset_paid: u64,
    quote_paid: u64,
    tick: I32,
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
/// duplicate slots and unknown permission bits. Hook packages must keep witnesses sealed;
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

/// Intended original caller, original/adjusted inputs, hook data, gross coin budgets,
/// actual core payments, and resulting tick. Output/change coins accompany the receipt.
public fun completion_context<Asset, Quote, Operation, Params: copy + drop + store>(
    _self: &Completion<Asset, Quote, Operation, Params>,
): (address, Params, Params, vector<u8>, u64, u64, u64, u64, I32) {
    abort EInterfaceOnly
}

/// Intended live price, tick, and current LP fee in ppm from either SwapFee variant.
public fun pool_state<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
): (u256, I32, u32) {
    abort EInterfaceOnly
}

// Hook-owned state. Never expose the pool UID to external packages.

/// Intended dynamic-field insertion under (original defining Hook type, typed key).
/// Require Hook registered in at least one callback on this pool; reject NoHook.
/// Reject duplicates. State is pool-owned, with no additional shared object input.
/// Before/after slots using the same witness share a namespace; other hooks cannot access it.
public fun add_hook_state<Asset, Quote, Hook: drop, Name: copy + drop + store, State: store>(
    _self: &mut Pool<Asset, Quote>,
    _hook: &Hook,
    _name: Name,
    _state: State,
) {
    abort EInterfaceOnly
}

/// Intended existence check in this registered hook's namespace; reject NoHook.
public fun has_hook_state<Asset, Quote, Hook: drop, Name: copy + drop + store>(
    _self: &Pool<Asset, Quote>,
    _hook: &Hook,
    _name: Name,
): bool {
    abort EInterfaceOnly
}

/// Intended typed read in this registered hook's namespace; reject NoHook.
/// Require an existing field with matching State type.
public fun hook_state<Asset, Quote, Hook: drop, Name: copy + drop + store, State: store>(
    _self: &Pool<Asset, Quote>,
    _hook: &Hook,
    _name: Name,
): &State {
    abort EInterfaceOnly
}

/// Intended typed mutation in this registered hook's namespace; reject NoHook.
/// Borrow only the hook's stored value, never pool reserves, bindings, or UID.
public fun hook_state_mut<Asset, Quote, Hook: drop, Name: copy + drop + store, State: store>(
    _self: &mut Pool<Asset, Quote>,
    _hook: &Hook,
    _name: Name,
): &mut State {
    abort EInterfaceOnly
}

/// Intended typed removal in this registered hook's namespace; reject NoHook.
/// Return the actual stored value, preserving any resources it owns.
public fun remove_hook_state<Asset, Quote, Hook: drop, Name: copy + drop + store, State: store>(
    _self: &mut Pool<Asset, Quote>,
    _hook: &Hook,
    _name: Name,
): State {
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

/// Intended before-witness, original/adjusted input, actual-payment and reserve checks.
/// Authenticate sender from ctx, advance the nonce without wrapping, and consume coins.
/// The sealed hook attests the gross budgets captured before its coin mutations;
/// bound remaining payments by those budgets and preserve original user limits.
/// Return the actual output/change coins plus a mandatory after-approval receipt.
/// NoHook is accepted only when this before callback is disabled.
/// Bind both parameter sets to the actual owned position, pool, range and tick spacing.
public fun execute_add_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _original_params: LiquidityParams,
    _params: LiquidityParams,
    _hook_data: vector<u8>,
    _asset_budget: u64,
    _quote_budget: u64,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _position: &mut Position<Asset, Quote>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, AddLiquidity, LiquidityParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Validate the actual post-hook coins against ORIGINAL user limits: total gross
/// spend includes both hooks; final receipts include all output deductions.
/// Preserve per-asset reserve conservation. Consume the receipt and return coins.
/// NoHook is accepted only when this after callback is disabled.
public fun finish_add_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, AddLiquidity, LiquidityParams>,
    _asset_coin: Coin<Asset>,
    _quote_coin: Coin<Quote>,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

// Remove liquidity.

/// Intended before-witness, original/adjusted input, actual-payment and reserve checks.
/// Authenticate sender from ctx, advance the nonce without wrapping, and consume coins.
/// The sealed hook attests the gross budgets captured before its coin mutations;
/// bound remaining payments by those budgets and preserve original user limits.
/// Return the actual output/change coins plus a mandatory after-approval receipt.
/// NoHook is accepted only when this before callback is disabled.
/// Bind both parameter sets to the actual owned position, pool, range and tick spacing.
public fun execute_remove_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _original_params: LiquidityParams,
    _params: LiquidityParams,
    _hook_data: vector<u8>,
    _asset_budget: u64,
    _quote_budget: u64,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _position: &mut Position<Asset, Quote>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Validate the actual post-hook coins against ORIGINAL user limits: total gross
/// spend includes both hooks; final receipts include all output deductions.
/// Preserve per-asset reserve conservation. Consume the receipt and return coins.
/// NoHook is accepted only when this after callback is disabled.
public fun finish_remove_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    _asset_coin: Coin<Asset>,
    _quote_coin: Coin<Quote>,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

// Swap.

/// Intended before-witness, original/adjusted input, actual-payment and reserve checks.
/// Authenticate sender from ctx, advance the nonce without wrapping, and consume coins.
/// The sealed hook attests the gross budgets captured before its coin mutations;
/// bound remaining payments by those budgets and preserve original user limits.
/// Return the actual output/change coins plus a mandatory after-approval receipt.
/// NoHook is accepted only when this before callback is disabled.
/// Swap direction and exact-input/output mode stay caller-bound; adjusted amounts and
/// price limits cannot weaken original limits. LP override requires Dynamic and is per-swap.
/// Require zero payment on the output side, so pre-existing coins cannot satisfy
/// minimum receipts. Final net input spend includes fees taken by either hook.
public fun execute_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _original_params: SwapParams,
    _params: SwapParams,
    _hook_data: vector<u8>,
    _asset_budget: u64,
    _quote_budget: u64,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _lp_fee_override_ppm: Option<u32>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, Swap, SwapParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Validate the actual post-hook coins against ORIGINAL user limits: total gross
/// spend includes both hooks; final receipts include all output deductions.
/// Preserve per-asset reserve conservation. Consume the receipt and return coins.
/// NoHook is accepted only when this after callback is disabled.
public fun finish_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Swap, SwapParams>,
    _asset_coin: Coin<Asset>,
    _quote_coin: Coin<Quote>,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

// Donate.

/// Intended before-witness, original/adjusted input, actual-payment and reserve checks.
/// Authenticate sender from ctx, advance the nonce without wrapping, and consume coins.
/// The sealed hook attests the gross budgets captured before its coin mutations;
/// bound remaining payments by those budgets and preserve original user limits.
/// Return the actual output/change coins plus a mandatory after-approval receipt.
/// NoHook is accepted only when this before callback is disabled.
/// Credit actual donated coins to eligible LP fees without minting liquidity.
public fun execute_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _original_params: DonateParams,
    _params: DonateParams,
    _hook_data: vector<u8>,
    _asset_budget: u64,
    _quote_budget: u64,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, Donate, DonateParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Validate the actual post-hook coins against ORIGINAL user limits: total gross
/// spend includes both hooks; final receipts include all output deductions.
/// Preserve per-asset reserve conservation. Consume the receipt and return coins.
/// NoHook is accepted only when this after callback is disabled.
public fun finish_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Donate, DonateParams>,
    _asset_coin: Coin<Asset>,
    _quote_coin: Coin<Quote>,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended before-only swap: require AFTER_SWAP disabled, authenticate BEFORE_SWAP,
/// then execute the same actual-coin swap and original/final bounds as the two-phase path.
/// Require zero payment on the output side, just like execute_swap.
/// No outstanding completion exists; return final coins directly. Reject enabled after hooks.
public fun execute_swap_without_after<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _original_params: SwapParams,
    _params: SwapParams,
    _hook_data: vector<u8>,
    _asset_budget: u64,
    _quote_budget: u64,
    _asset_payment: Coin<Asset>,
    _quote_payment: Coin<Quote>,
    _lp_fee_override_ppm: Option<u32>,
    _ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
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
    i32::I32,
    params::{InitializeParams, LiquidityParams, SwapParams, DonateParams},
    permissions::Permissions,
    swap_fee::SwapFee,
};

use std::type_name::TypeName;
use sui::coin::Coin;
