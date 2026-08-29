/// Generated Meme package that creates one Blast launch ticket at publication.
module blast_fun_template::meme;

use blast_fun::{creator_authority, launch_ticket};
use sui::address;

// === Constants ===

const SYMBOL: vector<u8> = b"MEME";
const NAME: vector<u8> = b"Blast Meme";
const DESCRIPTION: vector<u8> = b"A Meme launched on Blast";
const ICON_URL: vector<u8> = b"https://blast.fun/meme.png";
const CREATOR_IDENTITY_BYTES: vector<u8> = x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const CREATOR_IS_X: bool = true;
const BURNABLE: bool = false;
const SELL_BURN_BPS: u64 = 0;

// === Public Structs ===

/// One-time witness for this generated Meme currency.
public struct MEME() has drop;

// === Private Initialization ===

fun init(otw: MEME, ctx: &mut TxContext) {
    // Resolve this before the call so the compiler does not spill the witness
    // and metadata arguments across the identity-kind branch.
    let creator_identity = if (CREATOR_IS_X) {
        creator_authority::new_x(CREATOR_IDENTITY_BYTES)
    } else {
        creator_authority::new_address(address::from_bytes(CREATOR_IDENTITY_BYTES))
    };
    let ticket = launch_ticket::new(
        otw,
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        creator_identity,
        BURNABLE,
        SELL_BURN_BPS,
        ctx,
    );

    transfer::public_transfer(ticket, ctx.sender());
}
