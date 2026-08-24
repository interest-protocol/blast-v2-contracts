/// Generated-coin creation and linear capability custody before launch opens.
module blast_fun::launch_ticket;

use blast_fun::{
    creator_authority::{Self, CreatorAuthority},
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

/// Creates an OTW currency ticket whose creator identity is a concrete address.
public fun new_address<Meme: drop>(
    otw: Meme,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    creator: address,
    burnable: bool,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    let creator_authority = creator_authority::new_address<Meme>(creator);
    let ticket = new(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        creator_authority,
        burnable,
        ctx,
    );

    ticket.emit_created(
        option::some(creator),
        option::none(),
        ctx.sender(),
    );

    ticket
}

/// Creates an OTW currency ticket whose creator identity is an X commitment.
public fun new_x<Meme: drop>(
    otw: Meme,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    x_identity_hash: vector<u8>,
    burnable: bool,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    let creator_authority = creator_authority::new_x<Meme>(x_identity_hash);
    let ticket = new(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        creator_authority,
        burnable,
        ctx,
    );

    ticket.emit_created(
        option::none(),
        option::some(x_identity_hash),
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

fun new<Meme: drop>(
    otw: Meme,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    creator_authority: CreatorAuthority<Meme>,
    burnable: bool,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
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

    LaunchTicket {
        id: object::new(ctx),
        treasury_cap,
        metadata_cap,
        creator_authority,
        burnable,
    }
}

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
