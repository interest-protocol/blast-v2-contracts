/// Minimal Aftermath AMM mainnet revision-3 factory interface.
module amm::pool_factory;

use amm::{pool::{CreatePoolCapV2, Pool}, pool_registry::PoolRegistry};
use std::option::Option;
use sui::coin::Coin;

public fun create_pool_2_coins_v2<L, C1, C2>(
    create_pool_cap: CreatePoolCapV2,
    pool_registry: &mut PoolRegistry,
    name: vector<u8>,
    weights: vector<u64>,
    flatness: u64,
    fees_swap_in: vector<u64>,
    fees_swap_out: vector<u64>,
    fees_deposit: vector<u64>,
    fees_withdraw: vector<u64>,
    coin_1: Coin<C1>,
    coin_2: Coin<C2>,
    decimals: Option<vector<u8>>,
    respect_decimals: bool,
    ctx: &mut TxContext,
): (Pool<L>, Coin<L>) { abort 0 }
