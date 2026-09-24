// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::graduation_tests;

// === Tests ===

#[test]
fun seventy_five_twenty_five_conserves_both_precisions() {
    let plan = plan(500, 2_000);
    assert_eq!(
        plan.apportion_meme(1_000_000_000_000_000),
        vector[750_000_000_000_000, 50_000_000_000_000, 200_000_000_000_000],
    );
    assert_eq!(
        plan.apportion_meme(1_000_000_000_000_000_000),
        vector[750_000_000_000_000_000, 50_000_000_000_000_000, 200_000_000_000_000_000],
    );
}

#[test]
fun protected_ceiling_precedes_stable_id_remainder_tie() {
    let plan = plan(2_000, 4_000);
    assert_eq!(plan.apportion_meme(1), vector[0, 1, 0]);
    assert_eq!(plan.apportion_meme(2), vector[1, 1, 0]);
    assert_eq!(plan.apportion_meme(3), vector[1, 1, 1]);
    assert_eq!(plan.apportion_quote(1), vector[1, 0]);
}

#[test]
fun maximum_u64_products_conserve_both_assets() {
    assert_conservation(&plan(1_000, 8_999), std::u64::max_value!());
}

#[test]
fun dense_small_totals_exhaust_three_way_tenth_weights() {
    10u64.do!(|protocol| 10u64.do!(|lp| {
        if (lp > 0 && protocol + lp < 10) {
            let plan = plan(protocol * 1_000, lp * 1_000);
            33u64.do!(|total| assert_conservation(&plan, total));
        };
    }));
}

#[test]
fun fixed_seed_random_shapes_are_permutation_invariant_and_dust_free() {
    let mut seed = 0xB1A57u64;
    64u64.do!(|_| {
        seed = (seed * 48_271) % 2_147_483_647;
        let plan = random_plan(2 + seed % 15, seed);
        let mut channels = *plan.channels();
        let mut meme = *plan.meme_weights();
        let mut quote = *plan.quote_weights();
        channels.reverse();
        meme.reverse();
        quote.reverse();
        let reversed = allocation::new(channels, meme, quote);
        assert_eq!(bcs::to_bytes(&plan), bcs::to_bytes(&reversed));
        assert_eq!(plan.apportion_meme(seed), reversed.apportion_meme(seed));
        assert_eq!(plan.apportion_quote(seed), reversed.apportion_quote(seed));
        assert_conservation(&plan, seed);
    });
}

#[test]
fun distinct_remainders_beat_id_and_equal_remainders_use_id() {
    assert_eq!(plan(1_429, 2_857).apportion_meme(7), vector[3, 2, 2]);
    assert_eq!(plan(1_000, 4_500).apportion_meme(11), vector[5, 2, 4]);
}

