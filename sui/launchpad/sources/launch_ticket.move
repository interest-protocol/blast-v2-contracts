/// Generated-coin creation, finalized supply, and linear custody before launch opens.
module blast_fun::launch_ticket;

use blast_fun::{
    bps::{Self, Bps},
    constants,
    creator_authority::{CreatorAuthority, CreatorIdentity},
    events,
};
use std::string::String;
use sui::{
    balance::Balance,
    coin_registry::{Self, MetadataCap},
};

// === Public Structs ===

/// Linear custody of a generated coin's inventory and authorities before launch.
public struct LaunchTicket<phantom Meme> has key, store {
    id: UID,
    meme: Balance<Meme>,
    metadata_cap: MetadataCap<Meme>,
    creator_authority: CreatorAuthority<Meme>,
    sell_burn_bps: Bps,
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
    sell_burn_bps: u64,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    let sell_burn_bps = bps::new(sell_burn_bps);

    let creator = creator_identity.creator();
    let x_identity_hash = creator_identity.x_identity_hash();
    let creator_authority = creator_identity.into_authority<Meme>();
    let (mut initializer, mut treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        constants::meme_decimals!(),
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let meme = treasury_cap.mint_balance(constants::meme_total_supply_atomic_units!());

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
        sell_burn_bps,
    };

    ticket.emit_created(creator, x_identity_hash, burnable, sell_burn_bps.value());

    ticket
}

// === Package Functions ===

/// Returns the complete generated supply held for launch intake.
public(package) fun initial_supply<Meme>(self: &LaunchTicket<Meme>): u64 {
    self.meme.value()
}

/// Destroys the ticket and releases its stored launch resources.
public(package) fun destroy<Meme>(
    self: LaunchTicket<Meme>,
): (
    Balance<Meme>,
    MetadataCap<Meme>,
    CreatorAuthority<Meme>,
    Bps,
) {
    let LaunchTicket {
        id,
        meme,
        metadata_cap,
        creator_authority,
        sell_burn_bps,
    } = self;

    id.delete();

    (meme, metadata_cap, creator_authority, sell_burn_bps)
}

fun emit_created<Meme>(
    self: &LaunchTicket<Meme>,
    creator: Option<address>,
    x_identity_hash: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
) {
    events::launch_ticket_created<Meme>(
        self.id.to_inner(),
        self.meme.value(),
        object::id(&self.metadata_cap),
        creator,
        x_identity_hash,
        burnable,
        sell_burn_bps,
    );
}

// === Test-Only Functions ===

#[test_only]
/// Removes ticket inventory without changing Currency supply to model malformed legacy intake.
public fun truncate_supply_for_testing<Meme>(
    self: &mut LaunchTicket<Meme>,
    amount: u64,
) {
    self.meme.split(amount).destroy_for_testing();
}
