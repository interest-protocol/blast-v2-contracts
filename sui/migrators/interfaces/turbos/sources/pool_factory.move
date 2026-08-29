/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::pool_factory;

use turbos_clmm::{
    fee::Fee,
    pool::Versioned,
    position_manager::Positions,
    position_nft::TurbosPositionNFT,
};
use sui::{clock::Clock, coin::Coin};

public struct PoolConfig has key, store { id: UID }

public fun deploy_pool_and_mint_with_return_<CoinTypeA, CoinTypeB, FeeType>(
    _pool_config: &mut PoolConfig,
    _fee_type: &Fee<FeeType>,
    _sqrt_price: u128,
    _positions: &mut Positions,
    _coins_a: vector<Coin<CoinTypeA>>,
    _coins_b: vector<Coin<CoinTypeB>>,
    _tick_lower_index: u32,
    _tick_lower_index_is_neg: bool,
    _tick_upper_index: u32,
    _tick_upper_index_is_neg: bool,
    _amount_a_desired: u64,
    _amount_b_desired: u64,
    _amount_a_min: u64,
    _amount_b_min: u64,
    _deadline: u64,
    _clock: &Clock,
    _versioned: &Versioned,
    _ctx: &mut TxContext,
): (TurbosPositionNFT, Coin<CoinTypeA>, Coin<CoinTypeB>, ID) { abort 0 }
