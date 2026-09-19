// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Pure share, position, and maintenance-reserve accounting for one Vault.
///
/// The reserve is real collateral inside the bound venue account, but it is
/// excluded from shareholder NAV, share pricing, and target notional. Mint and
/// redemption fees credit it. Only an exact negative funding settlement may
/// consume it during normal operation. Trading loss, slippage, liquidation,
/// ADL, and socialized loss are not funding costs and must not be passed to
/// `absorb_funding_cost` by the later venue adapter.
///
/// Package-visible operations take venue equity together with the recorded
/// reserve, or operate only on share supply and base. Raw formulas
/// that accept already-derived shareholder NAV stay private so a future state
/// module cannot accidentally price shares or size the position from venue equity.
///
/// This module owns no state and cannot authenticate a funding settlement.
/// The adapter must reconcile the authoritative venue funding accumulator and
/// its checkpoint before it passes one linear settlement into core. A
/// priced operation must reject venue equity below the stored reserve and use
/// a separate successful health transition for that loss state.
module blast_boosts_core::accounting_math;

// === Package Functions ===

// --- Health ---

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
/// equity. In both cases health reports invalid priced state rather than run
/// priced arithmetic, which aborts with the NAV code at zero.
public(package) fun is_shareholder_nav_positive(
    venue_equity: u64,
    maintenance_reserve: u64,
): bool {
    maintenance_reserve < venue_equity
}

/// Returns whether conservative accounting leverage is below a limit, without aborting.
///
/// `notional`, `venue_equity`, and `maintenance_reserve` use atomic
/// collateral units. `max_leverage_bps` uses leverage basis points, where
/// 10,000 is 1x. The ratio rounds up before the strict comparison: equality
/// is unsafe. An unbacked reserve, zero shareholder NAV, or zero limit returns
/// false. The comparison stays wide, so every `u64` input is supported without
/// narrowing or aborting.
public(package) fun is_accounting_leverage_below_limit(
    notional: u64,
    venue_equity: u64,
    maintenance_reserve: u64,
    max_leverage_bps: u64,
): bool {
    is_shareholder_nav_positive(venue_equity, maintenance_reserve)
        && max_leverage_bps > 0
        && leverage_bps_up(notional, venue_equity - maintenance_reserve)
            < (max_leverage_bps as u128)
}

/// Returns whether base exceeds the minimum operation size, without aborting.
///
/// Ordinary mints and non-flat redemptions both require a proportional
/// order of at least `lot_size * min_order_lots`. When
/// `base_before` is at or below that product, a mint needs a contribution of
/// at least the complete shareholder NAV and no non-flat redemption can pass,
/// so the position is locked for every ordinary holder until it is closed
/// completely or the position is reopened. A zero lot or lot multiple returns
/// false so the caller fails closed. A true result is necessary, not
/// sufficient, for a legal redemption. Initialization requires this minimum
/// position; ordinary redemptions enforce their exact proportional bounds.
public(package) fun is_base_above_min_order(
    base_before: u64,
    lot_size: u64,
    min_order_lots: u64,
): bool {
    lot_size > 0
        && min_order_lots > 0
        && (base_before as u128) > (lot_size as u128) * (min_order_lots as u128)
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
        blast_boosts_core::errors::maintenance_reserve_exceeds_equity!(),
    );

    venue_equity - maintenance_reserve
}

// --- Fees ---

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
    assert!(amount > 0, blast_boosts_core::errors::zero_amount!());
    assert!(
        fee_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_fee_bps!(),
    );

    amount.mul_div_ceil(fee_bps, constants::basis_points_denominator!())
}

/// Returns the admin's share of a collected fee, rounding down.
///
/// `fee` and the result are atomic collateral units. `admin_share_bps` is a
/// rate on the 10,000 basis-point denominator and may equal it. Rounding down
/// leaves the allocation remainder with the maintenance reserve, so
/// `admin <= fee` always holds.
public(package) fun admin_share_down(fee: u64, admin_share_bps: u64): u64 {
    assert!(
        admin_share_bps <= constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_fee_bps!(),
    );

    fee.mul_div(admin_share_bps, constants::basis_points_denominator!())
}

