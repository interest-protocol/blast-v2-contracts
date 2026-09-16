// `blast_leverage_series_one::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and stable codes pinned by tests.
#[allow(lint(abort_without_constant))]
/// Pure share, exposure, and maintenance-reserve accounting for one leverage Series.
///
/// The reserve is real collateral inside the bound venue account, but it is
/// excluded from shareholder NAV, share pricing, and target exposure. Mint and
/// redemption fees credit it. Only an exact negative funding settlement may
/// consume it during normal operation. Trading loss, slippage, liquidation,
/// ADL, and socialized loss are not funding costs and must not be passed to
/// `absorb_funding_cost` by the later venue adapter.
///
/// Package-visible operations take venue equity together with the recorded
/// reserve, or operate only on share supply and base exposure. Raw formulas
/// that accept already-derived shareholder NAV stay private so a future state
/// module cannot accidentally price shares or size exposure from venue equity.
///
/// This module owns no state and cannot authenticate a funding settlement.
/// The adapter must reconcile the authoritative venue funding accumulator and
/// its checkpoint before it passes one linear settlement into Series1. A
/// priced operation must reject venue equity below the stored reserve and use
/// a separate successful health transition for that loss state.
module blast_leverage_series_one::accounting_math;

use blast_leverage_series_one::constants;

// === Package API ===

/// Returns whether venue equity backs the complete recorded reserve.
///
/// Unlike `shareholder_nav`, this predicate never aborts. The later successful
/// health transition must use it to detect a reserve-underwater account before
/// it calls priced arithmetic. Backing alone is not enough for priced
/// arithmetic: equality leaves zero shareholder NAV, and every leverage or
/// sizing formula aborts on zero NAV. The health transition must also check
/// `is_shareholder_nav_positive` before it computes accounting leverage.
public(package) fun is_reserve_backed(
    venue_equity: u64,
    maintenance_reserve: u64,
): bool {
    maintenance_reserve <= venue_equity
}

/// Returns whether shareholder NAV is positive, without aborting.
///
/// A false result means the reserve is unbacked or exactly consumes venue
/// equity. In both cases health reports invalid priced state rather than call
/// `accounting_leverage_bps_up`, which aborts with the NAV code at zero.
public(package) fun is_shareholder_nav_positive(
    venue_equity: u64,
    maintenance_reserve: u64,
): bool {
    maintenance_reserve < venue_equity
}

/// Returns whether conservative accounting leverage is below a limit, without aborting.
///
/// `absolute_notional`, `venue_equity`, and `maintenance_reserve` use atomic
/// collateral units. `leverage_limit_bps` uses leverage basis points, where
/// 10,000 is 1x. The ratio rounds up before the strict comparison, matching
/// `accounting_leverage_bps_up`: equality is unsafe. An unbacked reserve, zero
/// shareholder NAV, or zero limit returns false. The widened numerator is at
/// most `u64::MAX * 10_000`, so every `u64` input is supported without
/// narrowing or aborting.
public(package) fun is_accounting_leverage_below_limit(
    absolute_notional: u64,
    venue_equity: u64,
    maintenance_reserve: u64,
    leverage_limit_bps: u64,
): bool {
    if (maintenance_reserve >= venue_equity || leverage_limit_bps == 0) {
        false
    } else {
        let nav = (venue_equity - maintenance_reserve) as u128;
        let leverage_bps = (absolute_notional as u128).mul_div_ceil(
            constants::basis_points_denominator!() as u128,
            nav,
        );

        leverage_bps < (leverage_limit_bps as u128)
    }
}

