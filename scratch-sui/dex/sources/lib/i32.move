// Package error macros keep aborts in the module that checks the invariant.
#[allow(lint(abort_without_constant))]
/// Two's-complement signed 32-bit integer for pool ticks.
/// Holds only the conversions and ordering that tick validation needs.
module blast_fun_dex::i32;

// === Constants ===

const SIGN_BIT: u32 = 0x8000_0000;
const TWO_POW_32: u64 = 0x1_0000_0000;

// === Public Types ===

/// A signed 32-bit value stored as its two's-complement bits.
/// Every bit pattern is valid; the highest bit is the sign and zero is unique.
public struct I32(u32) has copy, drop, store;

// === Public Functions ===

/// Nonnegative value. Aborts above 2^31 - 1.
public fun from_u32(value: u32): I32 {
    assert!(value < SIGN_BIT, blast_fun_dex::errors::magnitude_too_large!());

    I32(value)
}

/// Value with a negative sign and the given magnitude. Aborts above 2^31.
/// A zero magnitude returns zero.
public fun neg_from_u32(magnitude: u32): I32 {
    assert!(magnitude <= SIGN_BIT, blast_fun_dex::errors::magnitude_too_large!());

    I32(twos_complement(magnitude))
}

public fun is_negative(self: &I32): bool {
    (self.0 & SIGN_BIT) != 0
}

/// Absolute value. The minimum value returns 2^31 without overflow.
public fun magnitude(self: &I32): u32 {
    if (!self.is_negative()) return self.0;

    twos_complement(self.0)
}

/// Signed less-than.
public fun lt(self: &I32, other: &I32): bool {
    // Flipping the sign bit maps signed order onto unsigned order.
    (self.0 ^ SIGN_BIT) < (other.0 ^ SIGN_BIT)
}

// === Private Functions ===

/// 2^32 - value modulo 2^32, so zero maps to zero.
fun twos_complement(value: u32): u32 {
    if (value == 0) return 0;

    (TWO_POW_32 - (value as u64)) as u32
}
