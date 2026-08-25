#[test_only]
module blast_fun::blast_tests;

use blast_fun::{acl, blast};
use std::unit_test::destroy;
use sui::{package, test_scenario};

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Tests ===

#[test]
fun package_init_claims_and_keeps_publisher() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<package::Publisher>();

    assert!(publisher.from_module<blast::BLAST>());
    assert!(publisher.from_package<acl::ProtocolAuthority>());

    publisher.burn_publisher();
    destroy(scenario);
}
