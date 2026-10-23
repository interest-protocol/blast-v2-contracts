// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::cetus_route_tests;

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;
public struct OTHER() has drop;

// === Tests ===

#[test]
/// One route serves both Cetus coin orders: it reports which side the Meme is on.
fun the_route_locates_meme_in_either_coin_order() {
    assert!(cetus::meme_is_coin_a_for_testing<MEME, QUOTE, MEME, QUOTE>());
    assert!(!cetus::meme_is_coin_a_for_testing<MEME, QUOTE, QUOTE, MEME>());
}

#[test]
#[expected_failure(abort_code = cetus::EWrongCoinPair, location = blast_presale::cetus)]
/// A pair that is not exactly the presale's Meme and Quote is rejected before any cast.
fun the_route_rejects_a_foreign_coin_pair() {
    cetus::assert_coin_pair_for_testing<MEME, QUOTE, MEME, OTHER>();
}

#[test]
#[expected_failure(abort_code = cetus::EWrongCoinPair, location = blast_presale::cetus)]
fun the_route_rejects_the_same_coin_twice() {
    cetus::assert_coin_pair_for_testing<MEME, QUOTE, MEME, MEME>();
}

#[test]
#[expected_failure(abort_code = cetus::EWrongCoinPair, location = blast_presale::cetus)]
/// Locating the Meme proves the pair first, so a foreign pair never gets a side.
fun locating_the_meme_rejects_a_foreign_coin_pair() {
    assert!(cetus::meme_is_coin_a_for_testing<MEME, QUOTE, OTHER, QUOTE>());
}

#[test]
/// A dynamic field returns the balance under its own type, value intact.
fun a_cast_to_the_same_type_returns_the_value() {
    let mut ctx = tx_context::dummy();
    let mut scratch = object::new(&mut ctx);

    let meme = scratch.cast_for_testing<Balance<MEME>, Balance<MEME>>(
        balance::create_for_testing<MEME>(7),
    );

    assert_eq!(meme.destroy_for_testing(), 7);

    scratch.delete();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = sui::dynamic_field::EFieldTypeMismatch, location = sui::dynamic_field)]
/// The framework refuses to hand a stored balance back under any other type.
fun a_cast_to_another_type_aborts_in_the_framework() {
    let mut ctx = tx_context::dummy();
    let mut scratch = object::new(&mut ctx);

    let quote = scratch.cast_for_testing<Balance<MEME>, Balance<QUOTE>>(
        balance::create_for_testing<MEME>(7),
    );
    destroy(quote);
    abort
}

// === Imports ===

use blast_presale::cetus;

use std::unit_test::{assert_eq, destroy};

use sui::balance::{Self, Balance};

use fun cetus::cast_for_testing as UID.cast_for_testing;
