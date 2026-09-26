// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::payout_tests;

// === Constants ===

const TEAM: address = @0x7EA3;

const CREATOR: address = @0xC0FFEE;

// === Test-Only Types ===

public struct ADAPTER() has drop;

public struct TOKEN() has drop;

public struct QUOTE() has drop;

// === Tests ===

// --- Construction ---

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidRecipient, location = blast_presale::payout)]
fun a_zero_recipient_address_is_rejected() {
    payout::recipient(@0x0, 1);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidRecipient, location = blast_presale::payout)]
fun a_zero_recipient_share_is_rejected() {
    payout::recipient(TEAM, 0);
}

#[test]
fun liquidity_records_its_adapter_and_pool_tier() {
    let liquidity = payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, 5_000, 1, 2);
    let (tick_spacing, fee_rate) = liquidity.pool_tier();

    assert_eq!(liquidity.venue(), type_name::with_original_ids<ADAPTER>());
    assert!(liquidity.is_for<TOKEN, QUOTE>());
    assert!(!liquidity.is_for<QUOTE, TOKEN>());
    assert_eq!(tick_spacing, 60);
    assert_eq!(fee_rate, 2_500);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidLiquidity, location = blast_presale::payout)]
fun a_zero_liquidity_share_is_rejected() {
    payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, 0, 1, 2);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidLiquidity, location = blast_presale::payout)]
fun a_liquidity_share_above_the_whole_is_rejected() {
    payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, 10_001, 1, 2);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidLiquidity, location = blast_presale::payout)]
fun a_listing_price_without_quote_is_rejected() {
    payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, 5_000, 0, 2);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidLiquidity, location = blast_presale::payout)]
fun a_listing_price_without_tokens_is_rejected() {
    payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, 5_000, 1, 0);
}

// --- Shares ---

#[test]
fun recipients_and_liquidity_must_sum_to_the_whole() {
    payout::assert_shares(&vector[payout::recipient(TEAM, 10_000)], &option::none());
    payout::assert_shares(&vector[], &option::some(liquidity(10_000)));
    payout::assert_shares(
        &vector[payout::recipient(TEAM, 3_000), payout::recipient(CREATOR, 2_000)],
        &option::some(liquidity(5_000)),
    );
    let sixteen = vector::tabulate!(16, |_| payout::recipient(TEAM, 625));
    payout::assert_shares(&sixteen, &option::none());
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidPayout, location = blast_presale::payout)]
fun shares_below_the_whole_are_rejected() {
    payout::assert_shares(&vector[payout::recipient(TEAM, 4_999)], &option::some(liquidity(5_000)));
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidPayout, location = blast_presale::payout)]
fun shares_above_the_whole_are_rejected() {
    payout::assert_shares(&vector[payout::recipient(TEAM, 5_001)], &option::some(liquidity(5_000)));
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidPayout, location = blast_presale::payout)]
fun a_seventeenth_recipient_is_rejected() {
    let mut recipients = vector::tabulate!(16, |_| payout::recipient(TEAM, 625));
    recipients.push_back(payout::recipient(CREATOR, 1));

    payout::assert_shares(&recipients, &option::none());
}

// --- Amounts ---

#[test]
fun the_reserve_is_the_liquidity_share_of_the_most_quote_at_the_listing_price() {
    assert_eq!(payout::reserve_down(&option::none(), 700), 0);
    // Half of 700 Quote is 350, which buys 700 tokens at 1 Quote per 2 tokens.
    assert_eq!(payout::reserve_down(&option::some(liquidity(5_000)), 700), 700);
    // A third of 700 is 233, which buys 466 tokens.
    assert_eq!(payout::reserve_down(&option::some(liquidity(3_333)), 700), 466);
}

#[test]
fun the_first_recipient_takes_the_rounding_remainder() {
    let recipients = vector[payout::recipient(TEAM, 3_333), payout::recipient(CREATOR, 3_333)];
    let liquidity = option::some(liquidity(3_334));
    let (amounts, pool_quote) = payout::split_down(&recipients, &liquidity, 1_000);

    assert_eq!(amounts, vector[334, 333]);
    assert_eq!(pool_quote, 333);
}

#[test]
fun without_liquidity_the_recipients_share_everything() {
    let recipients = vector[payout::recipient(TEAM, 5_000), payout::recipient(CREATOR, 5_000)];
    let (amounts, pool_quote) = payout::split_down(&recipients, &option::none(), 1_001);

    assert_eq!(amounts, vector[501, 500]);
    assert_eq!(pool_quote, 0);
}

#[test]
fun without_recipients_the_liquidity_takes_everything() {
    let liquidity = option::some(liquidity(10_000));
    let (amounts, pool_quote) = payout::split_down(&vector[], &liquidity, 1_001);

    assert_eq!(amounts, vector[]);
    assert_eq!(pool_quote, 1_001);
}

#[test]
fun the_pool_buys_tokens_at_the_listing_price_rounded_down() {
    let liquidity = payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, 5_000, 3, 10);

    assert_eq!(liquidity.tokens_down(297), 990);
    assert_eq!(liquidity.tokens_down(1), 3);
    assert_eq!(liquidity.tokens_down(0), 0);
}

// === Test Helpers ===

/// `bps` of the raise into a pool opening at 1 Quote per 2 tokens.
fun liquidity(bps: u64): Liquidity {
    payout::liquidity<TOKEN, QUOTE, _>(ADAPTER(), 60, 2_500, bps, 1, 2)
}

// === Imports ===

use blast_presale::payout::{Self, Liquidity};

use std::{type_name, unit_test::assert_eq};
