// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Boundary and transition tests for sealed operational generations.
module blast_admin::operational_version_tests;

// === Constants ===

const CONTAINER_ID: address = @0xCAFE;

// === Tests ===

#[test]
fun new_value_starts_at_generation_one_and_accepts_generation_one() {
    let version = operational_version::new<package_marker::PACKAGE_MARKER>();

    version.assert_current(1);
    version.assert_next(2);
    assert_eq!(version.generation_for_testing(), 1);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun next_assertion_rejects_a_skipped_generation_before_mutation() {
    let version = operational_version::new<package_marker::PACKAGE_MARKER>();

    version.assert_next(3);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionOverflow, location = blast_admin::operational_version)]
fun next_assertion_rejects_overflow_before_mutation() {
    let mut version = operational_version::new<package_marker::PACKAGE_MARKER>();
    version.set_generation_for_testing(std::u64::max_value!());

    version.assert_next(0);

    destroy(version);
}

#[test]
fun exact_next_generation_advances_once_and_emits_complete_fact() {
    let mut version = operational_version::new<package_marker::PACKAGE_MARKER>();

    version.advance(CONTAINER_ID.to_id(), 2);

    assert_eq!(version.generation_for_testing(), 2);
    let advanced = events::collect_one<
        events::OperationalVersionAdvanced<package_marker::PACKAGE_MARKER>,
    >(0);
    let (container_id, package_id, previous_generation, new_generation) =
        advanced.operational_version_advanced_fields();
    assert_eq!(container_id, CONTAINER_ID.to_id());
    assert_eq!(package_id, type_name::original_id<package_marker::PACKAGE_MARKER>());
    assert_eq!(previous_generation, 1);
    assert_eq!(new_generation, 2);
    assert_eq!(event::events_by_type<
        events::OperationalVersionAdvanced<package_marker::PACKAGE_MARKER>,
    >().length(), 1);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun current_assertion_rejects_stale_bytecode() {
    let version = operational_version::new<package_marker::PACKAGE_MARKER>();

    version.assert_current(0);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun advance_rejects_a_skipped_generation() {
    let mut version = operational_version::new<package_marker::PACKAGE_MARKER>();

    version.advance(CONTAINER_ID.to_id(), 3);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun advance_rejects_repeating_the_current_generation() {
    let mut version = operational_version::new<package_marker::PACKAGE_MARKER>();

    version.advance(CONTAINER_ID.to_id(), 1);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun advance_rejects_rollback() {
    let mut version = operational_version::new<package_marker::PACKAGE_MARKER>();
    version.set_generation_for_testing(3);

    version.advance(CONTAINER_ID.to_id(), 2);

    destroy(version);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionOverflow, location = blast_admin::operational_version)]
fun advance_rejects_overflow_before_mutation() {
    let mut version = operational_version::new<package_marker::PACKAGE_MARKER>();
    version.set_generation_for_testing(std::u64::max_value!());

    version.advance(CONTAINER_ID.to_id(), 0);

    destroy(version);
}

// === Imports ===

use 0xa::package_marker;

use blast_admin::{errors, events, operational_version};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::event;
