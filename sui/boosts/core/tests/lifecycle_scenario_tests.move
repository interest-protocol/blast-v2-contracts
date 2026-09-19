#[test_only]
/// Whole-lifetime scenarios driven through the simulated venue and test adapter.
///
/// Every test walks a vault the way a real adapter would, from issuance to
/// terminal claims, and checks the invariants a holder relies on at each
/// step: remaining holders never lose NAV per share to another user's
/// operation, the reserve never exceeds its ceiling for the live position,
/// venue equity always reconciles to NAV plus reserve, and every operation
/// is refused outside the lifecycle phase it belongs to.
module blast_boosts_core::lifecycle_scenario_tests;

// === Constants ===

const USDC: u64 = 1_000_000;
const SEED: u64 = 10_000 * USDC;
const SEED_RESERVE: u64 = 500 * USDC;
/// The seed after four capped opening orders each paid 20 bps slippage and 5 bps fee.
const SEED_NAV: u64 = 9_452_481_000;
const BPS: u64 = 10_000;
/// One basis point of the calm venue's $2.50 base price.
const PRICE_STEP: u64 = 250_000;

// === Tests ===

// --- Best Case ---

/// Activation opens the target position in capped orders and prices the seed after costs.
#[test]
fun activation_opens_the_target_in_capped_orders_and_locks_the_seed_shares() {
    let vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    // Four fills at the 5,000 USDC cap cost 47.519 USDC in slippage and fees.
    assert_eq!(vault.locked() / 1_000, SEED_NAV);
    assert_eq!(vault.venue().equity(), SEED_NAV + SEED_RESERVE);
    assert_eq!(vault.venue().base(), 7_600_000_000_000);
    assert_eq!(vault.venue().notional(), 19_000 * USDC);
    assert_eq!(vault.reserve(), SEED_RESERVE);
    assert_eq!(vault.locked(), SEED_NAV * 1_000);
    assert_eq!(vault.supply(), vault.locked());
    assert!(vault.state().is_active_for_testing());
    // Leverage lands just above 2x: the costs came out of NAV, not the position.
    assert!(vault.leverage_bps() > 20_000 && vault.leverage_bps() < 20_200);
    assert_reconciled(&vault);
    vault.destroy();
}

/// A calm lifetime: deposits, profit, maintenance, withdrawals, funding, and an
/// orderly shutdown, with no holder ever diluted by another holder's operation.
#[test]
fun a_calm_lifetime_never_dilutes_remaining_holders() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    let deposits = vector[1_000 * USDC, 250 * USDC, 5_000 * USDC, 40 * USDC, 12_345 * USDC];
    let mut holders = vector[];
    deposits.do!(|deposit| {
        let price_before = vault.nav_per_share();
        let shares = vault.mint(deposit, 1);
        assert!(shares > 0);
        assert!(vault.nav_per_share() >= price_before);
        assert_reconciled(&vault);
        holders.push_back(shares);
        vault.venue_mut().advance(60_000);
    });
    assert!(vault.leverage_bps() >= 16_000 && vault.leverage_bps() <= 26_000);

    // A 40% rally: NAV rises faster than notional and leverage falls below the band.
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 140 / 100);
    assert!(vault.leverage_bps() < 16_000);
    let before = vault.nav_per_share();
    let orders = vault.rebalance();
    assert!(orders > 0);
    assert!(vault.leverage_bps() <= 20_000 && vault.leverage_bps() >= 19_000);
    // Maintenance costs the holders execution, never more than the venue charged.
    assert!(vault.nav_per_share() < before);
    assert_reconciled(&vault);

    // Funding is charged and absorbed by the reserve; holders' NAV is untouched.
    let nav_before_funding = vault.nav();
    let (absorbed, uncovered, _) = vault.charge_funding(30 * USDC);
    assert_eq!(vector[absorbed, uncovered], vector[30 * USDC, 0]);
    assert_eq!(vault.nav(), nav_before_funding);
    assert_eq!(vault.reserve(), SEED_RESERVE - 30 * USDC + total_reserve_fees(&deposits));

    // Everyone but the seed redeems; each payout is worth at most their proportional claim.
    let mut index = 0;
    while (index < holders.length()) {
        let shares = holders[index];
        let claim = (vault.nav() as u128) * (shares as u128) / (vault.supply() as u128);
        let price_before = vault.nav_per_share();
        let payout = vault.redeem(shares, 1);
        // At most the claim, and short of it by no more than the fee plus execution on 2x notional.
        assert!((payout as u128) <= claim && (payout as u128) >= claim * 9_920 / 10_000);
        assert!(vault.nav_per_share() >= price_before);
        assert_reconciled(&vault);
        index = index + 1;
    };
    assert_eq!(vault.supply(), vault.locked());

    // Shutdown closes the position and returns everything, reserve included, as cash.
    let cash = vault.shutdown();
    assert!(vault.state().is_settled_for_testing());
    assert_eq!(vault.reserve(), 0);
    assert_eq!(vault.venue().base(), 0);
    assert_eq!(vault.venue().equity(), 0);
    assert!(cash > 0);
    vault.destroy();
}

