#[test_only]
/// Maintenance-reserve accounting and cross-operation conservation tests.
module blast_boosts_core::maintenance_math_tests;

// === Tests ===

/// Pins reserve exclusion at zero, equality, and maximum-width boundaries.
#[test]
fun shareholder_nav_excludes_the_complete_reserve() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::shareholder_nav(0, 0), 0);
    assert_eq!(accounting_math::shareholder_nav(1_000, 0), 1_000);
    assert_eq!(accounting_math::shareholder_nav(1_000, 100), 900);
    assert_eq!(accounting_math::shareholder_nav(1_000, 1_000), 0);
    assert_eq!(accounting_math::shareholder_nav(max, max), 0);
    assert_eq!(accounting_math::shareholder_nav(max, max - 1), 1);
}

/// Gives `sync_health` a non-aborting way to detect the loss state.
#[test]
fun reserve_backing_detection_never_aborts() {
    let max = std::u64::max_value!();

    assert!(accounting_math::is_reserve_backed(0, 0));
    assert!(accounting_math::is_reserve_backed(1_000, 1_000));
    assert!(accounting_math::is_reserve_backed(max, max));
    assert!(!accounting_math::is_reserve_backed(999, 1_000));
    assert!(!accounting_math::is_reserve_backed(max - 1, max));
}

/// Pins the non-aborting conservative leverage predicate at every unsafe width boundary.
#[test]
fun accounting_leverage_limit_detection_never_aborts() {
    let max = std::u64::max_value!();

    assert!(accounting_math::is_accounting_leverage_below_limit(
        259_990,
        100_000,
        0,
        26_000,
    ));
    assert!(!accounting_math::is_accounting_leverage_below_limit(
        260_000,
        100_000,
        0,
        26_000,
    ));
    assert!(!accounting_math::is_accounting_leverage_below_limit(
        1,
        100,
        100,
        26_000,
    ));
    assert!(!accounting_math::is_accounting_leverage_below_limit(
        1,
        99,
        100,
        26_000,
    ));
    assert!(!accounting_math::is_accounting_leverage_below_limit(
        max,
        1,
        0,
        26_000,
    ));
}

/// Exhausts the small domain and ties the non-aborting health predicate to the NAV identity.
#[test]
fun reserve_backing_and_shareholder_nav_agree_across_the_small_domain() {
    0u64.range_do!(65, |venue_equity| {
        0u64.range_do!(65, |maintenance_reserve| {
            let is_backed = accounting_math::is_reserve_backed(
                venue_equity,
                maintenance_reserve,
            );

            assert_eq!(is_backed, maintenance_reserve <= venue_equity);
            if (is_backed) {
                let nav = accounting_math::shareholder_nav(
                    venue_equity,
                    maintenance_reserve,
                );

                assert_eq!(nav, venue_equity - maintenance_reserve);
                assert_eq!(nav + maintenance_reserve, venue_equity);
            };
        });
    });
}

/// Prevents share pricing from subtracting an unbacked reserve.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMaintenanceReserveExceedsEquity,
    location = blast_boosts_core::accounting_math,
)]
fun a_reserve_above_venue_equity_is_rejected() {
    accounting_math::shareholder_nav(999, 1_000);
}

/// Pins the exact maximum-width underwater boundary and abort owner.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMaintenanceReserveExceedsEquity,
    location = blast_boosts_core::accounting_math,
)]
fun a_maximum_reserve_one_unit_above_equity_is_rejected() {
    accounting_math::shareholder_nav(
        std::u64::max_value!() - 1,
        std::u64::max_value!(),
    );
}

/// Pins exact fee credits, including a zero-fee no-op and the largest result.
#[test]
fun fee_credits_are_exact() {
    let max = std::u64::max_value!();

    assert_eq!(accounting_math::credit_fee(0, 0), 0);
    assert_eq!(accounting_math::credit_fee(0, max), max);
    assert_eq!(accounting_math::credit_fee(100, 0), 100);
    assert_eq!(accounting_math::credit_fee(100, 7), 107);
    assert_eq!(accounting_math::credit_fee(max - 1, 1), max);
    assert_eq!(accounting_math::credit_fee(max, 0), max);
}

/// Exhausts every successful small reserve credit and proves exact conservation.
#[test]
fun fee_credits_conserve_every_unit_across_the_small_domain() {
    0u64.range_do!(65, |reserve_before| {
        0u64.range_do!(65, |fee| {
            let reserve_after = accounting_math::credit_fee(reserve_before, fee);

            assert_eq!(reserve_after, reserve_before + fee);
            assert_eq!(reserve_after - reserve_before, fee);
            assert!(reserve_after >= reserve_before);
        });
    });
}

/// Catches a reserve credit that wraps at the u64 boundary.
#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_boosts_core::accounting_math,
)]
fun a_fee_credit_that_overflows_is_rejected() {
    accounting_math::credit_fee(std::u64::max_value!(), 1);
}

/// Covers zero, partial, exact, exhausted, and maximum-width funding costs.
#[test]
fun funding_cost_absorption_has_the_expected_boundaries() {
    let max = std::u64::max_value!();

    assert_funding_quote(100, 0, 100, 0, 0);
    assert_funding_quote(100, 60, 40, 60, 0);
    assert_funding_quote(100, 100, 0, 100, 0);
    assert_funding_quote(100, 160, 0, 100, 60);
    assert_funding_quote(0, max, 0, 0, max);
    assert_funding_quote(max - 1, max, 0, max - 1, 1);
    assert_funding_quote(max, max, 0, max, 0);
}

/// Exhausts a bounded domain and proves both reserve and funding conservation.
#[test]
fun funding_cost_absorption_conserves_every_unit() {
    0u64.range_do!(65, |reserve_before| {
        0u64.range_do!(65, |funding_cost| {
            let (reserve_after, absorbed, uncovered) =
                accounting_math::absorb_funding_cost(reserve_before, funding_cost);

            assert_eq!(reserve_after + absorbed, reserve_before);
            assert_eq!(absorbed + uncovered, funding_cost);
            assert!(absorbed <= reserve_before);
            assert!(absorbed <= funding_cost);
            assert!(reserve_after == 0 || uncovered == 0);
        });
    });
}

