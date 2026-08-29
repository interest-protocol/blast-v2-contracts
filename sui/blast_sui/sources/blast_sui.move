/// The unrestricted residual-share LST that receives all vault staking rewards.
module blast_sui::blast_sui;

use sui::{coin::TreasuryCap, coin_registry};

// === Public Structs ===

/// One-time witness and coin type for blastSUI.
public struct BLAST_SUI() has drop;

// === Private Initialization ===

#[allow(lint(self_transfer))]
fun init(otw: BLAST_SUI, ctx: &mut TxContext) {
    let treasury_cap = create(otw, ctx);
    transfer::public_transfer(treasury_cap, ctx.sender());
}

// === Private Functions ===

fun create(
    otw: BLAST_SUI,
    ctx: &mut TxContext,
): TreasuryCap<BLAST_SUI> {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        9,
        b"blastSUI".to_string(),
        b"blastSUI".to_string(),
        b"Yield-bearing residual share of the Blast SUI staking vault".to_string(),
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
): TreasuryCap<BLAST_SUI> {
    create(BLAST_SUI(), ctx)
}