/// The admin's fee share accrues as cash outside the vault and the rest builds the reserve.
#[test]
fun fee_splits_route_admin_cash_out_and_the_remainder_into_the_reserve() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.set_fees(100, 100, 5_000);

    let shares = vault.mint(2_000 * USDC, 1);
    // A 1% fee on 2,000 is 20 USDC, split evenly.
    assert_eq!(vault.admin_cash(), 10 * USDC);
    assert_eq!(vault.reserve(), SEED_RESERVE + 10 * USDC);
    assert_reconciled(&vault);

    let claim = (vault.nav() as u128) * (shares as u128) / (vault.supply() as u128);
    let payout = vault.redeem(shares, 1);
    // The 1% redemption fee comes off the gross claim, half to admin cash and half to the reserve.
    assert!((payout as u128) <= claim * 9_900 / 10_000 && (payout as u128) >= claim * 9_820 / 10_000);
    let redemption_fee = vault.admin_cash() - 10 * USDC + (vault.reserve() - SEED_RESERVE - 10 * USDC);
    assert!(redemption_fee > 0);
    assert_eq!(vault.admin_cash() - 10 * USDC, redemption_fee / 2);
    assert!(vault.admin_cash() - 10 * USDC <= vault.reserve() - SEED_RESERVE - 10 * USDC);
    assert_reconciled(&vault);
    vault.destroy();
}

/// Reserve above the ceiling is released to holders one operation at a time,
/// and a newcomer pays the released NAV rather than sharing it.
#[test]
fun reserve_above_the_ceiling_is_released_to_holders_before_a_newcomer_is_priced() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let cap = 19_000 * USDC / 10;

    // Funding credits carry no observation and can push the reserve past the 10% ceiling.
    vault.credit_funding(2_000 * USDC);
    assert!(vault.reserve() > cap);
    let stored_reserve = vault.reserve();
    let priced_nav = vault.venue().equity() - cap;

    let shares = vault.mint(1_000 * USDC, 1);
    // Shares are priced on the released NAV: at most the deposit's share of it, and short of
    // that only by the execution cost of the proportional buy.
    let ceiling = ((vault.supply() - shares) as u128) * ((999 * USDC) as u128) / (priced_nav as u128);
    assert!((shares as u128) <= ceiling && (shares as u128) >= ceiling * 9_930 / 10_000);
    // The stored reserve is the pre-mint ceiling plus this mint's 1 USDC fee slice.
    assert!(vault.reserve() < stored_reserve);
    assert_eq!(vault.reserve(), cap + USDC);
    assert_reconciled(&vault);

    // A donation is never refused; whatever exceeds the ceiling is holder NAV.
    let nav_before = vault.nav();
    vault.donate(5_000 * USDC);
    assert_eq!(vault.reserve(), reserve_cap(&vault));
    assert!(vault.nav() > nav_before);
    assert_reconciled(&vault);
    vault.destroy();
}

// --- Worst Case ---

/// A 30% crash on a 2x position: leverage breaches the hard cap, mints are refused,
/// the emergency reduction brings it back under the cap, an ordinary reduction
/// finishes the job, and holders can exit.
#[test]
fun a_crash_locks_mints_permits_reduction_and_lets_holders_exit() {
    let mut vault = stressed_vault().activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    let price = vault.venue().base_price();

    vault.venue_mut().set_base_price(price * 70 / 100);
    vault.venue_mut().set_slippage_bps(90);
    assert!(vault.leverage_bps() > 30_000);

    // The emergency call stops as soon as leverage is no longer above the cap.
    let orders = vault.rebalance();
    assert!(orders > 0);
    assert!(vault.leverage_bps() <= 30_000 && vault.leverage_bps() > 26_000);
    // Still above the band, an ordinary call completes the reduction to target.
    vault.rebalance();
    assert!(vault.leverage_bps() <= 20_000 && vault.leverage_bps() >= 19_000);
    assert_reconciled(&vault);

    // The holder exits at a loss but never at more than the proportional claim.
    let claim = (vault.nav() as u128) * (shares as u128) / (vault.supply() as u128);
    let payout = vault.redeem(shares, 1);
    assert!(payout < 1_000 * USDC && (payout as u128) <= claim);
    // Even in a stressed book the shortfall is bounded by fee plus slippage on the unwound notional.
    assert!((payout as u128) >= claim * 9_700 / 10_000);
    assert_reconciled(&vault);
    vault.destroy();
}

