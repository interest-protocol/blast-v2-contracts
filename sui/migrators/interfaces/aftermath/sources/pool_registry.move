/// Minimal Aftermath AMM mainnet revision-3 registry interface.
module amm::pool_registry;

public struct PoolRegistry has key, store {
    id: UID,
    protocol_version: u64,
}

public fun contains_lp_coin<L>(registry: &PoolRegistry): bool { abort 0 }
public fun lp_type_to_pool_id<L>(registry: &PoolRegistry): ID { abort 0 }
