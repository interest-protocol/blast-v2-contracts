// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_protection_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const PROTOCOL_ADMIN: address = @0xAD;

const LAUNCHER: address = @0xB1A57;

const CREATOR: address = @0xC0FFEE;

const ALICE: address = @0xA11CE;

const BOB: address = @0xB0B;

const SELL_BURN_BPS: u64 = 1_000;

const TARGET: u64 = 25_000_000;

const PUBLIC_START_MS: u64 = 1_000;

const WINDOW_MS: u64 = 60_000;

const PROTECTION_END_MS: u64 = 61_000;

const CUMULATIVE_BPS: u64 = 100;

/// One percent of the nine-decimal supply of 10^18 atoms.
const CUMULATIVE_LIMIT: u64 = 10_000_000__000_000_000;

const PER_TRANSACTION_BPS: u64 = 50;

/// Half a percent of the nine-decimal supply of 10^18 atoms.
const PER_TRANSACTION_LIMIT: u64 = 5_000_000__000_000_000;

/// Buys about 3.2 * 10^15 gross atoms: three fit the cumulative limit, a fourth does not.
const SMALL_BUY: u64 = 20_000;

/// Buys about 6.3 * 10^15 gross atoms: above the per-transaction limit only.
const OVERSIZED_BUY: u64 = 40_000;

/// Buys about 9.4 * 10^15 gross atoms: above the per-transaction limit, within the cumulative one.
const LARGE_BUY: u64 = 60_000;

/// Buys about 1.09 * 10^16 gross atoms: above both limits.
const EXCESSIVE_BUY: u64 = 70_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_PROTECTION_TESTS has drop {}

public struct TEST_QUOTE() has drop;

public struct TEST_MIGRATION_WITNESS() has drop;

/// Configured cold policy and one clock standing at the public start time.
public struct ProtectionFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    config: LaunchConfig,
    runtime_config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
fun disabled_protection_records_zero_settings_and_creates_no_sender_record() {
    let mut fixture = start();
    let launch = fixture.new_launch(0, 0, 0);
    let expected = protection_configured_bytes(object::id(&launch), 0, 0, 0, 0, 0);

    assert_eq!(protection_configured(), expected);
    assert_eq!(launch.protection_window_ms(), 0);
    assert_eq!(launch.cumulative_sender_bps().value(), 0);
    assert_eq!(launch.cumulative_atomic_limit(), 0);
    assert_eq!(launch.per_transaction_bps().value(), 0);
    assert_eq!(launch.per_transaction_atomic_limit(), 0);
    assert_eq!(launch.protection_end_ms(), option::none());
    fixture.share(launch);

    fixture.buy(ALICE, EXCESSIVE_BUY, 1);
    fixture.buy(ALICE, EXCESSIVE_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protection_end_ms(), option::some(PUBLIC_START_MS));
        assert_eq!(launch.protected_purchases(ALICE), 0);
        assert!(!launch.has_protected_purchases_for_testing(ALICE));
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun enabled_protection_records_exact_settings_and_atomic_limits() {
    let mut fixture = start();
    let launch = fixture.new_launch(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    let expected = protection_configured_bytes(
        object::id(&launch),
        WINDOW_MS,
        CUMULATIVE_BPS,
        CUMULATIVE_LIMIT,
        PER_TRANSACTION_BPS,
        PER_TRANSACTION_LIMIT,
    );

    assert_eq!(protection_configured(), expected);
    assert_eq!(launch.protection_window_ms(), WINDOW_MS);
    assert_eq!(launch.cumulative_sender_bps().value(), CUMULATIVE_BPS);
    assert_eq!(launch.cumulative_atomic_limit(), CUMULATIVE_LIMIT);
    assert_eq!(launch.per_transaction_bps().value(), PER_TRANSACTION_BPS);
    assert_eq!(launch.per_transaction_atomic_limit(), PER_TRANSACTION_LIMIT);
    assert_eq!(launch.protection_end_ms(), option::none());
    assert_eq!(launch.protected_purchases(ALICE), 0);
    fixture.share(launch);

    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protection_end_ms(), option::some(PROTECTION_END_MS));
        assert_eq!(launch.protected_purchases(ALICE), 0);
        assert!(!launch.has_protected_purchases_for_testing(ALICE));
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun smallest_enabled_protection_limits_one_basis_point_of_supply() {
    let mut fixture = start();
    let launch = fixture.new_launch(1, 1, 0);

    assert_eq!(launch.cumulative_atomic_limit(), 100_000__000_000_000);
    assert_eq!(launch.per_transaction_atomic_limit(), 0);
    destroy(launch);
    fixture.end();
}

#[test]
fun largest_protection_limits_the_whole_supply_and_ends_at_u64_max() {
    let mut fixture = start();
    let launch = fixture.new_launch(
        std::u64::max_value!() - PUBLIC_START_MS,
        10_000,
        10_000,
    );

    assert_eq!(launch.cumulative_atomic_limit(), 1_000_000_000__000_000_000);
    assert_eq!(launch.per_transaction_atomic_limit(), 1_000_000_000__000_000_000);
    fixture.share(launch);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protection_end_ms(), option::some(std::u64::max_value!()));
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidProtection, location = blast_fun::launch)]
fun zero_window_rejects_a_cumulative_rate() {
    let mut fixture = start();
    let launch = fixture.new_launch(0, 1, 0);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidProtection, location = blast_fun::launch)]