/// In a market that only fills at 3%, the emergency bound carries the reduction
/// down to the cap and no further: the orders placed above the cap stand, and
/// the rest waits for a calmer book under the ordinary bound.
#[test]
fun an_emergency_reduction_in_a_wide_market_stops_at_the_cap_and_keeps_its_progress() {
    let mut vault = stressed_vault().activate(SEED, SEED_RESERVE);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 70 / 100);
    vault.venue_mut().set_slippage_bps(300);
    assert!(vault.leverage_bps() > 30_000);

    let orders = vault.rebalance();
    assert!(orders > 0);
    assert!(vault.leverage_bps() <= 30_000 && vault.leverage_bps() > 26_000);
    assert_reconciled(&vault);

    vault.venue_mut().set_slippage_bps(50);
    vault.rebalance();
    assert!(vault.leverage_bps() <= 20_000);
    vault.destroy();
}

/// Below the cap only the ordinary bound applies, so the same wide market refuses the follow-up.
#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_ordinary_reduction_in_a_wide_market_is_refused() {
    let mut vault = stressed_vault().activate(SEED, SEED_RESERVE);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 70 / 100);
    vault.venue_mut().set_slippage_bps(300);
    vault.rebalance();

    vault.rebalance();
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EMintOutsideRebalanceBand, location = blast_boosts_core::state)]
fun a_mint_is_refused_while_leverage_is_outside_the_band() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 80 / 100);

    vault.mint(100 * USDC, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EExecutionOutsideMaxSlippage, location = blast_boosts_core::policy)]
fun an_ordinary_fill_outside_max_slippage_is_refused() {
    let vault = test_adapter::issue(test_adapter::calm_venue().with_slippage_bps(150)).activate(SEED, SEED_RESERVE);
    vault.destroy();
}

/// A crash that consumes the reserve leaves zero shareholder NAV: every priced
/// operation fails closed, and only shutdown can return what remains, pro rata.
#[test]
fun a_crash_through_the_reserve_fails_closed_until_shutdown_pays_pro_rata() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    let price = vault.venue().base_price();

    // A 50% move on a 2x position wipes NAV; the reserve is all that backs the account.
    vault.venue_mut().set_base_price(price / 2);
    assert!(vault.venue().equity() <= vault.reserve());

    let cash = vault.shutdown();
    assert!(cash > 0 && cash < SEED_RESERVE);
    let expected = (cash as u128) * (shares as u128) / ((vault.supply() - vault.locked()) as u128);
    let output = vault.claim(shares, 1);
    assert_eq!(output as u128, expected);
    assert_eq!(vault.supply(), vault.locked());
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun zero_shareholder_nav_refuses_every_priced_operation() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price / 2);

    vault.rebalance();
    vault.destroy();
}

/// A funding storm exhausts the reserve, holders carry the deficit, and later
/// credits repay holders before a single atom rebuilds the reserve.
#[test]
fun a_funding_storm_charges_holders_only_after_the_reserve_and_repays_them_first() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let nav_before = vault.nav();

    let (absorbed, uncovered, _) = vault.charge_funding(400 * USDC);
    assert_eq!(vector[absorbed, uncovered], vector[400 * USDC, 0]);
    assert_eq!(vault.nav(), nav_before);

    let (absorbed, uncovered, _) = vault.charge_funding(300 * USDC);
    assert_eq!(vector[absorbed, uncovered], vector[100 * USDC, 200 * USDC]);
    assert_eq!(vault.reserve(), 0);
    assert_eq!(vault.state().uncovered_deficit(), 200 * USDC);
    assert_eq!(vault.nav(), nav_before - 200 * USDC);

    let (_, _, restored) = vault.credit_funding(150 * USDC);
    assert_eq!(restored, 150 * USDC);
    assert_eq!(vault.reserve(), 0);
    assert_eq!(vault.state().uncovered_deficit(), 50 * USDC);

    let (_, _, restored) = vault.credit_funding(120 * USDC);
    assert_eq!(restored, 50 * USDC);
    assert_eq!(vault.reserve(), 70 * USDC);
    assert_eq!(vault.state().uncovered_deficit(), 0);
    assert_eq!(vault.nav(), nav_before);
    assert_reconciled(&vault);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = test_adapter::EVenueNotReady, location = blast_boosts_core::test_adapter)]
fun a_paused_venue_refuses_active_operations() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.venue_mut().set_operational(false);

    vault.mint(100 * USDC, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = test_adapter::EVenueNotReady, location = blast_boosts_core::test_adapter)]
fun an_unsafe_margin_refuses_active_operations() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.venue_mut().set_margin_safe(false);

    vault.redeem(1, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun a_stale_oracle_refuses_active_operations() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    // The oracle stays at its last publish time while the clock moves past the 30 s window.
    let observation = vault.venue().observe();
    vault.venue_mut().advance(31_000);

    let plan = vault.state().prepare_mint(observation, 100 * USDC, vault.supply(), 1, vault.venue().now_ms());
    std::unit_test::destroy(plan);
    vault.destroy();
}

