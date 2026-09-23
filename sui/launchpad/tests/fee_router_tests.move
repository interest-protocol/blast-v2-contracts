// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::fee_router_tests;

// === Constants ===

const ADMIN: address = @0xAD;

const LAUNCH: address = @0x1A;

const PROTOCOL: address = @0xB1A57;

const DESTINATION_A: address = @0xA;

const DESTINATION_B: address = @0xB;

// === Test-Only Types ===

public struct MEME has drop {}

public struct QUOTE has drop {}

public struct TestSettlementWitness() has drop;

public struct RouterFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    root: SuperAdminCap<BLAST_FUN_DOMAIN>,
    admin: AdminCap<BLAST_FUN_DOMAIN>,
    version: PackageVersion,
    policy: LpFeePolicy,
    router: FeeRouter<MEME, QUOTE>,
    config_cap: RouterConfigCap<MEME, QUOTE>,
}

public struct ExpectedActivation has copy, drop {
    router_id: ID,
    launch_id: ID,
    partner: bool,
    meme_bps: u64,
    quote_bps: u64,
    settlement_witness: TypeName,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    generation: u64,
    routes: Routes,
}

public struct ExpectedCollection has copy, drop {
    router_id: ID,
    launch_id: ID,
    generation: u64,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    meme_amounts: vector<u64>,
    quote_amounts: vector<u64>,
}

// === Tests ===

#[test]
fun pending_activation_freezes_the_default_snapshot_and_emits_the_complete_binding() {
    let mut fixture = start(independent_routes());
    fixture.next_tx!(|f| {
        assert!(!f.router.is_active());
        assert!(f.router.policy().is_none());
        assert!(f.router.settlement_binding().is_none());
        assert_eq!(f.router.launch_id(), object::id_from_address(LAUNCH));
        assert_eq!(f.router.generation(), 0);
        assert_eq!(bcs::to_bytes(f.router.routes()), bcs::to_bytes(&independent_routes()));
        f.set_defaults(1_000, 2_500);
        f.activate();
        let snapshot = f.router.policy().destroy_some();
        assert!(!snapshot.is_partner());
        assert_eq!(snapshot.meme_share().value(), 1_000);
        assert_eq!(snapshot.quote_share().value(), 2_500);
        assert_eq!(
            bcs::to_bytes(&events::collect_one<events::RouterActivated>(0)),
            bcs::to_bytes(
                &ExpectedActivation {
                    router_id: object::id(&f.router),
                    launch_id: object::id_from_address(LAUNCH),
                    partner: false,
                    meme_bps: 1_000,
                    quote_bps: 2_500,
                    settlement_witness: type_name::with_original_ids<TestSettlementWitness>(),
                    vault_id: object::id_from_address(@0xA1),
                    pool_id: object::id_from_address(@0xA2),
                    position_id: object::id_from_address(@0xA3),
                    generation: 0,
                    routes: independent_routes(),
                },
            ),
        );
    });
    fixture.end();
}

#[test]
fun partner_overrides_both_assets_and_later_policy_changes_cannot_reprice_collections() {
    let mut fixture = start(independent_routes());
    fixture.next_tx!(|f| {
        f.set_defaults(1, 2);
        let admin = f.authority.sign_in(&f.admin);
        f.policy.set_partner_shares<MEME>(&f.version, &admin, bps::new(1_000), bps::new(2_500));
        f.activate();
        assert!(f.router.policy().destroy_some().is_partner());
    });
    fixture.next_tx!(|f| {
        let admin = f.authority.sign_in(&f.admin);
        f.policy.clear_partner_shares<MEME>(&f.version, &admin);
        f.set_defaults(10_000, 10_000);
        f.collect(11, 7);
        assert!(f.router.policy().destroy_some().is_partner());
        f.assert_collection(11, 7, 2, 2, vector[5, 4], vector[1, 4]);
    });
    fixture.next_tx_as!(PROTOCOL, |f| f.assert_received(2, 2));
    fixture.next_tx_as!(DESTINATION_A, |f| f.assert_received(5, 1));
    fixture.next_tx_as!(DESTINATION_B, |f| f.assert_received(4, 4));
    fixture.end();
}

