/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::pool;

public struct Pool<phantom CoinTypeA, phantom CoinTypeB, phantom FeeType> has key, store { id: UID }
public struct Versioned has key, store { id: UID }

public fun get_pool_sqrt_price<CoinTypeA, CoinTypeB, FeeType>(
    _pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
): u128 { abort 0 }

public fun get_pool_tick_spacing<CoinTypeA, CoinTypeB, FeeType>(
    _pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
): u32 { abort 0 }

public fun get_pool_fee<CoinTypeA, CoinTypeB, FeeType>(
    _pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
): u32 { abort 0 }
