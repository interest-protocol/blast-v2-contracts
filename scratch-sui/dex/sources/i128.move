/// Interface sketch only. Typed signed integer conversions and checked arithmetic.
/// All function bodies abort; do not publish.
module blast_fun_dex::i128;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

/// Two's-complement signed 128-bit integer, with no fixed-point scaling.
/// All bit patterns are valid; the highest bit is the sign and zero is unique.
public struct I128(u128) has copy, drop, store;

// === Public Functions ===

/// Intended bit-preserving constructor; interpret the input as signed bits.
public fun from_bits(_bits: u128): I128 {
    abort EInterfaceOnly
}

/// Intended raw two's-complement projection; this is not an unsigned amount.
public fun bits(_self: &I128): u128 {
    abort EInterfaceOnly
}

/// Intended nonnegative conversion; reject values above 2^127 - 1.
public fun from_u128(_value: u128): I128 {
    abort EInterfaceOnly
}

/// Intended sign-bit test.
public fun is_negative(_self: &I128): bool {
    abort EInterfaceOnly
}

/// Intended unsigned absolute magnitude; MIN returns 2^127 without overflow.
public fun magnitude(_self: &I128): u128 {
    abort EInterfaceOnly
}

/// Intended signed addition; abort on signed overflow, never wrap or saturate.
public fun add(_self: I128, _rhs: I128): I128 {
    abort EInterfaceOnly
}

/// Intended signed subtraction; abort on signed overflow, never wrap or saturate.
public fun sub(_self: I128, _rhs: I128): I128 {
    abort EInterfaceOnly
}

/// Intended signed negation; abort for MIN, whose positive counterpart cannot fit.
public fun neg(_self: I128): I128 {
    abort EInterfaceOnly
}

/// Intended signed ordering; unsigned carrier ordering must not be used.
public fun lt(_self: &I128, _rhs: &I128): bool {
    abort EInterfaceOnly
}
