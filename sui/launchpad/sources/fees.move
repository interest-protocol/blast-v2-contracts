// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the ledger's abort location.
#[allow(lint(abort_without_constant))]
/// The protocol and creator trade-fee balances a launch holds.
module blast_fun::fees;

// === Public Types ===

public struct FeeLedger<phantom Meme, phantom Quote> has store {
    protocol_meme: Balance<Meme>,
    creator_meme: Balance<Meme>,
    protocol_quote: Balance<Quote>,
    creator_quote: Balance<Quote>,
}

// === Package Functions ===

public(package) fun new<Meme, Quote>(): FeeLedger<Meme, Quote> {
    FeeLedger {
        protocol_meme: balance::zero(),
        creator_meme: balance::zero(),
        protocol_quote: balance::zero(),
        creator_quote: balance::zero(),
    }
}

/// Splits one trade's fees: the protocol share rounds up and the creator gets the rest. Returns
/// `(protocol_meme, creator_meme, protocol_quote, creator_quote)`.
public(package) fun accrue<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    mut meme_fee: Balance<Meme>,
    mut quote_fee: Balance<Quote>,
    protocol_fee_share_bps: Bps,
): (u64, u64, u64, u64) {
    let protocol_meme_amount = protocol_fee_share_bps.apply_up(meme_fee.value());
    let protocol_quote_amount = protocol_fee_share_bps.apply_up(quote_fee.value());
    let protocol_meme = meme_fee.split(protocol_meme_amount);
    let protocol_quote = quote_fee.split(protocol_quote_amount);

    let (creator_meme_amount, creator_quote_amount) = (meme_fee.value(), quote_fee.value());

    self.protocol_meme.join(protocol_meme);
    self.creator_meme.join(meme_fee);
    self.protocol_quote.join(protocol_quote);
    self.creator_quote.join(quote_fee);

    (protocol_meme_amount, creator_meme_amount, protocol_quote_amount, creator_quote_amount)
}

public(package) fun claim_creator_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    assert!(
        self.creator_meme.value() > 0 || self.creator_quote.value() > 0,
        blast_fun::errors::nothing_accrued!(),
    );

    (
        self.creator_meme.withdraw_all().into_coin(ctx),
        self.creator_quote.withdraw_all().into_coin(ctx),
    )
}

public(package) fun claim_protocol_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    assert!(
        self.protocol_meme.value() > 0 || self.protocol_quote.value() > 0,
        blast_fun::errors::nothing_accrued!(),
    );

    (
        self.protocol_meme.withdraw_all().into_coin(ctx),
        self.protocol_quote.withdraw_all().into_coin(ctx),
    )
}

// === Test-Only Functions ===

#[test_only]
public fun totals_for_testing<Meme, Quote>(self: &FeeLedger<Meme, Quote>): (u64, u64, u64, u64) {
    (
        self.protocol_meme.value(),
        self.creator_meme.value(),
        self.protocol_quote.value(),
        self.creator_quote.value(),
    )
}

// === Imports ===

use blast_fun::bps::Bps;

use sui::{balance::{Self, Balance}, coin::Coin};
