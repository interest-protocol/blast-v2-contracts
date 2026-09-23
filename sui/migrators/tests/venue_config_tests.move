// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::venue_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const MAX_ADMINS: u64 = 16;

const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct TestVenue() has drop;

/// A sealed key for an authority-bearing entry.
public struct TestObjectKey() has copy, drop, store;

/// An authority-bearing object a venue module stores as a write-once entry.
public struct TestCap has key, store {
    id: UID,
}

/// Admin-pinned tier policy through the core ACL sign-in seam.
public struct TierFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: package_version::PackageVersion,
    config: VenueConfig,
}

// === Tests ===

#[test]
fun substrate_pins_reads_and_replaces_one_sealed_entry() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.config.has_tier<TestVenue>(), false);

        f.config.set_tier(TestVenue(), 60, 3_000);
        assert_eq!(f.config.has_tier<TestVenue>(), true);
        let (tick_spacing, fee_rate) = f.config.tier<TestVenue>();
        assert_eq!(tick_spacing, 60);
        assert_eq!(fee_rate, 3_000);

        f.config.set_tier(TestVenue(), 60, 4_000);
        let (tick_spacing, fee_rate) = f.config.tier<TestVenue>();
        assert_eq!(tick_spacing, 60);
        assert_eq!(fee_rate, 4_000);
    });

    fixture.end();
}

#[test]
fun venue_pins_read_back_per_venue() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.config.has_tier<bluefin::Venue>(), false);
        assert_eq!(f.config.has_tier<cetus::Venue>(), false);

        let admin_witness = f.sign_in();
        f.config.set_bluefin_tier(&f.package_version, &admin_witness, 220, 20_000);
        f.config.set_cetus_tier(&f.package_version, &admin_witness, 200, 10_000);

        let (tick_spacing, fee_rate) = f.config.tier<bluefin::Venue>();
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
        let (tick_spacing, fee_rate) = f.config.tier<cetus::Venue>();
        assert_eq!(tick_spacing, 200);
        assert_eq!(fee_rate, 10_000);
    });

    fixture.end();
}

#[test]
fun venue_pins_stay_sealed_per_witness_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_bluefin_tier(&f.package_version, &admin_witness, 220, 20_000);

        // Only the Bluefin entry changed; every other venue stays unpinned.
        assert_eq!(f.config.has_tier<cetus::Venue>(), false);
        assert_eq!(f.config.has_tier<TestVenue>(), false);
    });

    fixture.end();
}

#[test]
fun an_object_entry_keeps_its_id_as_a_dynamic_object_field() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let cap = f.new_test_cap();
        let cap_id = object::id(&cap);
        assert_eq!(f.config.has_object(TestObjectKey()), false);

        f.config.add_object(TestObjectKey(), cap);

        assert_eq!(f.config.has_object(TestObjectKey()), true);
        assert_eq!(object::id(f.config.object<_, TestCap>(TestObjectKey())), cap_id);
        // The object is a child object under the key, never a plain value.
        assert_eq!(f.config.has_policy(TestObjectKey()), false);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EInvalidTickSpacing,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_zero_tick_spacing() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.set_tier(TestVenue(), 0, 3_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EInvalidFeeRate,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_zero_fee_rate() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.set_tier(TestVenue(), 60, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EUnchangedTier,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_unchanged_tier() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.set_tier(TestVenue(), 100, 10_000);
        f.config.set_tier(TestVenue(), 100, 10_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unpinned_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let (_, _) = f.config.tier<TestVenue>();
    });

    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut TierFixture,
    $sender: address,
    $fn: |&mut TierFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): TierFixture {
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

    TierFixture { scenario, authority, admin_cap, package_version, config }
}

fun new_test_cap(self: &mut TierFixture): TestCap {
    TestCap { id: object::new(self.scenario.ctx()) }
}

fun sign_in(self: &TierFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: TierFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::blast_fun_domain::BLAST_FUN_DOMAIN;

use blast_fun_migrators::{bluefin, cetus, package_version, venue_config::{Self, VenueConfig}};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};

use fun bluefin::set_tier as VenueConfig.set_bluefin_tier;

use fun cetus::set_tier as VenueConfig.set_cetus_tier;
