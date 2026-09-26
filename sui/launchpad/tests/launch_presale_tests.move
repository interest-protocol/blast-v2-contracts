// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_presale_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const PROTOCOL_ADMIN: address = @0xAD;

const LAUNCHER: address = @0xB1A57;

const CREATOR: address = @0xC0FFEE;

const ALICE: address = @0xA11CE;

const BOB: address = @0xB0B;

/// Settles and delivers without having bid.
const KEEPER: address = @0x4EE9;

const SELL_BURN_BPS: u64 = 1_000;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const TARGET: u64 = 25_000_000;

const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 250;

/// Eighty percent of the nine-decimal supply of 10^18 atoms.
const CURVE_MEME: u64 = 800_000_000__000_000_000;

const PUBLIC_START_MS: u64 = 1_000;

const MIN_PRESALE_MS: u64 = 60_000;

/// Three days.
const MAX_PRESALE_MS: u64 = 259_200_000;

const SETTLEMENT_DELAY_MS: u64 = 10_000;

const MAX_DELIVERY_WINDOW_MS: u64 = 300_000;

/// The end of a shortest presale shared at `PUBLIC_START_MS`.
const PRESALE_END_MS: u64 = 61_000;

/// The first time that presale can settle.
const SETTLE_MS: u64 = 71_000;

/// When that presale's trading opens if it settles at `SETTLE_MS`: its own length later.
const TRADING_OPENS_MS: u64 = 131_000;

const ALICE_BID: u64 = 1_000_000;

const BOB_BID: u64 = 2_000_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_PRESALE_TESTS has drop {}

public struct TEST_QUOTE() has drop;

public struct TEST_MIGRATION_WITNESS() has drop;

public struct OTHER_MIGRATION_WITNESS() has drop;

/// Configured cold policy, the accumulator root, and one clock standing at the public start time.
public struct PresaleFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    config: LaunchConfig,
    runtime_config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

// --- Settings ---

#[test]
fun zero_presale_starts_live_and_trades_at_share() {
    let mut fixture = start();
    let launch = fixture.new_launch(0);

    assert_launch_created(object::id(&launch), 0);
    assert!(launch.is_live_for_testing());
    assert_eq!(launch.presale_ms_for_testing(), 0);
    assert_eq!(launch.trading_opens_ms_for_testing(), 0);
    destroy(launch);
    fixture.end();
}

#[test]
fun shortest_presale_is_accepted() {
    let mut fixture = start();
    let launch = fixture.new_launch(MIN_PRESALE_MS);

    assert_launch_created(object::id(&launch), MIN_PRESALE_MS);
    assert!(launch.is_presale_for_testing());
    assert_eq!(launch.presale_ms_for_testing(), MIN_PRESALE_MS);
    destroy(launch);
    fixture.end();
}

#[test]
fun longest_presale_is_accepted() {
    let mut fixture = start();
    let launch = fixture.new_launch(MAX_PRESALE_MS);

    assert_launch_created(object::id(&launch), MAX_PRESALE_MS);
    assert!(launch.is_presale_for_testing());
    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidPresale, location = blast_fun::launch)]
fun presale_below_the_minimum_is_rejected() {
    let mut fixture = start();
    let launch = fixture.new_launch(MIN_PRESALE_MS - 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidPresale, location = blast_fun::launch)]
fun presale_above_the_maximum_is_rejected() {
    let mut fixture = start();
    let launch = fixture.new_launch(MAX_PRESALE_MS + 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidPresale, location = blast_fun::launch)]
