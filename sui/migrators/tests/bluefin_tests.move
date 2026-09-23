// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Bluefin binding and tier pinning. The venue interface is an `abort 0` link stub, so the
/// migrate, collection, and settled-update routes are proven on the venue-fork harness instead.
module blast_fun_migrators::bluefin_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const TARGET: u64 = 25_000_000;

// === Errors ===

#[error]
const EUnexpectedSuccess: vector<u8> = b"The guarded operation unexpectedly returned.";

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct BLUEFIN_TESTS has drop {}

public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

public struct BluefinFixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    config: LaunchConfig,
    venue_config: VenueConfig,
}

// === Tests ===

#[test]
fun bind_records_bluefin_and_its_quote_for_launch_intake() {
    let mut f = start();
    f.admit_bluefin();

    let mut ticket = f.new_ticket();
    ticket.bind_bluefin<_, QUOTE>(&f.config);
    let launch = f.open_launch<QUOTE>(ticket);

    assert_eq!(launch.migration_witness(), type_name::with_original_ids<bluefin::Witness>());

    destroy(launch);
    f.end();
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
    location = blast_fun::launch_config,
)]
fun bind_aborts_until_the_config_admits_bluefin() {
    let mut f = start();

    let mut ticket = f.new_ticket();
    ticket.bind_bluefin<_, QUOTE>(&f.config);

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
    location = blast_fun::launch_config,
)]
fun a_bluefin_binding_admits_only_its_quote_at_intake() {
    let mut f = start();
    f.admit_bluefin();

    let mut ticket = f.new_ticket();
    ticket.bind_bluefin<_, QUOTE>(&f.config);
    let _launch = f.open_launch<OTHER_QUOTE>(ticket);

    abort EUnexpectedSuccess
}

#[test]
fun tier_pin_stores_the_venue_bounds_and_leaves_their_enforcement_to_the_venue() {
    let mut f = start();

    // The smallest and largest pairs Bluefin accepts, then a pair above both of its bounds: only
    // pool creation rejects the last one, so a later valid pin can still migrate the launch.
    vector[vector[1, 1], vector[400, 20_000], vector[401, 20_001]].do!(|tier| {
        let tick_spacing = tier[0] as u32;
        let fee_rate = tier[1];
        f.pin_bluefin_tier(tick_spacing, fee_rate);
        let (pinned_tick_spacing, pinned_fee_rate) = f.venue_config.tier<bluefin::Venue>();
        assert_eq!(pinned_tick_spacing, tick_spacing);
        assert_eq!(pinned_fee_rate, fee_rate);
    });

    f.end();
}

#[test, expected_failure(
    abort_code = venue_config::EInvalidTickSpacing,
    location = blast_fun_migrators::venue_config,
)]
fun tier_pin_rejects_a_zero_tick_spacing() {
    let mut f = start();

    f.pin_bluefin_tier(0, 10_000);

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = venue_config::EInvalidFeeRate,
    location = blast_fun_migrators::venue_config,
)]
fun tier_pin_rejects_a_zero_fee_rate() {
    let mut f = start();

    f.pin_bluefin_tier(200, 0);

    abort EUnexpectedSuccess
}

// === Test Helpers ===

fun start(): BluefinFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role(), ADMIN, scenario.ctx());
    destroy(root);
    launch_config::init_for_testing(scenario.ctx());
    venue_config::init_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let mut config = scenario.take_shared<LaunchConfig>();
    let venue_config = scenario.take_shared<VenueConfig>();
    let admin = authority.sign_in(&admin_cap);
    config.allow_quote<QUOTE>(&version, &admin, 5_000_000);
    config.allow_quote<OTHER_QUOTE>(&version, &admin, 5_000_000);
    config.set_trade_fees(&version, &admin, bps::new(100), bps::new(100));
    config.set_protocol_allocation(&version, &admin, 1, ADMIN, bps::new(0), bps::new(0));

    BluefinFixture {
        scenario,
        version,
        migrators_version,
        authority,
        admin_cap,
        config,
        venue_config,
    }
}

fun admit_bluefin(f: &mut BluefinFixture) {
    let admin = f.authority.sign_in(&f.admin_cap);
    f.config.allow_migration_witness<bluefin::Witness>(&f.version, &admin);
}

fun pin_bluefin_tier(f: &mut BluefinFixture, tick_spacing: u32, fee_rate: u64) {
    let admin_witness = f.authority.sign_in(&f.admin_cap);
    f.venue_config.set_bluefin_tier(&f.migrators_version, &admin_witness, tick_spacing, fee_rate);
}

fun new_ticket(f: &mut BluefinFixture): LaunchTicket<BLUEFIN_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<BLUEFIN_TESTS>(),
        9,
        b"BLUE".to_string(),
        b"Bluefin binding".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        f.scenario.ctx(),
    )
}

/// Opens a launch in `Quote` through the public constructor, as launch intake does.
fun open_launch<Quote>(
    f: &mut BluefinFixture,
    ticket: LaunchTicket<BLUEFIN_TESTS>,
): Launch<BLUEFIN_TESTS, Quote> {
    f.scenario.next_tx(ADMIN);
    let mut currency = f.scenario.take_from_address<Currency<BLUEFIN_TESTS>>(COIN_REGISTRY);
    let launch = launch::new<_, Quote>(
        ticket,
        &mut currency,
        &f.version,
        &f.config,
        TARGET,
        allocation::new(
            vector[allocation::channel(2, allocation::liquidity_role(), CREATOR)],
            vector[allocation::weight(0, bps::new(8_000)), allocation::weight(2, bps::new(2_000))],
            vector[allocation::weight(2, bps::new(10_000))],
        ),
        0,
        bps::new(0),
        bps::new(0),
        f.scenario.ctx(),
    );
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

fun end(f: BluefinFixture) {
    let BluefinFixture {
        scenario,
        version,
        migrators_version,
        authority,
        admin_cap,
        config,
        venue_config,
    } = f;
    destroy(version);
    destroy(migrators_version);
    destroy(authority);
    destroy(admin_cap);
    test_scenario::return_shared(config);
    test_scenario::return_shared(venue_config);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap};

use blast_fun::{
    allocation,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority,
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    package_version::{Self, PackageVersion},
};

use blast_fun_migrators::{
    bluefin,
    package_version::{Self as migrators_package_version, PackageVersion as MigratorsVersion},
    venue_config::{Self, VenueConfig},
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{coin_registry::Currency, test_scenario::{Self, Scenario}, test_utils};

use fun bluefin::bind as LaunchTicket.bind_bluefin;

use fun bluefin::set_tier as VenueConfig.set_bluefin_tier;