fun zero_window_rejects_a_per_transaction_rate() {
    let mut fixture = start();
    let launch = fixture.new_launch(0, 0, 1);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidProtection, location = blast_fun::launch)]
fun enabled_window_rejects_a_zero_cumulative_rate() {
    let mut fixture = start();
    let launch = fixture.new_launch(1, 0, 10_000);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidBps, location = blast_fun::bps)]
/// The parameters are validated rates, so a value above 10,000 cannot reach launch intake.
fun rates_above_ten_thousand_bps_are_unrepresentable() {
    let mut fixture = start();
    let launch = fixture.new_launch(WINDOW_MS, 10_001, 0);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidSellBurnBps, location = blast_fun::launch)]
fun ticket_sell_burn_precedes_invalid_protection() {
    let mut fixture = start();
    let mut ticket = fixture.new_ticket();
    ticket.set_sell_burn_bps_for_testing(5_001);
    let launch = fixture.intake(ticket, plan(), 0, 1, 0);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidProtection, location = blast_fun::launch)]
fun invalid_protection_precedes_the_allocation_policy() {
    let mut fixture = start();
    let ticket = fixture.new_ticket();
    let launch = fixture.intake(ticket, protocol_plan(), 0, 1, 0);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidProtection, location = blast_fun::launch)]
fun invalid_protection_aborts_before_ticket_custody_moves() {
    let mut fixture = start();
    let mut ticket = fixture.new_ticket();
    ticket.burn_meme_for_testing(1);
    let launch = fixture.intake(ticket, plan(), 0, 1, 0);

    destroy(launch);
    fixture.end();
}

#[test, expected_failure(arithmetic_error, location = blast_fun::launch)]
fun share_rejects_a_protection_end_beyond_u64_max() {
    let mut fixture = start();
    let launch = fixture.new_launch(
        std::u64::max_value!() - PUBLIC_START_MS + 1,
        CUMULATIVE_BPS,
        0,
    );

    fixture.share(launch);
    fixture.end();
}

#[test]
fun protected_purchases_accumulate_gross_output_per_sender() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    let first = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();
        let meme = f.take_meme();

        assert!(meme.value() < first);
        assert_eq!(launch.protected_purchases(ALICE), first);
        assert!(launch.has_protected_purchases_for_testing(ALICE));
        assert!(!launch.has_protected_purchases_for_testing(BOB));
        destroy(meme);
        launch.put_back();
    });

    let second = fixture.buy(ALICE, SMALL_BUY, 1);
    let bob = fixture.buy(BOB, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protected_purchases(ALICE), first + second);
        assert_eq!(launch.protected_purchases(BOB), bob);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun sells_and_transfers_never_reduce_protected_purchases() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    let first = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| transfer::public_transfer(f.take_meme(), BOB));
    fixture.sell_all(BOB);
    let second = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.sell_all(ALICE);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protected_purchases(ALICE), first + second);
        assert_eq!(launch.protected_purchases(BOB), 0);
        assert!(!launch.has_protected_purchases_for_testing(BOB));
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECumulativeLimitExceeded, location = blast_fun::launch)]
fun selling_everything_does_not_restore_cumulative_capacity() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);
    fixture.buy(ALICE, LARGE_BUY, 1);
    fixture.sell_all(ALICE);

    fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.end();
}