fun invalid_presale_precedes_the_ticket_sell_burn() {
    let mut fixture = start();
    let mut ticket = fixture.new_ticket();
    ticket.set_sell_burn_bps_for_testing(5_001);
    let launch = fixture.intake(ticket, plan(), 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun allocation_sums_precede_an_invalid_presale() {
    let mut fixture = start();
    let ticket = fixture.new_ticket();
    let plan = allocation::plan(
        bps::new(8_000),
        bps::new(2_000),
        bps::new(10_000),
        vector[allocation::recipient(CREATOR, bps::new(1), bps::new(0))],
    );
    let launch = fixture.intake(ticket, plan, 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidPresale, location = blast_fun::launch)]
fun invalid_presale_aborts_before_ticket_custody_moves() {
    let mut fixture = start();
    let mut ticket = fixture.new_ticket();
    ticket.burn_meme_for_testing(1);
    let launch = fixture.intake(ticket, plan(), 1);

    destroy(launch);
    fixture.end();
}

// --- Joining ---

#[test]
fun a_bid_is_owned_by_the_launch_and_joining_leaves_the_launch_untouched() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    let bid_id = fixture.join(ALICE, ALICE_BID);

    assert_eq!(
        bcs::to_bytes(&only_event<PresaleJoined>()),
        joined_bytes(launch_id, bid_id, ALICE_BID),
    );
    assert_eq!(fixture.bid(launch_id, bid_id), vector[ALICE.to_u256(), ALICE_BID as u256]);
    assert!(!fixture.has_coin<TEST_QUOTE>(ALICE));
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(launch.is_presale_for_testing());
        assert_presale(&launch, 0, 0, 0);
        assert_curve_untouched(&launch);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun creator_bids_before_share_and_every_join_is_its_own_bid() {
    let mut fixture = start();
    let launch = fixture.new_launch(MIN_PRESALE_MS);
    let launch_id = object::id(&launch);
    let creator_bid = fixture.join_before_share(&launch, ALICE_BID);
    fixture.share(launch);
    let first = fixture.join(ALICE, ALICE_BID);
    let second = fixture.join(ALICE, BOB_BID);

    assert!(first != second);
    assert_eq!(fixture.bid(launch_id, creator_bid), vector[LAUNCHER.to_u256(), ALICE_BID as u256]);
    assert_eq!(fixture.bid(launch_id, first), vector[ALICE.to_u256(), ALICE_BID as u256]);
    assert_eq!(fixture.bid(launch_id, second), vector[ALICE.to_u256(), BOB_BID as u256]);
    assert_eq!(fixture.bid_count(launch_id), 3);
    fixture.end();
}

#[test]
fun join_one_millisecond_before_the_end_is_accepted() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    fixture.set_time(PRESALE_END_MS - 1);
    let bid_id = fixture.join(ALICE, ALICE_BID);

    assert_eq!(fixture.bid(launch_id, bid_id), vector[ALICE.to_u256(), ALICE_BID as u256]);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPresaleEnded, location = blast_fun::launch)]
fun join_at_the_exact_end_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(PRESALE_END_MS);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPresaleEnded, location = blast_fun::launch)]
fun an_ended_presale_precedes_a_zero_bid() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(PRESALE_END_MS);

    fixture.join(ALICE, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_package_version_aborts_a_join_before_the_lifecycle_check() {
    let mut fixture = start();
    fixture.open(0);
    fixture.package_version.set_for_testing(2);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroPresaleBid, location = blast_fun::launch)]
fun zero_bid_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);

    fixture.join(ALICE, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun join_without_a_presale_is_rejected() {
    let mut fixture = start();
    fixture.open(0);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun join_after_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle(KEEPER);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

// --- Nothing trades during the presale ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun creator_cannot_buy_before_share_with_a_presale() {
    let mut fixture = start();
    let mut launch = fixture.new_launch(MIN_PRESALE_MS);

    fixture.buy_owned(&mut launch, ALICE_BID);
    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun buy_during_the_presale_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun buy_after_the_end_but_before_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun sell_during_the_presale_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);

    fixture.sell(ALICE, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun delivery_before_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let bid_id = fixture.join(ALICE, ALICE_BID);
    fixture.set_time(SETTLE_MS);

    fixture.deliver(bid_id);
    fixture.end();
}

// --- Settling ---

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_package_version_aborts_settlement_before_the_lifecycle_check() {
    let mut fixture = start();
    fixture.open(0);
    fixture.package_version.set_for_testing(2);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPresaleNotSettleable, location = blast_fun::launch)]
