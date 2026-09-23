// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// A router collection pays the holder distributor by address; the permissionless intake receives
/// the pushed coins into reward custody without any router, channel, or venue authority.
module blast_fun_distributor::router_intake_tests;

// === Constants ===

const CREATOR: address = @0xC;

const COIN_REGISTRY: address = @0xc;

const ALICE: address = @0xA;

const BOT: address = @0xB;

const OTHER_DESTINATION: address = @0xD;

const VAULT: address = @0xA1;

const POOL: address = @0xA2;

const POSITION: address = @0xA3;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct ROUTER_INTAKE_TESTS has drop {}

public struct QUOTE() has drop;

/// Migration witness the launch ticket binds.
public struct Venue() has drop;

/// Stands in for the venue adapter's private settlement witness.
public struct Settlement() has drop;

/// An enrolled, shared distributor and an active router that pays it 60% of both assets.
public struct IntakeFixture {
    scenario: Scenario,
    version: PackageVersion,
    policy: LpFeePolicy,
    control: Version,
    admin: AdminCap,
    distributor: Distributor<ROUTER_INTAKE_TESTS, QUOTE>,
    publisher: PublisherCap,
    router: FeeRouter<ROUTER_INTAKE_TESTS, QUOTE>,
}

public struct ExpectedIntake has copy, drop {
    distributor: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_total: u64,
    quote_total: u64,
}

// === Tests ===

#[test]
fun router_payout_reaches_holder_claims_only_through_the_intake() {
    let mut f = start();
    f.next_tx!(BOT, |f| {
        f.collect(100, 200);
        f.assert_router_paid_distributor(60, 120);
    });
    f.next_tx!(BOT, |f| {
        assert_eq!(f.pending(), vector[1, 1]);
        assert_eq!(f.balances(), vector[0, 0]);
        f.receive_pending();
        f.assert_intake(60, 120, 60, 120);
    });
    let mut existing = f.publish(0, ALICE, 10, 20);

    f.next_tx!(BOT, |f| {
        f.collect(50, 30);
        f.assert_router_paid_distributor(30, 18);
    });
    f.next_tx!(BOT, |f| {
        assert_eq!(f.pending(), vector[1, 1]);
        f.receive_pending();
        f.assert_intake(30, 18, 80, 118);
    });
    f.next_tx!(BOT, |f| assert_eq!(f.pending(), vector[0, 0]));
    assert_eq!(existing.balances(), vector[10, 20]);

    let mut next = f.publish(1, BOT, 80, 118);
    f.claim(&mut existing, ALICE, 10, 20);
    f.claim(&mut next, BOT, 80, 118);
    f.next_tx!(ALICE, |f| f.assert_paid(ALICE, 10, 20));
    f.next_tx!(BOT, |f| f.assert_paid(BOT, 80, 118));
    f.next_tx!(OTHER_DESTINATION, |f| f.assert_paid(OTHER_DESTINATION, 60, 92));
    assert_eq!(f.balances(), vector[0, 0]);
    destroy(existing);
    destroy(next);
    f.end();
}

#[test]
fun paused_distributor_leaves_router_payouts_waiting_at_its_address() {
    let mut f = start();
    f.pause(true);
    f.next_tx!(BOT, |f| f.collect(100, 200));
    f.next_tx!(BOT, |f| f.collect(50, 30));
    f.next_tx!(OTHER_DESTINATION, |f| {
        f.assert_paid(OTHER_DESTINATION, 60, 92);
        assert_eq!(f.pending(), vector[2, 2]);
        assert_eq!(f.balances(), vector[0, 0]);
    });

    f.pause(false);
    f.next_tx!(BOT, |f| {
        f.receive_pending();
        f.assert_intake(90, 138, 90, 138);
    });
    f.next_tx!(BOT, |f| assert_eq!(f.pending(), vector[0, 0]));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EPaused,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun paused_intake_rejects_pushed_coins() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.collect(100, 200));
    f.pause(true);
    f.next_tx!(BOT, |f| f.receive_pending());
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun retired_code_cannot_receive_pushed_coins_even_if_also_paused() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.collect(100, 200));
    f.pause(true);
    f.retire();
    f.next_tx!(BOT, |f| f.receive_pending());
    f.end();
}

