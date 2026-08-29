/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::fee;

public struct Fee<phantom FeeType> has key, store { id: UID }

public fun get_fee<FeeType>(_self: &Fee<FeeType>): u32 { abort 0 }
public fun get_tick_spacing<FeeType>(_self: &Fee<FeeType>): u32 { abort 0 }
