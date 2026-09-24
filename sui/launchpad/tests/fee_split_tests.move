// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::fee_split_tests;

// === Constants ===

const DESTINATION_A: address = @0xA;

const DESTINATION_B: address = @0xB;

const U64_MAX: u64 = 18_446_744_073_709_551_615;

// === Tests ===

#[test]
fun recipients_keep_the_creator_order() {
    let fee_split = split(0, 0, 0, 0, vector[route(DESTINATION_B, 4_000), route(DESTINATION_A, 6_000)]);

    assert_eq!(fee_split.recipients()[0].destination(), DESTINATION_B);
    assert_eq!(fee_split.recipients()[0].route_bps_for_testing(), 4_000);
    assert_eq!(fee_split.recipients()[1].destination(), DESTINATION_A);
}

#[test]
fun every_part_alone_can_take_the_whole_split() {
    assert_eq!(split(10_000, 0, 0, 0, vector[]).creator_bps_for_testing().value(), 10_000);
    assert_eq!(split(0, 10_000, 0, 0, vector[]).auto_lp_bps_for_testing().value(), 10_000);
    assert_eq!(split(0, 0, 10_000, 0, vector[]).rewards_bps_for_testing().value(), 10_000);
    assert_eq!(split(0, 0, 0, 10_000, vector[]).burn_bps_for_testing().value(), 10_000);
    assert_eq!(split(0, 0, 0, 0, vector[route(DESTINATION_A, 10_000)]).recipients().length(), 1);
}

#[test]
fun sixteen_recipients_are_admitted() {
    let mut recipients = vector[];
    16u64.do!(|i| recipients.push_back(route(sui::address::from_u256(16 - (i as u256)), 625)));

    let fee_split = split(0, 0, 0, 0, recipients);

    assert_eq!(fee_split.recipients().length(), 16);
    assert_eq!(fee_split.recipients()[0].destination(), sui::address::from_u256(16));
}

#[test]
fun dense_small_totals_conserve_and_break_ties_in_part_order() {
    // Creator, auto-LP, rewards, burn, and one recipient at 20% each.
    let fee_split = split(2_000, 2_000, 2_000, 2_000, vector[route(DESTINATION_A, 2_000)]);

    33u64.do!(|total| {
        let (creator, auto_lp, rewards, burn, recipients) = fee_split.apportion_fee_split(total);

        assert_eq!(creator + auto_lp + rewards + burn + recipients[0], total);
        assert_eq!(creator, (total + 4) / 5);
        assert_eq!(auto_lp, (total + 3) / 5);
        assert_eq!(rewards, (total + 2) / 5);
        assert_eq!(burn, (total + 1) / 5);
        assert_eq!(recipients[0], total / 5);
    });
}

#[test]
fun a_zero_part_never_receives_dust() {
    let fee_split = split(0, 5_000, 0, 0, vector[route(DESTINATION_A, 5_000)]);

    33u64.do!(|total| {
        let (creator, auto_lp, rewards, burn, recipients) = fee_split.apportion_fee_split(total);

        assert_eq!(creator, 0);
        assert_eq!(rewards, 0);
        assert_eq!(burn, 0);
        assert_eq!(auto_lp + recipients[0], total);
    });
}

#[test]
fun u64_max_total_uses_wide_products_and_exact_conservation() {
    let fee_split = split(1_000, 2_000, 3_000, 1_500, vector[route(DESTINATION_A, 2_500)]);
    let (creator, auto_lp, rewards, burn, recipients) = fee_split.apportion_fee_split(U64_MAX);

    assert_eq!(
        (creator as u128) + (auto_lp as u128) + (rewards as u128) + (burn as u128)
            + (recipients[0] as u128),
        U64_MAX as u128,
    );
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun an_empty_split_fails_the_sum() {
    split(0, 0, 0, 0, vector[]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun an_incomplete_split_fails_the_sum() {
    split(2_500, 2_500, 2_500, 0, vector[route(DESTINATION_A, 2_499)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun an_oversized_split_fails_the_sum() {
    split(10_000, 0, 0, 0, vector[route(DESTINATION_A, 1)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidDestination, location = blast_fun::allocation)]
fun zero_destination_rejected() { route(@0x0, 10_000); }

#[test, expected_failure(abort_code = blast_fun::errors::EDuplicateDestination, location = blast_fun::allocation)]
fun duplicate_recipient_rejected() {
    split(0, 0, 0, 0, vector[route(DESTINATION_A, 5_000), route(DESTINATION_A, 5_000)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERecipientCapacityReached, location = blast_fun::allocation)]
fun seventeen_recipients_rejected_before_duplicates_and_the_sum() {
    let mut recipients = vector[];
    17u64.do!(|_| recipients.push_back(route(DESTINATION_A, 1)));
    split(0, 0, 0, 0, recipients);
}

// === Test Helpers ===

fun route(destination: address, bps: u64): Route { allocation::route(destination, bps::new(bps)) }

fun split(creator: u64, auto_lp: u64, rewards: u64, burn: u64, recipients: vector<Route>): FeeSplit {
    allocation::fee_split(
        bps::new(creator),
        bps::new(auto_lp),
        bps::new(rewards),
        bps::new(burn),
        recipients,
    )
}

// === Imports ===

use blast_fun::{allocation::{Self, FeeSplit, Route}, bps};

use std::unit_test::assert_eq;