#[test]
fun zero_per_transaction_rate_admits_a_purchase_the_cumulative_limit_allows() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);
    let bought = fixture.buy(ALICE, LARGE_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert!(bought > PER_TRANSACTION_LIMIT && bought <= CUMULATIVE_LIMIT);
        assert_eq!(launch.per_transaction_atomic_limit(), 0);
        assert_eq!(launch.protected_purchases(ALICE), bought);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECumulativeLimitExceeded, location = blast_fun::launch)]
fun zero_per_transaction_rate_keeps_the_cumulative_limit() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);

    fixture.buy(ALICE, EXCESSIVE_BUY, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPerTransactionLimitExceeded, location = blast_fun::launch)]
fun per_transaction_limit_rejects_one_oversized_purchase() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);

    fixture.buy(ALICE, OVERSIZED_BUY, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPerTransactionLimitExceeded, location = blast_fun::launch)]
fun per_transaction_limit_precedes_the_cumulative_limit() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);

    fixture.buy(ALICE, EXCESSIVE_BUY, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun slippage_precedes_the_per_transaction_limit() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);

    fixture.buy(ALICE, EXCESSIVE_BUY, std::u64::max_value!());
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun slippage_precedes_the_cumulative_limit() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);

    fixture.buy(ALICE, EXCESSIVE_BUY, std::u64::max_value!());
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECumulativeLimitExceeded, location = blast_fun::launch)]
fun cumulative_limit_rejects_the_purchase_that_would_cross_it() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    let bought = fixture.buy(ALICE, SMALL_BUY, 1)
        + fixture.buy(ALICE, SMALL_BUY, 1)
        + fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protected_purchases(ALICE), bought);
        assert!(bought <= CUMULATIVE_LIMIT);
        launch.put_back();
    });

    fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.end();
}

#[test]
fun per_transaction_limit_admits_exactly_its_limit() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    let bought = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert!(CUMULATIVE_LIMIT - bought > PER_TRANSACTION_LIMIT);
        launch.assert_protected_purchase_for_testing(ALICE, PER_TRANSACTION_LIMIT);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun cumulative_limit_admits_exactly_the_remaining_allowance() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);
    let bought = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        launch.assert_protected_purchase_for_testing(ALICE, CUMULATIVE_LIMIT - bought);
        launch.assert_protected_purchase_for_testing(BOB, CUMULATIVE_LIMIT);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPerTransactionLimitExceeded, location = blast_fun::launch)]
fun per_transaction_limit_rejects_one_atom_above_it() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        launch.assert_protected_purchase_for_testing(ALICE, PER_TRANSACTION_LIMIT + 1);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECumulativeLimitExceeded, location = blast_fun::launch)]
fun cumulative_limit_rejects_one_atom_above_the_remaining_allowance() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);
    let bought = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        launch.assert_protected_purchase_for_testing(ALICE, CUMULATIVE_LIMIT - bought + 1);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun pre_share_purchase_never_enters_the_public_counter() {
    let mut fixture = start();
    let mut launch = fixture.new_launch(WINDOW_MS, CUMULATIVE_BPS, 0);
    let pre_share_gross = fixture.pre_share_buy(&mut launch, EXCESSIVE_BUY);

    assert!(pre_share_gross > CUMULATIVE_LIMIT);
    assert!(!launch.has_protected_purchases_for_testing(LAUNCHER));
    fixture.share(launch);

    let bought = fixture.buy(LAUNCHER, LARGE_BUY, 1);
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protected_purchases(LAUNCHER), bought);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun purchase_one_millisecond_before_the_end_is_recorded() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    fixture.set_time(PROTECTION_END_MS - 1);
    let bought = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert_eq!(launch.protected_purchases(ALICE), bought);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECumulativeLimitExceeded, location = blast_fun::launch)]
fun purchase_one_millisecond_before_the_end_is_limited() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, 0);
    fixture.set_time(PROTECTION_END_MS - 1);

    fixture.buy(ALICE, EXCESSIVE_BUY, 1);
    fixture.end();
}

