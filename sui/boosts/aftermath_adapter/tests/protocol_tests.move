// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for the adapter's own operational generation.
///
/// The checked arithmetic and the replay event belong to
/// `blast_admin::operational_version`. These tests prove only that this
/// package's container carries the compiled constants it claims.
module blast_boosts_aftermath::protocol_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

// === Test-Only Types ===

/// The adapter generation exactly as production initialization shared it.
public struct InitFixture {
    scenario: Scenario,
}

/// An unshared adapter generation.
public struct Fixture {
    scenario: Scenario,
    protocol: Protocol,
}

// === Tests ===

#[test]
/// Production initialization originally shared adapter generation one.
fun init_shares_the_adapter_generation_at_its_first_generation() {
    let mut fixture = start_init();

    fixture.next_tx!(ROOT, |fixture| {
        let container = fixture.take_protocol();

        assert_eq!(container.version_for_testing(), 1);
        fixture.return_protocol(container);
    });

    fixture.end();
}

#[test]
/// The container advances to exactly the generation this bytecode hands over
/// to, and the shared package emits the only cutover fact.
fun the_generation_advances_to_the_next_compiled_generation() {
    let mut fixture = start();

    assert_eq!(fixture.protocol.version_for_testing(), 1);

    fixture.protocol.advance_for_testing();

    let advanced = blast_admin::blast_admin_events::collect_one<
        blast_admin::blast_admin_events::OperationalVersionAdvanced<BLAST_BOOSTS_AFTERMATH>,
    >(0);
    let (container_id, _, previous_generation, new_generation) =
        advanced.operational_version_advanced_fields();
    assert_eq!(container_id, fixture.protocol.id_for_testing());
    assert_eq!(previous_generation, 1);
    assert_eq!(new_generation, 2);
    assert_eq!(new_generation, fixture.protocol.version_for_testing());

    fixture.end();
}

#[test]
/// The finalizer proves the exact next generation before it commits a receipt.
fun the_finalizer_accepts_the_exact_next_generation_before_committing() {
    let fixture = start();

    fixture.protocol.assert_next_for_testing();

    assert_eq!(fixture.protocol.version_for_testing(), 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun the_finalizer_rejects_a_skipped_generation_before_committing() {
    let mut fixture = start();

    fixture.protocol.set_version_for_testing(5);

    fixture.protocol.assert_next_for_testing();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// Once the container already sits at the compiled cutover target, the
/// finalizer's proof fails: the next generation would be three, not two.
fun the_finalizer_rejects_an_already_advanced_generation_as_next() {
    let mut fixture = start();

    fixture.protocol.set_version_for_testing(2);

    fixture.protocol.assert_next_for_testing();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun the_cutover_rejects_a_skipped_generation() {
    let mut fixture = start();

    fixture.protocol.set_version_for_testing(5);

    fixture.protocol.advance_for_testing();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionOverflow,
    location = blast_admin::operational_version,
)]
fun the_cutover_rejects_a_generation_overflow() {
    let mut fixture = start();

    fixture.protocol.set_version_for_testing(std::u64::max_value!());

    fixture.protocol.advance_for_testing();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_this_bytecode() {
    let mut fixture = start();

    fixture.protocol.set_version_for_testing(2);

    fixture.protocol.assert_current_for_testing();

    fixture.end();
}

// === Test Helpers ===

// --- Initialization Fixture ---

macro fun init_next_tx(
    $self: &mut InitFixture,
    $sender: address,
    $body: |&mut InitFixture|,
) {
    let fixture = $self;

    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(ROOT);
    protocol::init_for_testing(scenario.ctx());

    InitFixture { scenario }
}

fun init_take_protocol(self: &InitFixture): Protocol {
    self.scenario.take_shared<Protocol>()
}

fun init_return_protocol(_self: &InitFixture, container: Protocol) {
    test_scenario::return_shared(container);
}

fun init_end(self: InitFixture) {
    let InitFixture { scenario } = self;

    scenario.end();
}

// --- Generation Fixture ---

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let protocol = protocol::new_for_testing(scenario.ctx());

    Fixture { scenario, protocol }
}

fun end(self: Fixture) {
    let Fixture { scenario, protocol } = self;
    destroy(protocol);
    scenario.end();
}

// === Imports ===

use blast_boosts_aftermath::{blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH, protocol::{Self, Protocol}};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;

use fun init_return_protocol as InitFixture.return_protocol;

use fun init_take_protocol as InitFixture.take_protocol;
