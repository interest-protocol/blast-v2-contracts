// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale_testkit::testkit_tests;

// === Constants ===

const MINTER: address = @0xA11CE;

// === Tests ===

#[test]
/// Any caller mints from the shared faucet.
fun the_faucet_mints_for_anyone() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut registry = coin_registry::create_coin_data_registry_for_testing(scenario.ctx());
    test_sui::create(&mut registry, scenario.ctx());

    scenario.next_tx(MINTER);
    let mut faucet = scenario.take_shared<Faucet>();
    let coin = faucet.mint(1_000_000_000, scenario.ctx());

    assert_eq!(coin.value(), 1_000_000_000);

    destroy(coin);
    test_scenario::return_shared(faucet);
    destroy(registry);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = coin_registry::ECurrencyAlreadyExists, location = coin_registry)]
/// TEST_SUI registers once.
fun test_sui_registers_once() {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);

    test_sui::create(&mut registry, &mut ctx);
    test_sui::create(&mut registry, &mut ctx);
    abort
}

#[test]
/// A sale token starts with zero supply and a shared, unsealed `Currency`.
fun a_sale_token_starts_with_zero_supply() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut registry = coin_registry::create_coin_data_registry_for_testing(scenario.ctx());
    let treasury_cap = sale_tokens::new_sale_a(&mut registry, scenario.ctx());

    assert_eq!(treasury_cap.total_supply(), 0);

    scenario.next_tx(MINTER);
    let currency = scenario.take_shared<Currency<SALE_A>>();

    assert_eq!(currency.symbol(), b"BPTA".to_string());
    assert_eq!(currency.decimals(), 9);
    assert!(!currency.is_supply_fixed() && !currency.is_supply_burn_only());

    test_scenario::return_shared(currency);
    destroy(treasury_cap);
    destroy(registry);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = coin_registry::ECurrencyAlreadyExists, location = coin_registry)]
/// Each sale token registers once.
fun a_sale_token_registers_once() {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);

    destroy(sale_tokens::new_sale_b(&mut registry, &mut ctx));
    destroy(sale_tokens::new_sale_b(&mut registry, &mut ctx));
    abort
}

#[test]
/// The long-symbol token carries 33 bytes, one past Bluefin's bound.
fun the_long_symbol_exceeds_bluefins_bound() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut registry = coin_registry::create_coin_data_registry_for_testing(scenario.ctx());
    let treasury_cap = sale_tokens::new_sale_long_symbol(&mut registry, scenario.ctx());

    scenario.next_tx(MINTER);
    let currency = scenario.take_shared<Currency<SALE_LONG_SYMBOL>>();

    assert_eq!(currency.symbol().length(), 33);

    test_scenario::return_shared(currency);
    destroy(treasury_cap);
    destroy(registry);
    scenario.end();
}

// === Imports ===

use blast_presale_testkit::{
    sale_tokens::{Self, SALE_A, SALE_LONG_SYMBOL},
    test_sui::{Self, Faucet},
};

use std::unit_test::{assert_eq, destroy};

use sui::{coin_registry::{Self, Currency}, test_scenario};
