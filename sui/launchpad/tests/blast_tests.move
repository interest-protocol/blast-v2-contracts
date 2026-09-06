#[test_only]
module blast_fun::blast_tests;

use blast_fun::blast;
use std::unit_test::destroy;
use sui::{package::Publisher, test_scenario::{Self, Scenario}};

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
fun package_init_claims_and_keeps_publisher() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        assert!(f.publisher.from_module<blast::BLAST>());
        assert!(f.publisher.from_package<blast::BLAST>());
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx(
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
    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();

    PublisherFixture { scenario, publisher }
}

fun end(self: PublisherFixture) {
    destroy(self);
}