fun settlement_one_millisecond_before_the_delay_passes_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS - 1);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPresaleNotSettleable, location = blast_fun::launch)]
fun settlement_before_share_is_rejected() {
    let mut fixture = start();
    let mut launch = fixture.new_launch(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);

    fixture.settle_owned(&mut launch);
    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun settlement_without_a_presale_is_rejected_before_the_time_check() {
    let mut fixture = start();
    fixture.open(0);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun second_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle(KEEPER);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test]
fun settlement_reads_the_launch_address_balance_and_opens_trading_after_the_window() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle(KEEPER);

    assert_eq!(event::events_by_type<Event<Bought>>().length(), 0);
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleSettled>()),
        u64_payload(launch_id, vector[0, 0, 0, TRADING_OPENS_MS]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(launch.is_live_for_testing());
        assert_eq!(launch.trading_opens_ms_for_testing(), TRADING_OPENS_MS);
        assert_presale(&launch, 0, 0, 0);
        assert_curve_untouched(&launch);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun settlement_buys_once_with_the_whole_pot() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.join(BOB, BOB_BID);
    fixture.set_time(SETTLE_MS);
    let pot = ALICE_BID + BOB_BID;
    fixture.settle_pot(pot);
    let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        pot,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );

    let bought = event::events_by_type<Event<Bought>>();
    assert_eq!(bought.length(), 1);
    let mut fields = sui::bcs::new(bcs::to_bytes(&bought[0].unwrap()));
    fields.peel_address();
    assert_eq!(fields.peel_u64(), pot);
    assert_eq!(fields.peel_u64(), meme_out_gross);
    assert_eq!(fields.peel_u64(), meme_out_net);
    assert_eq!(fields.peel_u64(), 0);
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleSettled>()),
        u64_payload(launch_id, vector[pot, meme_out_net, 0, TRADING_OPENS_MS]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(launch.is_live_for_testing());
        assert_presale(&launch, pot, 0, meme_out_net);
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();
        assert_eq!(meme_reserve, CURVE_MEME - meme_out_gross);
        assert_eq!(real_quote, pot - quote_fee);
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme + creator_meme, meme_fee);
        assert_eq!(protocol_quote + creator_quote, quote_fee);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun pot_too_small_to_buy_is_refunded_whole() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    let bid_id = fixture.join(ALICE, 1);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(1);

    assert_eq!(event::events_by_type<Event<Bought>>().length(), 0);
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleSettled>()),
        u64_payload(launch_id, vector[1, 0, 1, TRADING_OPENS_MS]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert_curve_untouched(&launch);
        launch.put_back();
    });

    fixture.deliver(bid_id);
    fixture.next_tx!(ALICE, |f| {
        let refund = f.take_coin<TEST_QUOTE>(ALICE);

        assert_eq!(refund.value(), 1);
        assert!(!f.has_coin<LAUNCH_PRESALE_TESTS>(ALICE));
        destroy(refund);
    });
    fixture.end();
}

#[test]
fun pot_past_the_target_graduates_and_refunds_the_excess_pro_rata() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let alice_bid = fixture.join(ALICE, 10_000_000);
    let bob_bid = fixture.join(BOB, 30_000_000);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(40_000_000);
    let (quote_in_gross, excess) = curve::cap_buy_quote_input(
        0,
        TARGET,
        40_000_000,
        bps::new(QUOTE_FEE_BPS),
    );
    let (_, _, _, meme_out_net) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        quote_in_gross,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );

    assert!(excess > 0);
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(launch.is_migration_ready_for_testing());
        assert_presale(&launch, 40_000_000, excess, meme_out_net);
        launch.put_back();
    });

    fixture.deliver(alice_bid);
    fixture.deliver(bob_bid);
    fixture.next_tx!(KEEPER, |f| {
        let alice_meme = f.take_coin<LAUNCH_PRESALE_TESTS>(ALICE);
        let alice_quote = f.take_coin<TEST_QUOTE>(ALICE);
        let bob_meme = f.take_coin<LAUNCH_PRESALE_TESTS>(BOB);
        let bob_quote = f.take_coin<TEST_QUOTE>(BOB);
        let launch = f.take_launch();

        assert_eq!(alice_meme.value(), meme_out_net / 4);
        assert_eq!(alice_quote.value(), excess / 4);
        assert_eq!(bob_meme.value(), meme_out_net - meme_out_net / 4);
        assert_eq!(bob_quote.value(), excess - excess / 4);
        assert_presale(&launch, 0, 0, 0);
        destroy(alice_meme);
        destroy(alice_quote);
        destroy(bob_meme);
        destroy(bob_quote);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun donated_quote_buys_meme_that_no_bid_claims() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let alice_bid = fixture.join(ALICE, ALICE_BID);
    fixture.set_time(SETTLE_MS);
    let donation = BOB_BID;
    let pot = ALICE_BID + donation;
    fixture.settle_pot(pot);
    let (_, _, _, meme) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        pot,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );
    let alice_meme = meme / 3;

    fixture.deliver(alice_bid);
    fixture.next_tx!(KEEPER, |f| {
        let alice = f.take_coin<LAUNCH_PRESALE_TESTS>(ALICE);
        let launch = f.take_launch();

        assert_eq!(alice.value(), alice_meme);
        assert_presale(&launch, donation, 0, meme - alice_meme);
        destroy(alice);
        launch.put_back();
    });
    fixture.end();
}

// --- Trading opens after the delivery window ---

#[test]
fun a_short_presale_waits_its_own_length_before_trading() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle(KEEPER);
    fixture.set_time(SETTLE_MS + MIN_PRESALE_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.next_tx!(ALICE, |f| {
        assert!(f.has_coin<LAUNCH_PRESALE_TESTS>(ALICE));
    });
    fixture.end();
}

