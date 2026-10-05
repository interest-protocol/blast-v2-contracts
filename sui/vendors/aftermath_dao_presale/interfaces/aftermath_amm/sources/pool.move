/// Minimal Aftermath AMM mainnet revision-3 interface. Link stubs must not execute.
module amm::pool;

/// Capability backed by a fresh zero-supply LP currency. Revision 3 introduced it, so its defining
/// package is the revision-3 id rather than the original one.
public struct CreatePoolCapV2 has key, store { id: UID }

/// Aftermath pool identified by its fungible LP type.
public struct Pool<phantom L> has key, store { id: UID }

public fun balance_of<L, C>(pool: &Pool<L>): u64 { abort 0 }
