/// Minimal Full Sail mainnet revision-4 interface. Link stubs must not execute.
module clmm_pool::pool;

use clmm_pool::{
    config::GlobalConfig,
    position::Position,
    rewarder::RewarderGlobalVault,
};
use sui::{balance::Balance, clock::Clock};

public struct Pool<phantom CoinTypeA, phantom CoinTypeB> has key, store { id: UID }
public struct AddLiquidityReceipt<phantom CoinTypeA, phantom CoinTypeB> {}

public fun open_position<CoinTypeA, CoinTypeB>(
    _config: &GlobalConfig,
    _pool: &mut Pool<CoinTypeA, CoinTypeB>,
    _tick_lower: u32,
    _tick_upper: u32,
    _ctx: &mut TxContext,
): Position { abort 0 }

public fun add_liquidity_fix_coin<CoinTypeA, CoinTypeB>(
    _config: &GlobalConfig,
    _rewarder_vault: &mut RewarderGlobalVault,
    _pool: &mut Pool<CoinTypeA, CoinTypeB>,
    _position: &mut Position,
    _amount: u64,
    _fix_amount_a: bool,
    _clock: &Clock,
): AddLiquidityReceipt<CoinTypeA, CoinTypeB> { abort 0 }

public fun add_liquidity_pay_amount<CoinTypeA, CoinTypeB>(
    _receipt: &AddLiquidityReceipt<CoinTypeA, CoinTypeB>,
): (u64, u64) { abort 0 }

public fun repay_add_liquidity<CoinTypeA, CoinTypeB>(
    _config: &GlobalConfig,
    _pool: &mut Pool<CoinTypeA, CoinTypeB>,
    _balance_a: Balance<CoinTypeA>,
    _balance_b: Balance<CoinTypeB>,
    _receipt: AddLiquidityReceipt<CoinTypeA, CoinTypeB>,
) { abort 0 }

public fun collect_fee<CoinTypeA, CoinTypeB>(
    _config: &GlobalConfig,
    _pool: &mut Pool<CoinTypeA, CoinTypeB>,
    _position: &Position,
    _recalculate: bool,
): (Balance<CoinTypeA>, Balance<CoinTypeB>) { abort 0 }

public fun tick_spacing<CoinTypeA, CoinTypeB>(
    _pool: &Pool<CoinTypeA, CoinTypeB>,
): u32 { abort 0 }

public fun fee_rate<CoinTypeA, CoinTypeB>(
    _pool: &Pool<CoinTypeA, CoinTypeB>,
): u64 { abort 0 }

public fun current_sqrt_price<CoinTypeA, CoinTypeB>(
    _pool: &Pool<CoinTypeA, CoinTypeB>,
): u128 { abort 0 }