/// Splits one ceiling-rounded fee; its allocation remainder belongs to reserve.
public(package) fun fee_allocation(amount: u64, fee_bps: u64, admin_share_bps: u64): (u64, u64, u64) {
    let fee = fee_up(amount, fee_bps);
    let admin = admin_share_down(fee, admin_share_bps);

    (fee, admin, fee - admin)
}

/// Returns the reserve after crediting an exact mint or redemption fee.
///
/// A zero fee is a valid no-op. Overflow aborts with the package arithmetic
/// code instead of wrapping or silently narrowing.
fun credit_fee(maintenance_reserve: u64, fee: u64): u64 {
    maintenance_reserve
        .checked_add(fee)
        .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!())
}

// --- Mint ---

/// Quotes shares from an already-derived positive shareholder NAV contribution.
///
/// Returns `shares_out` in atomic Share units:
///
/// ```text
/// shares_out = floor(shares_before * contribution / nav_before)
/// ```
///
/// `contribution` is `nav_after - nav_before`, where both values are
/// shareholder NAV from one canonical price pair and `nav_after` already
/// excludes the newly credited fee. `accounting_math::allocated_mint_quote`
/// derives that contribution from the caller's reserve checkpoints and is the
/// production entry point; this raw formula stays private and has a test-only
/// seam for direct arithmetic checks. Venue fees and slippage reduce the
/// actual contribution, so the depositor pays them. Flooring `shares_out` gives
/// `nav_after / (shares_before + shares_out) >= nav_before / shares_before`
/// (ADR 0064 I9).
///
/// Preconditions: positive `nav_before`, `shares_before`, and `contribution`.
/// A contribution too small to buy one atomic share aborts instead of minting
/// zero. Guard order is `nav_before`, `shares_before`, `contribution`, then
/// the share results.
///
/// `shares_before * contribution` stays below `2^128`; `shares_out` and the
/// final supply abort when they leave the `u64` range. This function proves
/// no proportional order: pair it with `mint_base_to_buy_down` and
/// `assert_mint_base_within_bounds`.
fun mint_quote(
    contribution: u64,
    nav_before: u64,
    shares_before: u64,
): u64 {
    assert!(nav_before > 0, blast_boosts_core::errors::invalid_nav!());
    assert!(
        shares_before > 0,
        blast_boosts_core::errors::invalid_share_supply!(),
    );
    assert!(
        contribution > 0,
        blast_boosts_core::errors::nonpositive_contribution!(),
    );

    let shares_out = narrow_to_u64(
        (shares_before as u128) * (contribution as u128) / (nav_before as u128),
    );
    assert!(
        shares_out > 0,
        blast_boosts_core::errors::zero_shares_out!(),
    );
    assert!(
        shares_before.checked_add(shares_out).is_some(),
        blast_boosts_core::errors::arithmetic_overflow!(),
    );

    shares_out
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
    shares_before: u64,
    minimum_shares: u64,
): (u64, u64, u64) {
    let before = shareholder_nav(equity_before, reserve_before);
    let after = shareholder_nav(equity_after, reserve_after);
    assert!(after > before, blast_boosts_core::errors::nonpositive_contribution!());

    let contribution = (after - before).min(expected_contribution);
    let shares = mint_quote(contribution, before, shares_before);
    assert!(shares >= minimum_shares, blast_boosts_core::errors::shares_out_below_minimum!());

    (after, contribution, shares)
}

