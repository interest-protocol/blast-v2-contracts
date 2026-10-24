/// Interface sketch only. Every body aborts; this package must not be published.
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
    hook_type: TypeName,
    permissions: Permissions,
    initialized: bool,
    nonce: u64,
    in_flight: bool,
    dynamic_fee: bool,
    lp_fee_ppm: u32,
}

// Fields are intentionally unread while all interface bodies abort.
/// Caller-owned liquidity authority; construction binds pool, range, and salt.
#[allow(unused_field)]
public struct Position<phantom Asset, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    tick_lower: SignedAmount,
    tick_upper: SignedAmount,
    salt: u256,
    liquidity: u128,
}

// Fields are intentionally unread while all interface bodies abort.
/// Ten lifecycle permissions and four delta permissions, following v4 Hooks.sol.
#[allow(unused_field)]
public struct Permissions has copy, drop, store {
    before_initialize: bool,
    after_initialize: bool,
    before_add_liquidity: bool,
    after_add_liquidity: bool,
    before_remove_liquidity: bool,
    after_remove_liquidity: bool,
    before_swap: bool,
    after_swap: bool,
    before_donate: bool,
    after_donate: bool,
    before_swap_return_delta: bool,
    after_swap_return_delta: bool,
    after_add_liquidity_return_delta: bool,
    after_remove_liquidity_return_delta: bool,
}

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
    salt: u256,
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
public struct Initialize()
public struct AddLiquidity()
public struct RemoveLiquidity()
public struct Swap()
public struct Donate()

// Fields are intentionally unread while all interface bodies abort.
/// No abilities. Intended immutable context, sender from TxContext, and pool lock.
/// Params plus operation tag distinguish all five operations without erasing types.
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
/// Initialization exposes tick; liquidity exposes caller delta and fees accrued.
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
    tick: SignedAmount,
}

// Fields are intentionally unread while all interface bodies abort.
/// No abilities. Both ledgers must be reconciled exactly once before unlock.
/// Hook type and caller must match the original operation, even at zero delta.
#[allow(unused_field)]
public struct Settlement<phantom Asset, phantom Quote> {
    pool_id: ID,
    nonce: u64,
    sender: address,
    caller_delta: BalanceDelta,
    hook_delta: BalanceDelta,
    caller_settled: bool,
    hook_settled: bool,
}

// === Public Functions ===

// Construction and callback context.

/// Intended sealed-witness binding. Reject invalid permission combinations and fees.
public fun new<Asset, Quote, Hook: drop>(
    _hook: Hook,
    _permissions: Permissions,
    _tick_spacing: u32,
    _dynamic_fee: bool,
    _lp_fee_ppm: u32,
    _ctx: &mut TxContext,
): Pool<Asset, Quote> {
    abort EInterfaceOnly
}

/// Intended defining-module sink; require initialized state and no pending operation.
public fun share<Asset, Quote>(
    _self: Pool<Asset, Quote>,
) {
    abort EInterfaceOnly
}

/// Intended position constructor, validating initialized pool, range, and tick spacing.
public fun new_position<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _tick_lower: SignedAmount,
    _tick_upper: SignedAmount,
    _salt: u256,
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

/// Intended permission constructor; delta permission requires the matching callback.
public fun new_permissions(
    _before_initialize: bool,
    _after_initialize: bool,
    _before_add_liquidity: bool,
    _after_add_liquidity: bool,
    _before_remove_liquidity: bool,
    _after_remove_liquidity: bool,
    _before_swap: bool,
    _after_swap: bool,
    _before_donate: bool,
    _after_donate: bool,
    _before_swap_return_delta: bool,
    _after_swap_return_delta: bool,
    _after_add_liquidity_return_delta: bool,
    _after_remove_liquidity_return_delta: bool,
): Permissions {
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

/// Intended position, range, salt, liquidity, and payment/receipt bounds.
public fun liquidity_params(
    _self: &LiquidityParams,
): (ID, SignedAmount, SignedAmount, u256, u128, u64, u64) {
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

// Initialize.

/// Intended lifecycle checks, pool lock, nonce advance, and authenticated context.
public fun begin_initialize<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _sqrt_price_x96: u256,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Initialize, InitializeParams> {
    abort EInterfaceOnly
}

/// Intended witness, phase, pool/nonce, and economic checks, then core execution.
public fun execute_initialize<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, Initialize, InitializeParams>,
): Completion<Asset, Quote, Initialize, InitializeParams> {
    abort EInterfaceOnly
}

/// Intended after-hook authorization; mark initialized and unlock.
public fun finish_initialize<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Initialize, InitializeParams>,
) {
    abort EInterfaceOnly
}

