/// Interface sketch only. Validated operation inputs; pool enforces live context and economic bounds.
/// All function bodies abort; do not publish.
module blast_fun_dex::params;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

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
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
    asset_bound: u64,
    quote_bound: u64,
}

// Fields are intentionally unread while all interface bodies abort.
/// Both directions and exact-input/output swaps. Amounts use atomic coin units.
/// Final bounds apply to actual returned coins after BOTH hooks, including hook fees.
/// Exact-input amount is the caller gross budget before hooks; core trades the
/// remaining approved input. Exact-output amount is the final caller output target.
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

// === Public Functions ===

/// Intended swap constructor; core must independently recheck bounds at execution.
public fun new_swap(
    _asset_to_quote: bool,
    _exact_input: bool,
    _amount: u64,
    _sqrt_price_limit_x96: u256,
    _minimum_output: u64,
    _maximum_input: u64,
): SwapParams {
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
): (ID, I32, I32, u128, u64, u64) {
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

/// Intended ordered int24 tick bounds; pool additionally validates its tick range and spacing.
public fun new_liquidity(
    _position_id: ID,
    _tick_lower: I32,
    _tick_upper: I32,
    _liquidity: u128,
    _asset_bound: u64,
    _quote_bound: u64,
): LiquidityParams {
    abort EInterfaceOnly
}

/// Intended donation parameters in atomic token units.
public fun new_donate(_asset: u64, _quote: u64): DonateParams {
    abort EInterfaceOnly
}

// === Package Functions ===

/// Intended initialization parameters; validate the uint160 price carrier.
public(package) fun new_initialize(_sqrt_price_x96: u256): InitializeParams {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::i32::I32;
