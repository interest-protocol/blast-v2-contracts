// `blast_leverage_coins::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// Pure share, fee, leverage, and proportional-exposure arithmetic for one leverage Series.
///
/// Units: NAV, deposits, and payouts are atomic collateral units (USDC).
/// Shares are atomic Share units. Base amounts are absolute atomic venue base
/// units of the Series market; this module never encodes position direction.
/// Signed direction, reduce-only flags, and the final signed position check
/// belong to the later venue adapter (ADR 0064 I12 and I13).
/// Fee rates are basis points below 10,000. Leverage rates are basis points of
/// 1x on the same denominator without that bound, so `20_000` means 2x.
/// `min_exposure_lots` values are the Series' immutable minimum operation
/// size in live venue lots; the Series supplies them from its policy.
///
/// Every input is a `u64` and every product uses a `u128` or wider intermediate,
/// so a `u64` times a `u64` cannot wrap. Results that leave the `u64` range
/// abort with the package overflow code instead of narrowing silently.
///
/// This module owns no state, custody, authority, or lifecycle. It cannot
/// observe NAV, supply, maintenance reserve, or venue exposure; each caller
/// must supply shareholder NAV values taken from one canonical valuation and
/// settle funding exactly once beforehand.
module blast_leverage_coins::share_math;

use blast_leverage_coins::constants;

// === Package Functions ===

/// Returns the fee retained on `amount` at `fee_bps`, rounding up.
///
/// `amount` and the result are atomic collateral units. `fee_bps` is a rate on
/// the 10,000 basis-point denominator and must stay below it, so
/// `fee <= amount` always holds and a subtraction of the fee cannot underflow.
/// The returned amount must be credited to the separately accounted
/// maintenance reserve. It is excluded from shareholder NAV. A zero rate is
/// the only fee-free result. One atomic unit at any positive rate still pays
/// one unit, and the intermediate `amount * fee_bps` stays below `2^78`.
public(package) fun fee_up(amount: u64, fee_bps: u64): u64 {
    assert!(amount > 0, blast_leverage_coins::errors::zero_amount!());
    assert!(
        fee_bps < constants::basis_points_denominator!(),
        blast_leverage_coins::errors::invalid_fee_bps!(),
    );

    amount.mul_div_ceil(fee_bps, constants::basis_points_denominator!())
}

/// Quotes shares from an already-derived positive shareholder NAV contribution.
///
/// Returns `(shares_out, shares_after)` in atomic Share units:
///
/// ```text
/// shares_out   = floor(shares_before * contribution / nav_before)
/// shares_after = shares_before + shares_out
/// ```
///
/// `contribution` is `nav_after - nav_before`, where both values are
/// shareholder NAV from one canonical valuation pair and `nav_after` already
/// excludes the newly credited fee. `maintenance_math::mint_accounting_quote`
/// derives that contribution together with its reserve checkpoint and is the
/// production entry point; this formula stays package-visible for pure
/// composition and testing. Venue fees and slippage reduce the actual
/// contribution, so the depositor pays them. Flooring `shares_out` gives
/// `nav_after / shares_after >= nav_before / shares_before` (ADR 0064 I9).
///
/// Preconditions: positive `nav_before`, `shares_before`, and `contribution`.
/// A contribution too small to buy one atomic share aborts instead of minting
/// zero. Guard order is `nav_before`, `shares_before`, `contribution`, then
/// the share results.
///
/// `shares_before * contribution` stays below `2^128`; `shares_out` and
/// `shares_after` abort when they leave the `u64` range. This function proves
/// no proportional exposure change: pair it with `mint_base_delta_down` and
/// `assert_mint_base_within_bounds`.
public(package) fun mint_quote(
    contribution: u64,
    nav_before: u64,
    shares_before: u64,
): (u64, u64) {
    assert!(nav_before > 0, blast_leverage_coins::errors::invalid_nav!());
    assert!(
        shares_before > 0,
        blast_leverage_coins::errors::invalid_share_supply!(),
    );
    assert!(
        contribution > 0,
        blast_leverage_coins::errors::nonpositive_contribution!(),
    );

    let shares_out = narrow_to_u64(
        (shares_before as u128) * (contribution as u128) / (nav_before as u128),
    );
    assert!(
        shares_out > 0,
        blast_leverage_coins::errors::zero_shares_out!(),
    );

    let shares_after = shares_before
        .checked_add(shares_out)
        .destroy_or!(abort blast_leverage_coins::errors::arithmetic_overflow!());

    (shares_out, shares_after)
}