#[test]
fun intake_receives_the_maximum_batch() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.push(60, 40));
    f.next_tx!(BOT, |f| {
        f.receive_pending();
        f.assert_intake(60, 40, 60, 40);
    });
    f.next_tx!(BOT, |f| assert_eq!(f.pending(), vector[0, 0]));
    f.end();
}

#[test]
fun one_sided_intake_reports_zero_for_the_other_asset() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.push(0, 1));
    f.next_tx!(BOT, |f| {
        f.receive_pending();
        f.assert_intake(0, 1, 0, 1);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidReceivingCoinBatch,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun intake_rejects_an_empty_batch() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.receive_pending());
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidReceivingCoinBatch,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun intake_rejects_the_first_batch_above_the_maximum() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.push(60, 41));
    f.next_tx!(BOT, |f| f.receive_pending());
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EPaused,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun pause_precedes_the_batch_bound() {
    let mut f = start();
    f.pause(true);
    f.next_tx!(BOT, |f| f.receive_pending());
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::transfer::EUnableToReceiveObject,
        location = sui::transfer,
    ),
]
fun intake_cannot_take_coins_paid_to_another_destination() {
    let mut f = start();
    f.next_tx!(BOT, |f| f.collect(100, 200));
    f.next_tx!(BOT, |f| f.receive_from(OTHER_DESTINATION));
    f.end();
}

// === Test Helpers ===

macro fun next_tx($f: &mut IntakeFixture, $sender: address, $fn: |&mut IntakeFixture|) {
    let f = $f;
    f.scenario.next_tx($sender);
    $fn(f);
}

fun pause(self: &mut IntakeFixture, paused: bool) { self.control.set_paused(&self.admin, paused); }

fun retire(self: &mut IntakeFixture) { self.control.set_version_for_testing(2); }

/// Splits one exact position collection through the active router's frozen routes.
fun collect(self: &mut IntakeFixture, meme: u64, quote: u64) {
    self
        .router
        .collect(
            &self.version,
            &self.policy,
            Settlement(),
            object::id_from_address(VAULT),
            object::id_from_address(POOL),
            object::id_from_address(POSITION),
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            self.scenario.ctx(),
        );
}

/// Pays the distributor's address unit coins directly, as any sender or allocation channel can.
fun push(self: &mut IntakeFixture, meme_coins: u64, quote_coins: u64) {
    let destination = object::id(&self.distributor).to_address();
    meme_coins.do!(|_| self.pay_unit<ROUTER_INTAKE_TESTS>(destination));
    quote_coins.do!(|_| self.pay_unit<QUOTE>(destination));
}

fun pay_unit<T>(self: &mut IntakeFixture, destination: address) {
    transfer::public_transfer(coin::mint_for_testing<T>(1, self.scenario.ctx()), destination);
}

/// Receives every coin currently waiting at the distributor's address.
fun receive_pending(self: &mut IntakeFixture) {
    let owner = object::id(&self.distributor);
    self
        .distributor
        .receive_coins(
            &self.control,
            receiving_tickets<Coin<ROUTER_INTAKE_TESTS>>(owner),
            receiving_tickets<Coin<QUOTE>>(owner),
        );
}

/// Names coins owned by another address in a call on the distributor.
fun receive_from(self: &mut IntakeFixture, owner: address) {
    self
        .distributor
        .receive_coins(
            &self.control,
            receiving_tickets<Coin<ROUTER_INTAKE_TESTS>>(object::id_from_address(owner)),
            receiving_tickets<Coin<QUOTE>>(object::id_from_address(owner)),
        );
}

fun receiving_tickets<T: key>(owner: ID): vector<Receiving<T>> {
    waiting<T>(owner).map!(|id| test_scenario::receiving_ticket_by_id(id))
}

/// Returns the Meme and Quote coin counts waiting at the distributor's address.
fun pending(self: &IntakeFixture): vector<u64> {
    let owner = object::id(&self.distributor);
    vector[waiting<Coin<ROUTER_INTAKE_TESTS>>(owner).length(), waiting<Coin<QUOTE>>(owner).length()]
}

