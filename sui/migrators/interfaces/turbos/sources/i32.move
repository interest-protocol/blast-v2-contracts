/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::i32;

public struct I32 has copy, drop, store {}

public fun abs_u32(_value: I32): u32 { abort 0 }
public fun is_neg(_value: I32): bool { abort 0 }