#[test]
fun recurring_protocol_ceiling_leaves_project_remainder_for_equal_weights() {
    let gross = 11;
    let protocol = bps::new(1_000).apply_up(gross);
    let project = recipient_amounts(
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

    assert_eq!(recipient_amounts(&routes, 1), vector[1, 0]);
    assert_eq!(recipient_amounts(&routes, 2), vector[1, 1]);
    assert_eq!(recipient_amounts(&routes, 3), vector[2, 1]);
}

#[test]
fun route_distinct_remainders_precede_table_order() {
    let routes = vector[route(@0x3, 1_000), route(@0x7, 6_000), route(@0x9, 3_000)];

    assert_eq!(recipient_amounts(&routes, 1), vector[0, 1, 0]);
    assert_eq!(recipient_amounts(&routes, 3), vector[0, 2, 1]);
    assert_eq!(recipient_amounts(&routes, 10), vector[1, 6, 3]);
}

#[test]
fun route_zero_and_maximum_totals_conserve_without_overflow() {
    let routes = vector[route(@0x3, 5_000), route(@0x7, 5_000)];
    let maximum = std::u64::max_value!();
    let amounts = recipient_amounts(&routes, maximum);

    assert_eq!(recipient_amounts(&routes, 0), vector[0, 0]);
    assert_eq!(amounts, vector[maximum / 2 + 1, maximum / 2]);
    assert_eq!(amounts.fold!(0u64, |sum, amount| sum + amount), maximum);
    assert_eq!(recipient_amounts(&vector[route(@0x7, 10_000)], maximum), vector[maximum]);
}

#[test]
fun protocol_meme_only_and_quote_only_keep_absent_side_unprotected() {
    let channels = vector[lp(), allocation::channel(1, allocation::protocol_role(), @0x1)];
    let meme_only = allocation::new(
        channels,
        vector[weight(0, 7_500), weight(1, 500), weight(2, 2_000)],
        vector[weight(2, 10_000)],
    );
    meme_only.assert_protocol_policy(1, bps::new(500), bps::new(0), @0x1);
    assert_eq!(meme_only.apportion_quote(7), vector[7]);
    assert_conservation(&meme_only, 1);
    let quote_only = allocation::new(
        channels,
        vector[weight(0, 5_000), weight(2, 5_000)],
        vector[weight(1, 500), weight(2, 9_500)],
    );
    quote_only.assert_protocol_policy(1, bps::new(0), bps::new(500), @0x1);
    assert_eq!(quote_only.apportion_meme(3), vector[2, 1]);
    assert_eq!(quote_only.apportion_quote(3), vector[1, 2]);
    plan(0, 2_000).assert_protocol_policy(1, bps::new(0), bps::new(0), @0x1);
}

#[test]
fun one_and_sixteen_identities_are_admitted() {
    assert_eq!(bounded_plan(1, false).channels().length(), 1);
    assert_eq!(bounded_plan(16, false).channels().length(), 16);
    assert_conservation(&bounded_plan(16, false), std::u64::max_value!());
}

#[test]
fun plan_getters_read_every_channel_and_weight_in_canonical_id_order() {
    let plan = allocation::new(
        vector[external(7), lp(), allocation::channel(1, allocation::protocol_role(), @0x1)],
        vector[weight(7, 100), weight(2, 2_000), weight(0, 7_400), weight(1, 500)],
        vector[weight(7, 1_000), weight(1, 1_000), weight(2, 8_000)],
    );

    let channels = plan.channels();
    assert_eq!(channels.map_ref!(|channel| channel.channel_id()), vector[1, 2, 7]);
    assert_eq!(
        channels.map_ref!(|channel| channel.channel_role()),
        vector[allocation::protocol_role(), allocation::liquidity_role(), allocation::external_role()],
    );
    assert_eq!(channels.map_ref!(|channel| channel.channel_destination()), vector[@0x1, @0x2, @0x3]);
    assert_eq!(plan.meme_weights().map_ref!(|entry| entry.weight_channel_id()), vector[0, 1, 2, 7]);
    assert_eq!(plan.meme_weights().map_ref!(|entry| entry.weight_bps()), vector[7_400, 500, 2_000, 100]);
    assert_eq!(plan.quote_weights().map_ref!(|entry| entry.weight_channel_id()), vector[1, 2, 7]);
    assert_eq!(plan.quote_weights().map_ref!(|entry| entry.weight_bps()), vector[1_000, 8_000, 1_000]);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLiquidityChannel,
        location = blast_fun::allocation,
    ),
]
fun zero_identities_reject_missing_lp() {
    allocation::new(vector[], vector[weight(0, 10_000)], vector[]);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EMigrationChannelCapacityReached,
        location = blast_fun::allocation,
    ),
]
fun seventeenth_identity_is_rejected() { bounded_plan(17, false); }

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EDuplicateMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun duplicate_identity_precedes_first_over_capacity() {
    let plan = bounded_plan(16, false);
    let mut channels = *plan.channels();
    let duplicate = channels[0];
    channels.push_back(duplicate);
    allocation::new(channels, *plan.meme_weights(), *plan.quote_weights());
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EDuplicateMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun duplicate_quote_entry_precedes_first_over_capacity() {
    let plan = bounded_plan(16, false);
    let mut quote = *plan.quote_weights();
    let duplicate = quote[0];
    quote.push_back(duplicate);
    allocation::new(*plan.channels(), *plan.meme_weights(), quote);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EDuplicateMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun duplicate_meme_entry_precedes_first_over_capacity() {
    let plan = bounded_plan(16, false);
    let mut meme = *plan.meme_weights();
    let duplicate = meme[0];
    meme.push_back(duplicate);
    allocation::new(*plan.channels(), meme, *plan.quote_weights());
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EMigrationChannelCapacityReached,
        location = blast_fun::allocation,
    ),
]
fun gross_overlength_precedes_duplicate_sorting() {
    let plan = bounded_plan(16, false);
    let mut channels = *plan.channels();
    let duplicate = channels[0];
    channels.push_back(duplicate);
    let duplicate = channels[0];
    channels.push_back(duplicate);
    allocation::new(channels, *plan.meme_weights(), *plan.quote_weights());
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EAllocationSumInvalid,
        location = blast_fun::allocation,
    ),
]
fun invalid_meme_sum_is_rejected() {
    allocation::new(
        vector[lp()],
        vector[weight(0, 7_999), weight(2, 2_000)],
        vector[weight(2, 10_000)],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EAllocationSumInvalid,
        location = blast_fun::allocation,
    ),
]
fun invalid_quote_sum_is_rejected() {
    allocation::new(
        vector[lp()],
        vector[weight(0, 8_000), weight(2, 2_000)],
        vector[weight(2, 9_999)],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EAllocationSumInvalid,
        location = blast_fun::allocation,
    ),
]
fun zero_stored_weight_is_rejected() { weight(2, 0); }

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EUnknownMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun unknown_identity_is_rejected() {
    allocation::new(
        vector[lp()],
        vector[weight(0, 8_000), weight(3, 2_000)],
        vector[weight(2, 10_000)],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EUnknownMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun zero_destination_is_rejected() { allocation::channel(3, allocation::external_role(), @0x0); }

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EUnknownMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun curve_id_cannot_name_a_migration_channel() {
    allocation::channel(0, allocation::external_role(), @0x3);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EUnknownMigrationChannel,
        location = blast_fun::allocation,
    ),
]
fun quote_table_cannot_allocate_to_curve() {
    allocation::new(
        vector[lp()],
        vector[weight(0, 8_000), weight(2, 2_000)],
        vector[weight(0, 1), weight(2, 9_999)],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLiquidityChannel,
        location = blast_fun::allocation,
    ),
]
fun lp_requires_positive_quote() {
    allocation::new(
        vector[lp(), external(3)],
        vector[weight(0, 8_000), weight(2, 2_000)],
        vector[weight(3, 10_000)],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLiquidityChannel,
        location = blast_fun::allocation,
    ),
]
fun lp_requires_positive_meme() {
    allocation::new(
        vector[lp(), external(3)],
        vector[weight(0, 8_000), weight(3, 2_000)],
        vector[weight(2, 10_000)],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLiquidityChannel,
        location = blast_fun::allocation,
    ),
]
fun duplicate_lp_roles_are_rejected() {
    allocation::new(
        vector[lp(), allocation::channel(3, allocation::liquidity_role(), @0x3)],
        vector[],
        vector[],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolChannelMismatch,
        location = blast_fun::allocation,
    ),
]
fun duplicate_protocol_roles_are_rejected() {
    allocation::new(
        vector[
            lp(),
            allocation::channel(1, allocation::protocol_role(), @0x1),
            allocation::channel(3, allocation::protocol_role(), @0x1),
        ],
        vector[],
        vector[],
    );
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolChannelMismatch,
        location = blast_fun::allocation,
    ),
]
fun protocol_weights_must_match_policy() {
    plan(500, 2_000).assert_protocol_policy(1, bps::new(501), bps::new(500), @0x1);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolChannelMismatch,
        location = blast_fun::allocation,
    ),
]
fun protocol_destination_must_match_policy() {
    plan(500, 2_000).assert_protocol_policy(1, bps::new(500), bps::new(500), @0x3);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolChannelMismatch,
        location = blast_fun::allocation,
    ),
]
fun protocol_id_must_match_policy() {
    plan(500, 2_000).assert_protocol_policy(9, bps::new(500), bps::new(500), @0x1);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolChannelMismatch,
        location = blast_fun::allocation,
    ),
]
fun nonzero_policy_requires_protocol() {
    plan(0, 2_000).assert_protocol_policy(1, bps::new(500), bps::new(0), @0x1);
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolChannelMismatch,
        location = blast_fun::allocation,
    ),
]
fun zero_policy_requires_protocol_absence() {
    plan(500, 2_000).assert_protocol_policy(1, bps::new(0), bps::new(0), @0x1);
}

