// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::blast_fun_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

/// Custodies the bootstrap delivered by production package initialization.
public struct BootstrapFixture {
    scenario: Scenario,
    bootstrap: marker::Bootstrap,
}

// === Tests ===

#[test]
fun package_init_retains_canonical_publisher_in_bootstrap() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        assert!(f.bootstrap.publisher_for_bootstrap_testing().from_module<marker::BLAST_FUN>());
        assert!(f.bootstrap.publisher_for_bootstrap_testing().from_package<marker::BLAST_FUN>());
    });

    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut BootstrapFixture,
    $sender: address,
    $fn: |&mut BootstrapFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): BootstrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let bootstrap = scenario.take_from_sender<marker::Bootstrap>();

    BootstrapFixture { scenario, bootstrap }
}

fun end(self: BootstrapFixture) {
    destroy(self);
}

// === Imports ===

use blast_fun::blast_fun as marker;

use std::unit_test::destroy;

use sui::test_scenario::{Self, Scenario};
