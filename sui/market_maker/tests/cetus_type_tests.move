// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::cetus_type_tests;

// === Test-Only Types ===

public struct Meme has drop {}
public struct Quote has drop {}
public struct Foreign has drop {}

// === Tests ===

#[test]
fun pure_pair_proof_accepts_both_orders() {
    assert!(cetus_engine::prove_pair<Meme, Quote, Meme, Quote>());
    assert!(!cetus_engine::prove_pair<Meme, Quote, Quote, Meme>());
}

#[test]
#[
    expected_failure(
        abort_code = cetus_engine::EWrongPair,
        location = blast_market_maker::cetus_engine,
    ),
]
fun pair_proof_rejects_foreign_asset() {
    let _ = cetus_engine::prove_pair<Meme, Quote, Meme, Foreign>();
}

#[test]
#[
    expected_failure(
        abort_code = cetus_engine::EWrongPair,
        location = blast_market_maker::cetus_engine,
    ),
]
fun pair_proof_rejects_duplicate_pool_asset() {
    let _ = cetus_engine::prove_pair<Meme, Quote, Meme, Meme>();
}

#[test]
#[
    expected_failure(
        abort_code = cetus_engine::EWrongPair,
        location = blast_market_maker::cetus_engine,
    ),
]
fun pair_proof_rejects_identical_protocol_assets() {
    let _ = cetus_engine::prove_pair<Meme, Meme, Meme, Meme>();
}

#[test]
fun checked_reorder_preserves_exact_values_in_both_orders() {
    let mut ctx = tx_context::dummy();
    let (first, second): (u64, u128) = cetus_engine::reorder(7u64, 11u128, true, &mut ctx);
    assert!(first == 7 && second == 11);
    let (second, first): (u128, u64) = cetus_engine::reorder(7u64, 11u128, false, &mut ctx);
    assert!(first == 7 && second == 11);
}

#[test]
#[
    expected_failure(
        abort_code = sui::dynamic_field::EFieldTypeMismatch,
        location = sui::dynamic_field,
    ),
]
fun checked_reorder_refuses_forged_destination_type() {
    let mut ctx = tx_context::dummy();
    let (_first, _second): (u128, u64) = cetus_engine::reorder(7u64, 11u128, true, &mut ctx);
}

// === Imports ===

use blast_market_maker::cetus_engine;
use sui::tx_context;