// === Test Helpers ===

fun weight(id: u64, value: u64): Weight { allocation::weight(id, bps::new(value)) }

fun route(destination: address, value: u64): Route { allocation::route(destination, bps::new(value)) }

/// Apportions `total` across a split whose whole share goes to `recipients`.
fun recipient_amounts(recipients: &vector<Route>, total: u64): vector<u64> {
    let split = allocation::fee_split(bps::new(0), bps::new(0), bps::new(0), *recipients);
    let (creator, auto_lp, rewards, amounts) = split.apportion_fee_split(total);
    assert_eq!(creator + auto_lp + rewards, 0);

    amounts
}

fun lp(): Channel { allocation::channel(2, allocation::liquidity_role(), @0x2) }

fun external(id: u64): Channel { allocation::channel(id, allocation::external_role(), @0x3) }

fun plan(protocol: u64, liquidity: u64): AllocationPlan {
    let mut channels = vector[lp()];
    let mut meme = vector[weight(0, 10_000 - protocol - liquidity), weight(2, liquidity)];
    let mut quote = vector[weight(2, 10_000 - protocol)];
    if (protocol > 0) {
        channels.push_back(allocation::channel(1, allocation::protocol_role(), @0x1));
        meme.push_back(weight(1, protocol));
        quote.push_back(weight(1, protocol));
    };
    allocation::new(channels, meme, quote)
}

