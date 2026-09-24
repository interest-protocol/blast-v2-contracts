// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::graduation_tests;

// === Tests ===

#[test]
fun seventy_five_twenty_five_conserves_both_precisions() {
    let plan = plan(500, 2_000);

    assert_eq!(
        meme_amounts(&plan, 1_000_000_000_000_000),
        vector[750_000_000_000_000, 200_000_000_000_000, 50_000_000_000_000],
    );
    assert_eq!(
        meme_amounts(&plan, 1_000_000_000_000_000_000),
        vector[750_000_000_000_000_000, 200_000_000_000_000_000, 50_000_000_000_000_000],
    );
}

#[test]
fun blast_ceiling_precedes_remainder_ties() {
    let plan = plan(2_000, 4_000);

    assert_eq!(meme_amounts(&plan, 1), vector[0, 0, 1]);
    assert_eq!(meme_amounts(&plan, 2), vector[1, 0, 1]);
    assert_eq!(meme_amounts(&plan, 3), vector[1, 1, 1]);
    assert_eq!(quote_amounts(&plan, 1), vector[0, 1]);
}

#[test]
fun distinct_remainders_precede_part_order() {
    let plan = plan(0, 6_000);

    assert_eq!(meme_amounts(&plan, 1), vector[0, 1, 0]);
    assert_eq!(meme_amounts(&plan, 3), vector[1, 2, 0]);
}

#[test]
fun equal_remainders_go_to_the_earlier_part() {
    let plan = plan(0, 5_000);

    assert_eq!(meme_amounts(&plan, 1), vector[1, 0, 0]);
    assert_eq!(meme_amounts(&plan, 3), vector[2, 1, 0]);
}

#[test]
fun maximum_u64_products_conserve_both_assets() {
    assert_conservation(vector[1, 8_999, 1_000], vector[9_000, 1_000], std::u64::max_value!());
}

#[test]
fun dense_small_totals_exhaust_three_way_tenth_shares() {
    10u64.do!(|protocol| 10u64.do!(|lp| {
        if (lp > 0 && protocol + lp < 10) {
            33u64.do!(|total| assert_conservation(
                vector[(10 - protocol - lp) * 1_000, lp * 1_000, protocol * 1_000],
                vector[10_000 - protocol * 1_000, protocol * 1_000],
                total,
            ));
        };
    }));
}

#[test]
fun fixed_seed_random_shapes_are_dust_free() {
    let mut seed = 0xB1A57u64;
    64u64.do!(|_| {
        seed = (seed * 48_271) % 2_147_483_647;
        let recipients = 1 + seed % 16;
        assert_conservation(
            random_shares(recipients + 2, seed),
            random_shares(recipients + 1, seed + 7),
            seed,
        );
    });
}

#[test]
fun blast_is_first_and_creator_recipients_keep_their_order() {
    let plan = allocation::plan(
        bps::new(7_000),
        bps::new(2_000),
        bps::new(8_000),
        vector[recipient(@0x7, 400, 1_000), recipient(@0x1, 100, 0)],
    ).add_protocol(recipient(@0x1, 500, 1_000));

    assert_eq!(plan.destinations(), vector[@0x1, @0x7, @0x1]);
    assert_eq!(meme_amounts(&plan, 10_000), vector[7_000, 2_000, 500, 400, 100]);
    assert_eq!(quote_amounts(&plan, 10_000), vector[8_000, 1_000, 1_000, 0]);
}

#[test]
fun zero_shares_receive_nothing() {
    let meme_only = shaped(vector[7_500, 2_000, 500], vector[10_000, 0]);
    let quote_only = shaped(vector[5_000, 5_000, 0], vector[9_500, 500]);

    assert_eq!(quote_amounts(&meme_only, 7), vector[7, 0]);
    assert_eq!(meme_amounts(&quote_only, 3), vector[2, 1, 0]);
    assert_eq!(quote_amounts(&quote_only, 3), vector[2, 1]);
}

