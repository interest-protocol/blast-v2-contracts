/// Minimal Full Sail mainnet revision-4 interface. Link stubs must not execute.
module clmm_pool::factory;

use clmm_pool::{
    config::GlobalConfig,
    position::Position,
    rewarder::RewarderGlobalVault,
};
use std::string::String;
use sui::{clock::Clock, coin::Coin};

public struct Pools has key, store { id: UID }

public fun create_pool_with_liquidity<CoinTypeA, CoinTypeB>(
    _pools: &mut Pools,
    _config: &GlobalConfig,
    _rewarder_vault: &mut RewarderGlobalVault,
    _tick_spacing: u32,
    _initialize_price: u128,
    _url: String,
    _tick_lower: u32,
    _tick_upper: u32,
    _coin_a: Coin<CoinTypeA>,
    _coin_b: Coin<CoinTypeB>,
    _amount_a: u64,
    _amount_b: u64,
    _fix_amount_a: bool,
    _feed_id_a: address,
    _feed_id_b: address,
    _auto_calculation_volumes: bool,
    _clock: &Clock,
    _ctx: &mut TxContext,
): (Position, Coin<CoinTypeA>, Coin<CoinTypeB>) { abort 0 }
