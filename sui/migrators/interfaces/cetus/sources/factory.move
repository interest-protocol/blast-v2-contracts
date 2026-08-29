/// Minimal Cetus mainnet revision-14 interface. Link stubs must not execute.
module cetus_clmm::factory;

public struct Pools has key, store { id: UID }

public fun new_pool_key<CoinTypeA, CoinTypeB>(tick_spacing: u32): ID { abort 0 }
public fun is_right_order<CoinTypeA, CoinTypeB>(): bool { abort 0 }
