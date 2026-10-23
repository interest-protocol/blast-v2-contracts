/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::position;

use integer_mate::i32::I32;

public struct Position has key, store { id: UID }

public fun pool_id(position: &Position): ID { abort 0 }
public fun liquidity(position: &Position): u128 { abort 0 }
public fun tick_range(position: &Position): (I32, I32) { abort 0 }
