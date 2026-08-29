/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::position_manager;

use turbos_clmm::{
    i32::I32,
    pool::{Pool, Versioned},
    position_nft::TurbosPositionNFT,
};
use sui::{clock::Clock, coin::Coin};

public struct Positions has key, store { id: UID }

public fun mint_with_return_<CoinTypeA, CoinTypeB, FeeType>(
    _pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
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
): (TurbosPositionNFT, Coin<CoinTypeA>, Coin<CoinTypeB>) { abort 0 }

public fun collect_with_return_<CoinTypeA, CoinTypeB, FeeType>(
    _pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
    _positions: &mut Positions,
    _nft: &mut TurbosPositionNFT,
    _amount_a_max: u64,
    _amount_b_max: u64,
    _recipient: address,
    _deadline: u64,
    _clock: &Clock,
    _versioned: &Versioned,
    _ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>) { abort 0 }

public fun get_position_info(
    _positions: &Positions,
    _nft_address: address,
): (I32, I32, u128) { abort 0 }
