// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::fee_ledger_tests;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}

// === Tests ===

#[test]
fun fragmented_sharing_and_claims_preserve_each_assets_funded_remainders() {
    let mut meme = fee_ledger::new<MEME>();
    let mut quote = fee_ledger::new<QUOTE>();
    let mut meme_claim = fee_ledger::new_claim();
    let mut quote_claim = fee_ledger::new_claim();
    let mut meme_paid = 0;
    let mut quote_paid = 0;
    let mut kept = 0;
    let mut reinvested = 0;
    1_000u64.do!(|_| {
        meme.credit(balance::create_for_testing<MEME>(3));
        quote.credit(balance::create_for_testing<QUOTE>(5));
        let (m_keep, m_reinvest) = meme.allocate(fee_ledger::allocation(1, 1, 1), 7);
        let (q_keep, q_reinvest) = quote.allocate(fee_ledger::allocation(1, 3, 1), 7);
        kept = kept + m_keep.value() + q_keep.value();
        reinvested = reinvested + m_reinvest.value() + q_reinvest.value();
        m_keep.destroy_for_testing();
        m_reinvest.destroy_for_testing();
        q_keep.destroy_for_testing();
        q_reinvest.destroy_for_testing();
        let m = meme.claim(&mut meme_claim, 7);
        let q = quote.claim(&mut quote_claim, 7);
        meme_paid = meme_paid + m.value();
        quote_paid = quote_paid + q.value();
        m.destroy_for_testing();
        q.destroy_for_testing();
    });
    assert_eq!(kept, 2_000);
    assert_eq!(reinvested, 2_000);
    assert_eq!(meme.available(), 0);
    assert_eq!(quote.available(), 0);
    assert_eq!(meme_paid, 999);
    assert_eq!(quote_paid, 2_999);
    assert_eq!(meme_paid + meme.reserved(), 1_000);
    assert_eq!(quote_paid + quote.reserved(), 3_000);
    assert_eq!(meme.claimable(&meme_claim, 7), 0);
    assert_eq!(quote.claimable(&quote_claim, 7), 0);
    destroy(meme_claim);
    destroy(quote_claim);
    destroy(meme);
    destroy(quote);
}

#[test]
fun sharing_every_last_atom_to_binary_weights_is_exact_with_interleaved_claims() {
    let mut ledger = fee_ledger::new<MEME>();
    let mut small = fee_ledger::new_claim();
    let mut large = fee_ledger::new_claim();
    let mut small_paid = 0;
    100u64.do!(|_| {
        ledger.credit(balance::create_for_testing<MEME>(1));
        let (keep, reinvest) = ledger.allocate(fee_ledger::allocation(0, 1, 0), 4);
        keep.destroy_zero();
        reinvest.destroy_zero();
        let paid = ledger.claim(&mut small, 1);
        small_paid = small_paid + paid.value();
        paid.destroy_for_testing();
    });
    assert_eq!(small_paid, 25);
    let large_paid = ledger.claim(&mut large, 3);
    assert_eq!(large_paid.value(), 75);
    large_paid.destroy_for_testing();
    assert_eq!(ledger.reserved(), 0);
    assert_eq!(ledger.available(), 0);
    destroy(small);
    destroy(large);
    destroy(ledger);
}

#[test]
#[
    expected_failure(
        abort_code = fee_ledger::EAllocationOverflow,
        location = blast_market_maker::fee_ledger,
    ),
]
fun allocation_total_rejects_u64_overflow_before_balance_mutation() {
    let _ = fee_ledger::allocation(18_446_744_073_709_551_615, 1, 0);
}

// === Imports ===

use blast_market_maker::fee_ledger;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