#[test]
fun purchase_at_the_exact_end_is_unlimited_and_unrecorded() {
    let mut fixture = start();
    fixture.open(WINDOW_MS, CUMULATIVE_BPS, PER_TRANSACTION_BPS);
    let protected = fixture.buy(ALICE, SMALL_BUY, 1);
    fixture.set_time(PROTECTION_END_MS);
    let unprotected = fixture.buy(ALICE, EXCESSIVE_BUY, 1);
    fixture.buy(BOB, EXCESSIVE_BUY, 1);
    fixture.next_tx!(ALICE, |f| {
        let launch = f.take_launch();

        assert!(unprotected > CUMULATIVE_LIMIT);
        assert_eq!(launch.protected_purchases(ALICE), protected);
        assert!(!launch.has_protected_purchases_for_testing(BOB));
        launch.put_back();
    });
    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut ProtectionFixture,
    $sender: address,
    $fn: |&mut ProtectionFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): ProtectionFixture {
    let mut scenario = test_scenario::begin(PROTOCOL_ADMIN);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::package_admin_role(),
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
    config.allow_quote<TEST_QUOTE>(&package_version, &admin_witness, 5_000_000);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&package_version, &admin_witness);
    config.set_trade_fees(&package_version, &admin_witness, bps::new(100), bps::new(250));
    config.set_protocol_allocation(
        &package_version,
        &admin_witness,
        1,
        PROTOCOL_ADMIN,
        bps::new(0),
        bps::new(0),
    );
    destroy(admin_cap);
    destroy(authority);
    scenario.next_tx(LAUNCHER);

    ProtectionFixture { scenario, package_version, config, runtime_config, clock }
}

/// A curve holding 80 percent of supply and one liquidity channel holding the rest.
fun plan(): AllocationPlan {
    allocation::new(
        vector[allocation::channel(2, allocation::liquidity_role(), CREATOR)],
        vector[allocation::weight(0, bps::new(8_000)), allocation::weight(2, bps::new(2_000))],
        vector[allocation::weight(2, bps::new(10_000))],
    )
}

/// Names a protocol channel the fixture's zero protocol policy does not admit.
fun protocol_plan(): AllocationPlan {
    allocation::new(
        vector[
            allocation::channel(1, allocation::protocol_role(), PROTOCOL_ADMIN),
            allocation::channel(2, allocation::liquidity_role(), CREATOR),
        ],
        vector[
            allocation::weight(0, bps::new(7_500)),
            allocation::weight(1, bps::new(500)),
            allocation::weight(2, bps::new(2_000)),
        ],
        vector[allocation::weight(2, bps::new(10_000))],
    )
}

fun new_ticket(self: &mut ProtectionFixture): LaunchTicket<LAUNCH_PROTECTION_TESTS> {
    let mut ticket = launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_PROTECTION_TESTS>(),
        9,
        b"GUARD".to_string(),
        b"Protected Launch".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        SELL_BURN_BPS,
        self.scenario.ctx(),
    );
    ticket.bind_migration_witness<_, TEST_QUOTE, _>(&self.config, TEST_MIGRATION_WITNESS());

    ticket
}

/// Runs intake in the next transaction, once the Coin Registry holds the ticket's currency.
fun intake(
    self: &mut ProtectionFixture,
    ticket: LaunchTicket<LAUNCH_PROTECTION_TESTS>,
    plan: AllocationPlan,
    window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
): Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE> {
    self.scenario.next_tx(LAUNCHER);
    let mut currency = self
        .scenario
        .take_from_address<Currency<LAUNCH_PROTECTION_TESTS>>(COIN_REGISTRY);
    let launch = launch::new(
        ticket,
        &mut currency,
        &self.package_version,
        &self.config,
        TARGET,
        plan,
        window_ms,
        bps::new(cumulative_sender_bps),
        bps::new(per_transaction_bps),
        self.scenario.ctx(),
    );
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

fun new_launch(
    self: &mut ProtectionFixture,
    window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
): Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket();

    self.intake(ticket, plan(), window_ms, cumulative_sender_bps, per_transaction_bps)
}

fun new_router(
    self: &mut ProtectionFixture,
    launch: &mut Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE>,
): (
    FeeRouter<LAUNCH_PROTECTION_TESTS, TEST_QUOTE>,
    RouterConfigCap<LAUNCH_PROTECTION_TESTS, TEST_QUOTE>,
) {
    let route = vector[allocation::route(CREATOR, bps::new(10_000))];

    launch.new_fee_router(
        &self.package_version,
        allocation::routes(route, route),
        self.scenario.ctx(),
    )
}

