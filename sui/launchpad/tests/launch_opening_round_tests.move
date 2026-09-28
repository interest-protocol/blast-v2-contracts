// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_opening_round_tests;

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

const MIN_ROUND_MS: u64 = 60_000;

const MAX_ROUND_MS: u64 = 300_000;

const ROUND_END_MS: u64 = 61_000;

const ALICE_BID: u64 = 1_000_000;

const BOB_BID: u64 = 2_000_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_OPENING_ROUND_TESTS has drop {}

public struct TEST_QUOTE() has drop;

public struct TEST_MIGRATION_WITNESS() has drop;

/// Configured cold policy and one clock standing at the public start time.
public struct OpeningRoundFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    config: LaunchConfig,
    runtime_config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

// --- Settings ---

#[test]
fun zero_opening_round_starts_live() {
    let mut fixture = start();
    let launch = fixture.new_launch(0);

    assert_launch_created(object::id(&launch), 0);
    assert!(launch.is_live_for_testing());
    assert_eq!(launch.opening_round_ms_for_testing(), 0);
    destroy(launch);
    fixture.end();
}

#[test]
fun shortest_opening_round_is_accepted() {
    let mut fixture = start();
    let launch = fixture.new_launch(MIN_ROUND_MS);

    assert_launch_created(object::id(&launch), MIN_ROUND_MS);
    assert!(launch.is_opening_round_for_testing());
    assert_eq!(launch.opening_round_ms_for_testing(), MIN_ROUND_MS);
    destroy(launch);
    fixture.end();
}

#[test]
fun longest_opening_round_is_accepted() {
    let mut fixture = start();
    let launch = fixture.new_launch(MAX_ROUND_MS);

    assert_launch_created(object::id(&launch), MAX_ROUND_MS);
    assert!(launch.is_opening_round_for_testing());
    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidOpeningRound, location = blast_fun::launch)]
fun opening_round_below_the_minimum_is_rejected() {
    let mut fixture = start();
    let launch = fixture.new_launch(MIN_ROUND_MS - 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidOpeningRound, location = blast_fun::launch)]
fun opening_round_above_the_maximum_is_rejected() {
    let mut fixture = start();
    let launch = fixture.new_launch(MAX_ROUND_MS + 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidOpeningRound, location = blast_fun::launch)]
fun invalid_opening_round_precedes_the_ticket_sell_burn() {
    let mut fixture = start();
    let mut ticket = fixture.new_ticket();
    ticket.set_sell_burn_bps_for_testing(5_001);
    let launch = fixture.intake(ticket, plan(), 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
fun allocation_sums_precede_an_invalid_opening_round() {
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

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidOpeningRound, location = blast_fun::launch)]
fun invalid_opening_round_aborts_before_ticket_custody_moves() {
    let mut fixture = start();
    let mut ticket = fixture.new_ticket();
    ticket.burn_meme_for_testing(1);
    let launch = fixture.intake(ticket, plan(), 1);

    destroy(launch);
    fixture.end();
}

// --- Joining ---

#[test]
fun creator_and_public_bids_accumulate_per_bidder() {
    let mut fixture = start();
    let mut launch = fixture.new_launch(MIN_ROUND_MS);
    fixture.join_before_share(&mut launch, ALICE_BID);
    let launch_id = object::id(&launch);

    assert_eq!(
        bcs::to_bytes(&only_event<OpeningRoundJoined>()),
        u64_payload(launch_id, vector[ALICE_BID, ALICE_BID]),
    );
    fixture.share(launch);
    fixture.join(ALICE, ALICE_BID);
    fixture.join(ALICE, ALICE_BID);
    fixture.join(BOB, BOB_BID);

    assert_eq!(
        bcs::to_bytes(&only_event<OpeningRoundJoined>()),
        u64_payload(launch_id, vector[BOB_BID, 3 * ALICE_BID + BOB_BID]),
    );
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.opening_round_bid_for_testing(LAUNCHER), ALICE_BID);
        assert_eq!(launch.opening_round_bid_for_testing(ALICE), 2 * ALICE_BID);
        assert_eq!(launch.opening_round_bid_for_testing(BOB), BOB_BID);
        assert_opening_round(&launch, 3 * ALICE_BID + BOB_BID, 3 * ALICE_BID + BOB_BID, 0);
        assert_curve_untouched(&launch);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun join_one_millisecond_before_the_end_is_accepted() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS - 1);
    fixture.join(ALICE, ALICE_BID);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.opening_round_bid_for_testing(ALICE), ALICE_BID);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EOpeningRoundEnded, location = blast_fun::launch)]
