/// The unrestricted 1:1 SUI quote coin used by Blast liquidity.
module blast_sui::fun_sui;

use sui::{coin::TreasuryCap, coin_registry::{Self, MetadataCap}};

// === Public Structs ===

/// One-time witness and coin type for funSUI.
public struct FUN_SUI() has drop;

// === Private Initialization ===

#[allow(lint(self_transfer))]
fun init(otw: FUN_SUI, ctx: &mut TxContext) {
    let (treasury_cap, metadata_cap) = new(otw, ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}

// === Private Functions ===

fun new(
    otw: FUN_SUI,
    ctx: &mut TxContext,
): (TreasuryCap<FUN_SUI>, MetadataCap<FUN_SUI>) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        9,
        b"funSUI".to_string(),
        b"funSUI".to_string(),
        b"One-to-one SUI quote liquidity for blast.fun".to_string(),
        b"https://www.blast.fun/art/generated/blast-sui-mark-gpt-v4.png".to_string(),
        ctx,
    );
    (treasury_cap, initializer.finalize(ctx))
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<FUN_SUI>(), ctx);
}

#[test_only]
public fun new_for_testing(
    ctx: &mut TxContext,
): (TreasuryCap<FUN_SUI>, MetadataCap<FUN_SUI>) {
    new(FUN_SUI(), ctx)
}
