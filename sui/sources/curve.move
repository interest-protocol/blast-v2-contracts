// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
module blast_fun::curve;

// === Package Functions ===

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
    quote_fee_bps: u64,
    meme_fee_bps: u64,
): (u64, u64, u64, u64, u64, u64, u64, bool) {
    assert!(
        meme_reserve > 0 && virtual_quote > 0,
        blast_fun::errors::invalid_curve_reserve!(),
    );
    assert!(
        terminal_threshold > 0,
        blast_fun::errors::invalid_terminal_threshold!(),
    );
    assert!(
        quote_fee_bps <= blast_fun::constants::basis_points_denominator!(),
        blast_fun::errors::invalid_quote_fee_bps!(),
    );
    assert!(
        meme_fee_bps <= blast_fun::constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_fee_bps!(),
    );
    assert!(quote_in_gross > 0, blast_fun::errors::zero_trade_input!());

    let quote_fee = mul_div_up(
        quote_in_gross,
        quote_fee_bps,
        blast_fun::constants::basis_points_denominator!(),
    );
    let quote_in_net = quote_in_gross - quote_fee;
    assert!(quote_in_net > 0, blast_fun::errors::zero_trade_output!());

    let effective_quote_after =
        (virtual_quote as u256) + (real_quote as u256) + (quote_in_net as u256);
    let meme_out_gross = (
        ((meme_reserve as u256) * (quote_in_net as u256)) / effective_quote_after
    ) as u64;
    assert!(meme_out_gross > 0, blast_fun::errors::zero_trade_output!());

    let meme_fee = mul_div_up(
        meme_out_gross,
        meme_fee_bps,
        blast_fun::constants::basis_points_denominator!(),
    );
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
/// Returns `(meme_fee, meme_in_after_fee, progress_bps, burn_bps, meme_burned,
/// meme_in_effective, quote_out_gross, quote_fee, quote_out_net,
/// meme_reserve_after, real_quote_after)`.
public(package) fun quote_sell(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    terminal_threshold: u64,
    meme_in_gross: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    max_burn_bps: u64,
): (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    assert!(
        meme_reserve > 0 && virtual_quote > 0,
        blast_fun::errors::invalid_curve_reserve!(),
    );
    assert!(
        terminal_threshold > 0,
        blast_fun::errors::invalid_terminal_threshold!(),
    );
    assert!(
        quote_fee_bps <= blast_fun::constants::basis_points_denominator!(),
        blast_fun::errors::invalid_quote_fee_bps!(),
    );
    assert!(
        meme_fee_bps <= blast_fun::constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_fee_bps!(),
    );
    assert!(
        max_burn_bps <= blast_fun::constants::basis_points_denominator!(),
        blast_fun::errors::invalid_max_burn_bps!(),
    );
    assert!(meme_in_gross > 0, blast_fun::errors::zero_trade_input!());

    let meme_fee = mul_div_up(
        meme_in_gross,
        meme_fee_bps,
        blast_fun::constants::basis_points_denominator!(),
    );
    let meme_in_after_fee = meme_in_gross - meme_fee;
    assert!(meme_in_after_fee > 0, blast_fun::errors::zero_trade_output!());

    let progress_bps = if (real_quote >= terminal_threshold) {
        blast_fun::constants::basis_points_denominator!()
    } else {
        mul_div_down(
            real_quote,
            blast_fun::constants::basis_points_denominator!(),
            terminal_threshold,
        )
    };
    let burn_bps = mul_div_down(
        max_burn_bps,
        progress_bps,
        blast_fun::constants::basis_points_denominator!(),
    );
    let meme_burned = mul_div_up(
        meme_in_after_fee,
        burn_bps,
        blast_fun::constants::basis_points_denominator!(),
    );
    let meme_in_effective = meme_in_after_fee - meme_burned;
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
    let quote_fee = mul_div_up(
        quote_out_gross,
        quote_fee_bps,
        blast_fun::constants::basis_points_denominator!(),
    );
    let quote_out_net = quote_out_gross - quote_fee;
    assert!(quote_out_net > 0, blast_fun::errors::zero_trade_output!());

    (
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        meme_burned,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve_after,
        real_quote - quote_out_gross,
    )
}

// === Private Functions ===

/// Multiplies in u256 and rounds the quotient toward zero.
fun mul_div_down(
    multiplicand: u64,
    multiplier: u64,
    denominator: u64,
): u64 {
    (
        ((multiplicand as u256) * (multiplier as u256)) / (denominator as u256)
    ) as u64
}

/// Multiplies in u256 and rounds the quotient toward positive infinity.
fun mul_div_up(
    multiplicand: u64,
    multiplier: u64,
    denominator: u64,
): u64 {
    ((multiplicand as u256) * (multiplier as u256))
        .div_ceil(denominator as u256) as u64
}
