/// Interface sketch only. Operational bodies abort; flag macros are constants.
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
    dynamic_fee: bool,
    lp_fee_ppm: u32,
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
    tick: SignedAmount,
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
    tick_lower: SignedAmount,
    tick_upper: SignedAmount,
    liquidity: u128,
}

// Fields are intentionally unread while all interface bodies abort.
/// A u16 bitmap: ten lifecycle bits and four delta bits, following v4 Hooks.sol.
/// Only the low 14 bits are valid. Construction must validate callback dependencies.
#[allow(unused_field)]
public struct Permissions(u16) has copy, drop, store;

// Fields are intentionally unread while all interface bodies abort.
/// Sign/magnitude interface representation; implementation must canonicalize zero
/// and check the destination width (ticks int24, accounting deltas int128).
#[allow(unused_field)]
public struct SignedAmount has copy, drop, store { negative: bool, magnitude: u128 }

// Fields are intentionally unread while all interface bodies abort.
/// Token-order deltas. Positive: recipient is owed; negative: recipient pays.
/// Caller and hook deltas have separate ledgers with this same sign convention.
#[allow(unused_field)]
public struct BalanceDelta has copy, drop, store { asset: SignedAmount, quote: SignedAmount }

// Fields are intentionally unread while all interface bodies abort.
/// Before-swap hook delta, in specified/unspecified currency order.
#[allow(unused_field)]
public struct BeforeSwapDelta has copy, drop, store {
    specified: SignedAmount,
    unspecified: SignedAmount,
}

// Fields are intentionally unread while all interface bodies abort.
/// Initialization price uses Q64.96; implementation must enforce uint160 bounds.
#[allow(unused_field)]
public struct InitializeParams has copy, drop, store { sqrt_price_x96: u256 }

// Fields are intentionally unread while all interface bodies abort.
/// A range update. Zero liquidity on the remove path collects accrued fees.
/// Bounds are maximum payments when adding, minimum receipts when removing.
#[allow(unused_field)]
public struct LiquidityParams has copy, drop, store {
    position_id: ID,
    tick_lower: SignedAmount,
    tick_upper: SignedAmount,
    liquidity: u128,
    asset_bound: u64,
    quote_bound: u64,
}

// Fields are intentionally unread while all interface bodies abort.
/// Both directions and exact-input/output swaps. Amounts use atomic coin units.
/// Final bounds apply after all hook deltas and fees, including partial fills.
#[allow(unused_field)]
public struct SwapParams has copy, drop, store {
    asset_to_quote: bool,
    exact_input: bool,
    amount: u64,
    sqrt_price_limit_x96: u256,
    minimum_output: u64,
    maximum_input: u64,
}

// Fields are intentionally unread while all interface bodies abort.
/// Donation is credited to eligible LP fee growth, without minting liquidity.
#[allow(unused_field)]
public struct DonateParams has copy, drop, store { asset: u64, quote: u64 }

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
    tick: SignedAmount,
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

// Permission flags. Public macros expose named constants across package boundaries.

/// Enables the before-initialize callback.
macro public fun before_initialize_flag(): u16 { 0x2000 }
/// Enables the after-initialize callback.
macro public fun after_initialize_flag(): u16 { 0x1000 }
/// Enables the before-add-liquidity callback.
macro public fun before_add_liquidity_flag(): u16 { 0x0800 }
/// Enables the after-add-liquidity callback.
macro public fun after_add_liquidity_flag(): u16 { 0x0400 }
/// Enables the before-remove-liquidity callback.
macro public fun before_remove_liquidity_flag(): u16 { 0x0200 }
/// Enables the after-remove-liquidity callback.
macro public fun after_remove_liquidity_flag(): u16 { 0x0100 }
/// Enables the before-swap callback.
macro public fun before_swap_flag(): u16 { 0x0080 }
/// Enables the after-swap callback.
macro public fun after_swap_flag(): u16 { 0x0040 }
/// Enables the before-donate callback.
macro public fun before_donate_flag(): u16 { 0x0020 }
/// Enables the after-donate callback.
macro public fun after_donate_flag(): u16 { 0x0010 }
/// Allows a specified/unspecified delta from the before-swap callback.
macro public fun before_swap_returns_delta_flag(): u16 { 0x0008 }
/// Allows an unspecified delta from the after-swap callback.
macro public fun after_swap_returns_delta_flag(): u16 { 0x0004 }
/// Allows a token-pair delta from the after-add-liquidity callback.
macro public fun after_add_liquidity_returns_delta_flag(): u16 { 0x0002 }
/// Allows a token-pair delta from the after-remove-liquidity callback.
macro public fun after_remove_liquidity_returns_delta_flag(): u16 { 0x0001 }
/// All ten callbacks and four delta permissions, with both reserved bits clear.
macro public fun all_hook_flags(): u16 { 0x3fff }

