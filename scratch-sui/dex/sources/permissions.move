/// Interface sketch only. Hook bitmap constants and validation.
/// Function bodies abort; flag macros are constants. Do not publish.
module blast_fun_dex::permissions;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

// Fields are intentionally unread while all interface bodies abort.
/// A u16 bitmap: ten lifecycle bits and four delta bits, following v4 Hooks.sol.
/// Only the low 14 bits are valid. Construction must validate callback dependencies.
#[allow(unused_field)]
public struct Permissions(u16) has copy, drop, store;

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

/// Intended bitmap validation: reject unknown bits and delta bits without callbacks.
public fun new(
    _bitmap: u16,
): Permissions {
    abort EInterfaceOnly
}

/// Intended bitmap projection for hook policy and transaction composition.
public fun bits(
    _self: &Permissions,
): u16 {
    abort EInterfaceOnly
}

/// Intended all-bits check: (stored bitmap & mask) == mask.
public fun has(
    _self: &Permissions,
    _mask: u16,
): bool {
    abort EInterfaceOnly
}
