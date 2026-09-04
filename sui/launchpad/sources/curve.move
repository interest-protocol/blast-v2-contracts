// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
module blast_fun::curve;

use blast_fun::bps::{Self, Bps};

// === Package Functions ===

/// Caps a supplied buy coin so its post-fee Quote cannot exceed the terminal target.
///
/// Returns `(quote_in_gross, quote_refund)`. The accepted gross amount is the
/// smallest amount whose post-fee value reaches the remaining target.
public(package) fun cap_buy_quote_input(
    real_quote: u64,
    terminal_threshold: u64,
    quote_supplied: u64,
    quote_fee_bps: Bps,
): (u64, u64) {
    assert!(
        terminal_threshold > 0,
        blast_fun::errors::invalid_terminal_threshold!(),
    );
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
/// Returns `(quote_fee, quote_in_net, meme_out_gross, meme_fee, meme_out_net,
/// meme_reserve_after, real_quote_after, crossed_threshold)`.
public(package) fun quote_buy(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    terminal_threshold: u64,
    quote_in_gross: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
): (u64, u64, u64, u64, u64, u64, u64, bool) {
    assert!(
        meme_reserve > 0 && virtual_quote > 0,
        blast_fun::errors::invalid_curve_reserve!(),
    );
    assert!(
        terminal_threshold > 0,
        blast_fun::errors::invalid_terminal_threshold!(),
    );
    assert!(quote_in_gross > 0, blast_fun::errors::zero_trade_input!());

    let quote_fee = quote_fee_bps.apply_up(quote_in_gross);
    let quote_in_net = quote_in_gross - quote_fee;
    assert!(quote_in_net > 0, blast_fun::errors::zero_trade_output!());

    let effective_quote_after =
        (virtual_quote as u256) + (real_quote as u256) + (quote_in_net as u256);
    let meme_out_gross = (
        ((meme_reserve as u256) * (quote_in_net as u256)) / effective_quote_after
    ) as u64;
    assert!(meme_out_gross > 0, blast_fun::errors::zero_trade_output!());

    let meme_fee = meme_fee_bps.apply_up(meme_out_gross);
    let meme_out_net = meme_out_gross - meme_fee;
    assert!(meme_out_net > 0, blast_fun::errors::zero_trade_output!());

    let meme_reserve_after = meme_reserve - meme_out_gross;
    let real_quote_after = real_quote
        .checked_add(quote_in_net)
        .destroy_or!(abort blast_fun::errors::curve_reserve_overflow!());

    (
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        meme_reserve_after,
        real_quote_after,
        real_quote_after >= terminal_threshold,
    )
}

/// Quotes a sell without moving coins or mutating launch state.
///
/// Returns `(meme_fee, meme_in_after_fee, progress_bps, burn_bps, meme_pending_burn,
/// meme_in_effective, quote_out_gross, quote_fee, quote_out_net,
/// meme_reserve_after, real_quote_after)`.
public(package) fun quote_sell(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    terminal_threshold: u64,
    meme_in_gross: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    max_burn_bps: Bps,
): (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    assert!(
        meme_reserve > 0 && virtual_quote > 0,
        blast_fun::errors::invalid_curve_reserve!(),
    );
    assert!(
        terminal_threshold > 0,
        blast_fun::errors::invalid_terminal_threshold!(),
    );
    assert!(meme_in_gross > 0, blast_fun::errors::zero_trade_input!());

    let meme_fee = meme_fee_bps.apply_up(meme_in_gross);
    let meme_in_after_fee = meme_in_gross - meme_fee;
    assert!(meme_in_after_fee > 0, blast_fun::errors::zero_trade_output!());

    let progress_bps = if (real_quote >= terminal_threshold) {
        blast_fun::constants::basis_points_denominator!()
    } else {
        real_quote.mul_div(
            blast_fun::constants::basis_points_denominator!(),
            terminal_threshold,
        )
    };
    let burn_bps = bps::new(progress_bps).apply_down(max_burn_bps.value());
    let meme_pending_burn = bps::new(burn_bps).apply_up(meme_in_after_fee);
    let meme_in_effective = meme_in_after_fee - meme_pending_burn;
    assert!(meme_in_effective > 0, blast_fun::errors::zero_trade_output!());

    let meme_reserve_after = meme_reserve
        .checked_add(meme_in_effective)
        .destroy_or!(abort blast_fun::errors::curve_reserve_overflow!());
    let effective_quote = (virtual_quote as u256) + (real_quote as u256);
    let quote_out_gross_wide =
        (effective_quote * (meme_in_effective as u256))
            / (meme_reserve_after as u256);

    assert!(quote_out_gross_wide > 0, blast_fun::errors::zero_trade_output!());
    assert!(
        quote_out_gross_wide <= (real_quote as u256),
        blast_fun::errors::sell_back_invariant_violated!(),
    );

    let quote_out_gross = quote_out_gross_wide as u64;
    let quote_fee = quote_fee_bps.apply_up(quote_out_gross);
    let quote_out_net = quote_out_gross - quote_fee;
    assert!(quote_out_net > 0, blast_fun::errors::zero_trade_output!());

    (
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        meme_pending_burn,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve_after,
        real_quote - quote_out_gross,
    )
}
