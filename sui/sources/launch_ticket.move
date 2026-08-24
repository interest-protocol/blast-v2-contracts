/// Generated-coin creation and linear capability custody before launch opens.
module blast_fun::launch_ticket;

use blast_fun::{
    creator_authority::{Self, CreatorAuthority, CreatorIdentity},
    events,
};
use std::string::String;
use sui::{
    coin::TreasuryCap,
    coin_registry::{Self, MetadataCap},
};

/// Linear custody of a generated coin's authorities between publish and launch.
public struct LaunchTicket<phantom Meme> has key, store {
    id: UID,
    treasury_cap: TreasuryCap<Meme>,
    metadata_cap: MetadataCap<Meme>,
    creator_authority: CreatorAuthority<Meme>,
    burnable: bool,
}

// === Public Functions ===

/// Creates an OTW currency ticket for one validated creator identity.
public fun new<Meme: drop>(
    otw: Meme,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    creator_identity: CreatorIdentity,
    burnable: bool,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    let (creator, x_identity_hash) = creator_identity.event_fields();
    let creator_authority = creator_identity.into_authority<Meme>();
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);

    let ticket = LaunchTicket {
        id: object::new(ctx),
        treasury_cap,
        metadata_cap,
        creator_authority,
        burnable,
    };

    ticket.emit_created(
        creator,
        x_identity_hash,
        ctx.sender(),
    );

    ticket
}

// === Package Functions ===

/// Consumes the ticket and releases its stored launch inputs to the launch module.
public(package) fun into_parts<Meme>(
    self: LaunchTicket<Meme>,
): (
    TreasuryCap<Meme>,
    MetadataCap<Meme>,
    CreatorAuthority<Meme>,
    bool,
) {
    let LaunchTicket {
        id,
        treasury_cap,
        metadata_cap,
        creator_authority,
        burnable,
    } = self;

    id.delete();

    (treasury_cap, metadata_cap, creator_authority, burnable)
}

// === Private Functions ===

fun emit_created<Meme>(
    self: &LaunchTicket<Meme>,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    launcher: address,
) {
    events::launch_ticket_created<Meme>(
        object::id(self),
        object::id(&self.treasury_cap),
        object::id(&self.metadata_cap),
        launcher,
        creator,
        x_identity_hash,
        self.burnable,
    );
}
