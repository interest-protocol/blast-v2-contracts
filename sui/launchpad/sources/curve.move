// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Pure constant-product quotes and the terminal-target input cap; owns no state.
module blast_fun::curve;

use blast_fun::bps::{Self, Bps};

// === Package Functions ===

/// Returns the output for an exact constant-product input, rounded down.
///
/// The caller owns positive input, reserve, and output validation.
public(package) fun get_amount_out(
    amount_in: u256,
    reserve_in: u256,
    reserve_out: u256,
): u256 {
    reserve_out * amount_in / (reserve_in + amount_in)
}

/// Returns the constant product for two widened effective reserves.
public(package) fun k(reserve_x: u256, reserve_y: u256): u256 {
    reserve_x * reserve_y
}

/// Caps a supplied buy coin so its post-fee Quote cannot exceed the terminal target.
///
/// Returns `(quote_in_gross, quote_refund)`. The accepted gross amount is the
/// smallest amount whose post-fee value reaches the remaining target.
///
/// The complement of `quote_fee_bps` is the divisor, so the rate must stay below one hundred
/// percent. `launch_config` owns that bound by capping trade fees at ten percent, and every
/// launch snapshots the capped value; this module does not re-check it.
public(package) fun cap_buy_quote_input(
    real_quote: u64,
    terminal_threshold: u64,
    quote_supplied: u64,
    quote_fee_bps: Bps,
): (u64, u64) {
    let quote_fee = quote_fee_bps.apply_up(quote_supplied);
    let quote_in_net = quote_supplied - quote_fee;
    let quote_remaining = terminal_threshold - real_quote;

    if (quote_in_net <= quote_remaining) {
        (quote_supplied, 0)
    } else {
        let quote_in_gross = quote_remaining.mul_div_ceil(
            blast_fun::constants::basis_points_denominator!(),
            quote_fee_bps.complement().value(),
        );

        (quote_in_gross, quote_supplied - quote_in_gross)
    }
}

/// Quotes a buy without moving coins or mutating launch state.
///
/// Returns `(quote_fee, meme_out_gross, meme_fee, meme_out_net)`.
public(package) fun quote_buy(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    quote_in_gross: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
): (u64, u64, u64, u64) {
    assert!(
        meme_reserve > 0 && virtual_quote > 0,
        blast_fun::errors::invalid_curve_reserve!(),
    );
    assert!(quote_in_gross > 0, blast_fun::errors::zero_trade_input!());

    let quote_fee = quote_fee_bps.apply_up(quote_in_gross);
    let quote_after_fee = quote_in_gross - quote_fee;
    assert!(quote_after_fee > 0, blast_fun::errors::zero_trade_output!());

    let effective_quote = (virtual_quote as u256) + (real_quote as u256);
    let meme_out_gross = get_amount_out(
        quote_after_fee as u256,
        effective_quote,
        meme_reserve as u256,
    ) as u64;
    assert!(meme_out_gross > 0, blast_fun::errors::zero_trade_output!());

    let meme_fee = meme_fee_bps.apply_up(meme_out_gross);
    let meme_out_net = meme_out_gross - meme_fee;
    assert!(meme_out_net > 0, blast_fun::errors::zero_trade_output!());

    (quote_fee, meme_out_gross, meme_fee, meme_out_net)
}

/// Quotes a sell without moving coins or mutating launch state.
///
/// Returns `(meme_fee, pending_burn, quote_out_gross, quote_fee, quote_out_net)`.
public(package) fun quote_sell(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    meme_in_gross: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    sell_burn_bps: Bps,
): (u64, u64, u64, u64, u64) {
    assert!(
        meme_reserve > 0 && virtual_quote > 0,
        blast_fun::errors::invalid_curve_reserve!(),
    );
    assert!(meme_in_gross > 0, blast_fun::errors::zero_trade_input!());

    let meme_fee = meme_fee_bps.apply_up(meme_in_gross);
    let meme_after_fee = meme_in_gross - meme_fee;
    assert!(meme_after_fee > 0, blast_fun::errors::zero_trade_output!());

    let pending_burn = sell_burn_bps.apply_up(meme_after_fee);
    let meme_to_curve = meme_after_fee - pending_burn;
    assert!(meme_to_curve > 0, blast_fun::errors::zero_trade_output!());

    let effective_quote = (virtual_quote as u256) + (real_quote as u256);
    let quote_out_gross_wide = get_amount_out(
        meme_to_curve as u256,
        meme_reserve as u256,
        effective_quote,
    );

    assert!(quote_out_gross_wide > 0, blast_fun::errors::zero_trade_output!());
    assert!(
        quote_out_gross_wide <= (real_quote as u256),
        blast_fun::errors::sell_back_invariant_violated!(),
    );

    let quote_out_gross = quote_out_gross_wide as u64;
    let quote_fee = quote_fee_bps.apply_up(quote_out_gross);
    let quote_out_net = quote_out_gross - quote_fee;
    assert!(quote_out_net > 0, blast_fun::errors::zero_trade_output!());

    (meme_fee, pending_burn, quote_out_gross, quote_fee, quote_out_net)
}