fun waiting<T: key>(owner: ID): vector<ID> {
    test_scenario::receivable_object_ids_for_owner_id<T>(owner)
}

fun balances(self: &IntakeFixture): vector<u64> {
    let (meme, quote) = self.distributor.balances_for_testing();
    vector[meme, quote]
}

fun round_balances(self: &Round<ROUTER_INTAKE_TESTS, QUOTE>): vector<u64> {
    let (meme, quote) = self.balances_for_testing();
    vector[meme, quote]
}

fun publish(
    self: &mut IntakeFixture,
    number: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): Round<ROUTER_INTAKE_TESTS, QUOTE> {
    let root = merkle::leaf(object::id(&self.distributor), number, 0, beneficiary, meme, quote);
    self
        .distributor
        .publish_round(
            &self.publisher,
            &self.control,
            number,
            number * 10,
            (number + 1) * 10,
            root,
            vector::tabulate!(32, |_| 1u8),
            1,
            meme,
            quote,
            self.scenario.ctx(),
        )
}

fun claim(
    self: &mut IntakeFixture,
    round: &mut Round<ROUTER_INTAKE_TESTS, QUOTE>,
    beneficiary: address,
    meme: u64,
    quote: u64,
) {
    round.claim(&self.control, 0, beneficiary, meme, quote, vector[], self.scenario.ctx());
}

/// The router's collection event pays the distributor's route index exactly these amounts.
fun assert_router_paid_distributor(self: &IntakeFixture, meme: u64, quote: u64) {
    let destination = object::id(&self.distributor).to_address();
    let routes = self.router.routes();
    let meme_index = routes.meme_routes().find_index!(|route| route.destination() == destination);
    let quote_index = routes.quote_routes().find_index!(|route| route.destination() == destination);
    let (_, _, meme_amounts, quote_amounts) = events::collect_one<events::FeesCollected>(0)
        .fees_collected_amounts_for_testing();
    assert_eq!(meme_amounts[meme_index.destroy_some()], meme);
    assert_eq!(quote_amounts[quote_index.destroy_some()], quote);
}

/// The transaction's only intake event matches every field and the distributor's balances.
fun assert_intake(
    self: &IntakeFixture,
    meme_amount: u64,
    quote_amount: u64,
    meme_total: u64,
    quote_total: u64,
) {
    let received = event::events_by_type<distributor::CoinsReceived>();
    assert_eq!(received.length(), 1);
    assert_eq!(
        bcs::to_bytes(&received[0]),
        bcs::to_bytes(
            &ExpectedIntake {
                distributor: object::id(&self.distributor),
                meme_amount,
                quote_amount,
                meme_total,
                quote_total,
            },
        ),
    );
    assert_eq!(self.balances(), vector[meme_total, quote_total]);
}

/// Burns every coin the owner holds and checks both totals.
fun assert_paid(self: &IntakeFixture, owner: address, meme: u64, quote: u64) {
    assert_eq!(self.burn_all<ROUTER_INTAKE_TESTS>(owner), meme);
    assert_eq!(self.burn_all<QUOTE>(owner), quote);
}

fun burn_all<T>(self: &IntakeFixture, owner: address): u64 {
    test_scenario::ids_for_address<Coin<T>>(owner).fold!(0, |total, id| {
        total + self.scenario.take_from_address_by_id<Coin<T>>(owner, id).burn_for_testing()
    })
}

