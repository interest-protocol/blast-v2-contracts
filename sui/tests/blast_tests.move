#[test_only]
module blast_fun::blast_tests;

use blast_fun::{acl, blast};
use std::unit_test::destroy;
use sui::{package::Publisher, test_scenario::{Self, Scenario}};

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    publisher: Publisher,
}

// === Tests ===

#[test]
fun package_init_claims_and_keeps_publisher() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        assert!(f.publisher.from_module<blast::BLAST>());
        assert!(f.publisher.from_package<acl::ProtocolAuthority>());
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx($fixture: &mut Fixture, $sender: address, $fn: |&mut Fixture|) {
    let fixture = $fixture;

    fixture.advance($sender);
    $fn(fixture);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();

    Fixture { scenario, publisher }
}

fun advance(self: &mut Fixture, sender: address) {
    self.scenario.next_tx(sender);
}

fun end(self: Fixture) {
    destroy(self);
}