fun join_at_the_exact_end_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EOpeningRoundEnded, location = blast_fun::launch)]
fun an_ended_round_precedes_a_zero_bid() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);

    fixture.join(ALICE, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroOpeningRoundBid, location = blast_fun::launch)]
fun zero_bid_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);

    fixture.join(ALICE, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun join_without_an_opening_round_is_rejected() {
    let mut fixture = start();
    fixture.open(0);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun join_after_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);

    fixture.join(ALICE, ALICE_BID);
    fixture.end();
}

// --- Nothing trades during the round ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun creator_cannot_buy_before_share_with_an_opening_round() {
    let mut fixture = start();
    let mut launch = fixture.new_launch(MIN_ROUND_MS);
    let quote = coin::mint_for_testing<TEST_QUOTE>(ALICE_BID, fixture.ctx!());
    let (meme, refund) = launch.buy(
        &fixture.package_version,
        &fixture.runtime_config,
        quote,
        1,
        fixture.ctx!(),
    );

    destroy(meme);
    destroy(refund);
    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun buy_during_the_round_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun buy_after_the_end_but_before_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun sell_during_the_round_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.next_tx!(ALICE, |f| {
        let mut launch = f.take_launch();
        let meme = coin::mint_for_testing<LAUNCH_OPENING_ROUND_TESTS>(1, f.ctx!());
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 0, f.ctx!());

        destroy(quote);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun delivery_before_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.set_time(ROUND_END_MS);

    fixture.deliver(KEEPER, ALICE);
    fixture.end();
}

// --- Settling ---

#[test, expected_failure(abort_code = blast_fun::errors::EOpeningRoundNotEnded, location = blast_fun::launch)]
fun settle_one_millisecond_before_the_end_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS - 1);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EOpeningRoundNotEnded, location = blast_fun::launch)]
fun settle_before_share_is_rejected() {
    let mut fixture = start();
    let mut launch = fixture.new_launch(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);

    launch.settle_opening_round(&fixture.package_version, &fixture.runtime_config, &fixture.clock);
    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun settle_without_an_opening_round_is_rejected() {
    let mut fixture = start();
    fixture.open(0);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun second_settlement_is_rejected() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);

    fixture.settle(KEEPER);
    fixture.end();
}

#[test]
fun settlement_at_the_end_buys_once_with_the_whole_pot_and_opens_trading() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.join(BOB, BOB_BID);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);
    let pot = ALICE_BID + BOB_BID;
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
        bcs::to_bytes(&only_event<OpeningRoundSettled>()),
        u64_payload(launch_id, vector[pot, meme_out_net, 0]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(launch.is_live_for_testing());
        assert_opening_round(&launch, pot, 0, meme_out_net);
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();
        assert_eq!(meme_reserve, CURVE_MEME - meme_out_gross);
        assert_eq!(real_quote, pot - quote_fee);
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme + creator_meme, meme_fee);
        assert_eq!(protocol_quote + creator_quote, quote_fee);
        launch.put_back();
    });

    fixture.buy(ALICE, ALICE_BID, 1);
    fixture.end();
}

#[test]
fun empty_round_settles_live_without_a_purchase() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_ROUND_MS);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);

    assert_eq!(event::events_by_type<Event<Bought>>().length(), 0);
    assert_eq!(
        bcs::to_bytes(&only_event<OpeningRoundSettled>()),
        u64_payload(launch_id, vector[0, 0, 0]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(launch.is_live_for_testing());
        assert_curve_untouched(&launch);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun pot_too_small_to_buy_is_refunded_whole() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, 1);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);

    assert_eq!(event::events_by_type<Event<Bought>>().length(), 0);
    assert_eq!(
        bcs::to_bytes(&only_event<OpeningRoundSettled>()),
        u64_payload(launch_id, vector[1, 0, 1]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert_curve_untouched(&launch);
        launch.put_back();
    });

    fixture.deliver(KEEPER, ALICE);
    fixture.next_tx!(ALICE, |f| {
        let refund = f.take_coin<TEST_QUOTE>(ALICE);

        assert_eq!(refund.value(), 1);
        assert!(!owns_meme(ALICE));
        destroy(refund);
    });
    fixture.end();
}

