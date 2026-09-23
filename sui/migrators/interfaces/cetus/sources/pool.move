/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::pool;

use cetus_clmm::{config::GlobalConfig, position::Position};
use sui::balance::Balance;

public struct Pool<phantom CoinTypeA, phantom CoinTypeB> has key, store { id: UID }

public fun collect_fee<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position: &Position,
    recalculate: bool,
): (Balance<CoinTypeA>, Balance<CoinTypeB>) { abort 0 }
