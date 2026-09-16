/// Generated-coin creation, finalized supply, and linear custody before launch opens.
module blast_fun::launch_ticket;

use blast_fun::{
    bps::{Self, Bps},
    constants,
    creator_authority::{CreatorAuthority, CreatorRecipient},
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

/// Creates an OTW currency ticket for one validated creator recipient.
public fun new<Meme: drop>(
    otw: Meme,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    creator_recipient: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    assert!(
        sell_burn_bps <= constants::max_sell_burn_bps!(),
        blast_fun::errors::invalid_sell_burn_bps!(),
    );
    let sell_burn_bps = bps::new(sell_burn_bps);

    let creator_address = creator_recipient.recipient_address();
    let account_commitment = creator_recipient.account_commitment();
    let creator_authority = creator_recipient.into_authority<Meme>();
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

    events::launch_ticket_created<Meme>(
        ticket.id.to_inner(),
        ticket.meme.value(),
        object::id(&ticket.metadata_cap),
        creator_address,
        account_commitment,
        burnable,
        sell_burn_bps.value(),
    );

    ticket
}

// === Package Functions ===

/// Returns the identity the opened launch records for the ticket it consumed.
public(package) fun id<Meme>(self: &LaunchTicket<Meme>): ID {
    self.id.to_inner()
}

/// Returns the complete generated supply held for launch intake.
public(package) fun initial_supply<Meme>(self: &LaunchTicket<Meme>): u64 {
    self.meme.value()
}

/// Returns the creator-selected sell-burn rate for launch intake to re-validate.
public(package) fun sell_burn_bps<Meme>(self: &LaunchTicket<Meme>): Bps {
    self.sell_burn_bps
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

// === Test-Only Functions ===

#[test_only]
/// Removes ticket inventory without changing Currency supply to model malformed legacy intake.
public fun truncate_supply_for_testing<Meme>(
    self: &mut LaunchTicket<Meme>,
    amount: u64,
) {
    self.meme.split(amount).destroy_for_testing();
}

#[test_only]
/// Returns the identity of the native metadata capability this ticket custodies.
public fun metadata_cap_id_for_testing<Meme>(self: &LaunchTicket<Meme>): ID {
    object::id(&self.metadata_cap)
}

#[test_only]
/// Overrides the sell-burn rate past this package's ceiling to model an old-generation ticket.
public fun set_sell_burn_bps_for_testing<Meme>(self: &mut LaunchTicket<Meme>, value: u64) {
    self.sell_burn_bps = bps::new(value);
}
