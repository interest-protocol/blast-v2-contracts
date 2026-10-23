/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::pool;

use cetus_clmm::{config::GlobalConfig, position::Position};
use integer_mate::i32::I32;
use sui::{balance::Balance, clock::Clock};

public struct Pool<phantom CoinTypeA, phantom CoinTypeB> has key, store { id: UID }
public struct AddLiquidityReceipt<phantom CoinTypeA, phantom CoinTypeB> {}
public struct FlashSwapReceipt<phantom CoinTypeA, phantom CoinTypeB> {}

public fun collect_fee<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position: &Position,
    recalculate: bool,
): (Balance<CoinTypeA>, Balance<CoinTypeB>) { abort 0 }

public fun current_sqrt_price<CoinTypeA, CoinTypeB>(pool: &Pool<CoinTypeA, CoinTypeB>): u128 { abort 0 }

public fun current_tick_index<CoinTypeA, CoinTypeB>(pool: &Pool<CoinTypeA, CoinTypeB>): I32 { abort 0 }

public fun add_liquidity_fix_coin<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position: &mut Position,
    amount: u64,
    fix_amount_a: bool,
    clock: &Clock,
): AddLiquidityReceipt<CoinTypeA, CoinTypeB> { abort 0 }

public fun add_liquidity_pay_amount<CoinTypeA, CoinTypeB>(
    receipt: &AddLiquidityReceipt<CoinTypeA, CoinTypeB>,
): (u64, u64) { abort 0 }

public fun repay_add_liquidity<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    balance_a: Balance<CoinTypeA>,
    balance_b: Balance<CoinTypeB>,
    receipt: AddLiquidityReceipt<CoinTypeA, CoinTypeB>,
) { abort 0 }

public fun flash_swap<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    a2b: bool,
    by_amount_in: bool,
    amount: u64,
    sqrt_price_limit: u128,
    clock: &Clock,
): (Balance<CoinTypeA>, Balance<CoinTypeB>, FlashSwapReceipt<CoinTypeA, CoinTypeB>) { abort 0 }

public fun swap_pay_amount<CoinTypeA, CoinTypeB>(
    receipt: &FlashSwapReceipt<CoinTypeA, CoinTypeB>,
): u64 { abort 0 }

public fun repay_flash_swap<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a: Balance<CoinTypeA>,
    coin_b: Balance<CoinTypeB>,
    receipt: FlashSwapReceipt<CoinTypeA, CoinTypeB>,
) { abort 0 }

public fun tick_spacing<CoinTypeA, CoinTypeB>(pool: &Pool<CoinTypeA, CoinTypeB>): u32 { abort 0 }

public fun open_position<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    ctx: &mut TxContext,
): Position { abort 0 }

// Official interface pinned at CetusProtocol/cetus-clmm-interface@5ef409e5aa97cf0c545c5ff64560cb65eaa981e7.
public fun remove_liquidity<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig, pool: &mut Pool<CoinTypeA, CoinTypeB>, position_nft: &mut Position,
    delta_liquidity: u128, clock: &Clock,
): (Balance<CoinTypeA>, Balance<CoinTypeB>) { abort 0 }

public fun close_position<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig, pool: &mut Pool<CoinTypeA, CoinTypeB>, position_nft: Position,
) { abort 0 }

public fun calculate_and_update_rewards<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig, pool: &mut Pool<CoinTypeA, CoinTypeB>, position_id: ID, clock: &Clock,
): vector<u64> { abort 0 }

public fun get_position_fee<CoinTypeA, CoinTypeB>(pool: &Pool<CoinTypeA, CoinTypeB>, position_id: ID): (u64, u64) { abort 0 }

public fun collect_reward<CoinTypeA, CoinTypeB, Reward>(
    config: &GlobalConfig, pool: &mut Pool<CoinTypeA, CoinTypeB>, position_nft: &Position,
    vault: &mut cetus_clmm::rewarder::RewarderGlobalVault, recalculate: bool, clock: &Clock,
): Balance<Reward> { abort 0 }
