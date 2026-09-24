/// Minimal Cetus mainnet revision-15 interface. Link stubs must not execute.
module cetus_clmm::pool;

use cetus_clmm::{config::GlobalConfig, position::Position};
use integer_mate::i32::I32;
use sui::{balance::Balance, clock::Clock};

public struct Pool<phantom CoinTypeA, phantom CoinTypeB> has key, store { id: UID }
public struct AddLiquidityReceipt<phantom CoinTypeA, phantom CoinTypeB> {}

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

public fun tick_spacing<CoinTypeA, CoinTypeB>(pool: &Pool<CoinTypeA, CoinTypeB>): u32 { abort 0 }

public fun open_position<CoinTypeA, CoinTypeB>(
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    tick_lower: u32,
    tick_upper: u32,
    ctx: &mut TxContext,
): Position { abort 0 }
