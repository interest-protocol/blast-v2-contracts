// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::allocation_tests;

// === Constants ===

const DESTINATION_A: address = @0xA;

const DESTINATION_B: address = @0xB;

const SEED: u64 = 0xA110C;

// === Tests ===

// Construction.

#[test]
fun smallest_positive_curve_and_pool_shares_are_admitted() {
    let plan = shaped(vector[1, 1, 9_998], vector[1, 9_999]);

    assert_eq!(meme_amounts(&plan, 10_000), vector[1, 1, 9_998]);
    assert_eq!(quote_amounts(&plan, 10_000), vector[1, 9_999]);
}

#[test]
fun plan_leaves_the_share_sums_to_add_protocol() {
    let plan = allocation::plan(bps::new(1), bps::new(1), bps::new(1), vector[]);

    assert_eq!(plan.destinations(), vector[]);
}

#[test]
fun a_recipient_without_shares_is_admitted_and_paid_nothing() {
    let plan = shaped(vector[7_000, 2_000, 1_000, 0], vector[9_000, 1_000, 0]);

    assert_eq!(plan.destinations(), vector[@0x2]);
    assert_eq!(meme_amounts(&plan, 999), vector[699, 200, 100, 0]);
    assert_eq!(quote_amounts(&plan, 999), vector[899, 100, 0]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun an_oversized_meme_sum_is_rejected() { shaped(vector[8_000, 2_000, 1], vector[10_000, 0]); }

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun an_oversized_quote_sum_is_rejected() { shaped(vector[8_000, 2_000, 0], vector[10_000, 1]); }

#[test, expected_failure(abort_code = blast_fun::errors::EDuplicateDestination, location = blast_fun::allocation)]
fun a_fee_split_duplicate_is_rejected_before_the_sum() {
    fee_split(vector[0, 0, 0, 0], vector[route(DESTINATION_A, 1), route(DESTINATION_A, 1)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EDuplicateDestination, location = blast_fun::allocation)]
fun a_fee_split_duplicate_apart_from_its_twin_is_rejected() {
    fee_split(
        vector[0, 0, 0, 0],
        vector[
            route(DESTINATION_A, 3_000),
            route(DESTINATION_B, 4_000),
            route(DESTINATION_A, 3_000),
        ],
    );
}

// Apportionment.

#[test]
fun a_zero_total_pays_nothing() {
    let plan = shaped(vector[7_000, 2_000, 500, 500], vector[9_000, 500, 500]);

    assert_eq!(meme_amounts(&plan, 0), vector[0, 0, 0, 0]);
    assert_eq!(quote_amounts(&plan, 0), vector[0, 0, 0]);
    assert_eq!(fee_amounts(&split(vector[9_000, 500, 0, 500]), 0), vector[0, 0, 0, 0]);
}

#[test]
fun blast_ceiling_takes_the_unit_a_larger_remainder_would_win() {
    let plan = shaped(vector[7_000, 2_000, 500, 500], vector[9_000, 500, 500]);

    assert_eq!(meme_amounts(&plan, 101), vector[70, 20, 6, 5]);
    assert_eq!(quote_amounts(&plan, 101), vector[90, 6, 5]);
    // The same shares without a rounded-up part: the pool's 0.9 remainder wins the unit.
    assert_eq!(fee_amounts(&split(vector[9_000, 500, 0, 500]), 101), vector[91, 5, 0, 5]);
}

#[test]
fun blast_ceiling_can_leave_a_one_basis_point_pool_empty() {
    let plan = shaped(vector[9_998, 1, 1], vector[1, 9_999]);

    assert_eq!(quote_amounts(&plan, 1), vector[0, 1]);
    assert_eq!(quote_amounts(&plan, 9_999), vector[0, 9_999]);
    assert_eq!(quote_amounts(&plan, 10_000), vector[1, 9_999]);
    assert_eq!(quote_amounts(&plan, 10_001), vector[1, 10_000]);
}

#[test]
fun equal_routes_take_leftover_units_in_table_order() {
    let mut shares = vector[0, 0, 0, 0];
    16u64.do!(|_| shares.push_back(625));
    let split = split(shares);

    let (_, _, _, _, fifteen) = split.apportion_fee_split(15);
    let (_, _, _, _, seventeen) = split.apportion_fee_split(17);

    assert_eq!(fifteen, vector::tabulate!(16, |i| if (i < 15) 1 else 0));
    assert_eq!(seventeen, vector::tabulate!(16, |i| if (i == 0) 2 else 1));
}

#[test]
fun a_larger_total_can_pay_a_floored_part_one_unit_less() {
    let split = split(vector[4_700, 4_200, 0, 1_100]);

    assert_eq!(fee_amounts(&split, 22), vector[10, 9, 0, 3]);
    assert_eq!(fee_amounts(&split, 23), vector[11, 10, 0, 2]);
}

#[test]
fun blast_amount_never_decreases_as_the_total_grows() {
    let plan = shaped(vector[4_700, 3_200, 1_100, 1_000], vector[7_900, 1_100, 1_000]);
    let (mut previous_meme, mut previous_quote) = (0, 0);

    256u64.do!(|total| {
        let (_, _, meme, _) = plan.apportion_meme(total);
        let (_, quote, _) = plan.apportion_quote(total);

        assert!(meme >= previous_meme && quote >= previous_quote);
        (previous_meme, previous_quote) = (meme, quote);
    });
}

#[test]
fun every_four_parts_and_one_route_grid_split_follows_largest_remainder() {
    5u64.do!(|creator| 5u64.do!(|auto_lp| 5u64.do!(|rewards| 5u64.do!(|burn| {
        if (creator + auto_lp + rewards + burn <= 4) {
            let shares = vector[
                creator * 2_500,
                auto_lp * 2_500,
                rewards * 2_500,
                burn * 2_500,
                (4 - creator - auto_lp - rewards - burn) * 2_500,
            ];
            let split = split(shares);
            25u64.do!(|total| {
                assert_largest_remainder(&shares, fee_amounts(&split, total), option::none(), total)
            });
        };
    }))));
}

#[test]
fun random_plans_follow_largest_remainder_with_blast_rounded_up() {
    let mut seed = SEED;
    48u64.do!(|_| {
        seed = next(seed);
        let recipients = seed % constants::max_recipients!();
        let denominator = constants::basis_points_denominator!();
        let mut meme = random_shares(recipients + 3, denominator - 2, next(seed));
        *&mut meme[0] = meme[0] + 1;
        *&mut meme[1] = meme[1] + 1;
        let mut quote = random_shares(recipients + 2, denominator - 1, next(next(seed)));
        *&mut quote[0] = quote[0] + 1;
        let plan = shaped(meme, quote);
        let total = random_total(seed);

        assert_largest_remainder(&meme, meme_amounts(&plan, total), option::some(2), total);
        assert_largest_remainder(&quote, quote_amounts(&plan, total), option::some(1), total);
    });
}

#[test]
fun random_fee_splits_follow_largest_remainder() {
    let mut seed = SEED;
    48u64.do!(|_| {
        seed = next(seed);
        let routes = seed % (constants::max_recipients!() + 1);
        let shares = random_shares(4 + routes, constants::basis_points_denominator!(), next(seed));
        let total = random_total(seed);
        let amounts = fee_amounts(&split(shares), total);

        assert_largest_remainder(&shares, amounts, option::none(), total);
    });
}

#[test]
fun a_full_fee_split_conserves_the_maximum_total() {
    let routes = constants::max_recipients!();
    let mut shares = vector[1_000, 2_000, 3_000, 1_000];
    routes.do!(|i| shares.push_back(3_000 / routes + if (i == 0) 3_000 % routes else 0));
    let total = std::u64::max_value!();
    let amounts = fee_amounts(&split(shares), total);

    assert_largest_remainder(&shares, amounts, option::none(), total);
}

// === Test Helpers ===

fun recipient(destination: address, meme_bps: u64, quote_bps: u64): Recipient {
    allocation::recipient(destination, bps::new(meme_bps), bps::new(quote_bps))
}

fun route(destination: address, bps: u64): Route { allocation::route(destination, bps::new(bps)) }

/// Builds a plan from Meme shares `[curve, lp, blast, ...]` and Quote shares `[lp, blast, ...]`;
/// Blast pays to `@0x1` and the creator's recipients to `@0x2` onward.
fun shaped(meme: vector<u64>, quote: vector<u64>): AllocationPlan {
    let recipients = vector::tabulate!(
        meme.length() - 3,
        |i| recipient(address::from_u256((i + 2) as u256), meme[i + 3], quote[i + 2]),
    );

    allocation::plan(bps::new(meme[0]), bps::new(meme[1]), bps::new(quote[0]), recipients)
        .add_protocol(allocation::protocol_allocation(bps::new(meme[2]), bps::new(quote[1])))
}

fun fee_split(parts: vector<u64>, routes: vector<Route>): FeeSplit {
    allocation::fee_split(
        bps::new(parts[0]),
        bps::new(parts[1]),
        bps::new(parts[2]),
        bps::new(parts[3]),
        routes,
    )
}

/// Builds a fee split from shares `[creator, auto_lp, rewards, burn, ...]`; routes pay to `@0x2`
/// onward.
fun split(shares: vector<u64>): FeeSplit {
    fee_split(
        shares,
        vector::tabulate!(
            shares.length() - 4,
            |i| route(address::from_u256((i + 2) as u256), shares[i + 4]),
        ),
    )
}

/// The curve's, the pool's, Blast's, then each recipient's Meme amount.
fun meme_amounts(plan: &AllocationPlan, supply: u64): vector<u64> {
    let (curve, lp, protocol, recipients) = plan.apportion_meme(supply);
    let mut amounts = vector[curve, lp, protocol];
    amounts.append(recipients);

    amounts
}

/// The pool's, Blast's, then each recipient's Quote amount.
fun quote_amounts(plan: &AllocationPlan, reserve: u64): vector<u64> {
    let (lp, protocol, recipients) = plan.apportion_quote(reserve);
    let mut amounts = vector[lp, protocol];
    amounts.append(recipients);

    amounts
}

/// The creator's, auto-LP's, rewards', burn's, then each route's amount.
fun fee_amounts(split: &FeeSplit, total: u64): vector<u64> {
    let (creator, auto_lp, rewards, burn, routes) = split.apportion_fee_split(total);
    let mut amounts = vector[creator, auto_lp, rewards, burn];
    amounts.append(routes);

    amounts
}

fun next(seed: u64): u64 { (seed * 48_271) % 2_147_483_647 }

/// `count` shares, zeros allowed, summing to `sum`.
fun random_shares(count: u64, sum: u64, mut seed: u64): vector<u64> {
    let mut remaining = sum;
    vector::tabulate!(count, |i| {
        seed = next(seed);
        let share = if (i + 1 == count) remaining else seed % (remaining + 1);
        remaining = remaining - share;
        share
    })
}

/// Small, mid-range, and near-maximum totals in turn.
fun random_total(seed: u64): u64 {
    match (seed % 3) {
        0 => seed % 64,
        1 => seed,
        _ => std::u64::max_value!() - seed % 1_000,
    }
}

/// `amounts` is the largest-remainder apportionment of `total` over `shares`: the parts conserve
/// `total`, the `rounded_up` part is its ceiling, every other part is its floor or one unit more,
/// a part with no remainder takes no extra unit, and extra units go to larger remainders first and
/// to earlier parts on ties.
fun assert_largest_remainder(
    shares: &vector<u64>,
    amounts: vector<u64>,
    rounded_up: Option<u64>,
    total: u64,
) {
    let products = shares.map_ref!(|share| (total as u128) * (*share as u128));
    let denominator = constants::basis_points_denominator!() as u128;
    let floors = products.map_ref!(|product| (*product / denominator) as u64);
    let extra = vector::tabulate!(amounts.length(), |i| amounts[i] > floors[i]);

    assert_eq!(amounts.fold!(0u128, |sum, amount| sum + (amount as u128)), total as u128);
    amounts.length().do!(|i| {
        if (rounded_up.contains(&i)) {
            assert_eq!(amounts[i], products[i].div_ceil(denominator) as u64);
        } else {
            assert!(amounts[i] >= floors[i] && amounts[i] - floors[i] <= 1);
            assert!(!extra[i] || products[i] % denominator > 0);
        };
    });
    amounts.length().do!(|i| amounts.length().do!(|j| {
        if (extra[i] && !extra[j] && !rounded_up.contains(&i) && !rounded_up.contains(&j)) {
            let (remainder_i, remainder_j) = (products[i] % denominator, products[j] % denominator);
            assert!(remainder_i > remainder_j || (remainder_i == remainder_j && i < j));
        };
    }));
}

// === Imports ===

use blast_fun::{allocation::{Self, AllocationPlan, FeeSplit, Recipient, Route}, bps, constants};

use std::unit_test::assert_eq;

use sui::address;