/// Returns whether base exposure exceeds the minimum operation size, without aborting.
///
/// Ordinary mints and non-flat redemptions both require a proportional
/// exposure change of at least `lot_size * min_exposure_lots`. When
/// `base_before` is at or below that product, a mint needs a contribution of
/// at least the complete shareholder NAV and no non-flat redemption can pass,
/// so the position is locked for every ordinary holder until it is closed
/// completely or exposure is reopened. A zero lot or lot multiple returns
/// false so the caller fails closed. A true result is necessary, not
/// sufficient, for a legal redemption. Initialization requires this minimum
/// exposure; ordinary redemptions enforce their exact proportional bounds.
public(package) fun is_exposure_above_minimum_operation(
    base_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): bool {
    lot_size > 0
        && min_exposure_lots > 0
        && (base_before as u128) > (lot_size as u128) * (min_exposure_lots as u128)
}

/// Returns shareholder NAV after excluding the complete maintenance reserve.
///
/// Both inputs and the result are atomic collateral units. Equality is valid
/// and returns zero for health and shutdown accounting. Minting, risk increase,
/// and ordinary redemption separately require positive shareholder NAV.
public(package) fun shareholder_nav(
    venue_equity: u64,
    maintenance_reserve: u64,
): u64 {
    assert!(
        is_reserve_backed(venue_equity, maintenance_reserve),
        blast_leverage_series_one::errors::maintenance_reserve_exceeds_equity!(),
    );

    venue_equity - maintenance_reserve
}

/// Splits one ceiling-rounded fee; its allocation remainder belongs to buffer.
public(package) fun fee_allocation(amount: u64, rate_bps: u64, admin_bps: u64): (u64, u64, u64) {
    assert!(admin_bps <= 10_000, blast_leverage_series_one::errors::invalid_fee_bps!());
    let fee = fee_up(amount, rate_bps);
    let admin = fee.mul_div(admin_bps, 10_000);
    (fee, admin, fee - admin)
}

/// Prices shares after the separately allocated fee has left shareholder NAV.
///
/// Returns `(nav_after, contribution, shares)`. `expected_contribution` is the
/// deposit net of the whole protocol fee, and the credited contribution is
/// `min(nav_after - nav_before, expected_contribution)`: a favorable fill
/// credits at most what the depositor paid and its excess stays with existing
/// holders, while a costly fill credits the actual rise (ADR 0084 D3). A
/// mint whose NAV does not rise still aborts as a nonpositive contribution.
public(package) fun allocated_mint_quote(
    equity_before: u64,
    equity_after: u64,
    reserve_before: u64,
    reserve_after: u64,
    expected_contribution: u64,
    supply: u64,
    minimum: u64,
): (u64, u64, u64) {
    let before = shareholder_nav(equity_before, reserve_before);
    let after = shareholder_nav(equity_after, reserve_after);
    assert!(after > before, blast_leverage_series_one::errors::nonpositive_contribution!());
    let contribution = (after - before).min(expected_contribution);
    let (shares, _) = mint_quote(contribution, before, supply);
    assert!(shares >= minimum, blast_leverage_series_one::errors::shares_out_below_minimum!());
    (after, contribution, shares)
}

/// Quotes a redemption and credits its reserve fee only after the gross is known.
///
/// Returns `(reserve_after, shares_after, nav_kept, proportional_claim,
/// gross, fee, net)`. Both NAV readings exclude `reserve_before`, so the
/// credited fee never re-enters share pricing. `proportional_claim` is
/// `nav_before - equity_keep`; `gross` is capped at it (ADR 0084 D3);
/// `nav_kept = nav_unwound - gross >= equity_keep` is the NAV that remains and
/// the only source of the required final venue equity.
///
/// The state transition still authenticates both equity readings, withdraws
/// exactly `net`, and proves the final venue equity atomically.
public(package) fun redemption_accounting_quote(
    shares_burned: u64,
    venue_equity_before: u64,
    venue_equity_unwound: u64,
    reserve_before: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64, u64, u64, u64, u64) {
    let nav_before = shareholder_nav(venue_equity_before, reserve_before);
    let nav_unwound = shareholder_nav(venue_equity_unwound, reserve_before);
    let (shares_after, equity_keep, gross, fee, net) = redemption_quote(
        shares_burned,
        nav_before,
        nav_unwound,
        shares_before,
        redeem_fee_bps,
    );
    let proportional_claim = nav_before - equity_keep;
    let nav_kept = nav_unwound - gross;
    let reserve_after = credit_fee(reserve_before, fee);

    (
        reserve_after,
        shares_after,
        nav_kept,
        proportional_claim,
        gross,
        fee,
        net,
    )
}

