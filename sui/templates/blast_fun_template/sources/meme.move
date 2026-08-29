/// Generated Meme package that creates one Blast launch ticket at publication.
module blast_fun_template::meme;

use blast_fun::{creator_authority, launch_ticket};

// === Constants ===

const BURNABLE: bool = false;
const SELL_BURN_BPS: u64 = 0;

// === Public Structs ===

/// One-time witness for this generated Meme currency.
public struct MEME() has drop;

// === Private Initialization ===

fun init(otw: MEME, ctx: &mut TxContext) {
    let launcher = ctx.sender();
    let creator_identity = creator_authority::new_address(launcher);
    let ticket = launch_ticket::new(
        otw,
        b"MEME".to_string(),
        b"Blast Meme".to_string(),
        b"A Meme launched on Blast".to_string(),
        b"https://blast.fun/meme.png".to_string(),
        creator_identity,
        BURNABLE,
        SELL_BURN_BPS,
        ctx,
    );

    transfer::public_transfer(ticket, launcher);
}