/// A shutdown while the venue is paused still closes and settles: shutdown never
/// depends on the venue being healthy, only on it being closable.
#[test]
fun shutdown_proceeds_while_the_venue_reports_unsafe_margin() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.venue_mut().set_margin_safe(false);

    let cash = vault.shutdown();
    assert!(cash > 0);
    assert!(vault.state().is_settled_for_testing());
    vault.destroy();
}

// --- Edges ---

/// A deposit too small to buy the minimum order is refused.
#[test]
#[expected_failure(abort_code = errors::EOrderBelowMinLots, location = blast_boosts_core::accounting_math)]
fun a_dust_mint_below_the_minimum_order_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    // 100 lots of 0.001 base at $2.50 is 0.25 USDC; this deposit buys less.
    vault.mint(100_000, 1);
    vault.destroy();
}

/// The smallest deposit that buys exactly the minimum order mints.
#[test]
fun the_minimum_order_mint_is_accepted() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    // Proportional base is 7.6e12 * contribution / NAV; the minimum order is 1e8.
    let deposit = 130_000;
    let shares = vault.mint(deposit, 1);
    // Shares are the deposit net of fee and one lot's execution cost, at NAV per share.
    let ceiling = (vault.locked() as u128) * ((deposit - deposit / 1_000) as u128) / (SEED_NAV as u128);
    assert!((shares as u128) <= ceiling && (shares as u128) >= ceiling * 9_900 / 10_000);
    assert_reconciled(&vault);
    vault.destroy();
}

/// A holder may not present the whole supply; the locked seed always remains.
#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::accounting_math)]
fun the_entire_supply_cannot_be_redeemed() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    let supply = vault.supply();
    vault.redeem(supply, 1);
    vault.destroy();
}

/// The largest ordinary redemption leaves the locked seed and its minimum position.
#[test]
fun every_ordinary_share_can_leave_while_the_seed_stays() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(3_000 * USDC, 1);

    let payout = vault.redeem(shares, 1);
    assert!(payout > 2_900 * USDC && payout < 3_000 * USDC);
    assert_eq!(vault.supply(), vault.locked());
    assert!(vault.venue().base() > 0);
    assert_reconciled(&vault);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::ESharesOutBelowMinimum, location = blast_boosts_core::accounting_math)]
fun a_mint_below_the_users_minimum_shares_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    vault.mint(1_000 * USDC, 1_000 * USDC * 1_000);
    vault.destroy();
}

/// The depositor's fee ceiling is checked before any venue call, against the live rate.
#[test]
#[expected_failure(abort_code = errors::EUserFeeLimitExceeded, location = blast_boosts_core::state)]
fun a_mint_whose_fee_ceiling_is_below_the_live_rate_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.set_fees(50, 50, 0);

    vault.mint_with_fee_limit(1_000 * USDC, 1, 49);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EUserFeeLimitExceeded, location = blast_boosts_core::state)]
fun a_redemption_whose_fee_ceiling_is_below_the_live_rate_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    vault.set_fees(10, 30, 0);

    vault.redeem_with_fee_limit(shares, 1, 29);
    vault.destroy();
}

/// A fee ceiling equal to the live rate is accepted on both sides.
#[test]
fun a_fee_ceiling_at_the_live_rate_is_accepted() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint_with_fee_limit(1_000 * USDC, 1, 10);
    let payout = vault.redeem_with_fee_limit(shares, 1, 10);
    assert!(payout > 0);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::ERedemptionOutputBelowMinimum, location = blast_boosts_core::state)]
fun a_redemption_below_the_users_minimum_output_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);

    vault.redeem(shares, 1_000 * USDC);
    vault.destroy();
}

/// The NAV cap blocks mints only: profit may carry NAV over it, and redemptions still run.
#[test]
fun the_nav_cap_blocks_mints_but_not_profit_or_redemptions() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    let nav_cap = vault.nav() + 10 * USDC;
    vault.state_mut().set_nav_cap(nav_cap);

    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 102 / 100);
    assert!(vault.nav() > vault.state().nav_cap_for_testing());

    let payout = vault.redeem(shares, 1);
    assert!(payout > 1_000 * USDC);
    assert_reconciled(&vault);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state)]
fun a_mint_over_the_nav_cap_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let nav_cap = vault.nav() + 10 * USDC;
    vault.state_mut().set_nav_cap(nav_cap);

    vault.mint(100 * USDC, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun a_rebalance_inside_the_band_is_refused() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);

    vault.rebalance();
    vault.destroy();
}