/// Returns accounting leverage using shareholder NAV, never venue equity.
public(package) fun accounting_leverage_bps_up(
    notional: u64,
    venue_equity: u64,
    maintenance_reserve: u64,
): u64 {
    leverage_bps_up(
        notional,
        shareholder_nav(venue_equity, maintenance_reserve),
    )
}

/// Returns target notional from shareholder NAV, never venue equity.
public(package) fun target_notional_from_equity_down(
    venue_equity: u64,
    maintenance_reserve: u64,
    target_leverage_bps: u64,
): u64 {
    target_notional_down(
        shareholder_nav(venue_equity, maintenance_reserve),
        target_leverage_bps,
    )
}

/// Returns a mint's proportional base delta using shareholder NAV.
public(package) fun mint_base_delta_from_equity_down(
    contribution: u64,
    base_before: u64,
    venue_equity_before: u64,
    reserve_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): u64 {
    mint_base_delta_down(
        contribution,
        base_before,
        shareholder_nav(venue_equity_before, reserve_before),
        lot_size,
        min_exposure_lots,
    )
}

/// Returns a mint's permitted base delta range using shareholder NAV.
public(package) fun mint_base_bounds_from_equity(
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    venue_equity_before: u64,
    reserve_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): (u64, u64) {
    mint_base_bounds(
        expected_contribution,
        actual_contribution,
        base_before,
        shareholder_nav(venue_equity_before, reserve_before),
        lot_size,
        min_exposure_lots,
    )
}

/// Rejects a mint's final absolute base outside its range using shareholder NAV.
public(package) fun assert_mint_base_within_bounds_from_equity(
    base_final: u64,
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    venue_equity_before: u64,
    reserve_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    assert_mint_base_within_bounds(
        base_final,
        expected_contribution,
        actual_contribution,
        base_before,
        shareholder_nav(venue_equity_before, reserve_before),
        lot_size,
        min_exposure_lots,
    );
}

/// Quotes how a negative funding settlement consumes the reserve.
///
/// ```text
/// absorbed      = min(maintenance_reserve, funding_cost)
/// reserve_after = maintenance_reserve - absorbed
/// uncovered     = funding_cost - absorbed
/// ```
///
/// Shareholder NAV falls only by `uncovered`. Zero cost is a no-op; positive
/// funding is credited by State, never passed here.
public(package) fun absorb_funding_cost(
    maintenance_reserve: u64,
    funding_cost: u64,
): (u64, u64, u64) {
    let absorbed = maintenance_reserve.min(funding_cost);

    (
        maintenance_reserve - absorbed,
        absorbed,
        funding_cost - absorbed,
    )
}