#[test]
fun a_long_presale_waits_the_maximum_delivery_window() {
    let mut fixture = start();
    fixture.open(MAX_PRESALE_MS);
    let settle_ms = PUBLIC_START_MS + MAX_PRESALE_MS + SETTLEMENT_DELAY_MS;
    fixture.set_time(settle_ms);
    fixture.settle(KEEPER);
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.trading_opens_ms_for_testing(), settle_ms + MAX_DELIVERY_WINDOW_MS);
        launch.put_back();
    });
    fixture.set_time(settle_ms + MAX_DELIVERY_WINDOW_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ETradingNotOpen, location = blast_fun::launch)]
fun buy_before_trading_opens_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle(KEEPER);
    fixture.set_time(TRADING_OPENS_MS - 1);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ETradingNotOpen, location = blast_fun::launch)]
fun sell_before_trading_opens_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle(KEEPER);
    fixture.set_time(TRADING_OPENS_MS - 1);

    fixture.sell(ALICE, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ETradingNotOpen, location = blast_fun::launch)]
fun migration_before_trading_opens_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.join(ALICE, 30_000_000);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(30_000_000);
    fixture.set_time(TRADING_OPENS_MS - 1);

    fixture.migrate();
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun a_graduated_presale_rejects_a_buy_on_its_lifecycle_before_the_window() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.join(ALICE, 30_000_000);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(30_000_000);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun a_graduated_presale_rejects_a_sell_on_its_lifecycle_before_the_window() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.join(ALICE, 30_000_000);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(30_000_000);

    fixture.sell(ALICE, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ETradingNotOpen, location = blast_fun::launch)]
fun the_trading_window_precedes_the_migration_witness_check() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    fixture.join(ALICE, 30_000_000);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(30_000_000);

    fixture.migrate_with(OTHER_MIGRATION_WITNESS());
    fixture.end();
}

#[test]
fun a_presale_of_the_maximum_window_waits_exactly_that_long() {
    let mut fixture = start();
    fixture.open(MAX_DELIVERY_WINDOW_MS);
    let settle_ms = PUBLIC_START_MS + MAX_DELIVERY_WINDOW_MS + SETTLEMENT_DELAY_MS;
    fixture.set_time(settle_ms);
    fixture.settle(KEEPER);
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.trading_opens_ms_for_testing(), settle_ms + MAX_DELIVERY_WINDOW_MS);
        launch.put_back();
    });
    fixture.set_time(settle_ms + MAX_DELIVERY_WINDOW_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

// --- Delivering ---

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_package_version_aborts_delivery_before_the_lifecycle_check() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let bid_id = fixture.join(ALICE, ALICE_BID);
    fixture.package_version.set_for_testing(2);

    fixture.deliver(bid_id);
    fixture.end();
}

#[test, expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
fun a_bid_cannot_be_delivered_through_another_launch() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let bid_id = fixture.join(ALICE, ALICE_BID);
    let other = fixture.open(MIN_PRESALE_MS);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot_of(other, 0);

    fixture.deliver_through(other, bid_id);
    fixture.end();
}

#[test]
fun deliveries_pay_each_bid_the_same_price_and_the_last_takes_the_remainder() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    let alice_bid = fixture.join(ALICE, ALICE_BID);
    let bob_bid = fixture.join(BOB, BOB_BID);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(ALICE_BID + BOB_BID);
    let (_, _, _, meme) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        ALICE_BID + BOB_BID,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );
    let alice_share = meme / 3;

    assert!(meme % 3 != 0);
    fixture.deliver(alice_bid);
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleDelivered>()),
        delivered_bytes(launch_id, alice_bid, ALICE, alice_share, 0),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert_presale(&launch, BOB_BID, 0, meme - alice_share);
        launch.put_back();
    });

    fixture.deliver(bob_bid);
    fixture.next_tx!(KEEPER, |f| {
        let alice = f.take_coin<LAUNCH_PRESALE_TESTS>(ALICE);
        let bob = f.take_coin<LAUNCH_PRESALE_TESTS>(BOB);
        let launch = f.take_launch();

        assert_eq!(alice.value(), alice_share);
        assert_eq!(bob.value(), meme - alice_share);
        assert!(bob.value() - 2 * alice.value() <= 2);
        assert!(!f.has_coin<TEST_QUOTE>(BOB));
        assert!(!f.has_coin<LAUNCH_PRESALE_TESTS>(KEEPER));
        assert_presale(&launch, 0, 0, 0);
        destroy(alice);
        destroy(bob);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun reversing_the_delivery_order_moves_at_most_rounding_dust() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let alice_bid = fixture.join(ALICE, ALICE_BID);
    let bob_bid = fixture.join(BOB, BOB_BID);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(ALICE_BID + BOB_BID);
    let (_, _, _, meme) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        ALICE_BID + BOB_BID,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );

    fixture.deliver(bob_bid);
    fixture.deliver(alice_bid);
    fixture.next_tx!(KEEPER, |f| {
        let alice = f.take_coin<LAUNCH_PRESALE_TESTS>(ALICE);
        let bob = f.take_coin<LAUNCH_PRESALE_TESTS>(BOB);

        assert_eq!(bob.value(), meme * 2 / 3);
        assert_eq!(alice.value(), meme - meme * 2 / 3);
        assert!(alice.value() - meme / 3 <= 1);
        destroy(alice);
        destroy(bob);
    });
    fixture.end();
}

