/// Minimal Aftermath AMM mainnet revision-3 registry interface. Link stubs must not execute.
module amm::pool_registry;

public struct PoolRegistry has key, store {
    id: UID,
    protocol_version: u64,
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PoolRegistry {
    PoolRegistry { id: object::new(ctx), protocol_version: 0 }
}