#[test]
fun pot_past_the_target_graduates_and_refunds_the_excess_pro_rata() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, 10_000_000);
    fixture.join(BOB, 30_000_000);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);
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
        assert_opening_round(&launch, 40_000_000, excess, meme_out_net);
        launch.put_back();
    });

    fixture.deliver(KEEPER, ALICE);
    fixture.deliver(KEEPER, BOB);
    fixture.next_tx!(KEEPER, |f| {
        let alice_meme = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(ALICE);
        let alice_quote = f.take_coin<TEST_QUOTE>(ALICE);
        let bob_meme = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(BOB);
        let bob_quote = f.take_coin<TEST_QUOTE>(BOB);
        let launch = f.take_launch();

        assert_eq!(alice_meme.value(), meme_out_net / 4);
        assert_eq!(alice_quote.value(), excess / 4);
        assert_eq!(bob_meme.value(), meme_out_net - meme_out_net / 4);
        assert_eq!(bob_quote.value(), excess - excess / 4);
        assert_opening_round(&launch, 0, 0, 0);
        destroy(alice_meme);
        destroy(alice_quote);
        destroy(bob_meme);
        destroy(bob_quote);
        launch.put_back();
    });
    fixture.end();
}

// --- Delivering ---

#[test]
fun deliveries_pay_each_bidder_the_same_price_and_the_last_takes_the_remainder() {
    let mut fixture = start();
    let launch_id = fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.join(BOB, BOB_BID);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);
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
    fixture.deliver(KEEPER, ALICE);
    assert_eq!(
        bcs::to_bytes(&only_event<OpeningRoundDelivered>()),
        delivered_bytes(launch_id, ALICE, vector[ALICE_BID, alice_share, 0]),
    );
    fixture.next_tx!(KEEPER, |f| {
        let launch = f.take_launch();

        assert!(!launch.has_opening_round_bid_for_testing(ALICE));
        assert_opening_round(&launch, BOB_BID, 0, meme - alice_share);
        launch.put_back();
    });

    fixture.deliver(KEEPER, BOB);
    fixture.next_tx!(KEEPER, |f| {
        let alice = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(ALICE);
        let bob = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(BOB);
        let launch = f.take_launch();

        assert_eq!(alice.value(), alice_share);
        assert_eq!(bob.value(), meme - alice_share);
        assert!(bob.value() - 2 * alice.value() <= 2);
        assert!(!f.has_coin<TEST_QUOTE>(BOB));
        assert!(!owns_meme(KEEPER));
        assert_opening_round(&launch, 0, 0, 0);
        destroy(alice);
        destroy(bob);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun reversing_the_delivery_order_moves_at_most_rounding_dust() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.join(BOB, BOB_BID);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);
    let (_, _, _, meme) = curve::quote_buy(
        CURVE_MEME,
        0,
        VIRTUAL_QUOTE,
        ALICE_BID + BOB_BID,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );

    fixture.deliver(KEEPER, BOB);
    fixture.deliver(KEEPER, ALICE);
    fixture.next_tx!(KEEPER, |f| {
        let alice = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(ALICE);
        let bob = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(BOB);

        assert_eq!(bob.value(), meme * 2 / 3);
        assert_eq!(alice.value(), meme - meme * 2 / 3);
        assert!(alice.value() - meme / 3 <= 1);
        destroy(alice);
        destroy(bob);
    });
    fixture.end();
}

#[test]
fun delivery_after_migration_still_pays_the_bidder() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, 30_000_000);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);
    fixture.next_tx!(KEEPER, |f| {
        let mut launch = f.take_launch();
        f.migrate(&mut launch);

        assert!(launch.is_migrated_for_testing());
        launch.put_back();
    });

    fixture.deliver(KEEPER, ALICE);
    fixture.next_tx!(KEEPER, |f| {
        let meme = f.take_coin<LAUNCH_OPENING_ROUND_TESTS>(ALICE);
        let quote = f.take_coin<TEST_QUOTE>(ALICE);
        let launch = f.take_launch();

        assert!(meme.value() > 0 && quote.value() > 0);
        assert_opening_round(&launch, 0, 0, 0);
        destroy(meme);
        destroy(quote);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun second_delivery_to_a_bidder_aborts() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);
    fixture.deliver(KEEPER, ALICE);

    fixture.deliver(KEEPER, ALICE);
    fixture.end();
}