/// Prevents repeated settlement from absorbing more reserve than one combined settlement.
#[test]
fun sequential_funding_costs_match_one_combined_cost() {
    0u64.range_do!(33, |reserve_before| {
        0u64.range_do!(33, |first_cost| {
            0u64.range_do!(33, |second_cost| {
                let (reserve_1, absorbed_1, uncovered_1) =
                    accounting_math::absorb_funding_cost(reserve_before, first_cost);
                let (reserve_2, absorbed_2, uncovered_2) =
                    accounting_math::absorb_funding_cost(reserve_1, second_cost);
                let (combined_reserve, combined_absorbed, combined_uncovered) =
                    accounting_math::absorb_funding_cost(
                        reserve_before,
                        first_cost + second_cost,
                    );

                assert_eq!(reserve_2, combined_reserve);
                assert_eq!(absorbed_1 + absorbed_2, combined_absorbed);
                assert_eq!(uncovered_1 + uncovered_2, combined_uncovered);
            });
        });
    });

    let max = std::u64::max_value!();
    let (reserve_1, absorbed_1, uncovered_1) =
        accounting_math::absorb_funding_cost(max, max - 1);
    let (reserve_2, absorbed_2, uncovered_2) =
        accounting_math::absorb_funding_cost(reserve_1, 1);

    assert_eq!(reserve_2, 0);
    assert_eq!(absorbed_1 + absorbed_2, max);
    assert_eq!(uncovered_1 + uncovered_2, 0);
}

/// Proves covered funding leaves shareholder NAV unchanged and only the excess reaches it.
#[test]
fun the_reserve_shields_shareholders_only_from_authenticated_funding_cost() {
    let venue_equity_0 = 1_000;
    let reserve_0 = 100;
    let nav_0 = accounting_math::shareholder_nav(venue_equity_0, reserve_0);

    let (reserve_1, absorbed_1, uncovered_1) =
        accounting_math::absorb_funding_cost(reserve_0, 60);
    let venue_equity_1 = venue_equity_0 - 60;
    let nav_1 = accounting_math::shareholder_nav(venue_equity_1, reserve_1);

    assert_eq!(absorbed_1, 60);
    assert_eq!(uncovered_1, 0);
    assert_eq!(nav_1, nav_0);

    let (reserve_2, absorbed_2, uncovered_2) =
        accounting_math::absorb_funding_cost(reserve_1, 100);
    let venue_equity_2 = venue_equity_1 - 100;
    let nav_2 = accounting_math::shareholder_nav(venue_equity_2, reserve_2);

    assert_eq!(absorbed_2, 40);
    assert_eq!(uncovered_2, 60);
    assert_eq!(nav_2, nav_1 - uncovered_2);
}

/// Catches routing price loss or positive funding through the funding-cost reserve debit.
#[test]
fun non_funding_equity_changes_leave_the_reserve_unchanged() {
    let reserve = 100;
    let nav_before = accounting_math::shareholder_nav(1_000, reserve);
    let nav_after_trading_loss = accounting_math::shareholder_nav(975, reserve);
    let nav_after_positive_funding = accounting_math::shareholder_nav(1_025, reserve);

    assert_eq!(nav_before, 900);
    assert_eq!(nav_after_trading_loss, 875);
    assert_eq!(nav_after_positive_funding, 925);
}

/// Pins the worst non-funding loss: physical equity can fall below the recorded reserve.
#[test]
fun non_funding_loss_can_impair_the_reserve_and_must_enter_the_health_path() {
    assert!(accounting_math::is_reserve_backed(100, 100));
    assert!(!accounting_math::is_reserve_backed(99, 100));
}

/// Catches subtracting the reserve fee twice or ignoring actual execution loss.
#[test]
fun canonical_mint_credits_the_actual_nav_gain_net_of_the_retained_fee() {
    let (reserve_after, nav_before, nav_after, fee, contribution, shares_out, shares_after) =
        canonical_mint(
            1_000_000,
            1_000_000_000,
            1_001_000_000,
            0,
            2_000_000_000,
            100,
            0,
        );

    assert_eq!(reserve_after, 10_000);
    assert_eq!(nav_before, 1_000_000_000);
    assert_eq!(nav_after, 1_000_990_000);
    assert_eq!(fee, 10_000);
    assert_eq!(contribution, 990_000);
    assert_eq!(shares_out, 1_980_000);
    assert_eq!(shares_after, 2_001_980_000);

    // The same deposit through a market that costs 500_000 credits less.
    let (_, _, nav_after, fee, contribution, shares_out, shares_after) =
        canonical_mint(
            1_000_000,
            1_000_000_000,
            1_000_500_000,
            0,
            2_000_000_000,
            100,
            0,
        );

    assert_eq!(nav_after, 1_000_490_000);
    assert_eq!(fee, 10_000);
    assert_eq!(contribution, 490_000);
    assert_eq!(shares_out, 980_000);
    assert_eq!(shares_after, 2_000_980_000);
}

/// The allocation share is validated before any fee arithmetic.
#[test]
#[expected_failure(abort_code = accounting_math::EInvalidFeeBps, location = blast_boosts_core::accounting_math)]
fun fee_allocation_rejects_an_admin_share_above_the_whole_fee() {
    accounting_math::fee_allocation(1_000, 100, 10_001);
}

#[test]
fun fee_allocation_accepts_the_whole_fee_as_admin_share() {
    let (fee, admin, buffer) = accounting_math::fee_allocation(1_000, 100, 10_000);
    assert_eq!(vector[fee, admin, buffer], vector[10, 10, 0]);
}

/// Proves mint fees are excluded once while execution loss still reaches the depositor.
#[test]
fun mint_reserve_accounting_does_not_subtract_the_fee_twice() {
    let venue_equity_before = 10_000_000;
    let reserve_before = 100_000;
    let deposit = 1_000_000;
    // The venue charged 5,000 during the proportional position increase.
    let venue_equity_after = venue_equity_before + deposit - 5_000;
    let (reserve_after, nav_before, nav_after, fee, contribution, shares_out, _) =
        canonical_mint(
            deposit,
            venue_equity_before,
            venue_equity_after,
            reserve_before,
            9_900_000,
            100,
            0,
        );

    assert_eq!(reserve_after, 110_000);
    assert_eq!(nav_before, 9_900_000);
    assert_eq!(nav_after, 10_885_000);
    assert_eq!(fee, 10_000);
    assert_eq!(contribution, deposit - fee - 5_000);
    assert_eq!(shares_out, contribution);
}

/// Pins the only positive contribution possible from a 10,000-unit deposit at 9,999 bps.
#[test]
fun the_highest_fee_rate_can_mint_exactly_one_atomic_share() {
    let (reserve_after, _, nav_after, fee, contribution, shares_out, shares_after) =
        canonical_mint(
            10_000,
            100_000,
            110_000,
            0,
            100_000,
            9_999,
            0,
        );

    assert_eq!(reserve_after, 9_999);
    assert_eq!(nav_after, 100_001);
    assert_eq!(fee, 9_999);
    assert_eq!(contribution, 1);
    assert_eq!(shares_out, 1);
    assert_eq!(shares_after, 100_001);
}