/// Returns `(min_final_base, max_final_base)` for a redemption unwind.
///
/// With `S1 = shares_before - shares_burned`:
///
/// ```text
/// max_final_base = floor(base_before * S1 / shares_before)
/// required       = base_before - max_final_base
/// planned        = min(ceil_to_lot(required), base_before)
/// min_final_base = base_before - planned
/// ```
///
/// `max_final_base` is `Q_keep` (ADR 0064 I11): at least the proportional
/// exposure must close. `min_final_base` bounds over-reduction to below one
/// lot, and `required` must be at least `lot_size * min_exposure_lots`
/// unless the unwind reaches flat, so the over-reduction is also below
/// `1 / min_exposure_lots` of `required` (the redemption half of I26).
/// `required` is largest when all but one share burns; if that is still below
/// the minimum lot multiple, every non-flat redemption aborts and
/// `is_exposure_above_minimum_operation` reports the locked state.
///
/// Preconditions: `0 < shares_burned < shares_before`, positive `lot_size`
/// and `min_exposure_lots`. A flat Series returns `(0, 0)`. Guard order is the
/// share bound, `lot_size`, `min_exposure_lots`, then the minimum-lot bound.
/// The intermediate stays below `2^65` and is capped at `base_before`.
public(package) fun redemption_base_bounds(
    shares_burned: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): (u64, u64) {
    assert!(
        shares_burned > 0 && shares_burned < shares_before,
        blast_leverage_series_one::errors::invalid_share_amount!(),
    );
    assert!(
        lot_size > 0,
        blast_leverage_series_one::errors::invalid_lot_size!(),
    );
    assert!(
        min_exposure_lots > 0,
        blast_leverage_series_one::errors::invalid_min_exposure_lots!(),
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
        blast_leverage_series_one::errors::sub_lot_exposure_delta!(),
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
        blast_leverage_series_one::errors::redemption_under_reduced!(),
    );
    assert!(
        base_final >= min_final_base,
        blast_leverage_series_one::errors::redemption_over_reduced!(),
    );
}

// === Test Functions ===

/// Exposes the raw fee formula only to direct arithmetic tests.
#[test_only]
public(package) fun fee_up_for_testing(amount: u64, fee_bps: u64): u64 {
    fee_up(amount, fee_bps)
}

/// Exposes raw reserve credit only to direct arithmetic tests.
#[test_only]
public(package) fun credit_fee_for_testing(
    maintenance_reserve: u64,
    fee: u64,
): u64 {
    credit_fee(maintenance_reserve, fee)
}

/// Exposes the raw mint-share formula only to direct arithmetic tests.
#[test_only]
public(package) fun mint_quote_for_testing(
    contribution: u64,
    nav_before: u64,
    shares_before: u64,
): (u64, u64) {
    mint_quote(contribution, nav_before, shares_before)
}

/// Exposes the raw redemption-share formula only to direct arithmetic tests.
#[test_only]
public(package) fun redemption_quote_for_testing(
    shares_burned: u64,
    nav_before: u64,
    nav_unwound: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64, u64, u64) {
    redemption_quote(
        shares_burned,
        nav_before,
        nav_unwound,
        shares_before,
        redeem_fee_bps,
    )
}

/// Exposes raw accounting leverage only to direct arithmetic tests.
#[test_only]
public(package) fun leverage_bps_up_for_testing(notional: u64, nav: u64): u64 {
    leverage_bps_up(notional, nav)
}

/// Exposes raw target-notional sizing only to direct arithmetic tests.
#[test_only]
public(package) fun target_notional_down_for_testing(
    nav: u64,
    target_leverage_bps: u64,
): u64 {
    target_notional_down(nav, target_leverage_bps)
}

/// Exposes raw proportional mint sizing only to direct arithmetic tests.
#[test_only]
public(package) fun mint_base_delta_down_for_testing(
    contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): u64 {
    mint_base_delta_down(
        contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    )
}

/// Exposes raw mint bounds only to direct arithmetic tests.
#[test_only]
public(package) fun mint_base_bounds_for_testing(
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): (u64, u64) {
    mint_base_bounds(
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    )
}

/// Exposes the raw mint-bound assertion only to direct arithmetic tests.
#[test_only]
public(package) fun assert_mint_base_within_bounds_for_testing(
    base_final: u64,
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
) {
    assert_mint_base_within_bounds(
        base_final,
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_exposure_lots,
    );
}

// === Private Functions ===

/// Returns the reserve after crediting an exact mint or redemption fee.
///
/// A zero fee is a valid no-op. Overflow aborts with the package arithmetic
/// code instead of wrapping or silently narrowing.
fun credit_fee(maintenance_reserve: u64, fee: u64): u64 {
    maintenance_reserve
        .checked_add(fee)
        .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!())
}

