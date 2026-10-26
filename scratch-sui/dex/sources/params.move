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
/// Swap direction and input budget come from the request's typed payment balance.
/// The price limit can stop execution early; unspent payment returns as change.
/// Hooks and callers own full-fill requirements and final coin-amount checks.
#[allow(unused_field)]
public struct SwapParams(u256) has copy, drop, store;

// Fields are intentionally unread while all interface bodies abort.
/// Donation is credited to eligible LP fee growth, without minting liquidity.
#[allow(unused_field)]
public struct DonateParams has copy, drop, store { asset: u64, quote: u64 }

// === Public Functions ===

/// Intended swap constructor; core must recheck price limits and actual funding at execution.
public fun new_swap(
    _sqrt_price_limit_x96: u256,
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

/// Intended sqrt price limit; direction and amount belong to the typed payment.
public fun swap_price_limit_x96(
    _self: &SwapParams,
): u256 {
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
