// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Generated coin package whose one-time witness creates a standalone currency at publication.
module coin_template::my_coin;

// === Constants ===

const SYMBOL: vector<u8> = b"COIN";

const NAME: vector<u8> = b"My Coin";

const DESCRIPTION: vector<u8> = b"A coin created on Blast";

const ICON_URL: vector<u8> = b"https://blast.fun/coin.png";

const DECIMALS: u8 = 9;

/// Atomic units minted to `SUPPLY_RECIPIENT` at publication; zero mints nothing.
const INITIAL_SUPPLY: u64 = 1_000_000_000_000_000_000;

const SUPPLY_RECIPIENT: address = @0x5ee1;

/// 0 keeps the supply mintable and delivers the `TreasuryCap` to `TREASURY_CAP_RECIPIENT`;
/// 1 fixes the supply; 2 makes it burn-only. 1 and 2 consume the `TreasuryCap` and require a
/// nonzero `INITIAL_SUPPLY`.
const SUPPLY_MODE: u8 = 1;

const TREASURY_CAP_RECIPIENT: address = @0x7ca9;

/// True delivers the `MetadataCap` to `METADATA_CAP_RECIPIENT`; false deletes it, freezing the
/// metadata.
const METADATA_MUTABLE: bool = true;

const METADATA_CAP_RECIPIENT: address = @0x3e7a;

// === Errors ===

#[error(code = 0)]
const EInvalidSupplyMode: vector<u8> = b"The supply mode must be 0 (mintable), 1 (fixed), or 2 (burn-only).";

// === Public Types ===

/// One-time witness naming this package's currency; the Coin Registry proves it is unique.
public struct MY_COIN has drop {}

// === Private Initialization ===

fun init(otw: MY_COIN, ctx: &mut TxContext) {
    create_and_deliver_currency(
        otw,
        DECIMALS,
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        INITIAL_SUPPLY,
        SUPPLY_RECIPIENT,
        SUPPLY_MODE,
        TREASURY_CAP_RECIPIENT,
        METADATA_MUTABLE,
        METADATA_CAP_RECIPIENT,
        ctx,
    );
}

// === Private Functions ===

/// Registers the currency, mints and transfers its initial supply, then transfers or retires its
/// treasury and metadata capabilities. The `Currency` goes to the Coin Registry address; anyone
/// may then share it with `coin_registry::finalize_registration`.
fun create_and_deliver_currency(
    otw: MY_COIN,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    initial_supply: u64,
    supply_recipient: address,
    supply_mode: u8,
    treasury_cap_recipient: address,
    metadata_mutable: bool,
    metadata_cap_recipient: address,
    ctx: &mut TxContext,
) {
    assert!(supply_mode <= 2, EInvalidSupplyMode);

    let (mut initializer, mut treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );

    if (initial_supply > 0)
        transfer::public_transfer(treasury_cap.mint(initial_supply, ctx), supply_recipient);

    match (supply_mode) {
        0 => transfer::public_transfer(treasury_cap, treasury_cap_recipient),
        1 => initializer.make_supply_fixed(treasury_cap),
        _ => initializer.make_supply_burn_only(treasury_cap),
    };

    if (metadata_mutable)
        transfer::public_transfer(initializer.finalize(ctx), metadata_cap_recipient)
    else initializer.finalize_and_delete_metadata_cap(ctx);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(MY_COIN {}, ctx);
}

#[test_only]
/// Runs the initializer's currency creation with arguments in place of the template constants.
public fun create_and_deliver_currency_for_testing(
    decimals: u8,
    initial_supply: u64,
    supply_recipient: address,
    supply_mode: u8,
    treasury_cap_recipient: address,
    metadata_mutable: bool,
    metadata_cap_recipient: address,
    ctx: &mut TxContext,
) {
    create_and_deliver_currency(
        MY_COIN {},
        decimals,
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        initial_supply,
        supply_recipient,
        supply_mode,
        treasury_cap_recipient,
        metadata_mutable,
        metadata_cap_recipient,
        ctx,
    );
}

// === Imports ===

use std::string::String;

use sui::coin_registry;
