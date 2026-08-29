// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Integer accounting for blastSUI shares, the redemption fee, and native pool-token rates.
///
/// All inputs are atomic MIST, atomic share units, or native pool tokens held
/// in `u64`. Products use the framework `u128` intermediates of `mul_div` and
/// `mul_div_ceil`; every result is a real MIST, share, or pool-token amount,
/// bounded by total network SUI under the vault invariants (blast assets are
/// always at least the supply, pool rates start one-to-one), so the `u64`
/// narrowing cannot overflow on any reachable input.
module blast_sui::math;

use blast_sui::constants;

// === Package Functions ===

/// Returns blastSUI shares for a SUI deposit into blast custody, rounding down.
///
/// The bootstrap mints one share per MIST directly in `vault::create` and
/// locks that supply forever, so this quote always prices against positive
/// existing supply and assets. It preserves the current assets-per-share, so
/// the result never exceeds `deposit` while assets are at least the supply.
/// Remainders stay with existing holders. A zero supply cannot mint: it yields
/// zero shares and aborts.
public(package) fun blast_shares_out_down(
    deposit: u64,
    blast_assets: u64,
    blast_supply: u64,
): u64 {
    assert!(deposit > 0, blast_sui::errors::zero_amount!());
    assert!(blast_assets > 0, blast_sui::errors::blast_assets_depleted!());

    let shares = deposit.mul_div(blast_supply, blast_assets);
    assert!(shares > 0, blast_sui::errors::zero_blast_shares!());

    shares
}

/// Returns the gross SUI claim of blastSUI shares on blast custody, rounding down.
///
/// `shares` never reaches `blast_supply` in production because the locked seed
/// shares are never presented; the bound is kept as the supply invariant.
public(package) fun blast_gross_sui_out_down(
    shares: u64,
    blast_assets: u64,
    blast_supply: u64,
): u64 {
    assert!(shares > 0, blast_sui::errors::zero_amount!());
    assert!(shares <= blast_supply, blast_sui::errors::invalid_share_amount!());
    assert!(blast_assets > 0, blast_sui::errors::blast_assets_depleted!());

    let gross_sui = shares.mul_div(blast_assets, blast_supply);
    assert!(gross_sui > 0, blast_sui::errors::zero_sui_redemption!());

    gross_sui
}

/// Returns the redemption fee at `redeem_fee_bps`, rounding up to the next MIST.
///
/// `redeem_fee_bps` is at most `max_redeem_fee_bps` (100), so the fee never
/// exceeds one percent of `gross_sui`; a zero rate yields a zero fee, which is
/// the only fee-free user redemption.
public(package) fun blast_redeem_fee_up(gross_sui: u64, redeem_fee_bps: u64): u64 {
    assert!(gross_sui > 0, blast_sui::errors::zero_amount!());

    gross_sui.mul_div_ceil(redeem_fee_bps, constants::basis_points_denominator!())
}

/// Returns `(gross_sui, retained_fee, net_sui)` for a blastSUI redemption.
///
/// The gross claim is the floor pro-rata share of blast custody. Every
/// redemption pays the live fee, rounded up, which stays in blast custody for
/// the remaining holders; the locked seed supply guarantees that some remain.
public(package) fun blast_redemption_quote(
    shares: u64,
    blast_assets: u64,
    blast_supply: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64) {
    let gross_sui = blast_gross_sui_out_down(shares, blast_assets, blast_supply);
    let fee = blast_redeem_fee_up(gross_sui, redeem_fee_bps);

    (gross_sui, fee, gross_sui - fee)
}

/// Mirrors native `get_sui_amount`: floor, with one MIST per token at an empty rate.
public(package) fun sui_at_rate_down(pool_tokens: u64, rate_sui: u64, rate_pool_tokens: u64): u64 {
    if (rate_sui == 0 || rate_pool_tokens == 0) return pool_tokens;

    pool_tokens.mul_div(rate_sui, rate_pool_tokens)
}

/// Mirrors native `get_token_amount`: pool tokens worth at most `sui_amount` at the rate.
public(package) fun pool_tokens_at_rate_down(
    sui_amount: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
): u64 {
    if (rate_sui == 0 || rate_pool_tokens == 0) return sui_amount;

    sui_amount.mul_div(rate_pool_tokens, rate_sui)
}

/// Maximum MIST that one StakedSui-to-pool-token conversion can lose at `rate`.
///
/// Native conversion floors pool tokens, so valuing those tokens back loses
/// less than one SUI-per-token unit. The ceiling is conservative. The native
/// empty rate is one-to-one and loses nothing.
public(package) fun fun_conversion_loss_bound_up(
    rate_sui: u64,
    rate_pool_tokens: u64,
): u64 {
    if (rate_sui == 0 || rate_pool_tokens == 0) return 0;

    rate_sui.div_ceil(rate_pool_tokens)
}

/// Active pool tokens worth at least `sui_amount` at the conservative valuation.
///
/// `active_sui / held` never exceeds the native rate, so the ceiling requests
/// enough tokens; the result is capped at `held`, and an empty valuation
/// requests every held token.
public(package) fun pool_tokens_for_sui_up(sui_amount: u64, held: u64, active_sui: u64): u64 {
    if (active_sui == 0) return held;

    sui_amount.mul_div_ceil(held, active_sui).min(held)
}
