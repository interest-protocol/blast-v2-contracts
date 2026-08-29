/// Minimal Cetus mainnet revision-14 interface. Link stubs must not execute.
module cetus_clmm::config;

public struct GlobalConfig has key, store { id: UID }

public fun get_fee_rate(tick_spacing: u32, config: &GlobalConfig): u64 { abort 0 }