/// Moves the fixture clock to `timestamp_ms` for the following transactions.
fun set_time(self: &mut ProtectionFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

/// Creates and shares one launch at the fixture clock's current time.
fun open(
    self: &mut ProtectionFixture,
    window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
) {
    let launch = self.new_launch(window_ms, cumulative_sender_bps, per_transaction_bps);

    self.share(launch);
}

/// Shares the launch at the fixture clock's current time.
fun share(self: &mut ProtectionFixture, mut launch: Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE>) {
    let (router, config_cap) = self.new_router(&mut launch);

    launch.share(&self.package_version, config_cap, router, &self.clock);
}

fun take_launch(self: &ProtectionFixture): Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE> {
    self.scenario.take_shared()
}

/// Returns a taken launch to shared storage for a later transaction.
fun put_back(launch: Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE>) {
    test_scenario::return_shared(launch);
}

/// Takes the sender's most recent Meme coin.
fun take_meme(self: &ProtectionFixture): Coin<LAUNCH_PROTECTION_TESTS> {
    self.scenario.take_from_sender()
}

/// Runs the owned launch's pre-share purchase and returns its gross Meme output.
fun pre_share_buy(
    self: &mut ProtectionFixture,
    launch: &mut Launch<LAUNCH_PROTECTION_TESTS, TEST_QUOTE>,
    quote_in: u64,
): u64 {
    let quote = coin::mint_for_testing<TEST_QUOTE>(quote_in, self.scenario.ctx());
    let (meme, refund) = launch.pre_share_buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        1,
        self.scenario.ctx(),
    );
    destroy(meme);
    destroy(refund);

    pre_share_gross()
}

/// Buys from the curve as `sender` in a new transaction and returns the gross Meme output.
fun buy(self: &mut ProtectionFixture, sender: address, quote_in: u64, min_meme_out: u64): u64 {
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

    bought_gross()
}

/// Sells `sender`'s most recent Meme coin back to the curve in a new transaction.
fun sell_all(self: &mut ProtectionFixture, sender: address) {
    self.scenario.next_tx(sender);
    let mut launch = self.take_launch();
    let meme = self.take_meme();
    let quote = launch.sell(
        &self.package_version,
        &self.runtime_config,
        meme,
        1,
        self.scenario.ctx(),
    );
    transfer::public_transfer(quote, sender);
    launch.put_back();
}

/// Decodes `meme_out_gross` from this transaction's only `PreShareBought` event.
fun pre_share_gross(): u64 {
    let bought = events::collect_one<events::PreShareBought>(0);
    let mut fields = sui::bcs::new(bcs::to_bytes(&bought));
    fields.peel_address();
    fields.peel_u64();

    fields.peel_u64()
}

/// Decodes `meme_out_gross` from this transaction's only `Bought` event.
fun bought_gross(): u64 {
    let bought = events::collect_one<events::Bought>(0);
    let mut fields = sui::bcs::new(bcs::to_bytes(&bought));
    fields.peel_address();
    fields.peel_u64();

    fields.peel_u64()
}

/// The encoded payload of this transaction's only `ProtectionConfigured` event.
fun protection_configured(): vector<u8> {
    bcs::to_bytes(&events::collect_one<events::ProtectionConfigured>(0))
}

fun protection_configured_bytes(
    launch_id: ID,
    window_ms: u64,
    cumulative_sender_bps: u64,
    cumulative_atomic_limit: u64,
    per_transaction_bps: u64,
    per_transaction_atomic_limit: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&window_ms));
    expected.append(bcs::to_bytes(&cumulative_sender_bps));
    expected.append(bcs::to_bytes(&cumulative_atomic_limit));
    expected.append(bcs::to_bytes(&per_transaction_bps));
    expected.append(bcs::to_bytes(&per_transaction_atomic_limit));

    expected
}

fun end(self: ProtectionFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::AdminCap;

use blast_fun::{
    allocation::{Self, AllocationPlan},
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority,
    domain_fixture,
    events,
    fee_router::{FeeRouter, RouterConfigCap},
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
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun put_back as Launch.put_back;
