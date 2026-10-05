// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The single Cetus routes' pair proof and checked retype (ADR 0100). The routes themselves run
/// against real Cetus bytecode in the launchpad venue-fork tests.
module blast_fun_migrators::cetus_route_tests;

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;
public struct OTHER() has drop;

// === Tests ===

#[test]
/// One route serves both Cetus coin orders: it reports which side the Meme is on.
fun the_route_locates_meme_in_either_coin_order() {
    assert!(cetus::is_meme_coin_a_for_testing<MEME, QUOTE, MEME, QUOTE>());
    assert!(!cetus::is_meme_coin_a_for_testing<MEME, QUOTE, QUOTE, MEME>());
}

#[test]
#[expected_failure(abort_code = cetus::EWrongCoinPair, location = blast_fun_migrators::cetus)]
/// A pair that is not exactly the launch's Meme and Quote is rejected before any retype.
fun the_route_rejects_a_foreign_coin_pair() {
    cetus::is_meme_coin_a_for_testing<MEME, QUOTE, MEME, OTHER>();
}

#[test]
#[expected_failure(abort_code = cetus::EWrongCoinPair, location = blast_fun_migrators::cetus)]
/// Naming the Meme on both sides is not the launch's pair either.
fun the_route_rejects_the_same_coin_twice() {
    cetus::is_meme_coin_a_for_testing<MEME, QUOTE, MEME, MEME>();
}

#[test]
/// With Meme as coin A the pair keeps its order; otherwise it swaps, in both directions, and every
/// value arrives intact.
fun a_reorder_maps_either_coin_order_onto_the_other() {
    let mut ctx = tx_context::dummy();

    let (coin_a, coin_b) = cetus::reorder_for_testing<_, _, Balance<MEME>, Balance<QUOTE>>(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(11),
        true,
        &mut ctx,
    );
    assert_eq!(coin_a.destroy_for_testing(), 7);
    assert_eq!(coin_b.destroy_for_testing(), 11);

    let (coin_a, coin_b) = cetus::reorder_for_testing<_, _, Balance<QUOTE>, Balance<MEME>>(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(11),
        false,
        &mut ctx,
    );
    assert_eq!(coin_a.destroy_for_testing(), 11);
    assert_eq!(coin_b.destroy_for_testing(), 7);

    let (meme, quote) = cetus::reorder_for_testing<_, _, Balance<MEME>, Balance<QUOTE>>(
        balance::create_for_testing<QUOTE>(11),
        balance::create_for_testing<MEME>(7),
        false,
        &mut ctx,
    );
    assert_eq!(meme.destroy_for_testing(), 7);
    assert_eq!(quote.destroy_for_testing(), 11);
}

#[test]
#[expected_failure(abort_code = sui::dynamic_field::EFieldTypeMismatch, location = sui::dynamic_field)]
/// The framework refuses to hand a stored balance back under any other type.
fun a_reorder_to_another_type_aborts_in_the_framework() {
    let mut ctx = tx_context::dummy();

    let (coin_a, coin_b) = cetus::reorder_for_testing<_, _, Balance<QUOTE>, Balance<MEME>>(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(11),
        true,
        &mut ctx,
    );
    destroy(coin_a);
    destroy(coin_b);
    abort
}

// === Imports ===

use blast_fun_migrators::cetus;

use std::unit_test::{assert_eq, destroy};

use sui::balance::{Self, Balance};