/// Exhausts fee, reserve, execution-loss, NAV, and share-rounding combinations.
#[test]
fun canonical_mints_match_independent_accounting_across_the_small_domain() {
    1u64.range_do!(9, |nav_before| {
        0u64.range_do!(5, |reserve_before| {
            1u64.range_do!(13, |deposit| {
                0u64.range_do!(3, |execution_loss| {
                    vector[0u64, 1, 5_000, 9_999].do!(|mint_fee_bps| {
                        vector[1u64, 3, 7].do!(|shares_before| {
                            let fee = reference_fee_up(deposit, mint_fee_bps);
                            let cost = fee + execution_loss;

                            if (deposit > cost) {
                                let contribution = deposit - cost;
                                let expected_shares = (
                                    (shares_before as u128) * (contribution as u128)
                                        / (nav_before as u128),
                                ) as u64;

                                if (expected_shares > 0) {
                                    assert_canonical_mint_matches_reference(
                                        deposit,
                                        nav_before,
                                        reserve_before,
                                        shares_before,
                                        mint_fee_bps,
                                        execution_loss,
                                    );
                                };
                            };
                        });
                    });
                });
            });
        });
    });
}

/// Reaches a nonzero fee and reserve close to `u64::MAX` without narrowing or wrapping.
#[test]
fun canonical_mint_supports_the_highest_fee_near_the_u64_boundary() {
    let max = std::u64::max_value!();
    let (
        reserve_after,
        nav_before,
        nav_after,
        fee,
        contribution,
        shares_out,
        shares_after,
    ) = canonical_mint(
        10_000,
        max - 10_000,
        max,
        max - 20_000,
        10_000,
        9_999,
        0,
    );

    assert_eq!(reserve_after, max - 10_001);
    assert_eq!(nav_before, 10_000);
    assert_eq!(nav_after, 10_001);
    assert_eq!(fee, 9_999);
    assert_eq!(contribution, 1);
    assert_eq!(shares_out, 1);
    assert_eq!(shares_after, 10_001);
    assert_eq!(nav_after + reserve_after, max);
}

/// Pins the pre-mint reserve check ahead of every low-level mint input check.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMaintenanceReserveExceedsEquity,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_rejects_an_unbacked_pre_mint_reserve_first() {
    canonical_mint(0, 99, 0, 100, 0, 10_000, 0);
}

/// Pins fee validation before deriving an invalid post-mint reserve checkpoint.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidFeeBps,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_rejects_an_invalid_fee_before_post_mint_backing() {
    canonical_mint(1, 100, 0, 0, 0, 10_000, 0);
}

/// Pins fee validation ahead of contribution validation when both are invalid.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidFeeBps,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_rejects_an_invalid_fee_before_a_nonpositive_contribution() {
    canonical_mint(10, 1_000, 999, 0, 1_000, 10_000, 0);
}

/// Catches a maximum-width reserve credit that wraps before post-mint backing is checked.
#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_rejects_a_reserve_credit_above_u64() {
    canonical_mint(
        1,
        std::u64::max_value!(),
        std::u64::max_value!(),
        std::u64::max_value!(),
        1,
        1,
        0,
    );
}

/// Catches deriving post-mint NAV before crediting a fee that is no longer backed.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMaintenanceReserveExceedsEquity,
    location = blast_boosts_core::accounting_math,
)]
fun a_mint_cannot_credit_more_reserve_than_post_mint_equity_backs() {
    canonical_mint(100, 100, 99, 0, 100, 9_999, 0);
}

/// Catches accepting a deposit whose fee consumes the complete shareholder NAV gain.
#[test]
#[expected_failure(
    abort_code = accounting_math::ENonpositiveContribution,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_without_shareholder_nav_gain_is_rejected() {
    canonical_mint(10_000, 1_000, 1_000, 0, 1_000, 100, 0);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::ENonpositiveContribution,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_that_lowers_nav_is_rejected() {
    canonical_mint(10, 1_000, 999, 0, 1_000, 0, 0);
}

/// Pins the contribution guard ahead of the low-level supply guard.
#[test]
#[expected_failure(
    abort_code = accounting_math::ENonpositiveContribution,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_rejects_a_nonpositive_contribution_before_zero_supply() {
    canonical_mint(10, 1_000, 999, 0, 0, 0, 0);
}

/// Pins the low-level supply guard once the canonical path has a positive contribution.
#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidShareSupply,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_against_zero_supply_is_rejected() {
    canonical_mint(10, 1_000, 1_010, 0, 0, 0, 0);
}

/// Pins deposit validation before the low-level NAV and supply guards.
#[test]
#[expected_failure(
    abort_code = accounting_math::EZeroAmount,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_mint_rejects_zero_deposit_before_zero_nav_and_supply() {
    canonical_mint(0, 0, 0, 0, 0, 10_000, 0);
}

/// Pins the reserve-backing guard before redemption's low-level input guards.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMaintenanceReserveExceedsEquity,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_redemption_rejects_unbacked_reserve_before_share_inputs() {
    accounting_math::redemption_accounting_quote(0, 999, 999, 1_000, 0, 10_000);
}

/// The mint range assertion aborts with the over-exposure code above the planned fill.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMintOverExposed,
    location = blast_boosts_core::accounting_math,
)]
fun mint_base_bound_assertion_rejects_over_exposure() {
    accounting_math::assert_mint_base_within_bounds(1_761, 80, 75, 1_600, 800, 10, 1);
}

/// The mint range assertion aborts with the under-exposure code below the funded fill.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMintUnderExposed,
    location = blast_boosts_core::accounting_math,
)]
fun mint_base_bound_assertion_rejects_under_exposure() {
    accounting_math::assert_mint_base_within_bounds(1_749, 80, 75, 1_600, 800, 10, 1);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_boosts_core::accounting_math,
)]
fun leverage_ratio_rejects_an_overflowing_result() {
    accounting_math::leverage_bps_up(std::u64::max_value!(), 9_999);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_boosts_core::accounting_math,
)]
fun target_notional_rejects_an_overflowing_result() {
    accounting_math::target_notional_down(std::u64::max_value!(), 10_001);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EArithmeticOverflow,
    location = blast_boosts_core::accounting_math,
)]
fun mint_base_delta_rejects_an_overflowing_target() {
    accounting_math::mint_base_delta_down(3, std::u64::max_value!(), 2, 1, 1);
}

/// Reaches maximum-width venue equity through both canonical accounting paths.
#[test]
fun canonical_quotes_support_the_maximum_venue_equity() {
    let max = std::u64::max_value!();
    let (reserve_after, nav_before, nav_after, fee, contribution, shares_out, shares_after) =
        canonical_mint(
            100,
            max - 100,
            max,
            0,
            max - 100,
            0,
            0,
        );

    assert_eq!(reserve_after, 0);
    assert_eq!(nav_before, max - 100);
    assert_eq!(nav_after, max);
    assert_eq!(fee, 0);
    assert_eq!(contribution, 100);
    assert_eq!(shares_out, 100);
    assert_eq!(shares_after, max);

    let (reserve_after, shares_after, equity_keep, _, gross, fee, net) =
        accounting_math::redemption_accounting_quote(
            1,
            max,
            max,
            1,
            max - 1,
            0,
        );

    assert_eq!(reserve_after, 1);
    assert_eq!(shares_after, max - 2);
    assert_eq!(equity_keep, max - 2);
    assert_eq!(gross, 1);
    assert_eq!(fee, 0);
    assert_eq!(net, 1);
}

