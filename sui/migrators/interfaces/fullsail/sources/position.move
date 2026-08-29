/// Minimal Full Sail mainnet revision-4 interface. Link stubs must not execute.
module clmm_pool::position;

public struct Position has key, store { id: UID }

public fun pool_id(_position: &Position): ID { abort 0 }
public fun liquidity(_position: &Position): u128 { abort 0 }