/// Returns the fee retained on `amount` at `fee_bps`, rounding up.
///
/// `amount` and the result are atomic collateral units. `fee_bps` is a rate on
/// the 10,000 basis-point denominator and must stay below it, so
/// `fee <= amount` always holds and a subtraction of the fee cannot underflow.
/// The returned amount must be credited to the separately accounted
/// maintenance reserve. It is excluded from shareholder NAV. A zero rate is
/// the only fee-free result. One atomic unit at any positive rate still pays
/// one unit, and the intermediate `amount * fee_bps` stays below `2^78`.
fun fee_up(amount: u64, fee_bps: u64): u64 {
    assert!(amount > 0, blast_leverage_series_one::errors::zero_amount!());
    assert!(
        fee_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_fee_bps!(),
    );

    amount.mul_div_ceil(fee_bps, constants::basis_points_denominator!())
}

/// Quotes shares from a positive shareholder NAV contribution.
///
/// ```text
/// shares_out   = floor(shares_before * contribution / nav_before)
/// shares_after = shares_before + shares_out
/// ```
///
/// Flooring gives `nav_after / shares_after >= nav_before / shares_before`
/// (ADR 0064 I9). `allocated_mint_quote` derives the contribution with its
/// reserve checkpoint and is the production entry; this raw form stays
/// private with a test-only seam.
///
/// Guard order is `nav_before`, `shares_before`, `contribution`, then a zero
/// share result. `shares_before * contribution` stays below `2^128`; results
/// outside `u64` abort.
fun mint_quote(
    contribution: u64,
    nav_before: u64,
    shares_before: u64,
): (u64, u64) {
    assert!(nav_before > 0, blast_leverage_series_one::errors::invalid_nav!());
    assert!(
        shares_before > 0,
        blast_leverage_series_one::errors::invalid_share_supply!(),
    );
    assert!(
        contribution > 0,
        blast_leverage_series_one::errors::nonpositive_contribution!(),
    );

    let shares_out = narrow_to_u64(
        (shares_before as u128) * (contribution as u128) / (nav_before as u128),
    );
    assert!(
        shares_out > 0,
        blast_leverage_series_one::errors::zero_shares_out!(),
    );

    let shares_after = shares_before
        .checked_add(shares_out)
        .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!());

    (shares_out, shares_after)
}