/// Returns the target absolute notional for `target_leverage_bps`, rounding down.
///
/// `nav` and the result are atomic collateral units. Rounding down keeps the
/// planned base at or below the target, so the rounding remainder favors
/// safety. A one-unit NAV below `10_000 / target_leverage_bps` targets zero
/// notional. Preconditions: positive `nav` and positive target. The
/// intermediate `nav * target_leverage_bps` stays below `2^128`, and a result
/// outside the `u64` range aborts. The post-trade leverage and margin checks
/// remain authoritative; this pre-trade target is not a guarantee.
public(package) fun target_notional_down(nav: u64, target_leverage_bps: u64): u64 {
    assert!(nav > 0, blast_boosts_core::errors::invalid_nav!());
    assert!(
        target_leverage_bps > 0,
        blast_boosts_core::errors::invalid_target_leverage_bps!(),
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
/// for the base being sized. Before the trade, the core sizes its order
/// from the expected contribution `deposit - fee`. After the trade, it applies
/// the same formula to the actual contribution `nav_after - nav_before`
/// through `assert_mint_base_within_bounds`. The proportional target is
/// `floor(base_before * contribution / nav_before)`, rounded down to
/// `lot_size` so the venue can accept the order. Rounding down keeps the new
/// cohort from buying more base than it funds; the sub-lot remainder is
/// left unopened.
///
/// `min_order_lots` is the core' immutable minimum operation size in
/// live lots. A proportional target below `lot_size * min_order_lots`
/// aborts, so the unopened remainder is always below `1 / min_order_lots`
/// of the target. That relative cap is the mint half of the cumulative-drift
/// bound in ADR 0064 I26: each legal mint multiplies accounting leverage by at
/// least `1 - contribution / ((nav_before + contribution) * min_order_lots)`,
/// so after any sequence leverage stays close to
/// `L0 * (N0 / N)^(1 / min_order_lots)` where `N` is the final NAV. With a
/// one-lot minimum that cap is one lot per mint and the bound is not useful;
/// the core must supply a simulated value.
///
/// Preconditions: positive `nav_before`, `base_before`, `lot_size`, and
/// `min_order_lots`, and a proportional target of at least the minimum lot
/// multiple. A flat position cannot be sized proportionally, so once
/// `base_before` reaches zero with live shares no mint can pass this function;
/// reopening the position from flat needs a separate core primitive. Rounding down to lots is zero exactly when the target is below
/// one lot, so the single minimum-lot guard also rejects a zero rounded order
/// and any dust mint. Guard order is `nav_before`, `base_before`, `lot_size`,
/// `min_order_lots`, then the minimum-lot bound.
///
/// `base_before * contribution` and `lot_size * min_order_lots` use `u128`
/// intermediates, and a proportional target outside the `u64` range aborts.
public(package) fun mint_base_to_buy_down(
    contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_order_lots: u64,
): u64 {
    assert!(nav_before > 0, blast_boosts_core::errors::invalid_nav!());
    assert!(
        base_before > 0,
        blast_boosts_core::errors::invalid_base!(),
    );
    assert!(
        lot_size > 0,
        blast_boosts_core::errors::invalid_lot_size!(),
    );
    assert!(
        min_order_lots > 0,
        blast_boosts_core::errors::invalid_min_order_lots!(),
    );

    let proportional_base = narrow_to_u64(
        (base_before as u128) * (contribution as u128) / (nav_before as u128),
    );
    assert!(
        (proportional_base as u128) >= (lot_size as u128) * (min_order_lots as u128),
        blast_boosts_core::errors::order_below_min_lots!(),
    );

    proportional_base - proportional_base % lot_size
}

/// Returns the permitted absolute base order range for a mint.
///
/// Returns `(min_order_base, max_order_base)`:
///
/// ```text
/// max_order_base = mint_base_to_buy_down(expected_contribution)
/// min_order_base = min(mint_base_to_buy_down(actual_contribution), max_order_base)
/// ```
///
/// `expected_contribution` is the pre-trade `deposit - fee` that sized the
/// sealed order, and `actual_contribution` is the post-trade
/// `nav_after - nav_before` that prices the shares. A full fill of the planned
/// order always satisfies the range. When execution cost makes the actual
/// contribution smaller, the range admits a partial fill down to the base
/// the actual contribution funds. When a favorable fill makes it larger, the
/// cap keeps the range non-empty and demands the complete plan. Both
/// contributions pass the minimum-lot guard, so a mint whose actual credited
/// contribution is dust aborts even when its plan was not.
///
/// The range does not bound execution-cost over-buying: `max_order_base -
/// min_order_base` grows with the venue cost the depositor paid, and the admitted
/// band is wide. From 2.0x with a deposit equal to NAV, a fill that loses half
/// the deposit to execution still admits the complete plan and leaves the
/// pool at 2.67x; at 95 percent loss it admits 3.81x. The core' post-trade
/// leverage gate is therefore a hard release blocker, not an optional check,
/// and the user's slippage bound owns the rest.
fun mint_base_bounds(
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_order_lots: u64,
): (u64, u64) {
    let max_order_base = mint_base_to_buy_down(
        expected_contribution,
        base_before,
        nav_before,
        lot_size,
        min_order_lots,
    );
    let actual_order_base = mint_base_to_buy_down(
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_order_lots,
    );

    (actual_order_base.min(max_order_base), max_order_base)
}

/// Rejects an actual final absolute base outside the mint range.
///
/// It derives both bounds from the same canonical inputs as
/// `mint_base_bounds`, so a caller cannot present a stale or mismatched pair.
/// A final base above `base_before + max_order_base` opened more than the sealed
/// plan and aborts. A final base below `base_before + min_order_base` bought shares
/// without the position the credited contribution funds and aborts. The upper
/// sum is checked for overflow; the lower sum cannot exceed it.
public(package) fun assert_mint_base_within_bounds(
    base_after: u64,
    expected_contribution: u64,
    actual_contribution: u64,
    base_before: u64,
    nav_before: u64,
    lot_size: u64,
    min_order_lots: u64,
) {
    let (min_order_base, max_order_base) = mint_base_bounds(
        expected_contribution,
        actual_contribution,
        base_before,
        nav_before,
        lot_size,
        min_order_lots,
    );
    let max_final_base = base_before
        .checked_add(max_order_base)
        .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());

    assert!(
        base_after <= max_final_base,
        blast_boosts_core::errors::mint_base_above_bound!(),
    );
    assert!(
        base_after >= base_before + min_order_base,
        blast_boosts_core::errors::mint_base_below_bound!(),
    );
}

// --- Redemption ---

/// Quotes a redemption from the burned shares, the price pair, and the supply.
///
/// Returns `(gross, fee, net)` in atomic collateral units. With
/// `S1 = shares_before - shares_to_redeem`:
///
/// ```text
/// equity_keep = ceil(nav_before * S1 / shares_before)
/// gross       = min(nav_after_sell, nav_before) - equity_keep
/// fee         = ceil(gross * redeem_fee_bps / 10_000)
/// net         = gross - fee
/// ```
///
/// `nav_after_sell` is shareholder NAV after the proportional sell and before
/// the payout or reserve credit, at the same price pair as `nav_before`.
/// Production state transitions must use
/// `accounting_math::redemption_accounting_quote`, which pins that checkpoint
/// and credits the fee afterward. The gross is capped at the proportional
/// claim `nav_before - equity_keep`: a favorable sell pays exactly the
/// claim and its excess stays with the remaining holders (ADR 0084 D3).
/// Final shareholder NAV is `nav_after_sell - gross`, at least `equity_keep`.
/// Rounding the kept equity up gives
/// `equity_keep / S1 >= nav_before / shares_before` (ADR 0064 I10).
///
/// Preconditions: positive `nav_before`, `0 < shares_to_redeem < shares_before`, a
/// fee rate below 10,000, `min(nav_after_sell, nav_before) > equity_keep`, and a
/// positive net payout. The function enforces the share bound directly; the future locked
/// seed makes the complete production supply unpresentable. A zero supply
/// cannot satisfy the bound and aborts with the share-amount code. Guard order
/// is `nav_before`, the share bound, the fee rate, the gross claim, then the net
/// payout. Every cheap check precedes the kept-equity computation.
///
/// `nav_before * S1` stays below `2^128` and `equity_keep <= nav_before`, so no
/// result can leave the `u64` range.
fun redemption_quote(
    shares_to_redeem: u64,
    nav_before: u64,
    nav_after_sell: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64) {
    assert!(nav_before > 0, blast_boosts_core::errors::invalid_nav!());
    assert!(
        shares_to_redeem > 0 && shares_to_redeem < shares_before,
        blast_boosts_core::errors::invalid_share_amount!(),
    );
    assert!(
        redeem_fee_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_fee_bps!(),
    );

    let equity_keep = nav_before.mul_div_ceil(shares_before - shares_to_redeem, shares_before);
    let claimable = nav_after_sell.min(nav_before);
    assert!(
        claimable > equity_keep,
        blast_boosts_core::errors::nonpositive_gross!(),
    );

    let gross = claimable - equity_keep;
    let fee = fee_up(gross, redeem_fee_bps);
    let net = gross - fee;
    assert!(net > 0, blast_boosts_core::errors::zero_net_payout!());

    (gross, fee, net)
}

/// Quotes a redemption and credits its reserve fee at the correct checkpoint.
///
/// Returns `(reserve_after, nav_kept, fee, net)`. Both pre-redemption and
/// post-sell shareholder NAV exclude `reserve_before`. Only after the gross
/// claim is known does this function credit the fee. Thus the credited fee
/// cannot re-enter the current or a later redemption's share pricing base.
///
/// The gross is `min(nav_after_sell, nav_before) - equity_keep`, so it never
/// exceeds the redeemer's proportional claim `nav_before - equity_keep`: a
/// sell that costs the core pays less, and one that gains keeps the gain
/// with the remaining holders (ADR 0084 D3). `nav_kept` is the shareholder
/// NAV that actually remains, `nav_after_sell - gross`, which is at least
/// `equity_keep`; the core derives the required final venue equity from it
/// and never from a NAV of its own.
///
/// The later state transition must still authenticate both venue-equity values,
/// withdraw exactly `net`, and verify final venue equity and reserve atomically.
public(package) fun redemption_accounting_quote(
    shares_to_redeem: u64,
    venue_equity_before: u64,
    venue_equity_after_sell: u64,
    reserve_before: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64, u64) {
    let nav_before = shareholder_nav(venue_equity_before, reserve_before);
    let nav_after_sell = shareholder_nav(venue_equity_after_sell, reserve_before);
    let (gross, fee, net) = redemption_quote(
        shares_to_redeem,
        nav_before,
        nav_after_sell,
        shares_before,
        redeem_fee_bps,
    );

    (credit_fee(reserve_before, fee), nav_after_sell - gross, fee, net)
}

/// Returns the permitted absolute final base range for a redemption sell.
///
/// Returns `(min_final_base, max_final_base)`. With
/// `S1 = shares_before - shares_to_redeem`:
///
/// ```text
/// max_final_base = floor(base_before * S1 / shares_before)
/// required       = base_before - max_final_base
/// planned        = min(ceil_to_lot(required), base_before)
/// min_final_base = base_before - planned
/// ```
///
/// `max_final_base` is the `Q_keep` of ADR 0064 I11: the redemption must remove
/// at least the proportional position, so the floor keeps the remaining holders
/// at or below their proportional risk. `min_final_base` bounds deliberate
/// over-reduction: the risk-reducing planned order rounds the required
/// reduction up to `lot_size` and is capped at flat, so
/// `max_final_base - min_final_base` is always below one lot. The flat cap can
/// bind only when `max_final_base` is itself below one lot, and it then makes
/// `min_final_base` zero.
///
/// `min_order_lots` is the core' immutable minimum operation size in
/// live lots. Unless the redemption reaches flat, `required` must be at least
/// `lot_size * min_order_lots`, so the over-reduction is also below
/// `1 / min_order_lots` of `required`. That is the redemption half of the
/// cumulative-drift bound in ADR 0064 I26; without it a stream of dust
/// redemptions could each close a whole lot while burning almost no shares.
/// Together the two bounds give I26 a two-sided lot slippage that every
/// partial fill must satisfy cumulatively.
///
/// The minimum has a sharp lock condition. `required` is largest when the
/// redemption burns all but one share, where it equals
/// `base_before - floor(base_before / shares_before)`. When that value is below
/// `lot_size * min_order_lots` and `base_before >= shares_before`, no burn
/// count is legal and every non-flat redemption aborts; the flat exemption is
/// unreachable because a proportional keep of zero needs
/// `base_before < shares_before`. `is_base_above_min_order` is the
/// non-aborting predicate the health transition uses to observe that state.
///
/// Preconditions: `0 < shares_to_redeem < shares_before`, positive `lot_size`,
/// and positive `min_order_lots`. A flat core returns `(0, 0)` and must
/// stay flat. Guard order is the share bound, `lot_size`, `min_order_lots`,
/// then the minimum-lot bound. The reduction intermediate stays below `2^65`
/// and is capped at `base_before`, so no result can leave the `u64` range.
public(package) fun redemption_base_bounds(
    shares_to_redeem: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_order_lots: u64,
): (u64, u64) {
    assert!(
        shares_to_redeem > 0 && shares_to_redeem < shares_before,
        blast_boosts_core::errors::invalid_share_amount!(),
    );
    assert!(
        lot_size > 0,
        blast_boosts_core::errors::invalid_lot_size!(),
    );
    assert!(
        min_order_lots > 0,
        blast_boosts_core::errors::invalid_min_order_lots!(),
    );

    let max_final_base = base_before.mul_div(
        shares_before - shares_to_redeem,
        shares_before,
    );
    let required_reduction = base_before - max_final_base;
    assert!(
        max_final_base == 0
            || (required_reduction as u128)
                >= (lot_size as u128) * (min_order_lots as u128),
        blast_boosts_core::errors::order_below_min_lots!(),
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
/// their proportional position and aborts, which makes every partial-fill
/// condition cumulative: a fill that does not reach `Q_keep` fails the complete
/// redemption. A final base below `min_final_base` over-reduces by a lot or
/// more without reaching flat and also aborts.
public(package) fun assert_redemption_base_within_bounds(
    base_after: u64,
    shares_to_redeem: u64,
    base_before: u64,
    shares_before: u64,
    lot_size: u64,
    min_order_lots: u64,
) {
    let (min_final_base, max_final_base) = redemption_base_bounds(
        shares_to_redeem,
        base_before,
        shares_before,
        lot_size,
        min_order_lots,
    );

    assert!(
        base_after <= max_final_base,
        blast_boosts_core::errors::redemption_under_reduced!(),
    );
    assert!(
        base_after >= min_final_base,
        blast_boosts_core::errors::redemption_over_reduced!(),
    );
}

// --- Funding ---

/// Quotes how an exact negative funding settlement consumes the reserve.
///
/// Returns `(reserve_after, absorbed, uncovered)` in atomic collateral units:
///
/// ```text
/// absorbed      = min(maintenance_reserve, funding_cost)
/// reserve_after = maintenance_reserve - absorbed
/// uncovered     = funding_cost - absorbed
/// ```
///
/// Thus both conservation identities hold exactly. If venue equity has already
/// fallen by `funding_cost`, shareholder NAV falls only by `uncovered`. A zero
/// cost is a valid no-op. Positive funding is not a cost and must not call this
/// function; State credits positive net funding to the reserve instead.
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

// === Private Functions ===

/// Returns accounting leverage in leverage basis points, rounding up.
///
/// `notional` is the absolute oracle-valued position notional and `nav` is
/// positive shareholder NAV, both in atomic collateral units. Rounding up keeps
/// an unsafe position from appearing safer than it is. A flat position returns
/// zero. This accounting ratio is not the venue margin ratio; ADR 0064 keeps
/// both as independent gates. The caller guarantees a positive `nav`; the
/// result stays below `2^78` and is compared wide, never narrowed.
fun leverage_bps_up(notional: u64, nav: u64): u128 {
    (notional as u128).mul_div_ceil(
        constants::basis_points_denominator!() as u128,
        nav as u128,
    )
}

/// Narrows a wide intermediate to `u64` or aborts with the package overflow code.
fun narrow_to_u64(wide: u128): u64 {
    assert!(
        wide <= (std::u64::max_value!() as u128),
        blast_boosts_core::errors::arithmetic_overflow!(),
    );

    wide as u64
}

// === Test-Only Functions ===

#[test_only]
public fun fee_up_for_testing(amount: u64, fee_bps: u64): u64 {
    fee_up(amount, fee_bps)
}

#[test_only]
public fun credit_fee_for_testing(maintenance_reserve: u64, fee: u64): u64 {
    credit_fee(maintenance_reserve, fee)
}

#[test_only]
public fun mint_quote_for_testing(contribution: u64, nav_before: u64, shares_before: u64): u64 {
    mint_quote(contribution, nav_before, shares_before)
}

#[test_only]
public fun mint_base_bounds_for_testing(expected_contribution: u64, actual_contribution: u64, base_before: u64, nav_before: u64, lot_size: u64, min_order_lots: u64): (u64, u64) {
    mint_base_bounds(expected_contribution, actual_contribution, base_before, nav_before, lot_size, min_order_lots)
}

#[test_only]
public fun redemption_quote_for_testing(shares_to_redeem: u64, nav_before: u64, nav_after_sell: u64, shares_before: u64, redeem_fee_bps: u64): (u64, u64, u64) {
    redemption_quote(shares_to_redeem, nav_before, nav_after_sell, shares_before, redeem_fee_bps)
}

// === Imports ===

use blast_boosts_core::constants;