/// Quotes a redemption from the burned shares, the valuation pair, and the supply.
///
/// Returns `(shares_after, equity_keep, gross, fee, net)` in atomic Share and
/// atomic collateral units. With `S1 = shares_before - shares_burned`:
///
/// ```text
/// equity_keep = ceil(nav_before * S1 / shares_before)
/// gross       = nav_unwound - equity_keep
/// fee         = ceil(gross * redeem_fee_bps / 10_000)
/// net         = gross - fee
/// ```
///
/// `nav_unwound` is shareholder NAV after the proportional unwind and before
/// the payout or reserve credit, at the same valuation pair as `nav_before`.
/// Production state transitions must use
/// `maintenance_math::redemption_accounting_quote`, which pins that checkpoint
/// and credits the fee afterward. Final shareholder NAV is exactly
/// `equity_keep`. Rounding it up gives
/// `equity_keep / S1 >= nav_before / shares_before` (ADR 0064 I10).
///
/// Preconditions: positive `nav_before`, `0 < shares_burned < shares_before`, a
/// fee rate below 10,000, `nav_unwound > equity_keep`, and a positive net
/// payout. The function enforces the share bound directly; the future locked
/// seed makes the complete production supply unpresentable. A zero supply
/// cannot satisfy the bound and aborts with the share-amount code. Guard order
/// is `nav_before`, the share bound, the fee rate, the gross claim, then the net
/// payout. Every cheap check precedes the kept-equity computation.
///
/// `nav_before * S1` stays below `2^128` and `equity_keep <= nav_before`, so no
/// result can leave the `u64` range.
public(package) fun redemption_quote(
    shares_burned: u64,
    nav_before: u64,
    nav_unwound: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64, u64, u64) {
    assert!(nav_before > 0, blast_leverage_coins::errors::invalid_nav!());
    assert!(
        shares_burned > 0 && shares_burned < shares_before,
        blast_leverage_coins::errors::invalid_share_amount!(),
    );
    assert!(
        redeem_fee_bps < constants::basis_points_denominator!(),
        blast_leverage_coins::errors::invalid_fee_bps!(),
    );

    let shares_after = shares_before - shares_burned;
    let equity_keep = nav_before.mul_div_ceil(shares_after, shares_before);
    assert!(
        nav_unwound > equity_keep,
        blast_leverage_coins::errors::nonpositive_gross!(),
    );

    let gross = nav_unwound - equity_keep;
    let fee = fee_up(gross, redeem_fee_bps);
    let net = gross - fee;
    assert!(net > 0, blast_leverage_coins::errors::zero_net_payout!());

    (shares_after, equity_keep, gross, fee, net)
}

/// Returns accounting leverage in leverage basis points, rounding up.
///
/// `notional` is the absolute oracle-valued position notional and `nav` is
/// positive shareholder NAV, both in atomic collateral units. Rounding up keeps
/// an unsafe position from appearing safer than it is. A flat position returns
/// zero. This accounting ratio is not the venue margin ratio; ADR 0064 keeps
/// both as independent gates.
///
/// Supported bound: `ceil(notional * 10_000 / nav)` must fit in `u64`, so
/// ratios up to about `1.8 * 10^15` x are representable and anything above that
/// aborts with the overflow code. The intermediate stays below `2^78`.
public(package) fun leverage_bps_up(notional: u64, nav: u64): u64 {
    assert!(nav > 0, blast_leverage_coins::errors::invalid_nav!());

    narrow_to_u64(
        (notional as u128).mul_div_ceil(
            constants::basis_points_denominator!() as u128,
            nav as u128,
        ),
    )
}

/// Returns the target absolute notional for `target_leverage_bps`, rounding down.
///
/// `nav` and the result are atomic collateral units. Rounding down keeps the
/// planned exposure at or below the target, so the rounding remainder favors
/// safety. A one-unit NAV below `10_000 / target_leverage_bps` targets zero
/// notional. Preconditions: positive `nav` and positive target. The
/// intermediate `nav * target_leverage_bps` stays below `2^128`, and a result
/// outside the `u64` range aborts. The post-trade leverage and margin checks
/// remain authoritative; this pre-trade target is not a guarantee.
public(package) fun target_notional_down(nav: u64, target_leverage_bps: u64): u64 {
    assert!(nav > 0, blast_leverage_coins::errors::invalid_nav!());
    assert!(
        target_leverage_bps > 0,
        blast_leverage_coins::errors::invalid_target_leverage_bps!(),
    );

    narrow_to_u64(
        (nav as u128) * (target_leverage_bps as u128)
            / (constants::basis_points_denominator!() as u128),
    )
}

