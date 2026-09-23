// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// One-time-witness currency creation, adapter binding, and linear custody before launch opens.
module blast_fun::launch_ticket;

// === Public Types ===

/// Linear custody of a generated coin's inventory and authorities before launch.
///
/// The treasury capability stays here until launch intake fixes the supply mode, so the bound
/// migration adapter can prepare its venue for the bound Quote (a pool reservation can need it)
/// before any Meme can reach a third party.
public struct LaunchTicket<phantom Meme> has key, store {
    id: UID,
    meme: Balance<Meme>,
    treasury_cap: TreasuryCap<Meme>,
    metadata_cap: MetadataCap<Meme>,
    creator_authority: CreatorAuthority<Meme>,
    decimals: u8,
    burnable: bool,
    sell_burn_bps: Bps,
    migration_witness: Option<TypeName>,
    migration_quote: Option<TypeName>,
}

// === Public Functions ===

/// Creates one currency from the generated package's one-time witness and mints its supply.
///
/// The Coin Registry proves `otw` is the one-time witness of the module that defines `Meme`,
/// so only that package's initializer can build its ticket. Launch intake checks the decimal
/// policy, where the launch configuration is available, and checks the exact supply again
/// before fixing the supply mode.
public fun new<Meme: drop>(
    otw: Meme,
    decimals: u8,
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
    let atomic_supply = atomic_supply(decimals);
    let (initializer, mut treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let creator_address = creator_recipient.recipient_address();
    let account_commitment = creator_recipient.account_commitment();
    let creator_authority = creator_recipient.into_authority<Meme>();
    let meme = treasury_cap.mint_balance(atomic_supply);
    let metadata_cap = initializer.finalize(ctx);
    let ticket = LaunchTicket {
        id: object::new(ctx),
        meme,
        treasury_cap,
        metadata_cap,
        creator_authority,
        decimals,
        burnable,
        sell_burn_bps,
        migration_witness: option::none(),
        migration_quote: option::none(),
    };

    events::launch_ticket_created<Meme>(
        ticket.id.to_inner(),
        decimals,
        atomic_supply,
        object::id(&ticket.metadata_cap),
        creator_address,
        account_commitment,
        burnable,
        sell_burn_bps.value(),
    );

    ticket
}

/// Binds the ticket to the admitted migration adapter that constructs `Witness`, for `Quote`.
///
/// Only the adapter module can construct its witness, and only an admitted adapter can bind, so
/// no other code ever borrows the treasury capability. Launch intake admits the ticket only under
/// the adapter and Quote bound last, so an adapter that prepares its venue while binding has
/// always done so for the pair it migrates. Binding again replaces both.
public fun bind_migration_witness<Meme, Quote, Witness: drop>(
    self: &mut LaunchTicket<Meme>,
    config: &LaunchConfig,
    _: Witness,
) {
    let migration_witness = type_name::with_original_ids<Witness>();
    config.assert_migration_witness_allowed(migration_witness);

    self.migration_witness = option::some(migration_witness);
    self.migration_quote = option::some(type_name::with_original_ids<Quote>());
}

/// Lends the treasury capability to the bound adapter for venue preparation.
///
/// The adapter must still be admitted, so removing it from the allowlist also stops it borrowing
/// the capability of tickets already bound to it. Launch intake rejects any supply other than the
/// canonical one, so the adapter cannot change what the launch receives.
public fun treasury_cap_mut<Meme, Witness: drop>(
    self: &mut LaunchTicket<Meme>,
    config: &LaunchConfig,
    _: Witness,
): &mut TreasuryCap<Meme> {
    let migration_witness = type_name::with_original_ids<Witness>();
    assert!(
        self.migration_witness == option::some(migration_witness),
        blast_fun::errors::invalid_migration_witness!(),
    );
    config.assert_migration_witness_allowed(migration_witness);

    &mut self.treasury_cap
}

// === Package Functions ===

/// Calculates one billion whole tokens at `decimals`; a supply beyond u64 aborts.
public(package) fun atomic_supply(decimals: u8): u64 {
    constants::meme_total_supply_whole_tokens!() * std::u64::pow(10, decimals)
}

/// Returns the identity the opened launch records for the ticket it consumed.
public(package) fun id<Meme>(self: &LaunchTicket<Meme>): ID {
    self.id.to_inner()
}

/// Returns the decimal precision the currency was created with.
public(package) fun decimals<Meme>(self: &LaunchTicket<Meme>): u8 {
    self.decimals
}

/// Returns the creator-selected sell-burn rate for launch intake to re-validate.
public(package) fun sell_burn_bps<Meme>(self: &LaunchTicket<Meme>): Bps {
    self.sell_burn_bps
}

/// Returns the bound migration adapter's witness type if the ticket was bound for `Quote`.
public(package) fun migration_witness<Meme, Quote>(self: &LaunchTicket<Meme>): Option<TypeName> {
    if (self.migration_quote == option::some(type_name::with_original_ids<Quote>())) {
        self.migration_witness
    } else {
        option::none()
    }
}

/// Destroys the ticket, fixes the supply mode in the Coin Registry, and releases its resources.
///
/// Aborts unless the balance and the whole minted supply are exactly `atomic_supply`.
public(package) fun destroy<Meme>(
    self: LaunchTicket<Meme>,
    currency: &mut Currency<Meme>,
    atomic_supply: u64,
): (
    Balance<Meme>,
    MetadataCap<Meme>,
    CreatorAuthority<Meme>,
    Bps,
) {
    let LaunchTicket {
        id,
        meme,
        treasury_cap,
        metadata_cap,
        creator_authority,
        decimals: _,
        burnable,
        sell_burn_bps,
        migration_witness: _,
        migration_quote: _,
    } = self;

    assert!(
        meme.value() == atomic_supply && treasury_cap.total_supply() == atomic_supply,
        blast_fun::errors::invalid_initial_meme_supply!(),
    );

    if (burnable) {
        currency.make_supply_burn_only(treasury_cap);
    } else {
        currency.make_supply_fixed(treasury_cap);
    };

    id.delete();

    (meme, metadata_cap, creator_authority, sell_burn_bps)
}

// === Test-Only Functions ===

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

#[test_only]
/// Burns part of the minted supply to model an old-generation ticket with another supply rule.
public fun burn_meme_for_testing<Meme>(self: &mut LaunchTicket<Meme>, amount: u64) {
    sui::balance::destroy_for_testing(self.meme.split(amount));
}

// === Imports ===

use blast_fun::{
    bps::{Self, Bps},
    constants,
    creator_authority::{CreatorAuthority, CreatorRecipient},
    events,
    launch_config::LaunchConfig,
};

use std::{string::String, type_name::{Self, TypeName}};

use sui::{balance::Balance, coin::TreasuryCap, coin_registry::{Self, Currency, MetadataCap}};
