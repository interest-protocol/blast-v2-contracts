/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::position;

public struct Position has key, store { id: UID }

public fun pool_id(position: &Position): ID { abort 0 }
public fun liquidity(position: &Position): u128 { abort 0 }
