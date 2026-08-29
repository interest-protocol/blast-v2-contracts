/// Minimal Full Sail mainnet revision-4 interface. Link stubs must not execute.
module clmm_pool::config;

public struct GlobalConfig has key, store { id: UID }

public fun get_fee_rate(_tick_spacing: u32, _config: &GlobalConfig): u64 { abort 0 }