/// A large drift is corrected across the sixteen-order limit and finishes on a later call.
#[test]
fun a_large_drift_is_corrected_across_several_rebalance_calls() {
    let mut vault = test_adapter::issue_with(
        test_adapter::calm_venue(), test_adapter::standard_policy(policy::long()), 200 * USDC, 1_000_000_000_000,
    ).activate(SEED, SEED_RESERVE);
    // Doubling the price leaves a 2x long at 1.34x: far more than sixteen 200 USDC orders away.
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 2);
    assert!(vault.leverage_bps() < 14_000);

    let orders = vault.rebalance();
    assert_eq!(orders, 16);
    let after_first = vault.leverage_bps();
    assert!(after_first < 16_000);
    let mut calls = 1u64;
    while (vault.leverage_bps() < 16_000) {
        let before = vault.leverage_bps();
        vault.rebalance();
        assert!(vault.leverage_bps() > before);
        calls = calls + 1;
    };
    assert!(calls > 1);
    // Back inside the band the public trigger closes, even though target is not reached.
    assert!(vault.leverage_bps() >= 16_000 && vault.leverage_bps() < 20_000);
    assert_reconciled(&vault);
    vault.destroy();
}

/// Short products mirror every long behaviour with the direction reversed.
#[test]
fun a_short_product_runs_the_same_lifetime() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue().with_side(policy::short())).activate(SEED, SEED_RESERVE);
    assert_eq!(vault.locked() / 1_000, SEED_NAV);
    let shares = vault.mint(1_000 * USDC, 1);

    // A 10% fall is profit for a short; leverage drops below the band and is restored.
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 90 / 100);
    assert!(vault.leverage_bps() < 16_000);
    vault.rebalance();
    assert!(vault.leverage_bps() >= 19_000 && vault.leverage_bps() <= 20_000);

    let payout = vault.redeem(shares, 1);
    assert!(payout > 1_000 * USDC);
    let cash = vault.shutdown();
    assert!(cash > SEED);
    vault.destroy();
}

/// A short is wiped by a rally the way a long is by a crash: leverage breaches the cap,
/// the emergency reduction stops under it, and the ordinary one finishes.
#[test]
fun a_short_rally_above_the_cap_reduces_in_two_calls() {
    let mut vault = test_adapter::issue_with(
        test_adapter::calm_venue().with_side(policy::short()),
        test_adapter::standard_policy(policy::short()), 1_000 * USDC, 1_000_000_000_000,
    ).activate(SEED, SEED_RESERVE);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 125 / 100);
    assert!(vault.leverage_bps() > 30_000);

    vault.rebalance();
    assert!(vault.leverage_bps() <= 30_000 && vault.leverage_bps() > 26_000);
    vault.rebalance();
    assert!(vault.leverage_bps() <= 20_000 && vault.leverage_bps() >= 19_000);
    assert_reconciled(&vault);
    vault.destroy();
}

/// The book fills only nine tenths of each order: every path advances by what filled,
/// re-plans from the live position, and still lands where a full fill would.
#[test]
fun partial_fills_advance_every_path_by_what_actually_filled() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue().with_fill_ratio_bps(9_000)).activate(SEED, SEED_RESERVE);
    assert_eq!(vault.venue().base(), 7_600_000_000_000);

    let shares = vault.mint(1_000 * USDC, 1);
    assert!(vault.last_orders() > 1);
    assert_reconciled(&vault);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 140 / 100);
    vault.rebalance();
    assert!(vault.leverage_bps() <= 20_000 && vault.leverage_bps() >= 19_000);
    let payout = vault.redeem(shares, 1);
    assert!(payout > 1_000 * USDC);
    assert_reconciled(&vault);
    vault.destroy();
}

/// The oracle moves between the plan and the fill: the checkpoint no longer matches
/// and the whole operation reverts, so a stale plan can never settle at a new price.
#[test]
#[expected_failure(abort_code = errors::EActiveCheckpointChanged, location = blast_boosts_core::state)]
fun a_price_move_between_prepare_and_complete_reverts_the_mint() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let now_ms = vault.venue().now_ms();
    let supply = vault.supply();
    let observation = vault.venue().observe();
    let plan = vault.state().prepare_mint(observation, 1_000 * USDC, supply, 1, now_ms);
    let base_price = vault.venue().base_price();
    vault.venue_mut().set_base_price(base_price + 1);

    let observation = vault.venue().observe();
    let (_, _, _, _, _) = vault.state_mut().complete_mint(plan, observation, now_ms);
    vault.destroy();
}

/// The venue errors out mid-transaction: the post-fill observation is unusable and
/// the mint reverts as a whole, leaving the core exactly as it was.
#[test]
#[expected_failure(abort_code = test_adapter::EVenueNotReady, location = blast_boosts_core::test_adapter)]
fun a_venue_error_after_the_fill_reverts_the_mint() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let now_ms = vault.venue().now_ms();
    let supply = vault.supply();
    let observation = vault.venue().observe();
    let plan = vault.state().prepare_mint(observation, 1_000 * USDC, supply, 1, now_ms);
    let base_to_buy = plan.base_to_buy();
    vault.venue_mut().deposit(1_000 * USDC);
    vault.venue_mut().fill(base_to_buy, true);
    vault.venue_mut().set_operational(false);

    let observation = vault.venue().observe();
    let (_, _, _, _, _) = vault.state_mut().complete_mint(plan, observation, now_ms);
    vault.destroy();
}

