// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Bluefin launch start and its tier bounds. The venue interface is an `abort 0` link stub, so
/// migration, collection with auto-LP, and settled fee-split updates are proven on the venue-fork
/// harness instead.
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
}

// === Tests ===

#[test]
fun new_records_bluefin_and_the_smallest_tier_for_launch_intake() {
    let mut f = start();
    f.admit_bluefin();

    let launch = f.open_launch(1, 1);

    assert_eq!(launch.migration_witness_for_testing(), type_name::with_original_ids<bluefin::Witness>());
    let (tick_spacing, fee_rate) = launch.pool_tier();
    assert_eq!(tick_spacing, 1);
    assert_eq!(fee_rate, 1);
    destroy(launch);
    f.end();
}

#[test]
fun new_accepts_the_largest_bluefin_tier() {
    let mut f = start();
    f.admit_bluefin();

    let launch = f.open_launch(400, 20_000);

    let (tick_spacing, fee_rate) = launch.pool_tier();
    assert_eq!(tick_spacing, 400);
    assert_eq!(fee_rate, 20_000);
    destroy(launch);
    f.end();
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun new_rejects_a_zero_tick_spacing() {
    start_rejected_tier(0, 10_000)
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun new_rejects_a_tick_spacing_above_bluefin_bound() {
    start_rejected_tier(401, 10_000)
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun new_rejects_a_zero_fee_rate() {
    start_rejected_tier(200, 0)
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun new_rejects_a_fee_rate_above_bluefin_bound() {
    start_rejected_tier(200, 20_001)
}

#[test, expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun new_checks_the_migrators_generation_before_the_tier() {
    let mut f = start();
    f.admit_bluefin();
    f.migrators_version.set_for_testing(2);
    let ticket = f.new_ticket();

    let _initializer = bluefin::new<_, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        0,
        0,
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
    location = blast_fun::launch_config,
)]
fun new_aborts_until_the_config_admits_bluefin() {
    let mut f = start();
    let ticket = f.new_ticket();

    let _initializer = bluefin::new<_, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        200,
        10_000,
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EQuoteNotAllowed,
    location = blast_fun::launch_config,
)]
fun new_admits_only_an_allowed_quote() {
    let mut f = start();
    f.admit_bluefin();
    let ticket = f.new_ticket();

    let _initializer = bluefin::new<_, OTHER_QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        200,
        10_000,
    );

    abort EUnexpectedSuccess
}

// === Test Helpers ===

fun start(): BluefinFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role_for_testing(), ADMIN, scenario.ctx());
    destroy(root);
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let admin = authority.sign_in(&admin_cap);
    config.set_quote<QUOTE>(&version, &admin, 5_000_000);
    config.set_trade_fees(&version, &admin, bps::new(100), bps::new(100));
    config.set_protocol_allocation(&version, &admin, ADMIN, bps::new(0), bps::new(0));

    BluefinFixture {
        scenario,
        version,
        migrators_version,
        authority,
        admin_cap,
        config,
    }
}

/// Starts a Bluefin launch at an out-of-bounds tier; the start must abort.
fun start_rejected_tier(tick_spacing: u32, fee_rate: u64) {
    let mut f = start();
    f.admit_bluefin();
    let ticket = f.new_ticket();

    let _initializer = bluefin::new<_, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        tick_spacing,
        fee_rate,
    );

    abort EUnexpectedSuccess
}

fun admit_bluefin(f: &mut BluefinFixture) {
    let admin = f.authority.sign_in(&f.admin_cap);
    f.config.set_migration_witness_allowed<bluefin::Witness>(&f.version, &admin, true);
}

fun new_ticket(f: &mut BluefinFixture): LaunchTicket<BLUEFIN_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<BLUEFIN_TESTS>(),
        9,
        b"BLUE".to_string(),
        b"Bluefin launch".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        f.scenario.ctx(),
    )
}

/// Starts a Bluefin launch in `QUOTE` at the tier and finalizes it once the Coin Registry holds
/// the currency.
fun open_launch(
    f: &mut BluefinFixture,
    tick_spacing: u32,
    fee_rate: u64,
): Launch<BLUEFIN_TESTS, QUOTE> {
    let ticket = f.new_ticket();
    f.scenario.next_tx(ADMIN);
    let mut currency = f.scenario.take_from_address<Currency<BLUEFIN_TESTS>>(COIN_REGISTRY);
    let mut initializer = bluefin::new<_, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        tick_spacing,
        fee_rate,
    );
    initializer.set_graduation_target(TARGET);
    initializer.set_allocation_plan(
        allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[]),
    );
    initializer.set_lp_fee_split(
        allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[]),
    );
    let launch = initializer.finalize(&mut currency, &f.config, f.scenario.ctx());
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

fun end(f: BluefinFixture) {
    destroy(f);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap};

use blast_fun::{
    allocation,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority,
    launch::Launch,
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    package_version::{Self, PackageVersion},
};

use blast_fun_migrators::{
    bluefin,
    package_version::{Self as migrators_package_version, PackageVersion as MigratorsVersion},
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{coin_registry::Currency, test_scenario::{Self, Scenario}, test_utils};