#[test]
fun a_bidder_with_two_bids_is_paid_for_each() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    let first = fixture.join(ALICE, ALICE_BID);
    let second = fixture.join(ALICE, BOB_BID);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(ALICE_BID + BOB_BID);
    let (_, _, _, meme) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        ALICE_BID + BOB_BID,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );

    fixture.deliver(first);
    fixture.deliver(second);
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleDelivered>()),
        delivered_bytes(launch_id, second, ALICE, meme - meme / 3, 0),
    );
    assert_eq!(fixture.bid_count(launch_id), 0);
    fixture.end();
}

#[test]
fun delivery_deletes_the_bid() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_PRESALE_MS);
    let alice_bid = fixture.join(ALICE, ALICE_BID);
    fixture.join(BOB, BOB_BID);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(ALICE_BID + BOB_BID);

    fixture.deliver(alice_bid);
    assert_eq!(fixture.bid_count(launch_id), 1);
    fixture.end();
}

#[test]
fun delivery_after_migration_still_pays_the_bidder() {
    let mut fixture = start();
    fixture.open(MIN_PRESALE_MS);
    let bid_id = fixture.join(ALICE, 30_000_000);
    fixture.set_time(SETTLE_MS);
    fixture.settle_pot(30_000_000);
    fixture.set_time(TRADING_OPENS_MS);
    fixture.migrate();

    fixture.deliver(bid_id);
    fixture.next_tx!(KEEPER, |f| {
        let meme = f.take_coin<LAUNCH_PRESALE_TESTS>(ALICE);
        let quote = f.take_coin<TEST_QUOTE>(ALICE);
        let launch = f.take_launch();

        assert!(launch.is_migrated_for_testing());
        assert!(meme.value() > 0 && quote.value() > 0);
        assert_presale(&launch, 0, 0, 0);
        destroy(meme);
        destroy(quote);
        launch.put_back();
    });
    fixture.end();
}

// === Test Helpers ===

// --- Fixture ---

macro fun presale_next_tx(
    $fixture: &mut PresaleFixture,
    $sender: address,
    $fn: |&mut PresaleFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

/// Configured launch policy with Blast's allocation at zero, and the accumulator root the system
/// address creates.
fun start(): PresaleFixture {
    let mut scenario = test_scenario::begin(@0x0);
    accumulator::create_for_testing(scenario.ctx());
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::treasury_admin_role()
            | blast_fun_domain::fee_admin_role()
            | blast_fun_domain::listing_admin_role()
            | blast_fun_domain::adapter_admin_role(),
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    launch_config::init_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(PUBLIC_START_MS);

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let mut config = scenario.take_shared<LaunchConfig>();
    let admin_witness = authority.sign_in(&admin_cap);
    config.set_quote_allowed<TEST_QUOTE>(&package_version, &admin_witness, true);
    config.set_migration_witness_allowed<TEST_MIGRATION_WITNESS>(
        &package_version,
        &admin_witness,
        true,
    );
    config.set_trade_fees(
        &package_version,
        &admin_witness,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );
    config.set_protocol_allocation(
        &package_version,
        &admin_witness,
        PROTOCOL_ADMIN,
        bps::new(0),
        bps::new(0),
    );
    destroy(admin_cap);
    destroy(authority);
    scenario.next_tx(LAUNCHER);

    PresaleFixture { scenario, package_version, config, runtime_config, clock }
}

fun presale_end(self: PresaleFixture) {
    destroy(self);
}

/// Moves the fixture clock to `timestamp_ms` for the following transactions.
fun presale_set_time(self: &mut PresaleFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

// --- Construction ---

/// A curve holding 80 percent of supply and the pool the rest; Blast's allocation is zero.
fun plan(): AllocationPlan {
    allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[])
}

fun presale_new_ticket(self: &mut PresaleFixture): LaunchTicket<LAUNCH_PRESALE_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Presale".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        SELL_BURN_BPS,
        self.scenario.ctx(),
    )
}