/// Returns the absolute base a mint must add, rounded down to whole lots.
///
/// `base_before` is the pre-mint absolute base, `nav_before` is the matching
/// pre-mint shareholder NAV, and `contribution` is the shareholder NAV credited
/// for the exposure being sized. Before the trade, the Series sizes its order
/// from the expected contribution `deposit - fee`. After the trade, it applies
/// the same formula to the actual contribution `nav_after - nav_before`
/// through `assert_mint_base_within_bounds`. The proportional target is
/// `floor(base_before * contribution / nav_before)`, rounded down to
/// `lot_size` so the venue can accept the order. Rounding down keeps the new
/// cohort from buying more exposure than it funds; the sub-lot remainder is
/// left unopened.
///
/// `min_exposure_lots` is the Series' immutable minimum operation size in
/// live lots. A proportional target below `lot_size * min_exposure_lots`
/// aborts, so the unopened remainder is always below `1 / min_exposure_lots`
/// of the target. That relative cap is the mint half of the cumulative-drift
/// bound in ADR 0064 I26: each legal mint multiplies accounting leverage by at
/// least `1 - contribution / ((nav_before + contribution) * min_exposure_lots)`,
/// so after any sequence leverage stays close to
/// `L0 * (N0 / N)^(1 / min_exposure_lots)` where `N` is the final NAV. With a
/// one-lot minimum that cap is one lot per mint and the bound is not useful;
/// the Series must supply a simulated value.
///
/// Preconditions: positive `nav_before`, `base_before`, `lot_size`, and
/// `min_exposure_lots`, and a proportional target of at least the minimum lot
/// multiple. Rounding down to lots is zero exactly when the target is below
/// one lot, so the single minimum-lot guard also rejects a zero rounded delta
/// and any dust mint. Guard order is `nav_before`, `base_before`, `lot_size`,
/// `min_exposure_lots`, then the minimum-lot bound.
///
/// `base_before * contribution` and `lot_size * min_exposure_lots` use `u128`
/// intermediates, and a proportional target outside the `u64` range aborts.
public(package) fun mint_base_delta_down(
    contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): u64 {
    assert!(nav_before > 0, blast_leverage_coins::errors::invalid_nav!());
    assert!(
        base_before > 0,
        blast_leverage_coins::errors::invalid_base_exposure!(),
    );
    assert!(
        lot_size > 0,
        blast_leverage_coins::errors::invalid_lot_size!(),
    );
    assert!(
        min_exposure_lots > 0,
        blast_leverage_coins::errors::invalid_min_exposure_lots!(),
    );

    let proportional_base = narrow_to_u64(
        (base_before as u128) * (contribution as u128) / (nav_before as u128),
    );
    assert!(
        (proportional_base as u128) >= (lot_size as u128) * (min_exposure_lots as u128),
        blast_leverage_coins::errors::sub_lot_exposure_delta!(),
    );

    proportional_base - proportional_base % lot_size
}

