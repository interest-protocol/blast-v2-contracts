// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module coin_template::my_coin_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const PUBLISHER: address = @0xA11CE;

const HOLDER: address = @0xB0B;

const MINTER: address = @0xCAFE;

const CURATOR: address = @0xC0FFEE;

const DECIMALS: u8 = 6;

const SUPPLY: u64 = 21_000_000__000_000;

/// The template constants `init` passes, as the generated module declares them.
const TEMPLATE_DECIMALS: u8 = 9;

const TEMPLATE_SUPPLY: u64 = 1_000_000_000__000_000_000;

const TEMPLATE_SUPPLY_RECIPIENT: address = @0x5ee1;

const TEMPLATE_METADATA_CAP_RECIPIENT: address = @0x3e7a;

const MINTABLE: u8 = 0;

const FIXED: u8 = 1;

const BURN_ONLY: u8 = 2;

// === Tests ===

#[test]
fun init_registers_the_template_constants() {
    let mut scenario = test_scenario::begin(PUBLISHER);

    my_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    let currency = scenario.take_currency();

    assert_eq!(currency.decimals(), TEMPLATE_DECIMALS);
    assert_eq!(currency.symbol(), b"COIN".to_string());
    assert_eq!(currency.name(), b"My Coin".to_string());
    assert_eq!(currency.description(), b"A coin created on Blast".to_string());
    assert_eq!(currency.icon_url(), b"https://blast.fun/coin.png".to_string());
    assert!(currency.is_supply_fixed());
    assert_eq!(currency.total_supply(), option::some(TEMPLATE_SUPPLY));
    assert!(!test_scenario::has_most_recent_for_address<TreasuryCap<MY_COIN>>(PUBLISHER));
    assert_eq!(
        currency.metadata_cap_id(),
        option::some(scenario.metadata_cap_id(TEMPLATE_METADATA_CAP_RECIPIENT)),
    );
    assert_eq!(scenario.coin_value(TEMPLATE_SUPPLY_RECIPIENT), TEMPLATE_SUPPLY);
    assert!(!test_scenario::has_most_recent_for_address<Coin<MY_COIN>>(PUBLISHER));

    test_scenario::return_to_address(COIN_REGISTRY, currency);
    scenario.end();
}

#[test]
fun mintable_supply_delivers_the_treasury_cap_and_keeps_the_supply_open() {
    let mut scenario = create(SUPPLY, MINTABLE, true);
    let currency = scenario.take_currency();
    let mut treasury_cap = scenario.take_from_address<TreasuryCap<MY_COIN>>(MINTER);

    assert_eq!(currency.decimals(), DECIMALS);
    assert!(!currency.is_supply_fixed() && !currency.is_supply_burn_only());
    assert!(currency.total_supply().is_none());
    assert_eq!(currency.treasury_cap_id(), option::some(object::id(&treasury_cap)));
    assert_eq!(treasury_cap.total_supply(), SUPPLY);
    assert_eq!(scenario.coin_value(HOLDER), SUPPLY);

    destroy(treasury_cap.mint(1, scenario.ctx()));

    assert_eq!(treasury_cap.total_supply(), SUPPLY + 1);

    test_scenario::return_to_address(MINTER, treasury_cap);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
    scenario.end();
}

#[test]
fun mintable_zero_supply_mints_nothing_and_delivers_the_treasury_cap() {
    let scenario = create(0, MINTABLE, true);
    let treasury_cap = scenario.take_from_address<TreasuryCap<MY_COIN>>(MINTER);

    assert_eq!(treasury_cap.total_supply(), 0);
    assert!(!test_scenario::has_most_recent_for_address<Coin<MY_COIN>>(HOLDER));

    test_scenario::return_to_address(MINTER, treasury_cap);
    scenario.end();
}

#[test]
fun fixed_supply_retires_the_treasury_cap() {
    let scenario = create(SUPPLY, FIXED, true);
    let currency = scenario.take_currency();

    assert!(currency.is_supply_fixed());
    assert_eq!(currency.total_supply(), option::some(SUPPLY));
    assert!(!test_scenario::has_most_recent_for_address<TreasuryCap<MY_COIN>>(MINTER));
    assert_eq!(scenario.coin_value(HOLDER), SUPPLY);

    test_scenario::return_to_address(COIN_REGISTRY, currency);
    scenario.end();
}

