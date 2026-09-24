// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Write-once venue entries: authority-bearing objects keyed by the venue module that adds them.
module blast_fun_migrators::venue_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

/// A sealed key for an authority-bearing entry.
public struct TestObjectKey() has copy, drop, store;

/// An authority-bearing object a venue module stores as a write-once entry.
public struct TestCap has key, store {
    id: UID,
}

// === Tests ===

#[test]
fun an_object_entry_keeps_its_id_as_a_dynamic_object_field() {
    let (mut scenario, mut config) = start();
    let cap = TestCap { id: object::new(scenario.ctx()) };
    let cap_id = object::id(&cap);

    config.add_object(TestObjectKey(), cap);

    assert_eq!(object::id(config.object<_, TestCap>(TestObjectKey())), cap_id);
    test_scenario::return_shared(config);

    // The entry is a child object under its own ID, readable by that ID in later transactions.
    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<VenueConfig>();
    assert_eq!(object::id(config.object<_, TestCap>(TestObjectKey())), cap_id);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldAlreadyExists, location = sui::dynamic_field)]
fun an_entry_cannot_be_replaced() {
    let (mut scenario, mut config) = start();
    let first = TestCap { id: object::new(scenario.ctx()) };
    let second = TestCap { id: object::new(scenario.ctx()) };

    config.add_object(TestObjectKey(), first);
    config.add_object(TestObjectKey(), second);

    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun an_absent_entry_cannot_be_read() {
    let (scenario, config) = start();

    config.object<_, TestCap>(TestObjectKey());

    test_scenario::return_shared(config);
    scenario.end();
}

// === Test Helpers ===

fun start(): (Scenario, VenueConfig) {
    let mut scenario = test_scenario::begin(PUBLISHER);
    venue_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<VenueConfig>();

    (scenario, config)
}

// === Imports ===

use blast_fun_migrators::venue_config::{Self, VenueConfig};

use std::unit_test::assert_eq;

use sui::{dynamic_field, test_scenario::{Self, Scenario}};