// Construction and callback context.

/// Intended construction of a no-ability initializer. Validate pair, fee, and range units.
public fun new<Asset, Quote>(
    _tick_spacing: u32,
    _dynamic_fee: bool,
    _lp_fee_ppm: u32,
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

/// Intended position constructor, validating initialized pool, range, and tick spacing.
public fun new_position<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _tick_lower: SignedAmount,
    _tick_upper: SignedAmount,
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

/// Intended bitmap validation: reject unknown bits and delta bits without callbacks.
public fun new_permissions(
    _bitmap: u16,
): Permissions {
    abort EInterfaceOnly
}

/// Intended bitmap projection for hook policy and transaction composition.
public fun permission_bits(
    _self: &Permissions,
): u16 {
    abort EInterfaceOnly
}

/// Intended all-bits check: (stored bitmap & mask) == mask.
public fun has_permissions(
    _self: &Permissions,
    _mask: u16,
): bool {
    abort EInterfaceOnly
}

/// Intended canonical signed-value constructor; sign is false for zero.
public fun new_signed_amount(
    _negative: bool,
    _magnitude: u128,
): SignedAmount {
    abort EInterfaceOnly
}

/// Intended signed-value projection for hook policy.
public fun signed_amount(
    _self: &SignedAmount,
): (bool, u128) {
    abort EInterfaceOnly
}

/// Intended token-order delta constructor; values must fit int128.
public fun new_balance_delta(
    _asset: SignedAmount,
    _quote: SignedAmount,
): BalanceDelta {
    abort EInterfaceOnly
}

/// Intended delta projection for hook policy.
public fun balance_delta(
    _self: &BalanceDelta,
): (SignedAmount, SignedAmount) {
    abort EInterfaceOnly
}

/// Intended before-swap delta constructor, with both values bounded to int128.
public fun new_before_swap_delta(
    _specified: SignedAmount,
    _unspecified: SignedAmount,
): BeforeSwapDelta {
    abort EInterfaceOnly
}

/// Intended swap constructor; core must independently recheck bounds at execution.
public fun new_swap_params(
    _asset_to_quote: bool,
    _exact_input: bool,
    _amount: u64,
    _sqrt_price_limit_x96: u256,
    _minimum_output: u64,
    _maximum_input: u64,
): SwapParams {
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
): (address, Params, vector<u8>, BalanceDelta, BalanceDelta, SignedAmount) {
    abort EInterfaceOnly
}

/// Intended initial-price projection for hook policy.
public fun initialize_price_x96(
    _self: &InitializeParams,
): u256 {
    abort EInterfaceOnly
}

/// Intended position ID, range, liquidity, and payment/receipt bounds.
public fun liquidity_params(
    _self: &LiquidityParams,
): (ID, SignedAmount, SignedAmount, u128, u64, u64) {
    abort EInterfaceOnly
}

/// Intended direction, exact-input flag, amount, price limit, and final bounds.
public fun swap_params(
    _self: &SwapParams,
): (bool, bool, u64, u256, u64, u64) {
    abort EInterfaceOnly
}

/// Intended donated atomic amounts, in token order.
public fun donation_amounts(
    _self: &DonateParams,
): (u64, u64) {
    abort EInterfaceOnly
}

/// Intended live price, tick, and cached LP fee, available to hook policy.
public fun pool_state<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
): (u256, SignedAmount, u32) {
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
): (ID, address, InitializeParams, SignedAmount) {
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
/// requires a dynamic pool; before delta cannot change exact-in/out mode.
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
    _unspecified_hook_delta: SignedAmount,
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

/// Intended before-swap-hook-only cached fee update on dynamic pools; enforce <= 1,000,000 ppm.
public fun update_dynamic_lp_fee<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _lp_fee_ppm: u32,
) {
    abort EInterfaceOnly
}

// === Imports ===

use std::type_name::TypeName;
use sui::coin::Coin;