fun start(): IntakeFixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(
        16,
        7 * 24 * 60 * 60 * 1_000,
        scenario.ctx(),
    );
    authority.grant_admin(&root, 0, CREATOR, scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let launchpad_admin = scenario.take_from_sender<LaunchpadAdminCap<BLAST_FUN_DOMAIN>>();
    let witness = authority.sign_in(&launchpad_admin);
    let mut config = scenario.take_shared<LaunchConfig>();
    config.allow_quote<QUOTE>(&version, &witness, 5_000_000);
    config.allow_migration_witness<Venue>(&version, &witness);
    config.set_trade_fees(&version, &witness, bps::new(100), bps::new(100));
    config.set_protocol_allocation(&version, &witness, 1, CREATOR, bps::new(0), bps::new(0));
    let mut ticket = launch_ticket::new(
        test_utils::create_one_time_witness<ROUTER_INTAKE_TESTS>(),
        9,
        b"TEST".to_string(),
        b"Test".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        scenario.ctx(),
    );
    ticket.bind_migration_witness<_, QUOTE, _>(&config, Venue());

    scenario.next_tx(CREATOR);
    let mut currency = scenario.take_from_address<Currency<ROUTER_INTAKE_TESTS>>(COIN_REGISTRY);
    let mut launch = launch::new<_, QUOTE>(
        ticket,
        &mut currency,
        &version,
        &config,
        25_000_000,
        allocation::new(
            vector[allocation::channel(2, allocation::liquidity_role(), CREATOR)],
            vector[allocation::weight(0, bps::new(8_000)), allocation::weight(2, bps::new(2_000))],
            vector[allocation::weight(2, bps::new(10_000))],
        ),
        0,
        bps::new(0),
        bps::new(0),
        scenario.ctx(),
    );
    let (launch_router, launch_router_cap) = launch.new_fee_router(
        &version,
        routes(vector[allocation::route(CREATOR, bps::new(10_000))]),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    launch.share(&version, launch_router_cap, launch_router, &clock);
    test_scenario::return_shared(config);
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    scenario.next_tx(CREATOR);
    let mut launch = scenario.take_shared<Launch<ROUTER_INTAKE_TESTS, QUOTE>>();
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let (curve_fee_cap, metadata_cap, launch_router_cap) = launch.claim_setup_caps(
        &version,
        &runtime,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    let admin = distributor::new_admin_cap_for_testing(scenario.ctx());
    let control = distributor::new_version_for_testing(scenario.ctx());
    let (distributor, publisher) = distributor::new(
        &control,
        curve_fee_cap,
        &mut launch,
        &version,
        scenario.ctx(),
    );
    let destination = object::id(&distributor).to_address();
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let (mut router, config_cap) = fee_router::new_for_testing<ROUTER_INTAKE_TESTS, QUOTE>(
        object::id(&launch),
        routes(
            vector[
                allocation::route(destination, bps::new(6_000)),
                allocation::route(OTHER_DESTINATION, bps::new(4_000)),
            ],
        ),
        scenario.ctx(),
    );
    router.activate_for_testing<_, _, Settlement>(
        &policy,
        object::id_from_address(VAULT),
        object::id_from_address(POOL),
        object::id_from_address(POSITION),
    );
    distributor.share();
    test_scenario::return_shared(launch);
    destroy(config_cap);
    destroy(launch_router_cap);
    destroy(metadata_cap);
    destroy(runtime);
    destroy(witness);
    destroy(launchpad_admin);
    destroy(authority);
    destroy(root);
    clock.destroy_for_testing();

    scenario.next_tx(CREATOR);
    let distributor = scenario.take_shared<Distributor<ROUTER_INTAKE_TESTS, QUOTE>>();
    IntakeFixture {
        scenario,
        version,
        policy,
        control,
        admin,
        distributor,
        publisher,
        router,
    }
}

fun routes(table: vector<Route>): Routes { allocation::routes(table, table) }

fun end(f: IntakeFixture) {
    let IntakeFixture {
        scenario,
        version,
        policy,
        control,
        admin,
        distributor,
        publisher,
        router,
    } = f;
    test_scenario::return_shared(distributor);
    destroy(version);
    destroy(policy);
    destroy(control);
    destroy(admin);
    destroy(publisher);
    destroy(router);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, AdminCap as LaunchpadAdminCap};

use blast_fun::{
    allocation::{Self, Route, Routes},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    creator_authority,
    events,
    fee_router::{Self, FeeRouter},
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self, PackageVersion},
    runtime_config,
};

use blast_fun_distributor::{
    blast_fun_distributor::{
        Self as distributor,
        AdminCap,
        Distributor,
        PublisherCap,
        Round,
        Version,
    },
    merkle,
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{
    balance,
    clock,
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
    transfer::Receiving,
};

use fun round_balances as Round.balances;
