/// Minimal Aftermath DAO-fee pool mainnet revision-2 interface. Link stubs must not execute.
module dao_fee_amm::pool;

use amm::pool::Pool;
use dao_fee_amm::version::Version;

/// Wrapper that takes DAO fees before forwarding operations to the base pool.
public struct DaoFeePool<phantom Lp> has key, store { id: UID }

/// Capability that controls one DAO-fee pool's fee and recipient.
public struct OwnerCap<phantom Lp> has key, store { id: UID }

/// Consumes one base pool and returns its DAO-fee wrapper and policy cap.
public fun new<Lp>(
    pool: Pool<Lp>,
    version: &Version,
    fee_bps: u16,
    fee_recipient: address,
    ctx: &mut TxContext,
): (DaoFeePool<Lp>, OwnerCap<Lp>) { abort 0 }

/// Returns the wrapper's DAO fee in basis points.
public fun fee_bps<Lp>(pool: &DaoFeePool<Lp>): u16 { abort 0 }

/// Returns the address that receives separate DAO fee coins.
public fun fee_recipient<Lp>(pool: &DaoFeePool<Lp>): address { abort 0 }
