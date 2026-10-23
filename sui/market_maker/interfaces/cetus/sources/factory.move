/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::factory;

use cetus_clmm::config::GlobalConfig;
use sui::coin::TreasuryCap;

public struct Pools has key, store { id: UID }
public struct PoolCreationCap has key, store { id: UID }

public fun is_right_order<CoinTypeA, CoinTypeB>(): bool { abort 0 }

public fun mint_pool_creation_cap<CoinType>(
    config: &GlobalConfig,
    pools: &mut Pools,
    treasury_cap: &mut TreasuryCap<CoinType>,
    ctx: &mut TxContext,
): PoolCreationCap { abort 0 }

public fun register_permission_pair<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    pool_creation_cap: &PoolCreationCap,
    ctx: &mut TxContext,
) { abort 0 }
