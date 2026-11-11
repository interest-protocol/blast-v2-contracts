// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::blast_sui_package_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

/// Custodies the publication delivered by production package initialization.
public struct PublicationFixture {
    scenario: Scenario,
    publication: Publication<BLAST_SUI_PACKAGE>,
}

// === Tests ===

#[test]
fun package_init_retains_canonical_publisher_in_publication() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        assert!(f.publication.publisher_for_testing().from_module<BLAST_SUI_PACKAGE>());
        assert!(f.publication.publisher_for_testing().from_package<BLAST_SUI_PACKAGE>());
    });

    fixture.end();
}

#[test]
/// Publication shares no version; wrapping it shares the package version with every deposit
/// bit paused and the generic package administration.
fun wrapping_the_publication_shares_a_fully_paused_version() {
    let fixture = start();
    assert!(!fixture.has_shared_version());

    let (paused, valid_pause_bits, version) = fixture.wrap();

    assert_eq!(paused, constants::valid_pause_bits!());
    assert_eq!(valid_pause_bits, constants::valid_pause_bits!());
    assert_eq!(version, constants::version!());
}

#[test]
/// The three deposit paths each own one distinct bit, and the mask is exactly their union.
fun deposit_pause_bits_are_distinct_and_the_mask_is_their_union() {
    assert_eq!(constants::fun_mint_pause_bit!(), 1);
    assert_eq!(constants::blast_request_pause_bit!(), 2);
    assert_eq!(constants::blast_claim_pause_bit!(), 4);
    assert_eq!(constants::valid_pause_bits!(), 7);
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut PublicationFixture,
    $sender: address,
    $fn: |&mut PublicationFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): PublicationFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast_sui_package::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publication = scenario.take_from_sender<Publication<BLAST_SUI_PACKAGE>>();

    PublicationFixture { scenario, publication }
}

fun has_shared_version(_: &PublicationFixture): bool {
    test_scenario::has_most_recent_shared<PackageVersion<BLAST_SUI_PACKAGE>>()
}

/// Wraps the publication with a test upgrade cap and returns the shared version's paused bits,
/// defined bits, and version; the scenario ends here.
fun wrap(self: PublicationFixture): (u8, u8, u64) {
    let PublicationFixture { mut scenario, publication } = self;
    let upgrade_cap = sui::package::test_publish(@blast_sui.to_id(), scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, scenario.ctx());

    scenario.next_tx(PUBLISHER);
    assert!(test_scenario::has_most_recent_shared<PackageAdmin<BLAST_SUI_PACKAGE>>());
    let package_version = scenario.take_shared<PackageVersion<BLAST_SUI_PACKAGE>>();
    let (paused, valid_pause_bits, version) = (
        package_version.paused_for_testing(),
        package_version.valid_pause_bits_for_testing(),
        package_version.version_for_testing(),
    );
    test_scenario::return_shared(package_version);
    scenario.end();

    (paused, valid_pause_bits, version)
}

fun end(self: PublicationFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::{package_admin::{Self, PackageAdmin}, package_version::{PackageVersion, Publication}};

use blast_sui::{blast_sui_package::{Self, BLAST_SUI_PACKAGE}, constants};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};