#[test, expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun delivery_to_an_address_without_a_bid_aborts() {
    let mut fixture = start();
    fixture.open(MIN_ROUND_MS);
    fixture.join(ALICE, ALICE_BID);
    fixture.set_time(ROUND_END_MS);
    fixture.settle(KEEPER);

    fixture.deliver(KEEPER, BOB);
    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut OpeningRoundFixture,
    $sender: address,
    $fn: |&mut OpeningRoundFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun ctx($fixture: &mut OpeningRoundFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun take_coin<T>(self: &OpeningRoundFixture, owner: address): Coin<T> {
    self.scenario.take_from_address(owner)
}

fun has_coin<T>(_: &OpeningRoundFixture, owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<T>>(owner)
}

/// Migrates the launch as its stored adapter and discards the pool's share.
fun migrate(self: &mut OpeningRoundFixture, launch: &mut Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE>) {
    let mut currency = self
        .scenario
        .take_from_address<Currency<LAUNCH_OPENING_ROUND_TESTS>>(COIN_REGISTRY);
    let (meme, quote) = launch.migrate(
        &self.package_version,
        &mut currency,
        TEST_MIGRATION_WITNESS(),
        self.scenario.ctx(),
    );
    destroy(meme);
    destroy(quote);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
}

fun start(): OpeningRoundFixture {
    let mut scenario = test_scenario::begin(PROTOCOL_ADMIN);
    let package_version = package_version::new_for_testing(scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(PUBLIC_START_MS);

    scenario.next_tx(PROTOCOL_ADMIN);
    let mut config = scenario.take_shared<LaunchConfig>();
    config.set_quote_allowed<TEST_QUOTE>(
        &package_version,
        &blast_acl::witness_for_testing<ListingAdmin>(),
        true,
    );
    config.set_migration_witness_allowed<TEST_MIGRATION_WITNESS>(
        &package_version,
        &blast_acl::witness_for_testing<AdapterAdmin>(),
        true,
    );
    config.set_trade_fees(
        &package_version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );
    scenario.next_tx(LAUNCHER);

    OpeningRoundFixture { scenario, package_version, config, runtime_config, clock }
}

/// A curve holding 80 percent of supply and the pool the rest; Blast's allocation is zero.
fun plan(): AllocationPlan {
    allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[])
}

fun new_ticket(self: &mut OpeningRoundFixture): LaunchTicket<LAUNCH_OPENING_ROUND_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_OPENING_ROUND_TESTS>(),
        9,
        b"OPEN".to_string(),
        b"Opening Round".to_string(),
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
fun intake(
    self: &mut OpeningRoundFixture,
    ticket: LaunchTicket<LAUNCH_OPENING_ROUND_TESTS>,
    plan: AllocationPlan,
    opening_round_ms: u64,
): Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE> {
    self.scenario.next_tx(LAUNCHER);
    let mut currency = self
        .scenario
        .take_from_address<Currency<LAUNCH_OPENING_ROUND_TESTS>>(COIN_REGISTRY);
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
    initializer.set_opening_round(opening_round_ms);
    let creation_fee = coin::zero(self.scenario.ctx());
    let launch = initializer.finalize(&mut currency, &self.config, creation_fee, self.scenario.ctx());
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

fun new_launch(
    self: &mut OpeningRoundFixture,
    opening_round_ms: u64,
): Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket();

    self.intake(ticket, plan(), opening_round_ms)
}

/// Moves the fixture clock to `timestamp_ms` for the following transactions.
fun set_time(self: &mut OpeningRoundFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

/// Creates and shares one launch at the fixture clock's current time and returns its ID.
fun open(self: &mut OpeningRoundFixture, opening_round_ms: u64): ID {
    let launch = self.new_launch(opening_round_ms);
    let launch_id = object::id(&launch);
    self.share(launch);

    launch_id
}

/// Shares the launch at the fixture clock's current time.
fun share(self: &OpeningRoundFixture, launch: Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE>) {
    launch.share(&self.clock);
}

fun take_launch(self: &OpeningRoundFixture): Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE> {
    self.scenario.take_shared()
}

/// Returns a taken launch to shared storage for a later transaction.
fun put_back(launch: Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE>) {
    test_scenario::return_shared(launch);
}

/// Joins the owned launch's opening round before it is shared, as the launcher.
fun join_before_share(
    self: &mut OpeningRoundFixture,
    launch: &mut Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE>,
    quote_in: u64,
) {
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());

    launch.join_opening_round(&self.package_version, quote, &self.clock, self.scenario.ctx());
}

/// Joins the opening round as `sender` in a new transaction.
fun join(self: &mut OpeningRoundFixture, sender: address, quote_in: u64) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());

    launch.join_opening_round(&self.package_version, quote, &self.clock, self.scenario.ctx());
    launch.put_back();
}