/// Catches gaining shares by splitting a reserve-aware mint.
#[test]
fun splitting_a_canonical_mint_does_not_create_extra_shares() {
    let (_, _, _, _, _, combined_shares, _) = canonical_mint(
        200,
        1_100,
        1_300,
        100,
        333,
        100,
        0,
    );
    let (reserve_1, _, _, _, _, first_shares, shares_1) =
        canonical_mint(100, 1_100, 1_200, 100, 333, 100, 0);
    let (_, _, _, _, _, second_shares, _) = canonical_mint(
        100,
        1_200,
        1_300,
        reserve_1,
        shares_1,
        100,
        0,
    );

    assert_eq!(combined_shares, 65);
    assert_eq!(first_shares + second_shares, 64);
    assert!(first_shares + second_shares <= combined_shares);
}

/// Sweeps zero through maximum fees and a nonzero reserve for split-mint attacks.
#[test]
fun split_canonical_mints_never_create_more_shares_than_one_combined_mint() {
    vector[0u64, 1, 100, 5_000, 9_999].do!(|mint_fee_bps| {
        vector[0u64, 12_345].do!(|reserve_before| {
            assert_split_mint(
                1_000_000,
                reserve_before,
                333_333,
                1_000_000,
                1_000_001,
                mint_fee_bps,
            );
        });
    });
}

/// Reconciles the fee credit and payout back to exact remaining shareholder NAV.
#[test]
fun redemption_fee_moves_to_the_reserve_without_remaining_in_shareholder_nav() {
    let venue_equity_before = 10_000_000;
    let reserve_before = 100_000;
    let shares_before = 9_900_000;
    // The proportional unwind charged 10,000 in venue execution costs.
    let venue_equity_unwound = venue_equity_before - 10_000;
    let (reserve_after, _, equity_keep, _, _, fee, net) =
        accounting_math::redemption_accounting_quote(
            990_000,
            venue_equity_before,
            venue_equity_unwound,
            reserve_before,
            shares_before,
            100,
        );
    let venue_equity_after = venue_equity_unwound - net;
    let nav_after = accounting_math::shareholder_nav(venue_equity_after, reserve_after);

    assert_eq!(equity_keep, 8_910_000);
    assert_eq!(fee, 9_800);
    assert_eq!(net, 970_200);
    assert_eq!(nav_after, equity_keep);
}

/// Exhausts fee, reserve, execution-loss, NAV, supply, burn, and rounding combinations.
#[test]
fun canonical_redemptions_match_independent_accounting_across_the_small_domain() {
    1u64.range_do!(13, |nav_before| {
        0u64.range_do!(3, |reserve_before| {
            2u64.range_do!(9, |shares_before| {
                1u64.range_do!(shares_before, |shares_burned| {
                    0u64.range_do!(2, |execution_loss| {
                        vector[0u64, 1, 5_000, 9_999].do!(|redeem_fee_bps| {
                            let shares_after = shares_before - shares_burned;
                            let equity_keep = (
                                (nav_before as u128) * (shares_after as u128),
                            ).div_ceil(shares_before as u128) as u64;

                            if (nav_before >= execution_loss) {
                                let nav_unwound = nav_before - execution_loss;

                                if (nav_unwound > equity_keep) {
                                    let gross = nav_unwound - equity_keep;
                                    let fee = reference_fee_up(gross, redeem_fee_bps);

                                    if (gross > fee) {
                                        assert_canonical_redemption_matches_reference(
                                            nav_before,
                                            reserve_before,
                                            shares_before,
                                            shares_burned,
                                            redeem_fee_bps,
                                            execution_loss,
                                        );
                                    };
                                };
                            };
                        });
                    });
                });
            });
        });
    });
}

/// Reaches a maximum fee and near-maximum reserve while leaving one unit for each claimant.
#[test]
fun canonical_redemption_supports_the_highest_fee_near_the_u64_boundary() {
    let max = std::u64::max_value!();
    let (reserve_after, shares_after, equity_keep, _, gross, fee, net) =
        accounting_math::redemption_accounting_quote(
            10_000,
            max,
            max,
            max - 10_001,
            10_001,
            9_999,
        );
    let venue_equity_after = max - net;
    let nav_after = accounting_math::shareholder_nav(
        venue_equity_after,
        reserve_after,
    );

    assert_eq!(reserve_after, max - 2);
    assert_eq!(shares_after, 1);
    assert_eq!(equity_keep, 1);
    assert_eq!(gross, 10_000);
    assert_eq!(fee, 9_999);
    assert_eq!(net, 1);
    assert_eq!(nav_after, equity_keep);
}

/// Proves that authenticated unwind loss reduces only the redeemer's gross claim.
#[test]
fun canonical_redemption_reconciles_execution_loss_at_both_sides_of_a_rounding_cliff() {
    assert_canonical_redemption_matches_reference(1_001, 77, 100, 10, 100, 0);
    assert_canonical_redemption_matches_reference(1_001, 77, 100, 10, 100, 1);
}

/// Pins the post-unwind reserve check ahead of share and fee validation.
#[test]
#[expected_failure(
    abort_code = accounting_math::EMaintenanceReserveExceedsEquity,
    location = blast_boosts_core::accounting_math,
)]
fun a_canonical_redemption_rejects_an_unbacked_unwind_reserve_first() {
    accounting_math::redemption_accounting_quote(0, 100, 99, 100, 0, 10_000);
}

/// Regression for fee recapture: split redemptions now preserve the same final NAV and reserve.
#[test]
fun splitting_a_redemption_cannot_recapture_an_earlier_reserve_fee() {
    let venue_equity_0 = 10_000_000;
    let reserve_0 = 0;
    let (combined_reserve, _, combined_keep, _, _, _, combined_net) =
        accounting_math::redemption_accounting_quote(
            98,
            venue_equity_0,
            venue_equity_0,
            reserve_0,
            100,
            100,
        );
    let combined_equity = venue_equity_0 - combined_net;
    let combined_nav = accounting_math::shareholder_nav(
        combined_equity,
        combined_reserve,
    );

    let (reserve_1, shares_1, keep_1, _, _, _, net_1) =
        accounting_math::redemption_accounting_quote(
            49,
            venue_equity_0,
            venue_equity_0,
            reserve_0,
            100,
            100,
        );
    let venue_equity_1 = venue_equity_0 - net_1;
    let nav_1 = accounting_math::shareholder_nav(venue_equity_1, reserve_1);
    assert_eq!(nav_1, keep_1);

    let (reserve_2, _, keep_2, _, _, _, net_2) =
        accounting_math::redemption_accounting_quote(
            49,
            venue_equity_1,
            venue_equity_1,
            reserve_1,
            shares_1,
            100,
        );
    let venue_equity_2 = venue_equity_1 - net_2;
    let nav_2 = accounting_math::shareholder_nav(venue_equity_2, reserve_2);

    assert_eq!(combined_keep, 200_000);
    assert_eq!(combined_nav, combined_keep);
    assert_eq!(nav_2, keep_2);
    assert_eq!(nav_2, combined_nav);
    assert_eq!(reserve_2, combined_reserve);
    assert_eq!(net_1 + net_2, combined_net);
}