#[test]
fun protocol_destination_is_read_live_at_each_collection() {
    let mut fixture = start(independent_routes());
    fixture.next_tx!(|f| {
        f.set_defaults(10_000, 10_000);
        f.activate();
        f.collect(3, 5);
        let admin = f.authority.sign_in(&f.admin);
        f.policy.set_protocol_destination(&f.version, &admin, @0xCAFE);
        f.collect(7, 11);
        let collections = events::collect<events::FeesCollected>();
        assert_eq!(collections.length(), 2);
        assert_eq!(collections[0].protocol_destination_for_testing(), PROTOCOL);
        assert_eq!(collections[1].protocol_destination_for_testing(), @0xCAFE);
    });
    fixture.next_tx_as!(PROTOCOL, |f| f.assert_received(3, 5));
    fixture.next_tx_as!(@0xCAFE, |f| f.assert_received(7, 11));
    fixture.end();
}

#[test]
fun zero_settlement_is_eventless_and_one_sided_collections_pay_only_nonzero_routes() {
    let mut fixture = start(disjoint_routes());
    fixture.next_tx!(|f| f.activate());
    fixture.next_tx!(|f| {
        f.collect(0, 0);
        assert_eq!(event::num_events(), 0);
        f.collect(0, 9);
        f.assert_collection(0, 9, 0, 0, vector[0], vector[9]);
    });
    fixture.next_tx_as!(DESTINATION_B, |f| f.assert_received(0, 9));
    fixture.next_tx_as!(DESTINATION_A, |f| f.assert_received(0, 0));
    fixture.end();
}

#[test]
fun full_protocol_share_pays_only_the_protocol_destination() {
    let mut fixture = start(independent_routes());
    fixture.next_tx!(|f| {
        f.set_defaults(10_000, 10_000);
        f.activate();
        f.collect(17, 19);
        f.assert_collection(17, 19, 17, 19, vector[0, 0], vector[0, 0]);
    });
    fixture.next_tx_as!(PROTOCOL, |f| f.assert_received(17, 19));
    fixture.next_tx_as!(DESTINATION_A, |f| f.assert_received(0, 0));
    fixture.end();
}

#[test]
fun dense_small_totals_conserve_and_match_independent_net_project_oracle() {
    dense_totals(1_000);
}

#[test]
fun dense_small_totals_zero_protocol() { dense_totals(0); }

#[test]
fun dense_small_totals_minimum_protocol() { dense_totals(1); }

#[test]
fun dense_small_totals_maximum_partial_protocol() { dense_totals(9_999); }

#[test]
fun dense_small_totals_full_protocol() { dense_totals(10_000); }

#[test]
fun u64_max_settlement_uses_wide_products_and_exact_conservation() {
    let mut fixture = start(independent_routes());
    fixture.next_tx!(|f| {
        f.set_defaults(1_000, 9_999);
        f.activate();
        f.collect(18_446_744_073_709_551_615, 18_446_744_073_709_551_615);
        let (protocol_meme, protocol_quote, meme_amounts, quote_amounts) =
            events::collect_one<events::FeesCollected>(0).fees_collected_amounts_for_testing();
        assert_eq!(protocol_meme, 1_844_674_407_370_955_162);
        assert_eq!(protocol_quote, 18_444_899_399_302_180_660);
        assert_eq!(protocol_meme + meme_amounts[0] + meme_amounts[1], 18_446_744_073_709_551_615);
        assert_eq!(protocol_quote + quote_amounts[0] + quote_amounts[1], 18_446_744_073_709_551_615);
    });
    fixture.end();
}

#[test]
fun sixteen_destinations_across_both_tables_are_canonical_and_all_paid() {
    let mut meme = vector[];
    let mut quote = vector[];
    16u64.do!(|i| {
        let destination = sui::address::from_u256(16 - (i as u256));
        if (i < 8) meme.push_back(allocation::route(destination, bps::new(1_250)))
        else quote.push_back(allocation::route(destination, bps::new(1_250)));
    });
    let mut fixture = start(allocation::routes(meme, quote));
    fixture.next_tx!(|f| {
        f.activate();
        f.collect(17, 9);
        let (_, _, meme_amounts, quote_amounts) =
            events::collect_one<events::FeesCollected>(0).fees_collected_amounts_for_testing();
        // Sorted by destination, the eight Meme routes pay 9..16 and the Quote routes 1..8.
        assert_eq!(meme_amounts, vector[3, 2, 2, 2, 2, 2, 2, 2]);
        assert_eq!(quote_amounts, vector[2, 1, 1, 1, 1, 1, 1, 1]);
        let meme_routes = f.router.routes().meme_routes();
        assert_eq!(meme_routes[0].destination(), sui::address::from_u256(9));
        assert_eq!(meme_routes[7].destination(), sui::address::from_u256(16));
    });
    fixture.next_tx_as!(sui::address::from_u256(9), |f| f.assert_received(3, 0));
    fixture.next_tx_as!(sui::address::from_u256(1), |f| f.assert_received(0, 2));
    fixture.end();
}