// Add liquidity.

/// Intended lifecycle checks, pool lock, nonce advance, and authenticated context.
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

/// Intended witness, phase, pool/nonce, and economic checks, then core execution.
public fun execute_add_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, AddLiquidity, LiquidityParams>,
    _position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, AddLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended after-hook authorization; validate permitted deltas and create settlement.
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

/// Intended lifecycle checks, pool lock, nonce advance, and authenticated context.
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

/// Intended witness, phase, pool/nonce, and economic checks, then core execution.
public fun execute_remove_liquidity<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, RemoveLiquidity, LiquidityParams>,
    _position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, RemoveLiquidity, LiquidityParams> {
    abort EInterfaceOnly
}

/// Intended after-hook authorization; validate permitted deltas and create settlement.
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

/// Intended lifecycle checks, pool lock, nonce advance, and authenticated context.
public fun begin_swap<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _params: SwapParams,
    _hook_data: vector<u8>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Swap, SwapParams> {
    abort EInterfaceOnly
}

/// Intended witness, phase, and pool/nonce checks, then core execution.
/// Swap override only for dynamic pools; before delta cannot change exact-in/out mode.
public fun execute_swap<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, Swap, SwapParams>,
    _before_delta: BeforeSwapDelta,
    _lp_fee_override_ppm: Option<u32>,
): Completion<Asset, Quote, Swap, SwapParams> {
    abort EInterfaceOnly
}

/// Intended after-hook authorization; validate permitted deltas and create settlement.
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

/// Intended lifecycle checks, pool lock, nonce advance, and authenticated context.
public fun begin_donate<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _asset_amount: u64,
    _quote_amount: u64,
    _hook_data: vector<u8>,
    _ctx: &mut TxContext,
): Request<Asset, Quote, Donate, DonateParams> {
    abort EInterfaceOnly
}

/// Intended witness, phase, pool/nonce, and economic checks, then core execution.
public fun execute_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _request: Request<Asset, Quote, Donate, DonateParams>,
): Completion<Asset, Quote, Donate, DonateParams> {
    abort EInterfaceOnly
}

/// Intended after-hook authorization; validate permitted deltas and create settlement.
/// Donation amounts must match the caller debt, with no minted liquidity.
public fun finish_donate<Asset, Quote, Hook: drop>(
    _self: &mut Pool<Asset, Quote>,
    _hook: Hook,
    _completion: Completion<Asset, Quote, Donate, DonateParams>,
): Settlement<Asset, Quote> {
    abort EInterfaceOnly
}

// Settlement and dynamic fees.

/// Intended settlement projection for hook funding and payout authorization.
public fun settlement_context<Asset, Quote>(
    _self: &Settlement<Asset, Quote>,
): (address, BalanceDelta, BalanceDelta) {
    abort EInterfaceOnly
}

/// Intended exact-once original-caller settlement. Return payouts and payment change.
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

/// Intended exact-once registered-hook settlement. Return payouts and payment change.
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

/// Intended final sink: require both ledgers paid and per-asset conservation; unlock.
public fun finish_settlement<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _settlement: Settlement<Asset, Quote>,
) {
    abort EInterfaceOnly
}

/// Intended registered-hook-only cached fee update for dynamic pools; enforce <= 1,000,000 ppm.
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
