// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Q96 tick prices on the Uniswap v4 grid. Internal indexes offset signed
/// ticks by MAX_TICK so ordered lookup uses unsigned integers.
module blast_fun_dex::tick_math;

// === Constants ===

const Q128: u256 = 1 << 128;
// Round 2^128 / sqrt(1.0001^(2^i)) to nearest for each bit i.
const FACTORS: vector<u256> = vector[
    0xfffcb933bd6fad37aa2d162d1a594001,
    0xfff97272373d413259a46990580e213a,
    0xfff2e50f5f656932ef12357cf3c7fdcc,
    0xffe5caca7e10e4e61c3624eaa0941cd0,
    0xffcb9843d60f6159c9db58835c926644,
    0xff973b41fa98c081472e6896dfb254c0,
    0xff2ea16466c96a3843ec78b326b52861,
    0xfe5dee046a99a2a811c461f1969c3053,
    0xfcbe86c7900a88aedcffc83b479aa3a4,
    0xf987a7253ac413176f2b074cf7815e54,
    0xf3392b0822b70005940c7a398e4b70f3,
    0xe7159475a2c29b7443b29c7fa6e889d9,
    0xd097f3bdfd2022b8845ad8f792aa5825,
    0xa9f746462d870fdf8a65dc1f90e061e5,
    0x70d869a156d2a1b890bb3df62baf32f7,
    0x31be135f97d08fd981231505542fcfa6,
    0x09aa508b5b7a84e1c677de54f3e99bc9,
    0x005d6af8dedb81196699c329225ee604,
    0x00002216e584f5fa1ea926041bedfe98,
    0x00000000048a170391f7dc42444e8fa2,
];

// === Package Functions ===

public(package) fun index(tick: I32): u32 {
    let offset = constants::max_tick!();
    if (tick.is_negative()) offset - tick.magnitude() else offset + tick.magnitude()
}

/// Matches the grid's Q96 rounding at both protocol price bounds.
public(package) fun sqrt_price_x96(index: u32): u256 {
    let offset = constants::max_tick!();
    let mut magnitude = index.diff(offset);
    let mut ratio = Q128;
    let factors = FACTORS;
    let mut bit = 0;
    while (magnitude > 0) {
        if (magnitude & 1 != 0) ratio = (ratio * factors[bit]) >> 128;
        magnitude = magnitude >> 1;
        bit = bit + 1;
    };
    if (index > offset) ratio = u256::max_value!() / ratio;
    ratio.div_ceil(1 << 32)
}

/// Finds the highest tick price at or below the spot. Swaps already know the
/// containing initialized range and can restrict the search to that range.
public(package) fun floor_index(price_x96: u256, mut lower: u32, mut upper: u32): u32 {
    while (lower < upper) {
        let middle = lower + (upper - lower).div_ceil(2);
        if (sqrt_price_x96(middle) <= price_x96) lower = middle
        else upper = middle - 1;
    };
    lower
}

// === Imports ===

use blast_fun_dex::{constants, i32::I32};
use std::u256;