#[test]
fun burn_only_supply_retires_the_treasury_cap_and_burns_through_the_currency() {
    let mut scenario = create(SUPPLY, BURN_ONLY, true);
    let mut currency = scenario.take_currency();
    let mut supply = scenario.take_from_address<Coin<MY_COIN>>(HOLDER);

    assert!(currency.is_supply_burn_only());
    assert!(!test_scenario::has_most_recent_for_address<TreasuryCap<MY_COIN>>(MINTER));

    currency.burn(supply.split(1, scenario.ctx()));

    assert_eq!(currency.total_supply(), option::some(SUPPLY - 1));

    test_scenario::return_to_address(HOLDER, supply);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
    scenario.end();
}

#[test]
fun mutable_metadata_delivers_the_metadata_cap() {
    let scenario = create(SUPPLY, FIXED, true);
    let currency = scenario.take_currency();

    assert!(!currency.is_metadata_cap_deleted());
    assert_eq!(currency.metadata_cap_id(), option::some(scenario.metadata_cap_id(CURATOR)));

    test_scenario::return_to_address(COIN_REGISTRY, currency);
    scenario.end();
}

#[test]
fun immutable_metadata_deletes_the_metadata_cap() {
    let scenario = create(SUPPLY, FIXED, false);
    let currency = scenario.take_currency();

    assert!(currency.is_metadata_cap_deleted());
    assert!(!test_scenario::has_most_recent_for_address<MetadataCap<MY_COIN>>(CURATOR));

    test_scenario::return_to_address(COIN_REGISTRY, currency);
    scenario.end();
}

#[test, expected_failure(abort_code = my_coin::EInvalidSupplyMode, location = my_coin)]
fun supply_mode_above_burn_only_aborts() {
    create(SUPPLY, BURN_ONLY + 1, true).end();
}

#[test, expected_failure(abort_code = my_coin::EInvalidSupplyMode, location = my_coin)]
fun invalid_supply_mode_aborts_before_the_empty_supply_check() {
    create(0, BURN_ONLY + 1, true).end();
}

#[test]
#[expected_failure(abort_code = sui::coin_registry::EEmptySupply, location = sui::coin_registry)]
fun fixed_zero_supply_aborts() {
    create(0, FIXED, true).end();
}

#[test]
#[expected_failure(abort_code = sui::coin_registry::EEmptySupply, location = sui::coin_registry)]
fun burn_only_zero_supply_aborts() {
    create(0, BURN_ONLY, true).end();
}

// === Test Helpers ===

/// Publishes the currency with the given supply terms and advances past the publishing transaction.
fun create(initial_supply: u64, supply_mode: u8, metadata_mutable: bool): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);

    my_coin::create_and_deliver_currency_for_testing(
        DECIMALS,
        initial_supply,
        HOLDER,
        supply_mode,
        MINTER,
        metadata_mutable,
        CURATOR,
        scenario.ctx(),
    );
    scenario.next_tx(PUBLISHER);

    scenario
}

/// The one-time-witness path delivers the currency to the Coin Registry address.
fun take_currency(scenario: &Scenario): Currency<MY_COIN> {
    scenario.take_from_address(COIN_REGISTRY)
}

fun coin_value(scenario: &Scenario, owner: address): u64 {
    let supply = scenario.take_from_address<Coin<MY_COIN>>(owner);
    let value = supply.value();

    test_scenario::return_to_address(owner, supply);

    value
}

fun metadata_cap_id(scenario: &Scenario, owner: address): ID {
    let metadata_cap = scenario.take_from_address<MetadataCap<MY_COIN>>(owner);
    let id = object::id(&metadata_cap);

    test_scenario::return_to_address(owner, metadata_cap);

    id
}

// === Imports ===

use coin_template::my_coin::{Self, MY_COIN};

use std::unit_test::{assert_eq, destroy};

use sui::{
    coin::{Coin, TreasuryCap},
    coin_registry::{Currency, MetadataCap},
    test_scenario::{Self, Scenario},
};

use fun coin_value as Scenario.coin_value;

use fun metadata_cap_id as Scenario.metadata_cap_id;

use fun take_currency as Scenario.take_currency;
