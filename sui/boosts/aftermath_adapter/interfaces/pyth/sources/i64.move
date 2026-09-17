/// Pinned Pyth signed-magnitude ABI port.
module pyth::i64 {

struct I64 has copy, drop, store {
    negative: bool,
    magnitude: u64,
}

public fun get_is_negative(_self: &I64): bool { abort 404 }

public fun get_magnitude_if_positive(_self: &I64): u64 { abort 404 }

public fun get_magnitude_if_negative(_self: &I64): u64 { abort 404 }
}
