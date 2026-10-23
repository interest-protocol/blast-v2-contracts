/// Minimal Cetus LP Burn mainnet version-8 interface. Link stubs must not execute.
module lp_burn::lp_burn;

use cetus_clmm::{config::GlobalConfig, pool::Pool, position::Position};
use sui::coin::Coin;

public struct BurnManager has key { id: UID }
public struct CetusLPBurnProof has key, store { id: UID }

public fun burn_lp_v2(
    manager: &mut BurnManager,
    position: Position,
    ctx: &mut TxContext,
): CetusLPBurnProof { abort 0 }

public fun collect_fee<CoinTypeA, CoinTypeB>(
    m: &BurnManager,
    config: &GlobalConfig,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    position: &mut CetusLPBurnProof,
    ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>) { abort 0 }
