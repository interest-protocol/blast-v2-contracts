// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::fee_router_config_tests;

// === Constants ===

const OWNER: address = @0xA;

const LAUNCH: address = @0x1A;

const DESTINATION_A: address = @0xD1;

const DESTINATION_B: address = @0xD2;

// === Test-Only Types ===

public struct MEME has drop {}

public struct QUOTE has drop {}

public struct TestSettlementWitness() has drop;

public struct Custody has key {
    id: UID,
    config_cap: RouterConfigCap<MEME, QUOTE>,
}

public struct Inbox has key {
    id: UID,
}

public struct ConfigFixture {
    scenario: Scenario,
    version: PackageVersion,
    policy: LpFeePolicy,
    router: FeeRouter<MEME, QUOTE>,
    config_cap: RouterConfigCap<MEME, QUOTE>,
}

public struct ExpectedRoutesChanged has copy, drop {
    router_id: ID,
    old_generation: u64,
    new_generation: u64,
    old_routes: Routes,
    new_routes: Routes,
}

// === Tests ===

#[test]
fun pending_configuration_is_immediate_and_replays_complete_old_and_new_routes() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.configure(single_route(DESTINATION_B));
        assert_eq!(f.router.generation(), 1);
        assert_eq!(bcs::to_bytes(f.router.routes()), bcs::to_bytes(&single_route(DESTINATION_B)));
        assert_eq!(
            bcs::to_bytes(&events::collect_one<events::RoutesChanged>(0)),
            bcs::to_bytes(
                &ExpectedRoutesChanged {
                    router_id: object::id(&f.router),
                    old_generation: 0,
                    new_generation: 1,
                    old_routes: single_route(DESTINATION_A),
                    new_routes: single_route(DESTINATION_B),
                },
            ),
        );
    });
    fixture.end();
}

#[test]
fun external_custody_presents_the_cap_it_wraps_or_receives() {
    let fixture = start().configure_from_wrapping_custody(single_route(DESTINATION_B));
    assert_eq!(fixture.router.generation(), 1);
    let fixture = fixture.configure_from_receiving_custody(single_route(DESTINATION_A));
    assert_eq!(fixture.router.generation(), 2);
    assert_eq!(bcs::to_bytes(fixture.router.routes()), bcs::to_bytes(&single_route(DESTINATION_A)));
    fixture.end();
}

#[test]
fun active_update_pays_settled_fees_under_the_old_routes_and_only_later_fees_under_the_new() {
    let mut fixture = start();
    fixture.next_tx!(|f| f.activate());
    fixture.next_tx!(|f| {
        f.settle_routes(single_route(DESTINATION_B), 10, 20);
        assert_eq!(f.router.generation(), 1);
        assert_eq!(bcs::to_bytes(f.router.routes()), bcs::to_bytes(&single_route(DESTINATION_B)));
        let collected = events::collect_one<events::FeesCollected>(0);
        let (_, _, meme_amounts, quote_amounts) = collected.fees_collected_amounts_for_testing();
        assert_eq!(meme_amounts, vector[10]);
        assert_eq!(quote_amounts, vector[20]);
        f.collect(3, 4);
    });
    fixture.next_tx_as!(DESTINATION_A, |f| f.assert_received(10, 20));
    fixture.next_tx_as!(DESTINATION_B, |f| f.assert_received(3, 4));
    fixture.end();
}

#[test]
fun zero_fee_settlement_still_advances_exactly_once_without_a_collection_event() {
    let mut fixture = start();
    fixture.next_tx!(|f| f.activate());
    fixture.next_tx!(|f| {
        f.settle_routes(single_route(DESTINATION_B), 0, 0);
        assert_eq!(f.router.generation(), 1);
        assert!(events::collect<events::FeesCollected>().is_empty());
        assert_eq!(events::collect<events::RoutesChanged>().length(), 1);
    });
    fixture.end();
}

#[test]
fun collection_needs_no_configuration_cap() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.activate();
        f.collect(5, 6);
    });
    fixture.next_tx_as!(DESTINATION_A, |f| f.assert_received(5, 6));
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteUnchanged, location = blast_fun::fee_router)]
fun pending_identical_proposal_is_rejected() {
    let mut fixture = start();
    fixture.configure(single_route(DESTINATION_A));
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteUnchanged, location = blast_fun::fee_router)]
fun active_identical_proposal_is_rejected_before_settlement() {
    let mut fixture = start();
    fixture.activate();
    fixture.settle_routes(single_route(DESTINATION_A), 1, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouterAlreadyActive, location = blast_fun::fee_router)]