/// A funding credit far above the deficit and the ceiling: the next redemption
/// prices on the admitted reserve, the redeemer collects their share of the release,
/// and the stored reserve settles at the ceiling for the smaller position.
#[test]
fun a_large_funding_credit_is_released_at_the_next_redemption() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    vault.charge_funding(600 * USDC);
    assert_eq!(vault.state().uncovered_deficit(), 99 * USDC);
    let (_, _, restored) = vault.credit_funding(4_000 * USDC);
    assert_eq!(restored, 99 * USDC);
    assert!(vault.reserve() > vault.admitted_reserve());

    let claim = (vault.nav() as u128) * (shares as u128) / (vault.supply() as u128);
    let payout = vault.redeem(shares, 1);
    assert!((payout as u128) <= claim && (payout as u128) >= claim * 9_920 / 10_000);
    assert_eq!(vault.reserve(), reserve_cap(&vault));
    assert_reconciled(&vault);
    vault.destroy();
}

/// A release that lifts NAV over the cap blocks mints, exactly as profit does.
#[test]
#[expected_failure(abort_code = errors::ENavCapExceeded, location = blast_boosts_core::state)]
fun a_reserve_release_over_the_nav_cap_blocks_the_next_mint() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let nav_cap = vault.nav() + 100 * USDC;
    vault.state_mut().set_nav_cap(nav_cap);
    vault.credit_funding(3_000 * USDC);

    vault.mint(10 * USDC, 1);
    vault.destroy();
}

/// The public trigger opens at the first price that carries leverage below the band.
#[test]
fun the_first_price_below_the_band_opens_the_public_trigger() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let price = first_price_below_the_band(&mut vault);
    vault.venue_mut().set_base_price(price);
    assert!(vault.is_below_band());

    let orders = vault.rebalance();
    assert!(orders > 0);
    vault.destroy();
}

/// One basis point of price earlier, leverage is still at or above the edge and the trigger is closed.
#[test]
#[expected_failure(abort_code = errors::ERebalanceInsideBand, location = blast_boosts_core::state)]
fun the_last_price_at_the_band_edge_keeps_the_public_trigger_closed() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let price = first_price_below_the_band(&mut vault) - PRICE_STEP;
    vault.venue_mut().set_base_price(price);
    assert!(!vault.is_below_band());

    vault.rebalance();
    vault.destroy();
}

// --- Keeper Dry Run ---

/// The dry run agrees with the trigger on both sides of the band edge and after the correction.
#[test]
fun the_dry_run_tracks_the_public_trigger_across_the_band_edge() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    assert!(!vault.needs_rebalance());

    let price = first_price_below_the_band(&mut vault);
    vault.venue_mut().set_base_price(price - PRICE_STEP);
    assert!(!vault.needs_rebalance());

    vault.venue_mut().set_base_price(price);
    assert!(vault.needs_rebalance());
    vault.rebalance();
    assert!(!vault.needs_rebalance());
    vault.destroy();
}

/// A crash through the hard cap reads as due, and stays due after the emergency
/// call stops at the cap, until the ordinary call finishes.
#[test]
fun the_dry_run_stays_due_until_the_reduction_reaches_the_band() {
    let mut vault = stressed_vault().activate(SEED, SEED_RESERVE);
    vault.mint(1_000 * USDC, 1);
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 70 / 100);
    assert!(vault.needs_rebalance());

    vault.rebalance();
    assert!(vault.leverage_bps() <= 30_000 && vault.needs_rebalance());

    vault.rebalance();
    assert!(!vault.needs_rebalance());
    vault.destroy();
}

/// The dry run fails exactly where the real call would fail before its first order.
#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun the_dry_run_refuses_an_unwinding_vault() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.state_mut().begin_shutdown();

    vault.needs_rebalance();
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun the_dry_run_refuses_a_liquidated_vault() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.venue_mut().liquidate();

    vault.needs_rebalance();
    vault.destroy();
}

/// Lowering the order cap mid-life splits the next operation into more orders.
#[test]
fun a_lower_order_cap_splits_the_next_operation_into_more_orders() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.mint(2_000 * USDC, 1);
    assert_eq!(vault.last_orders(), 1);

    vault.set_max_order_notional(500 * USDC);
    let cap_base = vault.venue().base_for_notional(500 * USDC);
    let base_before = vault.venue().base();
    let shares = vault.mint(2_000 * USDC, 1);
    // 2,000 USDC at 2x buys about 4,000 USDC of base: eight or nine orders of 500.
    let bought = vault.venue().base() - base_before;
    assert_eq!(vault.last_orders(), bought.div_ceil(cap_base));
    assert!(vault.last_orders() >= 8);
    let base_before = vault.venue().base();
    vault.redeem(shares, 1);
    let sold = base_before - vault.venue().base();
    assert_eq!(vault.last_orders(), sold.div_ceil(cap_base));
    vault.destroy();
}