#[test]
fun one_and_sixteen_recipients_are_admitted() {
    let (meme, quote) = bounded(1);
    assert_eq!(shaped(meme, quote).destinations(), vector[@0x1]);

    let (meme, quote) = bounded(16);
    assert_eq!(shaped(meme, quote).destinations().length(), 16);
    assert_conservation(meme, quote, std::u64::max_value!());
}

#[test]
fun recurring_protocol_ceiling_leaves_project_remainder_for_equal_weights() {
    let gross = 11;
    let protocol = bps::new(1_000).apply_up(gross);
    let project = route_amounts(
        &vector[route(@0x3, 5_000), route(@0x7, 5_000)],
        gross - protocol,
    );

    assert_eq!(protocol, 2);
    assert_eq!(project, vector[5, 4]);
    assert_eq!(protocol + project.fold!(0u64, |sum, amount| sum + amount), gross);
}

#[test]
fun route_ties_use_table_order_without_protecting_any_route() {
    let routes = vector[route(@0x3, 5_000), route(@0x7, 5_000)];

    assert_eq!(route_amounts(&routes, 1), vector[1, 0]);
    assert_eq!(route_amounts(&routes, 2), vector[1, 1]);
    assert_eq!(route_amounts(&routes, 3), vector[2, 1]);
}

#[test]
fun route_distinct_remainders_precede_table_order() {
    let routes = vector[route(@0x3, 1_000), route(@0x7, 6_000), route(@0x9, 3_000)];

    assert_eq!(route_amounts(&routes, 1), vector[0, 1, 0]);
    assert_eq!(route_amounts(&routes, 3), vector[0, 2, 1]);
    assert_eq!(route_amounts(&routes, 10), vector[1, 6, 3]);
}

