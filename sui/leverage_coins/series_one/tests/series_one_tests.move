#[test_only]
/// Tests for the canonical Series1 package-provenance marker.
module blast_leverage_series_one::series_one_tests;

use blast_leverage_series_one::{acl, series_one};
use std::unit_test::destroy;
use sui::{package::Publisher, test_scenario::{Self, Scenario}};

use fun publisher_end as PublisherFixture.end;
use fun publisher_next_tx as PublisherFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

/// Custodies the Publisher delivered by production package initialization.
public struct PublisherFixture {
    scenario: Scenario,
    publisher: Publisher,
}

// === Tests ===

#[test]
fun package_init_claims_and_keeps_the_canonical_publisher() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        assert!(f.publisher.from_module<series_one::SERIES_ONE>());
        assert!(f.publisher.from_package<acl::ProtocolAuthority>());
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun publisher_next_tx(
    $fixture: &mut PublisherFixture,
    $sender: address,
    $fn: |&mut PublisherFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): PublisherFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    series_one::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();

    PublisherFixture { scenario, publisher }
}

fun publisher_end(self: PublisherFixture) {
    destroy(self)
}