/// Starts, configures, and finalizes the launch in the next transaction, once the Coin Registry
/// holds the ticket's currency.
fun presale_intake(
    self: &mut PresaleFixture,
    ticket: LaunchTicket<LAUNCH_PRESALE_TESTS>,
    plan: AllocationPlan,
    presale_ms: u64,
): Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE> {
    self.scenario.next_tx(LAUNCHER);
    let mut currency = self
        .scenario
        .take_from_address<Currency<LAUNCH_PRESALE_TESTS>>(COIN_REGISTRY);
    let mut initializer = launch::new<_, TEST_QUOTE, _>(
        ticket,
        &self.package_version,
        &self.config,
        TEST_MIGRATION_WITNESS(),
        200,
        10_000,
    );
    initializer.set_virtual_quote(VIRTUAL_QUOTE);
    initializer.set_graduation_target(TARGET);
    initializer.set_allocation_plan(plan);
    initializer.set_lp_fee_split(
        allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[]),
    );
    initializer.set_presale(presale_ms);
    let launch = initializer.finalize(&mut currency, &self.config, self.scenario.ctx());
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

fun presale_new_launch(
    self: &mut PresaleFixture,
    presale_ms: u64,
): Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket();

    self.intake(ticket, plan(), presale_ms)
}

/// Creates and shares one launch at the fixture clock's current time and returns its ID.
fun presale_open(self: &mut PresaleFixture, presale_ms: u64): ID {
    let launch = self.new_launch(presale_ms);
    let launch_id = object::id(&launch);
    self.share(launch);

    launch_id
}

/// Shares the launch at the fixture clock's current time.
fun presale_share(self: &PresaleFixture, launch: Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>) {
    launch.share(&self.clock);
}

// --- Presale ---

/// Joins the owned launch's presale before it is shared, as the launcher, and returns the bid ID.
fun presale_join_before_share(
    self: &mut PresaleFixture,
    launch: &Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>,
    quote_in: u64,
): ID {
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());
    launch.join_presale(&self.package_version, quote, &self.clock, self.scenario.ctx());

    joined_bid_id()
}

/// Joins the presale as `sender` in a new transaction and returns the bid ID.
fun presale_join(self: &mut PresaleFixture, sender: address, quote_in: u64): ID {
    self.scenario.next_tx(sender);
    let launch = self.take_launch();
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());
    launch.join_presale(&self.package_version, quote, &self.clock, self.scenario.ctx());
    launch.put_back();

    joined_bid_id()
}

/// Settles the presale as `sender` in a new transaction. Move tests cannot settle address
/// balances, so the launch reads an empty pot.
fun presale_settle(self: &mut PresaleFixture, sender: address) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();
    let accumulator_root = self.scenario.take_shared<AccumulatorRoot>();

    launch.settle_presale(
        &self.package_version,
        &self.runtime_config,
        &accumulator_root,
        &self.clock,
    );
    test_scenario::return_shared(accumulator_root);
    launch.put_back();
}

/// Settles the owned launch's presale in the current transaction.
fun presale_settle_owned(
    self: &mut PresaleFixture,
    launch: &mut Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>,
) {
    self.scenario.next_tx(KEEPER);
    let accumulator_root = self.scenario.take_shared<AccumulatorRoot>();

    launch.settle_presale(
        &self.package_version,
        &self.runtime_config,
        &accumulator_root,
        &self.clock,
    );
    test_scenario::return_shared(accumulator_root);
}

/// Settles the presale in a new transaction with a `pot` of Quote standing in for the launch's
/// settled address balance.
fun presale_settle_pot(self: &mut PresaleFixture, pot: u64) {
    self.scenario.next_tx(KEEPER);
    let mut launch = self.take_launch();

    launch.settle_presale_pot_for_testing(
        &self.runtime_config,
        balance::create_for_testing(pot),
        &self.clock,
    );
    launch.put_back();
}

/// `presale_settle_pot` for the launch `launch_id`, when several exist.
fun presale_settle_pot_of(self: &mut PresaleFixture, launch_id: ID, pot: u64) {
    self.scenario.next_tx(KEEPER);
    let mut launch = self
        .scenario
        .take_shared_by_id<Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>>(launch_id);

    launch.settle_presale_pot_for_testing(
        &self.runtime_config,
        balance::create_for_testing(pot),
        &self.clock,
    );
    launch.put_back();
}

