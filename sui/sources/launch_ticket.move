/// Generated-coin creation, finalized supply, and linear custody before launch opens.
module blast_fun::launch_ticket;

use blast_fun::{
    constants,
    creator_authority::{CreatorAuthority, CreatorIdentity},
    events,
};
use std::string::String;
use sui::{
    balance::Balance,
    coin_registry::{Self, MetadataCap},
};

/// Linear custody of a generated coin's inventory and authorities before launch.
public struct LaunchTicket<phantom Meme> has key, store {
    id: UID,
    meme: Balance<Meme>,
    metadata_cap: MetadataCap<Meme>,
    creator_authority: CreatorAuthority<Meme>,
}

// === Public Functions ===

/// Creates an OTW currency ticket for one validated creator identity.
public fun new<Meme: drop>(
    otw: Meme,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    creator_identity: CreatorIdentity,
    burnable: bool,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    let (creator, x_identity_hash) = creator_identity.fields();
    let creator_authority = creator_identity.into_authority<Meme>();
    let initial_supply = constants::meme_total_supply_atomic_units!();
    let (mut initializer, mut treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        constants::meme_decimals!(),
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let meme = treasury_cap.mint_balance(initial_supply);

    if (burnable) {
        initializer.make_supply_burn_only(treasury_cap);
    } else {
        initializer.make_supply_fixed(treasury_cap);
    };

    let metadata_cap = initializer.finalize(ctx);

    let ticket = LaunchTicket {
        id: object::new(ctx),
        meme,
        metadata_cap,
        creator_authority,
    };

    ticket.emit_created(
        creator,
        x_identity_hash,
        burnable,
        ctx.sender(),
    );

    ticket
}

// === Package Functions ===

/// Consumes the ticket and releases its stored launch inputs to the launch module.
public(package) fun into_parts<Meme>(
    self: LaunchTicket<Meme>,
): (
    Balance<Meme>,
    MetadataCap<Meme>,
    CreatorAuthority<Meme>,
) {
    let LaunchTicket {
        id,
        meme,
        metadata_cap,
        creator_authority,
    } = self;

    id.delete();

    (meme, metadata_cap, creator_authority)
}

fun emit_created<Meme>(
    self: &LaunchTicket<Meme>,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
    launcher: address,
) {
    events::launch_ticket_created<Meme>(
        object::id(self),
        self.meme.value(),
        object::id(&self.metadata_cap),
        launcher,
        creator,
        x_identity_hash,
        burnable,
    );
}
