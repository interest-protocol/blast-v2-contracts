/// Pinned Pyth price ABI port.
module pyth::price {

use pyth::i64::I64;

struct Price has copy, drop, store {
    price: I64,
    conf: u64,
    expo: I64,
    timestamp: u64,
}

public fun get_price(_self: &Price): I64 { abort 404 }

public fun get_conf(_self: &Price): u64 { abort 404 }

public fun get_timestamp(_self: &Price): u64 { abort 404 }

public fun get_expo(_self: &Price): I64 { abort 404 }
}
