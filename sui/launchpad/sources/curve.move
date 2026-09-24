// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the curve's abort location.
#[allow(lint(abort_without_constant))]
/// Constant-product quotes over the virtual Quote reserve; owns no state.
module blast_fun::curve;

// === Package Functions ===

/// Caps a buy so its post-fee Quote cannot pass the graduation target. Returns
/// `(quote_in_gross, quote_refund)`: the smallest gross input that reaches the target, and the
/// rest of `quote_supplied`.
public(package) fun cap_buy_quote_input(
    real_quote: u64,
    graduation_target: u64,
    quote_supplied: u64,
    quote_fee_bps: Bps,
): (u64, u64) {
    let quote_remaining = graduation_target - real_quote;

    if (quote_supplied - quote_fee_bps.apply_up(quote_supplied) <= quote_remaining) {
        (quote_supplied, 0)
    } else {
        let quote_in_gross = quote_remaining.mul_div_ceil(
            constants::basis_points_denominator!(),
            constants::basis_points_denominator!() - quote_fee_bps.value(),
        );

        (quote_in_gross, quote_supplied - quote_in_gross)
    }
}

/// Returns `(quote_fee, meme_out_gross, meme_fee, meme_out_net)`, rounded against the buyer.
public(package) fun quote_buy(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    quote_in_gross: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
): (u64, u64, u64, u64) {
    let quote_fee = quote_fee_bps.apply_up(quote_in_gross);
    let meme_out_gross = amount_out(
        (quote_in_gross - quote_fee) as u256,
        (virtual_quote as u256) + (real_quote as u256),
        meme_reserve as u256,
    );
    let meme_fee = meme_fee_bps.apply_up(meme_out_gross);
    let meme_out_net = meme_out_gross - meme_fee;
    assert!(meme_out_net > 0, blast_fun::errors::zero_trade_output!());

    (quote_fee, meme_out_gross, meme_fee, meme_out_net)
}

/// Returns `(meme_fee, pending_burn, quote_out_gross, quote_fee, quote_out_net)`, rounded against
/// the seller. The sell-burn share of the post-fee input never reaches the curve.
public(package) fun quote_sell(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    meme_in_gross: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    sell_burn_bps: Bps,
): (u64, u64, u64, u64, u64) {
    let meme_fee = meme_fee_bps.apply_up(meme_in_gross);
    let pending_burn = sell_burn_bps.apply_up(meme_in_gross - meme_fee);
    let quote_out_gross = amount_out(
        (meme_in_gross - meme_fee - pending_burn) as u256,
        meme_reserve as u256,
        (virtual_quote as u256) + (real_quote as u256),
    );
    let quote_fee = quote_fee_bps.apply_up(quote_out_gross);
    let quote_out_net = quote_out_gross - quote_fee;
    assert!(quote_out_net > 0, blast_fun::errors::zero_trade_output!());

    (meme_fee, pending_burn, quote_out_gross, quote_fee, quote_out_net)
}

// === Private Functions ===

/// Constant-product output for an exact input, rounded down.
fun amount_out(amount_in: u256, reserve_in: u256, reserve_out: u256): u64 {
    (reserve_out * amount_in / (reserve_in + amount_in)) as u64
}

// === Imports ===

use blast_fun::{bps::Bps, constants};