/// Quotes a redemption from the burned shares, one valuation pair, and the supply.
///
/// With `S1 = shares_before - shares_burned`:
///
/// ```text
/// equity_keep = ceil(nav_before * S1 / shares_before)
/// gross       = min(nav_unwound, nav_before) - equity_keep
/// fee         = ceil(gross * redeem_fee_bps / 10_000)
/// net         = gross - fee
/// ```
///
/// Rounding `equity_keep` up gives `equity_keep / S1 >= nav_before /
/// shares_before` (ADR 0064 I10); capping the gross at the proportional
/// claim keeps a favorable unwind with the remaining holders (ADR 0084 D3).
/// `redemption_accounting_quote` pins the checkpoint and credits the fee.
///
/// Preconditions: positive `nav_before`, `0 < shares_burned < shares_before`,
/// a fee rate below 10,000, `min(nav_unwound, nav_before) > equity_keep`, and
/// a positive net. Guard order is `nav_before`, the share bound, the fee rate,
/// the gross, then the net. `nav_before * S1` stays below `2^128` and
/// `equity_keep <= nav_before`.
fun redemption_quote(
    shares_burned: u64,
    nav_before: u64,
    nav_unwound: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64, u64, u64) {
    assert!(nav_before > 0, blast_leverage_series_one::errors::invalid_nav!());
    assert!(
        shares_burned > 0 && shares_burned < shares_before,
        blast_leverage_series_one::errors::invalid_share_amount!(),
    );
    assert!(
        redeem_fee_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_fee_bps!(),
    );

    let shares_after = shares_before - shares_burned;
    let equity_keep = nav_before.mul_div_ceil(shares_after, shares_before);
    let claimable = nav_unwound.min(nav_before);
    assert!(
        claimable > equity_keep,
        blast_leverage_series_one::errors::nonpositive_gross!(),
    );

    let gross = claimable - equity_keep;
    let fee = fee_up(gross, redeem_fee_bps);
    let net = gross - fee;
    assert!(net > 0, blast_leverage_series_one::errors::zero_net_payout!());

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
fun leverage_bps_up(notional: u64, nav: u64): u64 {
    assert!(nav > 0, blast_leverage_series_one::errors::invalid_nav!());

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
fun target_notional_down(nav: u64, target_leverage_bps: u64): u64 {
    assert!(nav > 0, blast_leverage_series_one::errors::invalid_nav!());
    assert!(
        target_leverage_bps > 0,
        blast_leverage_series_one::errors::invalid_target_leverage_bps!(),
    );

    narrow_to_u64(
        (nav as u128) * (target_leverage_bps as u128)
            / (constants::basis_points_denominator!() as u128),
    )
}

/// Returns the absolute base a mint must add, rounded down to whole lots.
///
/// The proportional target is `floor(base_before * contribution / nav_before)`
/// rounded down to `lot_size`, so the new cohort never buys more exposure than
/// it funds; the sub-lot remainder stays unopened. The Series sizes the order
/// from the expected contribution and re-applies the formula to the actual
/// one through `assert_mint_base_within_bounds`.
///
/// A target below `lot_size * min_exposure_lots` aborts, so the unopened
/// remainder is below `1 / min_exposure_lots` of the target: the mint half of
/// the cumulative-drift bound (ADR 0064 I26). A flat position cannot be sized
/// proportionally; reopening from flat needs a separate primitive.
///
/// Guard order is `nav_before`, `base_before`, `lot_size`,
/// `min_exposure_lots`, then the minimum-lot bound, which also rejects a zero
/// rounded delta. Intermediates are `u128`; a target outside `u64` aborts.
fun mint_base_delta_down(
    contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_exposure_lots: u64,
): u64 {
    assert!(nav_before > 0, blast_leverage_series_one::errors::invalid_nav!());
    assert!(
        base_before > 0,
        blast_leverage_series_one::errors::invalid_base_exposure!(),
    );
    assert!(
        lot_size > 0,
        blast_leverage_series_one::errors::invalid_lot_size!(),
    );
    assert!(
        min_exposure_lots > 0,
        blast_leverage_series_one::errors::invalid_min_exposure_lots!(),
    );

    let proportional_base = narrow_to_u64(
        (base_before as u128) * (contribution as u128) / (nav_before as u128),
    );
    assert!(
        (proportional_base as u128) >= (lot_size as u128) * (min_exposure_lots as u128),
        blast_leverage_series_one::errors::sub_lot_exposure_delta!(),
    );

    proportional_base - proportional_base % lot_size
}

/// Returns `(min_delta, max_delta)` for a mint's absolute base change.
///
/// ```text
/// max_delta = mint_base_delta_down(expected_contribution)
/// min_delta = min(mint_base_delta_down(actual_contribution), max_delta)
/// ```
///
/// A full planned fill always passes; execution cost lowers the actual
/// contribution and admits a partial fill down to what it funds. Both
/// contributions pass the minimum-lot guard. The range does not bound
/// execution-cost over-exposure (a fill losing half the deposit from 2.0x
/// still admits the plan and lands at 2.67x); the post-trade leverage gate
/// and the user's slippage bound own that.
fun mint_base_bounds(
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
fun assert_mint_base_within_bounds(
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
        .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!());

    assert!(
        base_final <= max_final_base,
        blast_leverage_series_one::errors::mint_over_exposed!(),
    );
    assert!(
        base_final >= base_before + min_delta,
        blast_leverage_series_one::errors::mint_under_exposed!(),
    );
}

/// Narrows a wide intermediate to `u64` or aborts with the package overflow code.
fun narrow_to_u64(wide: u128): u64 {
    assert!(
        wide <= (std::u64::max_value!() as u128),
        blast_leverage_series_one::errors::arithmetic_overflow!(),
    );

    wide as u64
}
