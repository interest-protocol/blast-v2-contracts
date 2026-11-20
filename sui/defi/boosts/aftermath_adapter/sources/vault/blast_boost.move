// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The share currency type of every Boost this adapter issues.
///
/// Wallets, explorers, and indexers identify a coin by its type argument, so
/// `Coin<BlastBoost<Product>>` is the name a holder reads. The shared
/// `vault::Vault<Product>` custodies the product; it is not the currency.
module blast_boosts_aftermath::blast_boost;

// === Public Types ===

/// Currency marker for one Boost's share coin.
///
/// No value of this type is ever constructed. It carries `key` only because
/// Coin Registry admits a non-OTW currency solely on a `key` type defined by
/// the registering module, and it names the product so the currency reads as
/// a Blast Boost on every surface that shows the type.
public struct BlastBoost<phantom Product> has key {
    id: UID,
}

// === Package Functions ===

/// Registers the one share currency of `Product` and returns its authorities.
///
/// Coin Registry rejects a second currency for the same `Product`, so this is
/// the only place a Boost currency can come from. The adapter Vault keeps
/// both capabilities as sealed children.
public(package) fun new_currency<Product>(
    registry: &mut CoinRegistry,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): (TreasuryCap<BlastBoost<Product>>, MetadataCap<BlastBoost<Product>>) {
    let (initializer, treasury_cap) = registry.new_currency<BlastBoost<Product>>(
        constants::share_decimals!(),
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );

    (treasury_cap, initializer.finalize(ctx))
}

// === Imports ===

use blast_boosts_aftermath::constants;

use std::string::String;

use sui::{coin::TreasuryCap, coin_registry::{CoinRegistry, MetadataCap}};