/// With every fee at zero the reserve never grows and the depositor's whole
/// contribution goes to work, less only the venue's execution cost.
#[test]
fun zero_fees_leave_the_reserve_untouched_through_mint_and_redemption() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.set_fees(0, 0, 0);

    let shares = vault.mint(1_000 * USDC, 1);
    assert_eq!(vault.reserve(), SEED_RESERVE);
    assert_eq!(vault.admin_cash(), 0);
    let claim = (vault.nav() as u128) * (shares as u128) / (vault.supply() as u128);
    let payout = vault.redeem(shares, 1);
    assert!((payout as u128) <= claim && (payout as u128) >= claim * 9_930 / 10_000);
    assert_eq!(vault.reserve(), SEED_RESERVE);
    assert_eq!(vault.admin_cash(), 0);
    assert_reconciled(&vault);
    vault.destroy();
}

/// A mint that would need more than sixteen orders is refused by the adapter.
#[test]
#[expected_failure]
fun a_mint_needing_more_than_sixteen_orders_is_refused() {
    let mut vault = test_adapter::issue_with(
        test_adapter::calm_venue(), test_adapter::standard_policy(policy::long()), 100 * USDC, 1_000_000_000_000,
    ).activate(SEED, SEED_RESERVE);

    vault.mint(2_000 * USDC, 1);
    vault.destroy();
}

/// A reduction with reserve above the ceiling sizes against the admitted NAV,
/// so it does not over-reduce on a NAV the release will restore.
#[test]
fun a_reduction_prices_the_release_before_sizing() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.credit_funding(3_000 * USDC);
    assert!(vault.reserve() > vault.admitted_reserve());
    let price = vault.venue().base_price();
    vault.venue_mut().set_base_price(price * 60 / 100);
    assert!(vault.leverage_bps() > 26_000);
    let reserve_priced = vault.admitted_reserve();

    vault.rebalance();
    // Sized on the reserve the plan admitted, the position lands at target; on the
    // smaller ceiling the reduction itself earned, it reads a little under.
    let leverage_on_plan = ((vault.venue().notional() as u128) * (BPS as u128))
        .div_ceil((vault.venue().equity() - reserve_priced) as u128);
    assert!(leverage_on_plan <= 20_000 && leverage_on_plan >= 19_000);
    assert!((vault.leverage_bps() as u128) < leverage_on_plan);
    // Maintenance writes no reserve, so the pending release still waits for a priced operation.
    assert!(vault.reserve() > reserve_cap(&vault));
    assert_eq!(vault.venue().equity(), vault.nav() + vault.admitted_reserve());
    vault.destroy();
}

/// Claims drain the terminal cash to zero: the last eligible share takes the remainder.
#[test]
fun consecutive_claims_drain_the_terminal_cash_to_zero() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let first = vault.mint(1_000 * USDC, 1);
    let second = vault.mint(700 * USDC, 1);
    let third = vault.mint(300 * USDC, 1);
    let cash = vault.shutdown();

    let paid = vault.claim(first, 1) + vault.claim(second, 1) + vault.claim(third, 1);
    assert_eq!(paid, cash);
    assert_eq!(vault.terminal_cash(), 0);
    assert_eq!(vault.supply(), vault.locked());
    vault.destroy();
}

/// The venue liquidates the position: the core fails closed on every priced
/// operation, shutdown settles with nothing, and every claim pays zero.
#[test]
fun a_liquidated_vault_settles_to_zero_and_claims_pay_nothing() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    vault.venue_mut().liquidate();
    assert_eq!(vault.venue().equity(), 0);

    let cash = vault.shutdown();
    assert_eq!(cash, 0);
    assert_eq!(vault.reserve(), 0);
    assert_eq!(vault.claim(shares, 0), 0);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidNav, location = blast_boosts_core::state)]
fun a_liquidated_vault_refuses_redemptions() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(1_000 * USDC, 1);
    vault.venue_mut().liquidate();

    vault.redeem(shares, 1);
    vault.destroy();
}

/// Winding down over several transactions: funding keeps settling between unwind
/// calls, a paused venue does not stop the close, and finalization sweeps the rest.
#[test]
fun winding_down_spans_transactions_with_funding_and_a_paused_venue_in_between() {
    let mut vault = test_adapter::issue_with(
        test_adapter::calm_venue(), test_adapter::standard_policy(policy::long()), 2_000 * USDC, 1_000_000_000_000,
    ).activate(SEED, SEED_RESERVE);
    vault.begin_shutdown();

    assert_eq!(vault.unwind(3), 3);
    assert!(vault.venue().base() > 0);
    let (absorbed, _, _) = vault.charge_funding(20 * USDC);
    assert_eq!(absorbed, 20 * USDC);
    vault.venue_mut().advance(120_000);
    vault.venue_mut().set_operational(false);
    while (vault.venue().base() > 0) { vault.unwind(4); };

    let cash = vault.finalize();
    assert!(cash > 0);
    assert_eq!(vault.venue().equity(), 0);
    assert!(vault.state().is_settled_for_testing());
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EStalePrice, location = blast_boosts_core::policy)]
fun winding_down_still_requires_fresh_oracles() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.begin_shutdown();
    let stale = vault.venue().oracle(vault.venue().base_price());
    vault.venue_mut().advance(31_000);
    let fresh = vault.venue().oracle(vault.venue().base_price());
    let now_ms = vault.venue().now_ms();

    let (_, _, _, _) = vault.state().unwind_constraints(stale, fresh, vault.venue().lot_size(), now_ms);
    vault.destroy();
}

