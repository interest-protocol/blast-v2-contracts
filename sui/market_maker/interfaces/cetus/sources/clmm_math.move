/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::clmm_math;

use integer_mate::i32::I32;

public fun get_liquidity_by_amount(
    lower_index: I32,
    upper_index: I32,
    current_tick_index: I32,
    current_sqrt_price: u128,
    amount: u64,
    is_fixed_a: bool,
): (u128, u64, u64) { abort 0 }