/// Delivers the bid `bid_id` as the keeper in a new transaction.
fun presale_deliver(self: &mut PresaleFixture, bid_id: ID) {
    self.scenario.next_tx(KEEPER);
    let mut launch = self.take_launch();

    launch.deliver_presale(
        &self.package_version,
        test_scenario::receiving_ticket_by_id(bid_id),
        self.scenario.ctx(),
    );
    launch.put_back();
}

/// Delivers the bid `bid_id` through the launch `launch_id`, whichever launch owns the bid.
fun presale_deliver_through(self: &mut PresaleFixture, launch_id: ID, bid_id: ID) {
    self.scenario.next_tx(KEEPER);
    let mut launch = self
        .scenario
        .take_shared_by_id<Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>>(launch_id);

    launch.deliver_presale(
        &self.package_version,
        test_scenario::receiving_ticket_by_id(bid_id),
        self.scenario.ctx(),
    );
    launch.put_back();
}

/// Returns the bid's `[bidder, quote]` in a new transaction, leaving it with the launch.
fun presale_bid(self: &mut PresaleFixture, launch_id: ID, bid_id: ID): vector<u256> {
    self.scenario.next_tx(KEEPER);
    let bid = self
        .scenario
        .take_from_address_by_id<BlastPresaleBid>(launch_id.to_address(), bid_id);
    let (bidder, quote) = bid.presale_bid_for_testing();
    test_scenario::return_to_address(launch_id.to_address(), bid);

    vector[bidder.to_u256(), quote as u256]
}

/// The number of undelivered bids the launch owns, in a new transaction.
fun presale_bid_count(self: &mut PresaleFixture, launch_id: ID): u64 {
    self.scenario.next_tx(KEEPER);

    test_scenario::receivable_object_ids_for_owner_id<BlastPresaleBid>(launch_id).length()
}

// --- Trading ---

/// Buys from the curve as `sender` in a new transaction.
fun presale_buy(self: &mut PresaleFixture, sender: address, quote_in: u64, min_meme_out: u64) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());
    let (meme, refund) = launch.buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        min_meme_out,
        &self.clock,
        self.scenario.ctx(),
    );
    transfer::public_transfer(meme, sender);
    destroy(refund);
    launch.put_back();
}

/// Buys from the owned launch in the current transaction.
fun presale_buy_owned(
    self: &mut PresaleFixture,
    launch: &mut Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>,
    quote_in: u64,
) {
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());
    let (meme, refund) = launch.buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        1,
        &self.clock,
        self.scenario.ctx(),
    );

    destroy(meme);
    destroy(refund);
}

/// Sells `meme_in` freshly minted Meme as `sender` in a new transaction.
fun presale_sell(self: &mut PresaleFixture, sender: address, meme_in: u64) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();
    let meme = coin::mint_for_testing<LAUNCH_PRESALE_TESTS>(meme_in, self.scenario.ctx());
    let quote = launch.sell(
        &self.package_version,
        &self.runtime_config,
        meme,
        0,
        &self.clock,
        self.scenario.ctx(),
    );

    destroy(quote);
    launch.put_back();
}

/// Migrates as the stored adapter in a new transaction and discards the pool's share.
fun presale_migrate(self: &mut PresaleFixture) {
    self.migrate_with(TEST_MIGRATION_WITNESS());
}

/// Migrates with `witness` in a new transaction and discards the pool's share.
fun presale_migrate_with<Witness: drop>(self: &mut PresaleFixture, witness: Witness) {
    self.scenario.next_tx(KEEPER);
    let mut launch = self.take_launch();
    let mut currency = self
        .scenario
        .take_from_address<Currency<LAUNCH_PRESALE_TESTS>>(COIN_REGISTRY);
    let (meme, quote) = launch.migrate(
        &self.package_version,
        &mut currency,
        witness,
        &self.clock,
        self.scenario.ctx(),
    );

    destroy(meme);
    destroy(quote);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
    launch.put_back();
}

// --- Storage ---

fun presale_take_launch(self: &PresaleFixture): Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE> {
    self.scenario.take_shared()
}

/// Returns a taken launch to shared storage for a later transaction.
fun put_back(launch: Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>) {
    test_scenario::return_shared(launch);
}

fun presale_take_coin<T>(self: &PresaleFixture, owner: address): Coin<T> {
    self.scenario.take_from_address(owner)
}

fun presale_has_coin<T>(_: &PresaleFixture, owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<T>>(owner)
}

// --- Assertions ---

/// Checks the undelivered pot and the Quote and Meme held for it.
fun assert_presale(
    launch: &Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>,
    pot: u64,
    quote: u64,
    meme: u64,
) {
    let (actual_pot, actual_quote, actual_meme) = launch.presale_for_testing();

    assert_eq!(actual_pot, pot);
    assert_eq!(actual_quote, quote);
    assert_eq!(actual_meme, meme);
}