/// Returns the permitted absolute base delta range for a mint.
///
/// Returns `(min_delta, max_delta)`:
///
/// ```text
/// max_delta = mint_base_delta_down(expected_contribution)
/// min_delta = min(mint_base_delta_down(actual_contribution), max_delta)
/// ```
///
/// `expected_contribution` is the pre-trade `deposit - fee` that sized the
/// sealed order, and `actual_contribution` is the post-trade
/// `nav_after - nav_before` that prices the shares. A full fill of the planned
/// order always satisfies the range. When execution cost makes the actual
/// contribution smaller, the range admits a partial fill down to the exposure
/// the actual contribution funds. When a favorable fill makes it larger, the
/// cap keeps the range non-empty and demands the complete plan. Both
/// contributions pass the minimum-lot guard, so a mint whose actual credited
/// contribution is dust aborts even when its plan was not.
///
/// The range does not bound execution-cost over-exposure: `max_delta -
/// min_delta` grows with the venue cost the depositor paid. The Series' final
/// leverage gate and the user's slippage bound own that residual.
public(package) fun mint_base_bounds(
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): (u64, u64) {
    let max_delta = mint_base_delta_down(
        expected_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
    let actual_delta = mint_base_delta_down(
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );

    (actual_delta.min(max_delta), max_delta)
}

/// Rejects an actual final absolute base outside the mint range.
///
/// It derives both bounds from the same canonical inputs as
/// `mint_base_bounds`, so a caller cannot present a stale or mismatched pair.
/// A final base above `base_before + max_delta` opened more than the sealed
/// plan and aborts. A final base below `base_before + min_delta` bought shares
/// without the exposure the credited contribution funds and aborts. The upper
/// sum is checked for overflow; the lower sum cannot exceed it.
public(package) fun assert_mint_base_within_bounds(
    base_final: u64,
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    let (min_delta, max_delta) = mint_base_bounds(
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
    let max_final_base = base_before
        .checked_add(max_delta)
        .destroy_or!(abort blast_leverage_coins::errors::arithmetic_overflow!());

    assert!(
        base_final <= max_final_base,
        blast_leverage_coins::errors::mint_over_exposed!(),
    );
    assert!(
        base_final >= base_before + min_delta,
        blast_leverage_coins::errors::mint_under_exposed!(),
    );
}

/// Returns the permitted absolute final base range for a redemption unwind.
///
/// Returns `(min_final_base, max_final_base)`. With
/// `S1 = shares_before - shares_burned`:
///
/// ```text
/// max_final_base = floor(base_before * S1 / shares_before)
/// required       = base_before - max_final_base
/// planned        = min(ceil_to_lot(required), base_before)
/// min_final_base = base_before - planned
/// ```
///
/// `max_final_base` is the `Q_keep` of ADR 0064 I11: the redemption must remove
/// at least the proportional exposure, so the floor keeps the remaining holders
/// at or below their proportional risk. `min_final_base` bounds deliberate
/// over-reduction: the risk-reducing planned order rounds the required
/// reduction up to `lot_size` and is capped at flat, so
/// `max_final_base - min_final_base` is always below one lot. The flat cap can
/// bind only when `max_final_base` is itself below one lot, and it then makes
/// `min_final_base` zero.
///
/// `min_exposure_lots` is the Series' immutable minimum operation size in
/// live lots. Unless the redemption reaches flat, `required` must be at least
/// `lot_size * min_exposure_lots`, so the over-reduction is also below
/// `1 / min_exposure_lots` of `required`. That is the redemption half of the
/// cumulative-drift bound in ADR 0064 I26; without it a stream of dust
/// redemptions could each close a whole lot while burning almost no shares.
/// Together the two bounds give I26 a two-sided lot tolerance that every
/// partial fill must satisfy cumulatively.
///
/// Preconditions: `0 < shares_burned < shares_before`, positive `lot_size`,
/// and positive `min_exposure_lots`. A flat Series returns `(0, 0)` and must
/// stay flat. Guard order is the share bound, `lot_size`, `min_exposure_lots`,
/// then the minimum-lot bound. The reduction intermediate stays below `2^65`
/// and is capped at `base_before`, so no result can leave the `u64` range.
public(package) fun redemption_base_bounds(
    shares_burned: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): (u64, u64) {
    assert!(
        shares_burned > 0 && shares_burned < shares_before,
        blast_leverage_coins::errors::invalid_share_amount!(),
    );
    assert!(
        lot_size > 0,
        blast_leverage_coins::errors::invalid_lot_size!(),
    );
    assert!(
        min_exposure_lots > 0,
        blast_leverage_coins::errors::invalid_min_exposure_lots!(),
    );

    let max_final_base = base_before.mul_div(
        shares_before - shares_burned,
        shares_before,
    );
    let required_reduction = base_before - max_final_base;
    assert!(
        max_final_base == 0
            || (required_reduction as u128)
                >= (lot_size as u128) * (min_exposure_lots as u128),
        blast_leverage_coins::errors::sub_lot_exposure_delta!(),
    );

    let planned_reduction = (
        (required_reduction as u128).div_ceil(lot_size as u128) * (lot_size as u128),
    ).min(base_before as u128) as u64;

    (base_before - planned_reduction, max_final_base)
}

/// Rejects an actual final absolute base outside the redemption bounds.
///
/// It derives both bounds from the same canonical inputs as
/// `redemption_base_bounds`, so a caller cannot present a stale or mismatched
/// pair. A final base above `max_final_base` leaves the remaining holders above
/// their proportional exposure and aborts, which makes every partial-fill
/// condition cumulative: a fill that does not reach `Q_keep` fails the complete
/// redemption. A final base below `min_final_base` over-reduces by a lot or
/// more without reaching flat and also aborts.
public(package) fun assert_redemption_base_within_bounds(
    base_final: u64,
    shares_burned: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    let (min_final_base, max_final_base) = redemption_base_bounds(
        shares_burned,
        base_before,
        shares_before,
        lot_size,
        min_exposure_lots,
    );

    assert!(
        base_final <= max_final_base,
        blast_leverage_coins::errors::redemption_under_reduced!(),
    );
    assert!(
        base_final >= min_final_base,
        blast_leverage_coins::errors::redemption_over_reduced!(),
    );
}

// === Private Functions ===

/// Narrows a wide intermediate to `u64` or aborts with the package overflow code.
fun narrow_to_u64(wide: u128): u64 {
    assert!(
        wide <= (std::u64::max_value!() as u128),
        blast_leverage_coins::errors::arithmetic_overflow!(),
    );

    wide as u64
}
