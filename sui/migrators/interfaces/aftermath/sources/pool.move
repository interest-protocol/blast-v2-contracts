/// Minimal Aftermath AMM mainnet revision-3 interface. Link stubs must not execute.
module amm::pool;

/// Capability backed by a fresh zero-supply LP currency.
public struct CreatePoolCapV2 has key, store { id: UID }

/// Aftermath pool identified by its fungible LP type.
public struct Pool<phantom L> has key, store { id: UID }

public fun share<L>(pool: Pool<L>) { abort 0 }
public fun flatness<L>(pool: &Pool<L>): u64 { abort 0 }
public fun size<L>(pool: &Pool<L>): u64 { abort 0 }
public fun lp_supply_value<L>(pool: &Pool<L>): u64 { abort 0 }
public fun balance_of<L, C>(pool: &Pool<L>): u64 { abort 0 }
public fun weight_of<L, C>(pool: &Pool<L>): u64 { abort 0 }
public fun fees_swap_in_for<L, C>(pool: &Pool<L>): u64 { abort 0 }
public fun fees_swap_out_for<L, C>(pool: &Pool<L>): u64 { abort 0 }
public fun fees_deposit_for<L, C>(pool: &Pool<L>): u64 { abort 0 }
public fun fees_withdraw_for<L, C>(pool: &Pool<L>): u64 { abort 0 }
public fun lp_decimals<L>(pool: &Pool<L>): u8 { abort 0 }