#[test]
fun route_tables_are_canonical_under_permutation() {
    let left = allocation::routes(
        vector[route(DESTINATION_B, 5_000), route(DESTINATION_A, 5_000)],
        vector[route(DESTINATION_B, 10_000)],
    );
    let right = allocation::routes(
        vector[route(DESTINATION_A, 5_000), route(DESTINATION_B, 5_000)],
        vector[route(DESTINATION_B, 10_000)],
    );
    assert_eq!(bcs::to_bytes(&left), bcs::to_bytes(&right));
    assert_eq!(left.meme_routes()[0].destination(), DESTINATION_A);
    assert_eq!(left.meme_routes()[0].route_bps(), 5_000);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteSumInvalid, location = blast_fun::allocation)]
fun empty_tables_fail_sum() {
    allocation::routes(vector[], vector[]);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteSumInvalid, location = blast_fun::allocation)]
fun incomplete_table_fails_sum() {
    allocation::routes(vector[route(DESTINATION_A, 9_999)], vector[route(DESTINATION_A, 10_000)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteSumInvalid, location = blast_fun::allocation)]
fun zero_weight_rejected_at_public_route_boundary() { route(DESTINATION_A, 0); }

#[test, expected_failure(abort_code = blast_fun::errors::ERouteInvalidDestination, location = blast_fun::allocation)]
fun zero_destination_rejected() { route(@0x0, 10_000); }

#[test, expected_failure(abort_code = blast_fun::errors::ERouteDuplicateDestination, location = blast_fun::allocation)]
fun duplicate_destination_in_one_table_rejected() {
    allocation::routes(
        vector[route(DESTINATION_A, 5_000), route(DESTINATION_A, 5_000)],
        vector[route(DESTINATION_A, 10_000)],
    );
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteDuplicateDestination, location = blast_fun::allocation)]
fun duplicate_at_one_over_precedes_capacity() {
    let mut meme = vector[];
    16u64.do!(|i| meme.push_back(route(sui::address::from_u256((i as u256) + 1), 625)));
    meme.push_back(route(sui::address::from_u256(1), 1));
    allocation::routes(meme, vector[route(DESTINATION_A, 10_000)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteCapacityReached, location = blast_fun::allocation)]
fun seventeen_distinct_destinations_rejected_before_bad_sum() {
    let mut meme = vector[];
    16u64.do!(|i| meme.push_back(route(sui::address::from_u256((i as u256) + 1), 625)));
    allocation::routes(meme, vector[route(@0x100, 10_000)]);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouteCapacityReached, location = blast_fun::allocation)]
fun gross_overlength_rejected_before_sort_or_duplicates() {
    let mut meme = vector[];
    18u64.do!(|_| meme.push_back(route(DESTINATION_A, 1)));
    allocation::routes(meme, vector[]);
}

#[test, expected_failure(abort_code = blast_fun::errors::ERouterNotActive, location = blast_fun::fee_router)]
fun pending_zero_collection_rejected_before_binding() {
    let mut fixture = start(independent_routes());
    fixture.collect(0, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESettlementBindingMismatch, location = blast_fun::fee_router)]
fun another_position_cannot_collect() {
    let mut fixture = start(independent_routes());
    fixture.activate();
    fixture.collect_from(object::id_from_address(@0xBAD), 1, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESettlementBindingMismatch, location = blast_fun::fee_router)]
fun another_adapter_witness_cannot_collect() {
    let mut fixture = start(independent_routes());
    fixture.activate();
    fixture.collect_as_other_adapter();
    fixture.end();
}

#[
    test,
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_version_precedes_pending_and_binding() {
    let mut fixture = start(independent_routes());
    fixture.version.set_for_testing(2);
    fixture.collect(0, 0);
    fixture.end();
}

// === Test Helpers ===

macro fun next_tx($fixture: &mut RouterFixture, $fn: |&mut RouterFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx(ADMIN);
    $fn(fixture);
}

macro fun next_tx_as($fixture: &mut RouterFixture, $sender: address, $fn: |&mut RouterFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(routes: Routes): RouterFixture {
    let mut scenario = test_scenario::begin(PROTOCOL);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&root, 0, ADMIN, scenario.ctx());
    // The publisher of the policy singleton is the initial protocol destination.
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let (router, config_cap) = fee_router::new_for_testing(
        object::id_from_address(LAUNCH),
        routes,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);
    let admin = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    RouterFixture { scenario, authority, root, admin, version, policy, router, config_cap }
}