/// Settles the opening round as `sender` in a new transaction.
fun settle(self: &mut OpeningRoundFixture, sender: address) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();

    launch.settle_opening_round(&self.package_version, &self.runtime_config, &self.clock);
    launch.put_back();
}

/// Delivers `bidder`'s share as `sender` in a new transaction.
fun deliver(self: &mut OpeningRoundFixture, sender: address, bidder: address) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();

    launch.deliver_opening_round(&self.package_version, bidder, self.scenario.ctx());
    launch.put_back();
}

/// Buys from the curve as `sender` in a new transaction.
fun buy(self: &mut OpeningRoundFixture, sender: address, quote_in: u64, min_meme_out: u64) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());
    let (meme, refund) = launch.buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        min_meme_out,
        self.scenario.ctx(),
    );
    transfer::public_transfer(meme, sender);
    destroy(refund);
    launch.put_back();
}

/// Checks this transaction's only `LaunchCreated` event names `launch_id` and `opening_round_ms`,
/// which the free creation's fee (8 bytes) and the absent partner (1) follow.
fun assert_launch_created(launch_id: ID, opening_round_ms: u64) {
    let created = bcs::to_bytes(&only_event<LaunchCreated>());
    let tail = created.length() - 17;

    assert_eq!(vector::tabulate!(32, |i| created[i]), bcs::to_bytes(&launch_id));
    assert_eq!(vector::tabulate!(8, |i| created[tail + i]), bcs::to_bytes(&opening_round_ms));
}

/// Expected bytes of a payload whose fields after the launch ID are all `u64`.
fun u64_payload(launch_id: ID, fields: vector<u64>): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    fields.do!(|field| expected.append(bcs::to_bytes(&field)));
    expected
}

/// Expected `OpeningRoundDelivered` bytes: the launch ID, the bidder, then `bid`, `meme`, `quote`.
fun delivered_bytes(launch_id: ID, bidder: address, fields: vector<u64>): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&bidder));
    fields.do!(|field| expected.append(bcs::to_bytes(&field)));
    expected
}

/// This transaction's only event of type `T`.
fun only_event<T: copy + drop>(): T {
    let mut events = event::events_by_type<Event<T>>();
    assert_eq!(events.length(), 1);

    events.pop_back().unwrap()
}

/// Whether `owner` holds any Meme coin.
fun owns_meme(owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<LAUNCH_OPENING_ROUND_TESTS>>(owner)
}

/// Checks the undelivered bids' total and the Quote and Meme held for them.
fun assert_opening_round(
    launch: &Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE>,
    bids: u64,
    quote: u64,
    meme: u64,
) {
    let (actual_bids, actual_quote, actual_meme) = launch.opening_round_for_testing();

    assert_eq!(actual_bids, bids);
    assert_eq!(actual_quote, quote);
    assert_eq!(actual_meme, meme);
}

/// Checks the curve and the pool's Meme are as finalized and no Quote reached the curve.
fun assert_curve_untouched(launch: &Launch<LAUNCH_OPENING_ROUND_TESTS, TEST_QUOTE>) {
    let (meme_reserve, real_quote, pending_burn, pool_meme) = launch.balances_for_testing();

    assert_eq!(meme_reserve, CURVE_MEME);
    assert_eq!(real_quote, 0);
    assert_eq!(pending_burn, 0);
    assert_eq!(pool_meme, 200_000_000__000_000_000);
}

fun end(self: OpeningRoundFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    allocation::{Self, AllocationPlan},
    blast_events::Event,
    blast_fun_domain::{AdapterAdmin, FeeAdmin, ListingAdmin},
    bps,
    creator_authority,
    curve,
    events::{
        Bought,
        LaunchCreated,
        OpeningRoundDelivered,
        OpeningRoundJoined,
        OpeningRoundSettled,
    },
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun put_back as Launch.put_back;
