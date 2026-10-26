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
/// Every consumer checks pool, operation and current nonce.
/// Consuming this requires after-hook approval, without interpreting its policy or results.
#[allow(unused_field)]
public struct Completion<phantom Asset, phantom Quote, phantom Operation, Params: copy + drop + store> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    params: Params,
    asset_paid: u64,
    quote_paid: u64,
    tick: I32,
}

// Fields are intentionally unread while all interface bodies abort.
/// No abilities. Sealed parameters chosen by the hook for one pool/operation/caller/nonce.
/// Only core constructs this after checking the registered sealed witness.
/// Owns both token balances and parameters chosen by the hook.
/// Core executes this exact payload without interpreting the hook's policy.
#[allow(unused_field)]
public struct Request<phantom Asset, phantom Quote, phantom Operation, Params: copy + drop + store> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    hook_type: TypeName,
    params: Params,
    lp_fee_override_ppm: Option<u32>,
    asset_payment: Balance<Asset>,
    quote_payment: Balance<Quote>,
}

// Fields are intentionally unread while all interface bodies abort.
/// Read-only simulation values, not executable changes or authority to mutate reserves.
/// Amounts are actual projected payments/receipts, never signed accounting deltas.
#[allow(unused_field)]
public struct Simulation<phantom Asset, phantom Quote, phantom Operation> has copy, drop {
    pool_id: ID,
    nonce: u64,
    asset_paid: u64,
    quote_paid: u64,
    asset_returned: u64,
    quote_returned: u64,
    sqrt_price_x96: u256,
    tick: I32,
    liquidity: u128,
    lp_fee_ppm: u32,
    asset_fee_growth_x128: u256,
    quote_fee_growth_x128: u256,
    position_liquidity: Option<u128>,
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

/// Intended caller, executed inputs, actual core payments and resulting tick.
/// Output/change coins accompany this immutable receipt and remain hook-controlled.
public fun completion_context<Asset, Quote, Operation, Params: copy + drop + store>(
    _self: &Completion<Asset, Quote, Operation, Params>,
): (address, Params, u64, u64, I32) {
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

// Read-only operation simulation.

/// Intended snapshot identity and economic nonce; simulation does not reserve the pool.
public fun simulation_context<Asset, Quote, Operation>(
    _self: &Simulation<Asset, Quote, Operation>,
): (ID, u64) {
    abort EInterfaceOnly
}

/// Intended projected payments and returned coin amounts in asset/quote order.
public fun simulation_amounts<Asset, Quote, Operation>(
    _self: &Simulation<Asset, Quote, Operation>,
): (u64, u64, u64, u64) {
    abort EInterfaceOnly
}

/// Intended post-operation price, tick, active liquidity, LP fee and fee growth.
/// The optional position liquidity is present only for liquidity operations.
public fun simulation_pool_state<Asset, Quote, Operation>(
    _self: &Simulation<Asset, Quote, Operation>,
): (u256, I32, u128, u32, u256, u256, Option<u128>) {
    abort EInterfaceOnly
}

/// Intended pure swap simulation using the same pricing, tick and fee math as execution.
/// Borrow pool state immutably. Do not move coins, write pool/hook state, or issue approval.
public fun simulate_swap<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _params: SwapParams,
    _lp_fee_override_ppm: Option<u32>,
): Simulation<Asset, Quote, Swap> {
    abort EInterfaceOnly
}

/// Intended read-only projection of pool, position and coin effects when adding liquidity.
public fun simulate_add_liquidity<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _params: LiquidityParams,
): Simulation<Asset, Quote, AddLiquidity> {
    abort EInterfaceOnly
}

/// Intended read-only projection of removal or zero-liquidity fee collection.
public fun simulate_remove_liquidity<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _params: LiquidityParams,
): Simulation<Asset, Quote, RemoveLiquidity> {
    abort EInterfaceOnly
}

/// Intended read-only projection of actual donated amounts and LP fee growth.
public fun simulate_donate<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _params: DonateParams,
): Simulation<Asset, Quote, Donate> {
    abort EInterfaceOnly
}

// Wrap hook-approved parameters and balances.

/// Intended wrapped pool, nonce, caller, parameters, fee override and payment amounts.
public fun request_context<Asset, Quote, Operation, Params: copy + drop + store>(
    _self: &Request<Asset, Quote, Operation, Params>,
): (ID, u64, address, Params, Option<u32>, u64, u64) {
    abort EInterfaceOnly
}