/// Sweeps split points, supplies, and a nonzero starting reserve for fee recapture.
#[test]
fun split_redemptions_never_pay_more_than_one_combined_redemption() {
    3u64.range_do!(18, |shares_before| {
        2u64.range_do!(shares_before, |shares_burned| {
            1u64.range_do!(shares_burned, |first_burn| {
                vector[0u64, 1, 100, 5_000, 9_999].do!(|redeem_fee_bps| {
                    assert_split_redemption(
                        1_000_000 + shares_before,
                        12_345,
                        shares_before,
                        shares_burned,
                        first_burn,
                        redeem_fee_bps,
                    );
                });
            });
        });
    });
}

/// Exercises mint, covered funding, redemption, and positive funding as one ledger sequence.
#[test]
fun a_multi_operation_sequence_preserves_venue_equity_as_nav_plus_reserve() {
    let venue_equity_0 = 1_000_000;
    let reserve_0 = 10_000;
    let nav_0 = accounting_math::shareholder_nav(venue_equity_0, reserve_0);
    let deposit = 100_000;
    let venue_equity_1 = venue_equity_0 + deposit - 500;
    let (
        reserve_1,
        quoted_nav_0,
        quoted_nav_1,
        _,
        contribution,
        minted,
        shares_1,
    ) =
        canonical_mint(
            deposit,
            venue_equity_0,
            venue_equity_1,
            reserve_0,
            nav_0,
            100,
            0,
        );
    let nav_1 = accounting_math::shareholder_nav(venue_equity_1, reserve_1);

    assert_eq!(quoted_nav_0, nav_0);
    assert_eq!(quoted_nav_1, nav_1);
    assert_eq!(contribution, deposit - 1_000 - 500);
    assert_eq!(minted, contribution);
    assert_eq!(venue_equity_1, nav_1 + reserve_1);

    let funding_cost = 7_000;
    let (reserve_2, absorbed, uncovered) =
        accounting_math::absorb_funding_cost(reserve_1, funding_cost);
    let venue_equity_2 = venue_equity_1 - funding_cost;
    let nav_2 = accounting_math::shareholder_nav(venue_equity_2, reserve_2);

    assert_eq!(absorbed, funding_cost);
    assert_eq!(uncovered, 0);
    assert_eq!(nav_2, nav_1);
    assert_eq!(venue_equity_2, nav_2 + reserve_2);

    let (reserve_3, _, equity_keep, _, _, _, net) =
        accounting_math::redemption_accounting_quote(
            minted,
            venue_equity_2,
            venue_equity_2,
            reserve_2,
            shares_1,
            100,
        );
    let venue_equity_3 = venue_equity_2 - net;
    let nav_3 = accounting_math::shareholder_nav(venue_equity_3, reserve_3);

    assert_eq!(nav_3, equity_keep);
    assert_eq!(venue_equity_3, nav_3 + reserve_3);

    let positive_funding = 2_000;
    let venue_equity_4 = venue_equity_3 + positive_funding;
    let nav_4 = accounting_math::shareholder_nav(venue_equity_4, reserve_3);

    assert_eq!(nav_4, nav_3 + positive_funding);
    assert_eq!(venue_equity_4, nav_4 + reserve_3);
}

/// Exercises mint, complete reserve depletion, uncovered funding, and redemption.
#[test]
fun a_sequence_after_reserve_exhaustion_charges_only_uncovered_funding_to_nav() {
    let venue_equity_0 = 1_000_000;
    let reserve_0 = 10_000;
    let nav_0 = accounting_math::shareholder_nav(venue_equity_0, reserve_0);
    let (reserve_1, _, nav_1, fee, contribution, minted, shares_1) =
        canonical_mint(
            100_000,
            venue_equity_0,
            1_100_000,
            reserve_0,
            nav_0,
            100,
            0,
        );

    assert_eq!(fee, 1_000);
    assert_eq!(reserve_1, 11_000);
    assert_eq!(contribution, 99_000);
    assert_eq!(minted, 99_000);

    let funding_cost = reserve_1 + 50_000;
    let (reserve_2, absorbed, uncovered) =
        accounting_math::absorb_funding_cost(reserve_1, funding_cost);
    let venue_equity_2 = 1_100_000 - funding_cost;
    let nav_2 = accounting_math::shareholder_nav(venue_equity_2, reserve_2);

    assert_eq!(reserve_2, 0);
    assert_eq!(absorbed, reserve_1);
    assert_eq!(uncovered, 50_000);
    assert_eq!(nav_2, nav_1 - uncovered);

    let (reserve_3, _, equity_keep, _, gross, fee, net) =
        accounting_math::redemption_accounting_quote(
            minted,
            venue_equity_2,
            venue_equity_2,
            reserve_2,
            shares_1,
            100,
        );
    let venue_equity_3 = venue_equity_2 - net;
    let nav_3 = accounting_math::shareholder_nav(venue_equity_3, reserve_3);

    assert_eq!(gross, fee + net);
    assert_eq!(nav_3, equity_keep);
    assert_eq!(venue_equity_3, nav_3 + reserve_3);
}

/// Samples the interior domain with Move random-test seeds.
#[random_test]
fun random_accounting_sequences_conserve(seed: u32) {
    let seed = seed as u64;
    let nav_before = seed * 97 + 10_000;
    let reserve_before = seed % 10_001;
    let venue_equity_before = nav_before + reserve_before;
    let deposit = seed % 1_000_001 + 10_000;
    let fee_bps = seed % 1_000;
    let venue_equity_after = venue_equity_before + deposit;
    let (
        reserve_after,
        quoted_nav_before,
        quoted_nav_after,
        fee,
        contribution,
        shares_out,
        shares_after,
    ) =
        canonical_mint(
            deposit,
            venue_equity_before,
            venue_equity_after,
            reserve_before,
            nav_before,
            fee_bps,
            0,
        );
    let nav_after = accounting_math::shareholder_nav(
        venue_equity_after,
        reserve_after,
    );

    assert_eq!(contribution, deposit - fee);
    assert_eq!(quoted_nav_before, nav_before);
    assert_eq!(quoted_nav_after, nav_after);
    assert_eq!(shares_out, contribution);
    assert_eq!(venue_equity_after, nav_after + reserve_after);

    let funding_cost = seed * 53 % (venue_equity_after + 1);
    let (reserve_funded, absorbed, uncovered) =
        accounting_math::absorb_funding_cost(reserve_after, funding_cost);
    let venue_equity_funded = venue_equity_after - funding_cost;
    let nav_funded = accounting_math::shareholder_nav(
        venue_equity_funded,
        reserve_funded,
    );

    assert_eq!(reserve_funded + absorbed, reserve_after);
    assert_eq!(absorbed + uncovered, funding_cost);
    assert_eq!(nav_funded + uncovered, nav_after);
    assert_eq!(venue_equity_funded, nav_funded + reserve_funded);
    assert_eq!(shares_after, nav_after);
}

