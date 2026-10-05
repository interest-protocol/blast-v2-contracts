/// Minimal Aftermath AMM mainnet revision-3 registry interface. Link stubs must not execute.
module amm::pool_registry;

public struct PoolRegistry has key, store {
    id: UID,
    protocol_version: u64,
}
