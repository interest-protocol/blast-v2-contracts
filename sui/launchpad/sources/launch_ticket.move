// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the ticket's abort location.
#[allow(lint(abort_without_constant))]
/// One-time-witness currency creation and custody of its inventory until a launch starts.
module blast_fun::launch_ticket;

// === Public Types ===

/// A generated coin's whole supply and authorities until launch finalization fixes the supply.
public struct LaunchTicket<phantom Meme> has key, store {
    id: UID,
    meme: Balance<Meme>,
    treasury_cap: TreasuryCap<Meme>,
    metadata_cap: MetadataCap<Meme>,
    creator: CreatorRecipient,
    decimals: u8,
    burnable: bool,
    sell_burn_bps: Bps,
}

// === Public Functions ===

/// Registers the currency with the generated package's one-time witness and mints one billion
/// whole tokens. Only that package's initializer holds the witness.
public fun new<Meme: drop>(
    otw: Meme,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    creator: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
    ctx: &mut TxContext,
): LaunchTicket<Meme> {
    assert!(
        sell_burn_bps <= constants::max_sell_burn_bps!(),
        blast_fun::errors::invalid_sell_burn_bps!(),
    );

    let (initializer, mut treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let ticket = LaunchTicket {
        id: object::new(ctx),
        meme: treasury_cap.mint_balance(atomic_supply(decimals)),
        treasury_cap,
        metadata_cap: initializer.finalize(ctx),
        creator,
        decimals,
        burnable,
        sell_burn_bps: bps::new(sell_burn_bps),
    };

    events::launch_ticket_created<Meme>(
        ticket.id.to_inner(),
        decimals,
        object::id(&ticket.metadata_cap),
        creator,
        burnable,
        sell_burn_bps,
    );

    ticket
}

// === Package Functions ===

/// One billion whole tokens at `decimals`; a supply beyond u64 aborts.
public(package) fun atomic_supply(decimals: u8): u64 {
    constants::meme_total_supply_whole_tokens!() * std::u64::pow(10, decimals)
}

public(package) fun id<Meme>(self: &LaunchTicket<Meme>): ID {
    self.id.to_inner()
}

public(package) fun decimals<Meme>(self: &LaunchTicket<Meme>): u8 {
    self.decimals
}

public(package) fun treasury_cap_mut<Meme>(self: &mut LaunchTicket<Meme>): &mut TreasuryCap<Meme> {
    &mut self.treasury_cap
}

/// Fixes the supply mode in the Coin Registry and releases the ticket's contents.
///
/// A ticket built against an older launchpad version followed that version's rules, so the
/// supply and the sell-burn rate are checked again here.
public(package) fun destroy<Meme>(
    self: LaunchTicket<Meme>,
    currency: &mut Currency<Meme>,
    atomic_supply: u64,
): (Balance<Meme>, MetadataCap<Meme>, CreatorRecipient, Bps) {
    let LaunchTicket {
        id,
        meme,
        treasury_cap,
        metadata_cap,
        creator,
        decimals: _,
        burnable,
        sell_burn_bps,
    } = self;

    assert!(
        meme.value() == atomic_supply && treasury_cap.total_supply() == atomic_supply,
        blast_fun::errors::invalid_initial_meme_supply!(),
    );
    assert!(
        sell_burn_bps.value() <= constants::max_sell_burn_bps!(),
        blast_fun::errors::invalid_sell_burn_bps!(),
    );

    if (burnable) currency.make_supply_burn_only(treasury_cap)
    else currency.make_supply_fixed(treasury_cap);
    id.delete();

    (meme, metadata_cap, creator, sell_burn_bps)
}

// === Test-Only Functions ===

#[test_only]
public fun metadata_cap_id_for_testing<Meme>(self: &LaunchTicket<Meme>): ID {
    object::id(&self.metadata_cap)
}

#[test_only]
/// Overrides the sell-burn rate past this package's ceiling to model an old-generation ticket.
public fun set_sell_burn_bps_for_testing<Meme>(self: &mut LaunchTicket<Meme>, value: u64) {
    self.sell_burn_bps = bps::new(value);
}

#[test_only]
/// Burns part of the minted supply to model an old-generation ticket with another supply rule.
public fun burn_meme_for_testing<Meme>(self: &mut LaunchTicket<Meme>, amount: u64) {
    self.meme.split(amount).destroy_for_testing();
}

// === Imports ===

use blast_fun::{bps::{Self, Bps}, constants, creator_authority::CreatorRecipient, events};

use std::string::String;

use sui::{balance::Balance, coin::TreasuryCap, coin_registry::{Self, Currency, MetadataCap}};