/// The favorable direction: equity that appears between the two readings stays
/// with the remaining holders; the redeemer is paid exactly the proportional
/// claim and the quote reports the NAV that actually remains (ADR 0084 D3).
#[test]
fun a_favorable_unwind_pays_exactly_the_claim_and_keeps_the_gain_for_holders() {
    let (reserve_after, shares_after, nav_kept, proportional_claim, gross, fee, net) =
        accounting_math::redemption_accounting_quote(
            1,
            1_000_000,
            1_000_100,
            0,
            1_000_000,
            0,
        );

    assert_eq!(reserve_after, 0);
    assert_eq!(shares_after, 999_999);
    assert_eq!(nav_kept, 1_000_099);
    assert_eq!(proportional_claim, 1);
    assert_eq!(gross, 1);
    assert_eq!(fee, 0);
    assert_eq!(net, 1);
}

/// Pins the three unwound readings: a gain pays the claim, a loss pays less, and
/// the NAV kept for the remaining holders is never below the proportional keep.
#[test]
fun the_proportional_claim_is_independent_of_the_unwound_reading() {
    let (_, _, kept_flat, claim_flat, gross_flat, _, _) =
        accounting_math::redemption_accounting_quote(250, 10_000, 10_000, 500, 1_000, 30);
    let (_, _, kept_gain, claim_gain, gross_gain, _, _) =
        accounting_math::redemption_accounting_quote(250, 10_000, 10_400, 500, 1_000, 30);
    let (_, _, kept_loss, claim_loss, gross_loss, _, _) =
        accounting_math::redemption_accounting_quote(250, 10_000, 9_900, 500, 1_000, 30);

    assert_eq!(kept_flat, 7_125);
    assert_eq!(kept_gain, 7_525);
    assert_eq!(kept_loss, 7_125);
    assert_eq!(claim_flat, 2_375);
    assert_eq!(claim_gain, claim_flat);
    assert_eq!(claim_loss, claim_flat);
    assert_eq!(gross_flat, 2_375);
    assert_eq!(gross_gain, 2_375);
    assert_eq!(gross_loss, 2_275);
}

/// A canonical mint whose NAV rises by more than `deposit - fee` credits exactly that.
#[test]
fun canonical_mint_credits_at_most_the_deposit_net_of_the_fee() {
    // The venue gained 5,000 during the proportional position increase.
    let (reserve_after, nav_before, nav_after, fee, contribution, shares_out, shares_after) =
        canonical_mint(
            1_000_000,
            10_000_000,
            10_000_000 + 1_000_000 + 5_000,
            100_000,
            9_900_000,
            100,
            0,
        );

    assert_eq!(reserve_after, 110_000);
    assert_eq!(nav_before, 9_900_000);
    assert_eq!(nav_after, 10_895_000);
    assert_eq!(fee, 10_000);
    assert_eq!(contribution, 990_000);
    assert_eq!(shares_out, 990_000);
    assert_eq!(shares_after, 10_890_000);
    // The 5,000-unit excess raises NAV per share for every holder.
    assert!((nav_after as u128) * 9_900_000 > (nav_before as u128) * (shares_after as u128));
}

/// The allocated quote credits `min(rise, expected)`, favorable or costly, and
/// still rejects a mint whose NAV does not rise.
#[test]
fun allocated_mint_quote_credits_the_capped_contribution() {
    let (nav_after, contribution, shares) =
        accounting_math::allocated_mint_quote(1_100_000, 2_102_000, 100_000, 101_000, 999_000, 1_000_000, 1);
    assert_eq!(vector[nav_after, contribution, shares], vector[2_001_000, 999_000, 999_000]);

    let (nav_after, contribution, shares) =
        accounting_math::allocated_mint_quote(1_100_000, 2_098_000, 100_000, 101_000, 999_000, 1_000_000, 1);
    assert_eq!(vector[nav_after, contribution, shares], vector[1_997_000, 997_000, 997_000]);

    let (nav_after, contribution, shares) =
        accounting_math::allocated_mint_quote(1_100_000, 2_100_000, 100_000, 101_000, 999_000, 1_000_000, 1);
    assert_eq!(vector[nav_after, contribution, shares], vector[1_999_000, 999_000, 999_000]);
}

#[test]
#[expected_failure(abort_code = accounting_math::ENonpositiveContribution, location = blast_boosts_core::accounting_math)]
fun allocated_mint_quote_rejects_a_flat_nav_before_the_cap() {
    accounting_math::allocated_mint_quote(1_100_000, 1_101_000, 100_000, 101_000, 999_000, 1_000_000, 1);
}

#[test]
#[expected_failure(abort_code = accounting_math::ESharesOutBelowMinimum, location = blast_boosts_core::accounting_math)]
fun allocated_mint_quote_applies_the_share_floor_to_the_capped_contribution() {
    accounting_math::allocated_mint_quote(1_100_000, 2_102_000, 100_000, 101_000, 999_000, 1_000_000, 999_001);
}

/// A maximum-width favorable rise is capped without widening or wrapping.
#[test]
fun allocated_mint_quote_caps_a_maximum_width_favorable_rise() {
    let max = std::u64::max_value!();
    let (nav_after, contribution, shares) =
        accounting_math::allocated_mint_quote(1, max, 0, 0, 1, 1, 1);
    assert_eq!(vector[nav_after, contribution, shares], vector[max, 1, 1]);
}

/// Exhausts deposits, fees, favorable and costly rises, and supplies: the
/// credited contribution is `min(rise, deposit - fee)` and the NAV per share of
/// existing holders never falls at the fixed valuation pair.
#[test]
fun capped_mints_never_lower_existing_holders_nav_per_share_across_the_small_domain() {
    1u64.range_do!(7, |nav_before| {
        1u64.range_do!(6, |shares_before| {
            1u64.range_do!(11, |deposit| {
                vector[0u64, 5_000].do!(|mint_fee_bps| {
                    0u64.range_do!(11, |rise| {
                        let fee = reference_fee_up(deposit, mint_fee_bps);
                        if (deposit > fee && rise > 0) {
                            let expected_contribution = (deposit - fee).min(rise);
                            let expected_shares = (
                                (shares_before as u128) * (expected_contribution as u128)
                                    / (nav_before as u128),
                            ) as u64;
                            if (expected_shares > 0) {
                                let (nav_after, contribution, shares) =
                                    accounting_math::allocated_mint_quote(
                                        nav_before, nav_before + rise, 0, 0,
                                        deposit - fee, shares_before, 0,
                                    );
                                assert_eq!(nav_after, nav_before + rise);
                                assert_eq!(contribution, expected_contribution);
                                assert_eq!(shares, expected_shares);
                                assert!(
                                    (nav_after as u128) * (shares_before as u128)
                                        >= (nav_before as u128) * ((shares_before + shares) as u128),
                                );
                            };
                        };
                    });
                });
            });
        });
    });
}

