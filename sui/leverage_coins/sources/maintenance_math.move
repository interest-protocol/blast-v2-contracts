// `blast_leverage_coins::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// Pure accounting for the funding-only maintenance reserve of one leverage Series.
///
/// The reserve is real collateral inside the bound venue account, but it is
/// excluded from shareholder NAV, share pricing, and target exposure. Mint and
/// redemption fees credit it. Only an exact negative funding settlement may
/// consume it during normal operation. Trading loss, slippage, liquidation,
/// ADL, and socialized loss are not funding costs and must not be passed to
/// `absorb_funding_cost` by the later venue adapter.
///
/// This module owns no state and cannot authenticate a funding settlement. The
/// later Series transition must reconcile the authoritative venue funding accumulator,
/// mutate the reserve and checkpoint atomically, and call each settlement
/// exactly once. A priced operation must reject venue equity below the stored
/// reserve and use a separate successful health transition for that loss state.
module blast_leverage_coins::maintenance_math;

use blast_leverage_coins::share_math;

// === Package Functions ===

/// Returns whether venue equity backs the complete recorded reserve.
///
/// Unlike `shareholder_nav`, this predicate never aborts. The later successful
/// health transition must use it to detect a reserve-underwater account before
/// it calls priced arithmetic.
public(package) fun is_reserve_backed(
    venue_equity: u64,
    maintenance_reserve: u64,
): bool {
    maintenance_reserve <= venue_equity
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
        blast_leverage_coins::errors::maintenance_reserve_exceeds_equity!(),
    );

    venue_equity - maintenance_reserve
}

/// Returns the reserve after crediting an exact mint or redemption fee.
///
/// A zero fee is a valid no-op. Overflow aborts with the package arithmetic
/// code instead of wrapping or silently narrowing.
public(package) fun credit_fee(maintenance_reserve: u64, fee: u64): u64 {
    maintenance_reserve
        .checked_add(fee)
        .destroy_or!(abort blast_leverage_coins::errors::arithmetic_overflow!())
}

/// Quotes a mint from venue equity while applying the reserve fee exactly once.
///
/// Returns `(reserve_after, nav_before, nav_after, fee, contribution,
/// shares_out, shares_after)`. Both venue-equity values use one canonical
/// valuation pair. This function derives pre-mint shareholder NAV with
/// `reserve_before`, computes the fee once, derives post-mint shareholder NAV
/// with `reserve_after`, requires a positive contribution, and only then
/// calls the low-level share formula. The returned NAV values are the exact
/// inputs that later exposure and final-leverage checks must consume. A
/// caller therefore cannot accidentally derive both NAV values with the same
/// reserve checkpoint, subtract the fee twice, or size exposure from venue
/// equity.
///
/// Guard order is pre-mint reserve backing, the deposit and fee rate, the
/// reserve credit, post-mint reserve backing, the contribution, then the
/// low-level NAV, supply, and share guards.
///
/// The later state transition must still prove that `venue_equity_after` is the
/// authenticated result of depositing `deposit` and executing only the sealed
/// proportional trade. Pure arithmetic cannot authenticate that venue fact.
public(package) fun mint_accounting_quote(
    deposit: u64,
    venue_equity_before: u64,
    venue_equity_after: u64,
    reserve_before: u64,
    shares_before: u64,
    mint_fee_bps: u64,
): (u64, u64, u64, u64, u64, u64, u64) {
    let nav_before = shareholder_nav(venue_equity_before, reserve_before);
    let fee = share_math::fee_up(deposit, mint_fee_bps);
    let reserve_after = credit_fee(reserve_before, fee);
    let nav_after = shareholder_nav(venue_equity_after, reserve_after);
    assert!(
        nav_after > nav_before,
        blast_leverage_coins::errors::nonpositive_contribution!(),
    );

    let contribution = nav_after - nav_before;
    let (shares_out, shares_after) = share_math::mint_quote(
        contribution,
        nav_before,
        shares_before,
    );

    (
        reserve_after,
        nav_before,
        nav_after,
        fee,
        contribution,
        shares_out,
        shares_after,
    )
}

/// Quotes a redemption and credits its reserve fee at the correct checkpoint.
///
/// Returns `(reserve_after, shares_after, equity_keep, gross, fee, net)`.
/// Both pre-redemption and post-unwind shareholder NAV exclude `reserve_before`.
/// Only after the gross claim is known does this function credit the fee. Thus
/// the credited fee cannot re-enter the current or a later redemption's share
/// pricing base.
///
/// The later state transition must still authenticate both venue-equity values,
/// withdraw exactly `net`, and verify final venue equity and reserve atomically.
public(package) fun redemption_accounting_quote(
    shares_burned: u64,
    venue_equity_before: u64,
    venue_equity_unwound: u64,
    reserve_before: u64,
    shares_before: u64,
    redeem_fee_bps: u64,
): (u64, u64, u64, u64, u64, u64) {
    let nav_before = shareholder_nav(venue_equity_before, reserve_before);
    let nav_unwound = shareholder_nav(venue_equity_unwound, reserve_before);
    let (shares_after, equity_keep, gross, fee, net) = share_math::redemption_quote(
        shares_burned,
        nav_before,
        nav_unwound,
        shares_before,
        redeem_fee_bps,
    );
    let reserve_after = credit_fee(reserve_before, fee);

    (reserve_after, shares_after, equity_keep, gross, fee, net)
}

/// Returns accounting leverage using shareholder NAV, never venue equity.
public(package) fun accounting_leverage_bps_up(
    notional: u64,
    venue_equity: u64,
    maintenance_reserve: u64,
): u64 {
    share_math::leverage_bps_up(
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
    share_math::target_notional_down(
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
    share_math::mint_base_delta_down(
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
    share_math::mint_base_bounds(
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
    share_math::assert_mint_base_within_bounds(
        base_final,
        expected_contribution,
        actual_contribution,
        base_before,
        shareholder_nav(venue_equity_before, reserve_before),
        lot_size,
        min_exposure_lots,
    );
}

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
/// function; it leaves the reserve unchanged and increases shareholder NAV.
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
