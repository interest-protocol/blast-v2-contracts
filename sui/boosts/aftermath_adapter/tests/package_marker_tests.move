#[test_only]
/// Tests for the adapter's canonical package marker.
///
/// The marker's initializer claims this package's Publisher and keeps it with
/// the publishing sender; the shared operational generation is created by
/// `protocol::init` and is covered by `protocol_tests`.
module blast_boosts_aftermath::package_marker_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

// === Test-Only Types ===

/// The adapter exactly as its own initializer left it, with the claimed
/// Publisher still owned by the publishing sender.
public struct MarkerFixture {
    scenario: Scenario,
}

// === Tests ===

#[test]
/// Production initialization claims exactly one Publisher from this module and
/// transfers it to the publishing sender.
fun init_claims_and_keeps_the_publisher() {
    let mut fixture = start();

    fixture.next_tx!(ROOT, |fixture| {
        let publisher = fixture.take_publisher();

        assert!(publisher.from_module<BLAST_BOOSTS_AFTERMATH>());

        fixture.return_publisher(publisher);
    });

    fixture.end();
}

// === Test Helpers ===

macro fun marker_next_tx(
    $self: &mut MarkerFixture,
    $sender: address,
    $body: |&mut MarkerFixture|,
) {
    let fixture = $self;

    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun start(): MarkerFixture {
    let mut scenario = test_scenario::begin(ROOT);
    marker::init_for_testing(scenario.ctx());

    MarkerFixture { scenario }
}

fun marker_take_publisher(self: &MarkerFixture): Publisher {
    self.scenario.take_from_sender<Publisher>()
}

fun marker_return_publisher(self: &MarkerFixture, publisher: Publisher) {
    self.scenario.return_to_sender(publisher);
}

fun marker_end(self: MarkerFixture) {
    let MarkerFixture { scenario } = self;

    scenario.end();
}

// === Imports ===

use blast_boosts_aftermath::blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH};

use sui::{package::Publisher, test_scenario::{Self, Scenario}};

use fun marker_end as MarkerFixture.end;

use fun marker_next_tx as MarkerFixture.next_tx;

use fun marker_return_publisher as MarkerFixture.return_publisher;

use fun marker_take_publisher as MarkerFixture.take_publisher;