/// Intended sealed request constructor called by the hook after its policy completes.
/// Require this operation's registered before witness; NoHook is disabled-only.
/// Bind pool ID, nonce and sender; move chosen parameters and balances into the request.
/// Core validates its own execution requirements, never interprets the hook's policy.
public fun prepare_add_liquidity<Asset, Quote, Hook: drop>(
    _self: &Pool<Asset, Quote>,
    _hook: Hook,
    _params: LiquidityParams,
    _asset_payment: Balance<Asset>,
    _quote_payment: Balance<Quote>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, AddLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended sealed request constructor called by the hook after its policy completes.
/// Require this operation's registered before witness; NoHook is disabled-only.
/// Bind pool ID, nonce and sender; move chosen parameters and balances into the request.
/// Core validates its own execution requirements, never interprets the hook's policy.
public fun prepare_remove_liquidity<Asset, Quote, Hook: drop>(
    _self: &Pool<Asset, Quote>,
    _hook: Hook,
    _params: LiquidityParams,
    _asset_payment: Balance<Asset>,
    _quote_payment: Balance<Quote>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended sealed request constructor called by the hook after its policy completes.
/// Require this operation's registered before witness; NoHook is disabled-only.
/// Bind pool ID, nonce and sender; move chosen parameters and balances into the request.
/// Core validates its own execution requirements, never interprets the hook's policy.
public fun prepare_swap<Asset, Quote, Hook: drop>(
    _self: &Pool<Asset, Quote>,
    _hook: Hook,
    _params: SwapParams,
    _asset_payment: Balance<Asset>,
    _quote_payment: Balance<Quote>,
    _lp_fee_override_ppm: Option<u32>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Swap, SwapParams> {
    abort EInterfaceOnly
}

/// Intended sealed request constructor called by the hook after its policy completes.
/// Require this operation's registered before witness; NoHook is disabled-only.
/// Bind pool ID, nonce and sender; move chosen parameters and balances into the request.
/// Core validates its own execution requirements, never interprets the hook's policy.
public fun prepare_donate<Asset, Quote, Hook: drop>(
    _self: &Pool<Asset, Quote>,
    _hook: Hook,
    _params: DonateParams,
    _asset_payment: Balance<Asset>,
    _quote_payment: Balance<Quote>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Donate, DonateParams> {
    abort EInterfaceOnly
}

// Add liquidity.

/// Intended consumption of a sealed request for this pool, operation, caller and current nonce.
/// Advance the economic nonce without wrapping. Recompute against live state;
/// execute the wrapped parameters, validate actual payment, preserve reserves and LP entitlement.
/// No separate parameter or payment input can replace the wrapped payload; policy stays opaque.
/// Return actual coins plus a mandatory after-hook completion.
/// Validate the owned position ID, pool, range, spacing and liquidity authority.
public fun execute_add_liquidity<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _request: Request<Asset, Quote, AddLiquidity, LiquidityParams>,
    _position: &mut Position<Asset, Quote>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, AddLiquidity, LiquidityParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Consume the completion and return the coins supplied after hook policy runs.
/// NoHook is disabled-only. Do not enforce hook policy, coin identity or return amounts;
/// any user-level checks on post-hook results belong to the caller or bundled wrapper.
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

/// Intended consumption of a sealed request for this pool, operation, caller and current nonce.
/// Advance the economic nonce without wrapping. Recompute against live state;
/// execute the wrapped parameters, validate actual payment, preserve reserves and LP entitlement.
/// No separate parameter or payment input can replace the wrapped payload; policy stays opaque.
/// Return actual coins plus a mandatory after-hook completion.
/// Validate the owned position ID, pool, range, spacing and liquidity authority.
public fun execute_remove_liquidity<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _request: Request<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    _position: &mut Position<Asset, Quote>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, RemoveLiquidity, LiquidityParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Consume the completion and return the coins supplied after hook policy runs.
/// NoHook is disabled-only. Do not enforce hook policy, coin identity or return amounts;
/// any user-level checks on post-hook results belong to the caller or bundled wrapper.
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

/// Intended consumption of a sealed request for this pool, operation, caller and current nonce.
/// Advance the economic nonce without wrapping. Recompute against live state;
/// execute the wrapped parameters, validate actual payment, preserve reserves and LP entitlement.
/// No separate parameter or payment input can replace the wrapped payload; policy stays opaque.
/// Return actual coins plus a mandatory after-hook completion.
/// Require zero output-side balance. LP override requires Dynamic and an enabled before hook.
public fun execute_swap<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _request: Request<Asset, Quote, Swap, SwapParams>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, Swap, SwapParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Consume the completion and return the coins supplied after hook policy runs.
/// NoHook is disabled-only. Do not enforce hook policy, coin identity or return amounts;
/// any user-level checks on post-hook results belong to the caller or bundled wrapper.
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

/// Intended consumption of a sealed request for this pool, operation, caller and current nonce.
/// Advance the economic nonce without wrapping. Recompute against live state;
/// execute the wrapped parameters, validate actual payment, preserve reserves and LP entitlement.
/// No separate parameter or payment input can replace the wrapped payload; policy stays opaque.
/// Return actual coins plus a mandatory after-hook completion.
/// Credit actual donated coins to eligible LP fees without minting liquidity.
public fun execute_donate<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _request: Request<Asset, Quote, Donate, DonateParams>,
    _ctx: &mut TxContext,
): (Completion<Asset, Quote, Donate, DonateParams>, Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended after-witness, pool, operation and current-nonce checks.
/// Consume the completion and return the coins supplied after hook policy runs.
/// NoHook is disabled-only. Do not enforce hook policy, coin identity or return amounts;
/// any user-level checks on post-hook results belong to the caller or bundled wrapper.
public fun finish_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Donate, DonateParams>,
    _asset_coin: Coin<Asset>,
    _quote_coin: Coin<Quote>,
): (Coin<Asset>, Coin<Quote>) {
    abort EInterfaceOnly
}

/// Intended before-only swap: consume the sealed request with the same execution checks.
/// Reject enabled after-swap callbacks. Return actual coins without a completion.
public fun execute_swap_without_after<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _request: Request<Asset, Quote, Swap, SwapParams>,
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
use sui::{balance::Balance, coin::Coin};
