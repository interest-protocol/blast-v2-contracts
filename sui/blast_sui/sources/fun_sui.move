/// The unrestricted 1:1 SUI quote coin used by Blast liquidity.
module blast_sui::fun_sui;

use sui::{coin::TreasuryCap, coin_registry};

// === Public Structs ===

/// One-time witness and coin type for funSUI.
public struct FUN_SUI() has drop;

// === Private Initialization ===

#[allow(lint(self_transfer))]
fun init(otw: FUN_SUI, ctx: &mut TxContext) {
    let treasury_cap = create(otw, ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
}

// === Private Functions ===

fun create(
    otw: FUN_SUI,
    ctx: &mut TxContext,
): TreasuryCap<FUN_SUI> {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        9,
        b"funSUI".to_string(),
        b"funSUI".to_string(),
        b"One-to-one SUI quote liquidity for blast.fun".to_string(),
        b"https://www.blast.fun/art/generated/blast-sui-mark-gpt-v4.png".to_string(),
        ctx,
    );
    initializer.finalize_and_delete_metadata_cap(ctx);

    treasury_cap
}

// === Test-Only Functions ===

#[test_only]
public fun create_for_testing(
    ctx: &mut TxContext,
): TreasuryCap<FUN_SUI> {
    create(FUN_SUI(), ctx)
}
