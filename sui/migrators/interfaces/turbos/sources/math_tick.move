/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::math_tick;

use turbos_clmm::i32::I32;

public fun get_min_tick(_tick_spacing: u32): I32 { abort 0 }
public fun get_max_tick(_tick_spacing: u32): I32 { abort 0 }
