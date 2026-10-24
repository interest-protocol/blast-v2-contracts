/// Interface sketch only. Token-order and swap-order signed accounting values.
/// All function bodies abort; do not publish.
module blast_fun_dex::delta;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

// Fields are intentionally unread while all interface bodies abort.
/// Token-order deltas. Positive: recipient is owed; negative: recipient pays.
/// Caller and hook deltas have separate ledgers with this same sign convention.
#[allow(unused_field)]
public struct BalanceDelta has copy, drop, store { asset: I128, quote: I128 }

// Fields are intentionally unread while all interface bodies abort.
/// Before-swap hook delta, in specified/unspecified currency order.
#[allow(unused_field)]
public struct BeforeSwapDelta has copy, drop, store {
    specified: I128,
    unspecified: I128,
}

// === Public Functions ===

/// Intended token-order delta constructor; values must fit int128.
public fun new(
    _asset: I128,
    _quote: I128,
): BalanceDelta {
    abort EInterfaceOnly
}

/// Intended delta projection for hook policy.
public fun amounts(
    _self: &BalanceDelta,
): (I128, I128) {
    abort EInterfaceOnly
}

/// Intended before-swap delta constructor, with both values bounded to int128.
public fun new_before_swap(
    _specified: I128,
    _unspecified: I128,
): BeforeSwapDelta {
    abort EInterfaceOnly
}

/// Intended specified/unspecified delta projection for core and hook policy.
public fun before_swap_amounts(_self: &BeforeSwapDelta): (I128, I128) {
    abort EInterfaceOnly
}

// === Imports ===

use blast_fun_dex::i128::I128;