/// Checks the curve and the pool's Meme are as finalized and no Quote reached the curve.
fun assert_curve_untouched(launch: &Launch<LAUNCH_PRESALE_TESTS, TEST_QUOTE>) {
    let (meme_reserve, real_quote, pending_burn, pool_meme) = launch.balances_for_testing();

    assert_eq!(meme_reserve, CURVE_MEME);
    assert_eq!(real_quote, 0);
    assert_eq!(pending_burn, 0);
    assert_eq!(pool_meme, 200_000_000__000_000_000);
}

// --- Events ---

/// Checks this transaction's only `LaunchCreated` event names `launch_id` and ends with
/// `presale_ms`.
fun assert_launch_created(launch_id: ID, presale_ms: u64) {
    let created = bcs::to_bytes(&only_event<LaunchCreated>());
    let tail = created.length() - 8;

    assert_eq!(vector::tabulate!(32, |i| created[i]), bcs::to_bytes(&launch_id));
    assert_eq!(vector::tabulate!(8, |i| created[tail + i]), bcs::to_bytes(&presale_ms));
}

/// The bid ID of this transaction's only `PresaleJoined` event.
fun joined_bid_id(): ID {
    let mut fields = sui::bcs::new(bcs::to_bytes(&only_event<PresaleJoined>()));
    fields.peel_address();

    object::id_from_address(fields.peel_address())
}

/// Expected bytes of a payload whose fields after the launch ID are all `u64`.
fun u64_payload(launch_id: ID, fields: vector<u64>): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    fields.do!(|field| expected.append(bcs::to_bytes(&field)));
    expected
}

/// Expected `PresaleJoined` bytes.
fun joined_bytes(launch_id: ID, bid_id: ID, quote: u64): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&bid_id));
    expected.append(bcs::to_bytes(&quote));
    expected
}

/// Expected `PresaleDelivered` bytes.
fun delivered_bytes(launch_id: ID, bid_id: ID, bidder: address, meme: u64, quote: u64): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&bid_id));
    expected.append(bcs::to_bytes(&bidder));
    expected.append(bcs::to_bytes(&meme));
    expected.append(bcs::to_bytes(&quote));
    expected
}

/// This transaction's only event of type `T`.
fun only_event<T: copy + drop>(): T {
    let mut events = event::events_by_type<Event<T>>();
    assert_eq!(events.length(), 1);

    events.pop_back().unwrap()
}

// === Imports ===

use blast_admin::acl::AdminCap;

use blast_fun::{
    allocation::{Self, AllocationPlan},
    blast_events::Event,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority,
    curve,
    domain_fixture,
    events::{Bought, LaunchCreated, PresaleDelivered, PresaleJoined, PresaleSettled},
    launch::{Self, BlastPresaleBid, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{
    accumulator::{Self, AccumulatorRoot},
    balance,
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun presale_end as PresaleFixture.end;

use fun presale_next_tx as PresaleFixture.next_tx;

use fun presale_set_time as PresaleFixture.set_time;

use fun presale_new_ticket as PresaleFixture.new_ticket;

use fun presale_intake as PresaleFixture.intake;

use fun presale_new_launch as PresaleFixture.new_launch;

use fun presale_open as PresaleFixture.open;

use fun presale_share as PresaleFixture.share;

use fun presale_join_before_share as PresaleFixture.join_before_share;

use fun presale_join as PresaleFixture.join;

use fun presale_settle as PresaleFixture.settle;

use fun presale_settle_owned as PresaleFixture.settle_owned;

use fun presale_settle_pot as PresaleFixture.settle_pot;

use fun presale_settle_pot_of as PresaleFixture.settle_pot_of;

use fun presale_deliver as PresaleFixture.deliver;

use fun presale_deliver_through as PresaleFixture.deliver_through;

use fun presale_bid as PresaleFixture.bid;

use fun presale_bid_count as PresaleFixture.bid_count;

use fun presale_buy as PresaleFixture.buy;

use fun presale_buy_owned as PresaleFixture.buy_owned;

use fun presale_sell as PresaleFixture.sell;

use fun presale_migrate as PresaleFixture.migrate;

use fun presale_migrate_with as PresaleFixture.migrate_with;

use fun presale_take_launch as PresaleFixture.take_launch;

use fun presale_take_coin as PresaleFixture.take_coin;

use fun presale_has_coin as PresaleFixture.has_coin;

use fun put_back as Launch.put_back;
