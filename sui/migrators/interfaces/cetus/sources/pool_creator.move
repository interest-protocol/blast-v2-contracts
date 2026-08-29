/// Minimal Cetus mainnet revision-14 interface. Link stubs must not execute.
module cetus_clmm::pool_creator;

use cetus_clmm::{config::GlobalConfig, factory::Pools, position::Position};
use std::string::String;
use sui::{clock::Clock, coin::Coin};

public fun create_pool_v3<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    initialize_price: u128,
    url: String,
    tick_lower_idx: u32,
    tick_upper_idx: u32,
    coin_a: Coin<CoinTypeA>,
    coin_b: Coin<CoinTypeB>,
    fix_amount_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Position, Coin<CoinTypeA>, Coin<CoinTypeB>) { abort 0 }

public fun full_range_tick_range(tick_spacing: u32): (u32, u32) { abort 0 }
