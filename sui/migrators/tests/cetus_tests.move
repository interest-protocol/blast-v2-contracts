// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Local Cetus tier and reservation custody. The Cetus interface is an `abort 0` link stub, so
/// binding, pool creation, migration, and collection are proven on the venue-fork harness.
module blast_fun_migrators::cetus_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const MAX_ADMINS: u64 = 16;

const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct MEME() has drop;

public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

public struct CetusFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: package_version::PackageVersion,
    config: VenueConfig,
}

// === Tests ===

#[test]
fun an_unpinned_tier_reads_the_compiled_default() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let (tick_spacing, fee_rate) = f.config.cetus_effective_tier();

        assert_eq!(tick_spacing, 200);
        assert_eq!(fee_rate, 10_000);
    });

    fixture.end();
}

#[test]
fun a_pin_replaces_the_default_for_later_bindings() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_cetus_tier(&f.package_version, &admin_witness, 220, 20_000);

        let (tick_spacing, fee_rate) = f.config.cetus_effective_tier();
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
    });

    fixture.end();
}

#[test]
fun a_reserved_pair_keeps_its_tick_spacing_after_a_later_pin() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.reserve_cetus_pair_for_testing<MEME, QUOTE>(200);

        f.config.set_cetus_tier(&f.package_version, &admin_witness, 60, 2_500);

        assert_eq!(f.config.cetus_reserved_tick_spacing<MEME, QUOTE>(), 200);
        let (tick_spacing, _) = f.config.cetus_effective_tier();
        assert_eq!(tick_spacing, 60);
    });

    fixture.end();
}

#[test]
fun each_quote_reads_only_its_own_reservation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.reserve_cetus_pair_for_testing<MEME, QUOTE>(200);
        f.config.reserve_cetus_pair_for_testing<MEME, OTHER_QUOTE>(60);

        assert_eq!(f.config.cetus_reserved_tick_spacing<MEME, QUOTE>(), 200);
        assert_eq!(f.config.cetus_reserved_tick_spacing<MEME, OTHER_QUOTE>(), 60);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun an_unreserved_quote_has_no_tick_spacing_to_migrate_at() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.reserve_cetus_pair_for_testing<MEME, QUOTE>(200);

        f.config.cetus_reserved_tick_spacing<MEME, OTHER_QUOTE>();
    });

    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut CetusFixture,
    $sender: address,
    $fn: |&mut CetusFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): CetusFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_for_testing<BLAST_FUN_DOMAIN>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    venue_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let config = scenario.take_shared<VenueConfig>();

    CetusFixture { scenario, authority, admin_cap, package_version, config }
}

fun sign_in(self: &CetusFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: CetusFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::blast_fun_domain::BLAST_FUN_DOMAIN;

use blast_fun_migrators::{cetus, package_version, venue_config::{Self, VenueConfig}};

use std::unit_test::{assert_eq, destroy};

use sui::{dynamic_field, test_scenario::{Self, Scenario}};

use fun cetus::effective_tier_for_testing as VenueConfig.cetus_effective_tier;

use fun cetus::reserve_for_testing as VenueConfig.reserve_cetus_pair_for_testing;

use fun cetus::reserved_tick_spacing_for_testing as VenueConfig.cetus_reserved_tick_spacing;

use fun cetus::set_tier as VenueConfig.set_cetus_tier;