/// Exhausts unwound readings below, at, and above the pre-unwind NAV: the gross
/// never exceeds the proportional claim and the NAV kept for the remaining
/// holders never prices below the pre-unwind share price.
#[test]
fun capped_redemptions_never_lower_remaining_holders_nav_per_share_across_the_small_domain() {
    1u64.range_do!(9, |nav_before| {
        2u64.range_do!(7, |shares_before| {
            1u64.range_do!(shares_before, |shares_burned| {
                0u64.range_do!(17, |nav_unwound| {
                    let shares_after = shares_before - shares_burned;
                    let equity_keep = ((nav_before as u128) * (shares_after as u128))
                        .div_ceil(shares_before as u128) as u64;
                    if (nav_unwound.min(nav_before) > equity_keep) {
                        let (_, quoted_after, nav_kept, claim, gross, fee, net) =
                            accounting_math::redemption_accounting_quote(
                                shares_burned, nav_before, nav_unwound, 0, shares_before, 0,
                            );
                        assert_eq!(quoted_after, shares_after);
                        assert_eq!(claim, nav_before - equity_keep);
                        assert_eq!(gross, nav_unwound.min(nav_before) - equity_keep);
                        assert!(gross <= claim);
                        assert_eq!(fee, 0);
                        assert_eq!(nav_kept + net, nav_unwound);
                        assert!(nav_kept >= equity_keep);
                        assert!(
                            (nav_kept as u128) * (shares_before as u128)
                                >= (nav_before as u128) * (shares_after as u128),
                        );
                    };
                });
            });
        });
    });
}

#[test]
fun a_mint_at_its_share_floor_is_accepted() {
    let (_, _, _, _, _, shares_out, shares_after) =
        canonical_mint(1_000, 1_000, 2_000, 0, 1_000, 0, 1_000);

    assert_eq!(shares_out, 1_000);
    assert_eq!(shares_after, 2_000);
}

#[test]
#[expected_failure(
    abort_code = accounting_math::ESharesOutBelowMinimum,
    location = blast_boosts_core::accounting_math,
)]
fun a_mint_one_share_below_its_floor_is_rejected() {
    canonical_mint(1_000, 1_000, 2_000, 0, 1_000, 0, 1_001);
}

/// The audit case: a one-share pool at NAV 1e9 takes a 1,999,999,999 deposit for
/// one share, a 25 percent rounding loss. A share floor of two rejects it.
#[test]
#[expected_failure(
    abort_code = accounting_math::ESharesOutBelowMinimum,
    location = blast_boosts_core::accounting_math,
)]
fun the_share_floor_bounds_the_seed_inflation_loss() {
    canonical_mint(
        1_999_999_999,
        1_000_000_000,
        2_999_999_999,
        0,
        1,
        0,
        2,
    );
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EZeroSharesOut,
    location = blast_boosts_core::accounting_math,
)]
fun zero_shares_are_rejected_before_the_share_floor() {
    canonical_mint(1, 1_000_000_000, 1_000_000_001, 0, 1, 0, 5);
}

#[test]
fun shareholder_nav_positivity_never_aborts_and_agrees_with_shareholder_nav() {
    0u64.range_do!(8, |venue_equity| {
        0u64.range_do!(8, |maintenance_reserve| {
            let positive = accounting_math::is_shareholder_nav_positive(
                venue_equity,
                maintenance_reserve,
            );

            assert_eq!(positive, maintenance_reserve < venue_equity);
            if (accounting_math::is_reserve_backed(venue_equity, maintenance_reserve)) {
                assert_eq!(
                    positive,
                    accounting_math::shareholder_nav(venue_equity, maintenance_reserve) > 0,
                );
            };
        });
    });
}

/// A wiped account is still backed, so the health path must also check
/// positivity before it prices leverage.
#[test]
fun a_wiped_account_is_backed_but_has_no_positive_nav() {
    assert!(accounting_math::is_reserve_backed(5_000_000, 5_000_000));
    assert!(!accounting_math::is_shareholder_nav_positive(5_000_000, 5_000_000));
    assert!(accounting_math::is_shareholder_nav_positive(5_000_001, 5_000_000));
    assert!(!accounting_math::is_shareholder_nav_positive(4_999_999, 5_000_000));
}

#[test]
#[expected_failure(
    abort_code = accounting_math::EInvalidNav,
    location = blast_boosts_core::accounting_math,
)]
fun leverage_ratio_rejects_zero_nav() {
    accounting_math::leverage_bps_up(10_000_000, 0);
}

// === Private Test Helpers ===

/// Independent ceiling-fee formula used only by this test module.
fun reference_fee_up(amount: u64, fee_bps: u64): u64 {
    ((amount as u128) * (fee_bps as u128)).div_ceil(10_000) as u64
}

/// Reconciles every output of one canonical mint against an independent formula.
fun assert_canonical_mint_matches_reference(
    deposit: u64,
    nav_before: u64,
    reserve_before: u64,
    shares_before: u64,
    mint_fee_bps: u64,
    execution_loss: u64,
) {
    let venue_equity_before = nav_before + reserve_before;
    let venue_equity_after = venue_equity_before + deposit - execution_loss;
    let expected_fee = reference_fee_up(deposit, mint_fee_bps);
    let expected_reserve = reserve_before + expected_fee;
    let expected_nav_after = venue_equity_after - expected_reserve;
    let expected_contribution = expected_nav_after - nav_before;
    let expected_shares = (
        (shares_before as u128) * (expected_contribution as u128)
            / (nav_before as u128),
    ) as u64;
    let (
        reserve_after,
        quoted_nav_before,
        quoted_nav_after,
        fee,
        contribution,
        shares_out,
        shares_after,
    ) = canonical_mint(
        deposit,
        venue_equity_before,
        venue_equity_after,
        reserve_before,
        shares_before,
        mint_fee_bps,
        0,
    );

    assert_eq!(reserve_after, expected_reserve);
    assert_eq!(quoted_nav_before, nav_before);
    assert_eq!(quoted_nav_after, expected_nav_after);
    assert_eq!(fee, expected_fee);
    assert_eq!(contribution, expected_contribution);
    assert_eq!(shares_out, expected_shares);
    assert_eq!(shares_after, shares_before + expected_shares);
    assert_eq!(venue_equity_after, quoted_nav_after + reserve_after);
    assert!(
        (quoted_nav_after as u128) * (shares_before as u128)
            >= (nav_before as u128) * (shares_after as u128),
    );
}

