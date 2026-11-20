// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for the adapter's canonical package marker.
///
/// The initializer delivers its typed publication proof to the publishing sender.
module blast_boosts_aftermath::package_marker_tests;

// === Tests ===

#[test]
fun init_keeps_the_typed_publication_with_the_publisher() {
    let mut scenario = test_scenario::begin(@0xA11CE);
    marker::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xA11CE);
    let publication = scenario.take_from_sender<Publication<BLAST_BOOSTS_AFTERMATH>>();
    assert!(publication.publisher_for_testing().from_module<BLAST_BOOSTS_AFTERMATH>());
    assert!(publication.valid_pause_bits() == marker::deposits!());
    assert!(publication.package_witness() == std::type_name::with_defining_ids<marker::PackageWitness>());
    scenario.return_to_sender(publication);
    scenario.end();
}

// === Imports ===

use blast_admin::package_version::Publication;
use blast_boosts_aftermath::blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH};
use sui::test_scenario;
