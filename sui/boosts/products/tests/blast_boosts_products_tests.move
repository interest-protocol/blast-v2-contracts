#[test_only]
module blast_boosts_products::blast_boosts_products_tests;

use blast_boosts_products::blast_boosts_products as marker;
use sui::{package::Publisher, test_scenario};

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Tests ===

#[test]
fun package_init_claims_and_keeps_publisher() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();
    assert!(publisher.from_module<marker::BLAST_BOOSTS_PRODUCTS>());
    assert!(publisher.from_package<marker::BLAST_BOOSTS_PRODUCTS>());

    scenario.return_to_sender(publisher);
    scenario.end();
}
