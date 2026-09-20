#[test_only]
/// Tests for the adapter's canonical package marker.
///
/// The marker's initializer claims this package's Publisher and keeps it with
/// the publishing sender; the shared operational generation is created by
/// `protocol::init` and is covered by `protocol_tests`.
module blast_boosts_aftermath::package_marker_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

// === Tests ===

#[test]
/// Production initialization claims exactly one Publisher from this module and
/// transfers it to the publishing sender.
fun init_claims_and_keeps_the_publisher() {
    let mut scenario = test_scenario::begin(ROOT);
    marker::init_for_testing(scenario.ctx());

    scenario.next_tx(ROOT);
    let publisher = scenario.take_from_sender<Publisher>();
    assert!(publisher.from_module<BLAST_BOOSTS_AFTERMATH>());

    scenario.return_to_sender(publisher);
    scenario.end();
}

// === Imports ===

use blast_boosts_aftermath::blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH};

use sui::{package::Publisher, test_scenario};