// --- Lifecycle Matrix ---

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun an_unwinding_vault_refuses_mints() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.state_mut().begin_shutdown();
    vault.mint(100 * USDC, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun an_unwinding_vault_refuses_redemptions() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let shares = vault.mint(100 * USDC, 1);
    vault.state_mut().begin_shutdown();
    vault.redeem(shares, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun an_unwinding_vault_refuses_rebalances() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.state_mut().begin_shutdown();
    vault.rebalance();
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun an_unwinding_vault_refuses_donations() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.state_mut().begin_shutdown();
    vault.donate(USDC);
    vault.destroy();
}

/// Funding keeps settling while unwinding: the venue still charges it.
#[test]
fun an_unwinding_vault_still_settles_funding() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.state_mut().begin_shutdown();
    let (absorbed, _, _) = vault.charge_funding(10 * USDC);
    assert_eq!(absorbed, 10 * USDC);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun an_unwinding_vault_refuses_claims() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.state_mut().begin_shutdown();
    vault.claim(1, 0);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun a_settled_vault_refuses_mints() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.shutdown();
    vault.mint(100 * USDC, 1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle)]
fun a_settled_vault_refuses_funding() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.shutdown();
    vault.charge_funding(1);
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun a_settled_vault_cannot_shut_down_again() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.shutdown();
    vault.state_mut().begin_shutdown();
    vault.destroy();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidShareAmount, location = blast_boosts_core::state)]
fun the_locked_seed_can_never_claim() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    vault.shutdown();
    vault.claim(1, 0);
    vault.destroy();
}

/// Terminal claims distribute the cash pro rata across every eligible share, to the atom.
#[test]
fun terminal_claims_pay_every_eligible_share_pro_rata() {
    let mut vault = test_adapter::issue(test_adapter::calm_venue()).activate(SEED, SEED_RESERVE);
    let first = vault.mint(1_000 * USDC, 1);
    let second = vault.mint(2_000 * USDC, 1);
    let cash = vault.shutdown();

    let eligible = vault.supply() - vault.locked();
    let first_claim = (cash as u128) * (first as u128) / (eligible as u128);
    let output_first = vault.claim(first, 1);
    assert_eq!(output_first as u128, first_claim);
    let output_second = vault.claim(second, 1);
    // The second claim is priced on the remaining cash and shares, so no dust is stranded twice.
    assert!(output_first + output_second <= cash);
    assert!(cash - output_first - output_second <= 1);
    assert_eq!(vault.supply(), vault.locked());
    vault.destroy();
}

// === Private Test Helpers ===

/// Walks the price up one basis point at a time from the seed price until leverage
/// first reads below the band, and restores the seed price before returning.
fun first_price_below_the_band(vault: &mut Vault): u64 {
    let seed_price = vault.venue().base_price();
    // A 2x long reads 1.6x at four thirds of the seed price; start just short of it.
    let mut price = seed_price * 4 / 3 - 20 * PRICE_STEP;
    vault.venue_mut().set_base_price(price);
    while (!vault.is_below_band()) {
        price = price + PRICE_STEP;
        vault.venue_mut().set_base_price(price);
    };
    vault.venue_mut().set_base_price(seed_price);

    price
}

/// A vault whose 1,000 USDC order cap makes every large correction take several orders.
fun stressed_vault(): Issued {
    test_adapter::issue_with(
        test_adapter::calm_venue(), test_adapter::standard_policy(policy::long()), 1_000 * USDC, 1_000_000_000_000,
    )
}

/// After a priced operation the stored reserve sits at or under the ceiling, so venue
/// equity is exactly shareholder NAV plus the stored reserve.
fun assert_reconciled(vault: &Vault) {
    assert!(vault.reserve() <= reserve_cap(vault));
    assert_eq!(vault.venue().equity(), vault.nav() + vault.reserve());
}

fun reserve_cap(vault: &Vault): u64 {
    vault.venue().notional() * 1_000 / BPS
}

/// The 10 bps mint fee on each deposit, all of which went to the reserve.
fun total_reserve_fees(deposits: &vector<u64>): u64 {
    let mut sum = 0;
    deposits.do_ref!(|deposit| sum = sum + *deposit / 1_000);
    sum
}

// === Imports ===

use blast_boosts_core::{errors, policy, test_adapter::{Self, Issued, Vault}};

use std::unit_test::assert_eq;