fun active_router_rejects_core_only_configuration() {
    let mut fixture = start();
    fixture.activate();
    fixture.configure(single_route(DESTINATION_B));
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouterNotActive, location = blast_fun::fee_router)]
fun pending_router_rejects_settled_updates() {
    let mut fixture = start();
    fixture.settle_routes(single_route(DESTINATION_B), 0, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESettlementBindingMismatch, location = blast_fun::fee_router)]
fun another_position_cannot_settle_an_update() {
    let mut fixture = start();
    fixture.activate();
    fixture.settle_routes_from(object::id_from_address(@0xBAD), single_route(DESTINATION_B), 0, 0);
    fixture.end();
}

// === Test Helpers ===

macro fun next_tx($fixture: &mut ConfigFixture, $fn: |&mut ConfigFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx(OWNER);
    $fn(fixture);
}

macro fun next_tx_as($fixture: &mut ConfigFixture, $sender: address, $fn: |&mut ConfigFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(OWNER);
    let version = package_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let (router, config_cap) = fee_router::new_for_testing(
        object::id_from_address(LAUNCH),
        single_route(DESTINATION_A),
        scenario.ctx(),
    );
    ConfigFixture { scenario, version, policy, router, config_cap }
}

fun activate(self: &mut ConfigFixture) {
    self.router.activate_for_testing<_, _, TestSettlementWitness>(
        &self.policy,
        object::id_from_address(@0xA1),
        object::id_from_address(@0xA2),
        object::id_from_address(@0xA3),
    );
}

fun collect(self: &mut ConfigFixture, meme: u64, quote: u64) {
    let ctx = self.scenario.ctx();
    self
        .router
        .collect(
            &self.version,
            &self.policy,
            TestSettlementWitness(),
            object::id_from_address(@0xA1),
            object::id_from_address(@0xA2),
            object::id_from_address(@0xA3),
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            ctx,
        );
}

fun configure(self: &mut ConfigFixture, routes: Routes) {
    self.router.configure(&self.version, &self.config_cap, routes);
}

/// Wraps the cap in an owned custody object, then configures by presenting it in place.
fun configure_from_wrapping_custody(self: ConfigFixture, routes: Routes): ConfigFixture {
    let ConfigFixture { mut scenario, version, policy, mut router, config_cap } = self;
    transfer::transfer(Custody { id: object::new(scenario.ctx()), config_cap }, OWNER);

    scenario.next_tx(OWNER);
    let custody = scenario.take_from_sender<Custody>();
    router.configure(&version, &custody.config_cap, routes);
    let Custody { id, config_cap } = custody;
    id.delete();

    ConfigFixture { scenario, version, policy, router, config_cap }
}

/// Pushes the cap to a custody object's address, receives it there, then configures with it.
fun configure_from_receiving_custody(self: ConfigFixture, routes: Routes): ConfigFixture {
    let ConfigFixture { mut scenario, version, policy, mut router, config_cap } = self;
    let inbox = Inbox { id: object::new(scenario.ctx()) };
    let inbox_id = object::id(&inbox);
    transfer::public_transfer(config_cap, inbox_id.to_address());
    transfer::transfer(inbox, OWNER);

    scenario.next_tx(OWNER);
    let mut inbox = scenario.take_from_sender<Inbox>();
    let config_cap = transfer::public_receive(
        &mut inbox.id,
        test_scenario::most_recent_receiving_ticket(&inbox_id),
    );
    router.configure(&version, &config_cap, routes);
    destroy(inbox);

    ConfigFixture { scenario, version, policy, router, config_cap }
}

fun settle_routes(self: &mut ConfigFixture, routes: Routes, meme: u64, quote: u64) {
    self.settle_routes_from(object::id_from_address(@0xA3), routes, meme, quote);
}

fun settle_routes_from(
    self: &mut ConfigFixture,
    position_id: ID,
    routes: Routes,
    meme: u64,
    quote: u64,
) {
    let ctx = self.scenario.ctx();
    self
        .router
        .settle_and_update_routes(
            &self.version,
            &self.policy,
            &self.config_cap,
            TestSettlementWitness(),
            object::id_from_address(@0xA1),
            object::id_from_address(@0xA2),
            position_id,
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            routes,
            ctx,
        );
}

fun assert_received(self: &ConfigFixture, meme: u64, quote: u64) {
    assert_eq!(self.scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), meme);
    assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    assert!(!self.scenario.has_most_recent_for_sender<Coin<MEME>>());
    assert!(!self.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

fun end(self: ConfigFixture) { destroy(self); }

fun single_route(destination: address): Routes {
    let route = vector[allocation::route(destination, bps::new(10_000))];
    allocation::routes(route, route)
}

// === Imports ===

use blast_fun::{
    allocation::{Self, Routes},
    bps,
    events,
    fee_router::{Self, FeeRouter, RouterConfigCap},
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self, PackageVersion},
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{balance, coin::Coin, test_scenario::{Self, Scenario}};