fun dense_totals(share: u64) {
    let mut fixture = start(independent_routes());
    fixture.next_tx!(|f| {
        if (share != 0) f.set_defaults(share, share);
        f.activate();
    });
    33u64.do!(|total| {
        fixture.next_tx!(|f| {
            if (total == 0) return;
            f.collect(total, total);
            let protocol = (((total as u128) * (share as u128) + 9_999) / 10_000) as u64;
            let project = total - protocol;
            let (protocol_meme, protocol_quote, meme_amounts, quote_amounts) =
                events::collect_one<events::FeesCollected>(0).fees_collected_amounts_for_testing();
            assert_eq!(protocol_meme, protocol);
            assert_eq!(protocol_quote, protocol);
            assert_eq!(meme_amounts[0], (project + 1) / 2);
            assert_eq!(meme_amounts[1], project / 2);
            // Quote table is 25/75: ties at residue .5 go to the lower destination.
            assert_eq!(quote_amounts[0], (project + 2) / 4);
            assert_eq!(quote_amounts[1], project - quote_amounts[0]);
        });
    });
    fixture.end();
}

fun set_defaults(self: &mut RouterFixture, meme: u64, quote: u64) {
    let admin = self.authority.sign_in(&self.admin);
    self.policy.set_default_shares(&self.version, &admin, bps::new(meme), bps::new(quote));
}

fun activate(self: &mut RouterFixture) {
    self.router.activate_for_testing<_, _, TestSettlementWitness>(
        &self.policy,
        object::id_from_address(@0xA1),
        object::id_from_address(@0xA2),
        object::id_from_address(@0xA3),
    );
}

fun collect(self: &mut RouterFixture, meme: u64, quote: u64) {
    self.collect_from(object::id_from_address(@0xA3), meme, quote);
}

fun collect_from(self: &mut RouterFixture, position_id: ID, meme: u64, quote: u64) {
    let ctx = self.scenario.ctx();
    self
        .router
        .collect(
            &self.version,
            &self.policy,
            TestSettlementWitness(),
            object::id_from_address(@0xA1),
            object::id_from_address(@0xA2),
            position_id,
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            ctx,
        );
}

fun collect_as_other_adapter(self: &mut RouterFixture) {
    let ctx = self.scenario.ctx();
    self
        .router
        .collect(
            &self.version,
            &self.policy,
            0u8,
            object::id_from_address(@0xA1),
            object::id_from_address(@0xA2),
            object::id_from_address(@0xA3),
            balance::create_for_testing(1),
            balance::create_for_testing(1),
            ctx,
        );
}

/// Asserts the sender received exactly one coin per nonzero asset since the last check.
fun assert_received(self: &RouterFixture, meme: u64, quote: u64) {
    if (meme > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), meme);
    };
    if (quote > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    };
    assert!(!self.scenario.has_most_recent_for_sender<Coin<MEME>>());
    assert!(!self.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

fun assert_collection(
    self: &RouterFixture,
    gross_meme: u64,
    gross_quote: u64,
    protocol_meme: u64,
    protocol_quote: u64,
    meme_amounts: vector<u64>,
    quote_amounts: vector<u64>,
) {
    assert_eq!(
        bcs::to_bytes(&events::collect_one<events::FeesCollected>(0)),
        bcs::to_bytes(
            &ExpectedCollection {
                router_id: object::id(&self.router),
                launch_id: object::id_from_address(LAUNCH),
                generation: 0,
                gross_meme,
                gross_quote,
                protocol_destination: self.policy.protocol_destination(),
                protocol_meme,
                protocol_quote,
                meme_amounts,
                quote_amounts,
            },
        ),
    );
}

fun end(self: RouterFixture) { destroy(self); }

fun route(destination: address, bps: u64): Route { allocation::route(destination, bps::new(bps)) }

/// Meme splits evenly; Quote pays A one quarter and B three quarters.
fun independent_routes(): Routes {
    allocation::routes(
        vector[route(DESTINATION_B, 5_000), route(DESTINATION_A, 5_000)],
        vector[route(DESTINATION_B, 7_500), route(DESTINATION_A, 2_500)],
    )
}

/// All Meme to A, all Quote to B.
fun disjoint_routes(): Routes {
    allocation::routes(vector[route(DESTINATION_A, 10_000)], vector[route(DESTINATION_B, 10_000)])
}

// === Imports ===

use blast_admin::acl::{Authority, SuperAdminCap, AdminCap};

use blast_fun::{
    allocation::{Self, Route, Routes},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    domain_fixture,
    events,
    fee_router::{Self, FeeRouter, RouterConfigCap},
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self, PackageVersion},
};

use std::{bcs, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{balance, coin::Coin, event, test_scenario::{Self, Scenario}};