#[test]
fun route_zero_and_maximum_totals_conserve_without_overflow() {
    let routes = vector[route(@0x3, 5_000), route(@0x7, 5_000)];
    let maximum = std::u64::max_value!();
    let amounts = route_amounts(&routes, maximum);

    assert_eq!(route_amounts(&routes, 0), vector[0, 0]);
    assert_eq!(amounts, vector[maximum / 2 + 1, maximum / 2]);
    assert_eq!(amounts.fold!(0u64, |sum, amount| sum + amount), maximum);
    assert_eq!(route_amounts(&vector[route(@0x7, 10_000)], maximum), vector[maximum]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun zero_curve_share_is_rejected() {
    allocation::plan(bps::new(0), bps::new(2_000), bps::new(10_000), vector[]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun zero_lp_meme_share_is_rejected() {
    allocation::plan(bps::new(8_000), bps::new(0), bps::new(10_000), vector[]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun invalid_meme_sum_is_rejected() { shaped(vector[7_999, 2_000, 0], vector[10_000, 0]); }

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun invalid_quote_sum_is_rejected() { shaped(vector[8_000, 2_000, 0], vector[9_999, 0]); }

#[
    test,
    expected_failure(
        abort_code = blast_fun::errors::ERecipientCapacityReached,
        location = blast_fun::allocation,
    ),
]
fun seventeenth_recipient_is_rejected() {
    let (meme, quote) = bounded(17);
    shaped(meme, quote);
}

#[
    test,
    expected_failure(
        abort_code = blast_fun::errors::ERecipientCapacityReached,
        location = blast_fun::allocation,
    ),
]
fun capacity_precedes_the_share_sums() {
    let (mut meme, quote) = bounded(17);
    *&mut meme[0] = 1;
    shaped(meme, quote);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidDestination, location = blast_fun::allocation)]
fun zero_recipient_destination_is_rejected() { recipient(@0x0, 0, 0); }

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidDestination, location = blast_fun::allocation)]
fun zero_route_destination_is_rejected() { route(@0x0, 0); }

// === Test Helpers ===

fun recipient(destination: address, meme_bps: u64, quote_bps: u64): Recipient {
    allocation::recipient(destination, bps::new(meme_bps), bps::new(quote_bps))
}

fun route(destination: address, value: u64): Route { allocation::route(destination, bps::new(value)) }

/// Builds a plan from Meme shares `[curve, lp, blast, ...]` and Quote shares `[lp, blast, ...]`;
/// Blast pays to `@0x1` and the creator's recipients to `@0x2` onward.
fun shaped(meme: vector<u64>, quote: vector<u64>): AllocationPlan {
    let recipients = vector::tabulate!(
        meme.length() - 3,
        |i| recipient(address::from_u256((i + 2) as u256), meme[i + 3], quote[i + 2]),
    );

    allocation::plan(bps::new(meme[0]), bps::new(meme[1]), bps::new(quote[0]), recipients)
        .add_protocol(recipient(@0x1, meme[2], quote[1]))
}

/// A curve, a pool, and Blast holding `protocol` of both assets.
fun plan(protocol: u64, liquidity: u64): AllocationPlan {
    shaped(
        vector[10_000 - protocol - liquidity, liquidity, protocol],
        vector[10_000 - protocol, protocol],
    )
}

/// Shares for `count` recipients, Blast included, of one basis point of each asset.
fun bounded(count: u64): (vector<u64>, vector<u64>) {
    let mut meme = vector[10_000 - count - 1, 1];
    let mut quote = vector[10_000 - count];
    count.do!(|_| {
        meme.push_back(1);
        quote.push_back(1);
    });

    (meme, quote)
}

/// The curve's, the pool's, then each recipient's Meme amount.
fun meme_amounts(plan: &AllocationPlan, supply: u64): vector<u64> {
    let (curve, lp, mut amounts) = plan.apportion_meme(supply);
    amounts.insert(lp, 0);
    amounts.insert(curve, 0);

    amounts
}

/// The pool's, then each recipient's Quote amount.
fun quote_amounts(plan: &AllocationPlan, reserve: u64): vector<u64> {
    let (lp, mut amounts) = plan.apportion_quote(reserve);
    amounts.insert(lp, 0);

    amounts
}

/// Apportions `total` across a split whose whole share goes to `routes`.
fun route_amounts(routes: &vector<Route>, total: u64): vector<u64> {
    let split = allocation::fee_split(bps::new(0), bps::new(0), bps::new(0), bps::new(0), *routes);
    let (creator, auto_lp, rewards, burn, amounts) = split.apportion_fee_split(total);
    assert_eq!(creator + auto_lp + rewards + burn, 0);

    amounts
}

/// `count` positive shares summing to 10,000.
fun random_shares(count: u64, mut seed: u64): vector<u64> {
    let mut remaining = 10_000u64;
    vector::tabulate!(count, |i| {
        seed = (seed * 48_271) % 2_147_483_647;
        let share = if (i + 1 == count) remaining else 1 + seed % (remaining - (count - i - 1));
        remaining = remaining - share;
        share
    })
}

/// Both assets apportion `total` exactly: Blast takes its ceiling and every other part is within
/// one unit above its floor.
fun assert_conservation(meme: vector<u64>, quote: vector<u64>, total: u64) {
    let plan = shaped(meme, quote);

    assert_apportioned(&meme, meme_amounts(&plan, total), 2, total);
    assert_apportioned(&quote, quote_amounts(&plan, total), 1, total);
}

fun assert_apportioned(shares: &vector<u64>, amounts: vector<u64>, blast: u64, total: u64) {
    assert_eq!(amounts.fold!(0u64, |sum, amount| sum + amount), total);
    shares.length().do!(|i| {
        let down = total.mul_div(shares[i], 10_000);
        if (i == blast) assert_eq!(amounts[i], total.mul_div_ceil(shares[i], 10_000))
        else assert!(amounts[i] == down || amounts[i] == down + 1);
    });
}

// === Imports ===

use blast_fun::{allocation::{Self, AllocationPlan, Recipient, Route}, bps};

use std::unit_test::assert_eq;

use sui::address;
