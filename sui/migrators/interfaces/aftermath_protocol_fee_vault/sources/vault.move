/// Minimal Aftermath ProtocolFeeVault mainnet interface. Link stubs must not execute.
module protocol_fee_vault::vault;

/// Shared protocol-fee rates every Aftermath deposit, swap, and withdrawal reads.
public struct ProtocolFeeVault has key, store { id: UID }

/// The sum of every protocol fee rate, in Aftermath's `1e18` unit, taken from each coin a route
/// deposits, swaps, or withdraws.
public fun total_protocol_fee(vault: &ProtocolFeeVault): u64 { abort 0 }

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): ProtocolFeeVault {
    ProtocolFeeVault { id: object::new(ctx) }
}