/// Compares one mint with the same deposit split into two transactions.
fun assert_split_mint(
    nav_before: u64,
    reserve_before: u64,
    shares_before: u64,
    first_deposit: u64,
    second_deposit: u64,
    mint_fee_bps: u64,
) {
    let venue_equity_before = nav_before + reserve_before;
    let combined_deposit = first_deposit + second_deposit;
    let (_, _, _, _, _, combined_shares, _) = canonical_mint(
        combined_deposit,
        venue_equity_before,
        venue_equity_before + combined_deposit,
        reserve_before,
        shares_before,
        mint_fee_bps,
        0,
    );
    let (reserve_1, _, _, _, _, first_shares, shares_1) =
        canonical_mint(
            first_deposit,
            venue_equity_before,
            venue_equity_before + first_deposit,
            reserve_before,
            shares_before,
            mint_fee_bps,
            0,
        );
    let venue_equity_1 = venue_equity_before + first_deposit;
    let (_, _, _, _, _, second_shares, _) = canonical_mint(
        second_deposit,
        venue_equity_1,
        venue_equity_1 + second_deposit,
        reserve_1,
        shares_1,
        mint_fee_bps,
        0,
    );

    assert!(first_shares + second_shares <= combined_shares);
}

/// Reconciles every output of one canonical redemption against an independent formula.
fun assert_canonical_redemption_matches_reference(
    nav_before: u64,
    reserve_before: u64,
    shares_before: u64,
    shares_burned: u64,
    redeem_fee_bps: u64,
    execution_loss: u64,
) {
    let venue_equity_before = nav_before + reserve_before;
    let venue_equity_unwound = venue_equity_before - execution_loss;
    let expected_shares_after = shares_before - shares_burned;
    let expected_equity_keep = (
        (nav_before as u128) * (expected_shares_after as u128),
    ).div_ceil(shares_before as u128) as u64;
    let expected_gross = nav_before - execution_loss - expected_equity_keep;
    let expected_fee = reference_fee_up(expected_gross, redeem_fee_bps);
    let expected_net = expected_gross - expected_fee;
    let expected_reserve = reserve_before + expected_fee;
    let (reserve_after, shares_after, equity_keep, proportional_claim, gross, fee, net) =
        accounting_math::redemption_accounting_quote(
            shares_burned,
            venue_equity_before,
            venue_equity_unwound,
            reserve_before,
            shares_before,
            redeem_fee_bps,
        );
    let venue_equity_after = venue_equity_unwound - net;

    assert_eq!(proportional_claim, nav_before - expected_equity_keep);
    assert_eq!(gross + execution_loss, proportional_claim);
    let nav_after = accounting_math::shareholder_nav(
        venue_equity_after,
        reserve_after,
    );

    assert_eq!(reserve_after, expected_reserve);
    assert_eq!(shares_after, expected_shares_after);
    assert_eq!(equity_keep, expected_equity_keep);
    assert_eq!(gross, expected_gross);
    assert_eq!(fee, expected_fee);
    assert_eq!(net, expected_net);
    assert_eq!(gross, fee + net);
    assert_eq!(nav_after, equity_keep);
    assert_eq!(venue_equity_after, nav_after + reserve_after);
    assert!(
        (equity_keep as u128) * (shares_before as u128)
            >= (nav_before as u128) * (shares_after as u128),
    );
}

/// Asserts every result of one funding-cost quote independently.
fun assert_funding_quote(
    reserve_before: u64,
    funding_cost: u64,
    expected_reserve_after: u64,
    expected_absorbed: u64,
    expected_uncovered: u64,
) {
    let (reserve_after, absorbed, uncovered) =
        accounting_math::absorb_funding_cost(reserve_before, funding_cost);

    assert_eq!(reserve_after, expected_reserve_after);
    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, expected_uncovered);
}

/// Compares one redemption with the same burn split into two transactions.
fun assert_split_redemption(
    nav_before: u64,
    reserve_before: u64,
    shares_before: u64,
    shares_burned: u64,
    first_burn: u64,
    redeem_fee_bps: u64,
) {
    let venue_equity_before = nav_before + reserve_before;
    let (combined_reserve, _, combined_keep, _, _, _, combined_net) =
        accounting_math::redemption_accounting_quote(
            shares_burned,
            venue_equity_before,
            venue_equity_before,
            reserve_before,
            shares_before,
            redeem_fee_bps,
        );
    let combined_equity = venue_equity_before - combined_net;
    let combined_nav = accounting_math::shareholder_nav(
        combined_equity,
        combined_reserve,
    );

    let (reserve_1, shares_1, keep_1, _, _, _, net_1) =
        accounting_math::redemption_accounting_quote(
            first_burn,
            venue_equity_before,
            venue_equity_before,
            reserve_before,
            shares_before,
            redeem_fee_bps,
        );
    let venue_equity_1 = venue_equity_before - net_1;
    let nav_1 = accounting_math::shareholder_nav(venue_equity_1, reserve_1);
    let (reserve_2, _, keep_2, _, _, _, net_2) =
        accounting_math::redemption_accounting_quote(
            shares_burned - first_burn,
            venue_equity_1,
            venue_equity_1,
            reserve_1,
            shares_1,
            redeem_fee_bps,
        );
    let venue_equity_2 = venue_equity_1 - net_2;
    let nav_2 = accounting_math::shareholder_nav(venue_equity_2, reserve_2);

    assert_eq!(nav_1, keep_1);
    assert_eq!(nav_2, keep_2);
    assert_eq!(combined_nav, combined_keep);
    assert!(net_1 + net_2 <= combined_net);
    assert!(nav_2 >= combined_nav);
    assert_eq!(
        venue_equity_2 - combined_equity,
        combined_net - (net_1 + net_2),
    );
}

// === Canonical Mint Helper ===

/// The reserve-aware mint as State performs it: fee once, reserve credited,
/// then the production quote. Returns
/// `(reserve_after, nav_before, nav_after, fee, contribution, shares_out, shares_after)`.
fun canonical_mint(
    deposit: u64,
    venue_equity_before: u64,
    venue_equity_after: u64,
    reserve_before: u64,
    shares_before: u64,
    mint_fee_bps: u64,
    min_shares_out: u64,
): (u64, u64, u64, u64, u64, u64, u64) {
    let nav_before = accounting_math::shareholder_nav(venue_equity_before, reserve_before);
    let fee = accounting_math::fee_up(deposit, mint_fee_bps);
    let reserve_after = accounting_math::credit_fee(reserve_before, fee);
    let (nav_after, contribution, shares_out) = accounting_math::allocated_mint_quote(
        venue_equity_before, venue_equity_after, reserve_before, reserve_after,
        deposit - fee, shares_before, min_shares_out,
    );
    (reserve_after, nav_before, nav_after, fee, contribution, shares_out, shares_before + shares_out)
}

// === Imports ===

use blast_boosts_core::{accounting_math};

use std::unit_test::assert_eq;
