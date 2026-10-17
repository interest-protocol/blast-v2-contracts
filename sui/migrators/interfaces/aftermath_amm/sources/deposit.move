/// Minimal Aftermath AMM mainnet revision-3 deposit interface. Link stubs must not execute.
module amm::deposit;

use amm::{pool::Pool, pool_registry::PoolRegistry};
use insurance_fund::insurance_fund::InsuranceFund;
use protocol_fee_vault::vault::ProtocolFeeVault;
use referral_vault::referral_vault::ReferralVault;
use sui::coin::Coin;
use treasury::treasury::Treasury;

/// Deposits exactly `coin_1` and `coin_2`, after Aftermath's protocol fee, at whatever ratio the
/// pool prices them, and mints at least `min_lp` LP coins.
public fun deposit_2_coins_direct<L, C1, C2>(
    pool: &mut Pool<L>,
    pool_registry: &PoolRegistry,
    protocol_fee_vault: &ProtocolFeeVault,
    treasury: &mut Treasury,
    insurance_fund: &mut InsuranceFund,
    referral_vault: &ReferralVault,
    coin_1: Coin<C1>,
    coin_2: Coin<C2>,
    min_lp: u64,
    ctx: &mut TxContext,
): Coin<L> { abort 0 }