fun bounded_plan(count: u64, reverse: bool): AllocationPlan {
    let mut channels = vector[lp()];
    let mut meme = vector[weight(0, 10_000 - count), weight(2, 1)];
    let mut quote = vector[weight(2, 10_001 - count)];
    (count - 1).do!(|i| {
        channels.push_back(external(i + 3));
        meme.push_back(weight(i + 3, 1));
        quote.push_back(weight(i + 3, 1));
    });
    if (reverse) { channels.reverse(); meme.reverse(); quote.reverse(); };
    allocation::new(channels, meme, quote)
}

fun random_plan(count: u64, seed: u64): AllocationPlan {
    let mut channels = vector[allocation::channel(1, allocation::protocol_role(), @0x1), lp()];
    (count - 2).do!(|i| channels.push_back(external(i + 3)));
    allocation::new(
        channels,
        random_weights(count + 1, 0, seed),
        random_weights(count, 1, seed + 7),
    )
}

fun random_weights(count: u64, first_id: u64, mut seed: u64): vector<Weight> {
    let mut remaining = 10_000u64;
    let mut weights = vector[];
    count.do!(|i| {
        seed = (seed * 48_271) % 2_147_483_647;
        let amount = if (i + 1 == count) remaining else 1 + seed % (remaining - (count - i - 1));
        weights.push_back(weight(first_id + i, amount));
        remaining = remaining - amount;
    });
    weights
}

fun assert_conservation(plan: &AllocationPlan, total: u64) {
    let meme = plan.apportion_meme(total);
    let quote = plan.apportion_quote(total);
    assert_eq!(meme.fold!(0u64, |sum, value| sum + value), total);
    assert_eq!(quote.fold!(0u64, |sum, value| sum + value), total);
    assert_rounding(plan.meme_weights(), &meme, total);
    assert_rounding(plan.quote_weights(), &quote, total);
}

fun assert_rounding(weights: &vector<Weight>, amounts: &vector<u64>, total: u64) {
    weights.length().do!(|i| {
        let weight = &weights[i];
        let down = total.mul_div(weight.weight_bps(), 10_000);
        assert!(amounts[i] == down || amounts[i] == down + 1);
        if (weight.weight_channel_id() == 1)
            assert_eq!(amounts[i], total.mul_div_ceil(weight.weight_bps(), 10_000));
    });
}

// === Imports ===

use blast_fun::{allocation::{Self, AllocationPlan, Channel, Route, Weight}, bps};

use std::{bcs, unit_test::assert_eq};
