// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// Sealed operational-generation arithmetic for consumer-owned version containers.
module blast_admin::operational_version;

// === Constants ===

const INITIAL_GENERATION: u64 = 1;

// === Public Types ===

/// Storable, package-typed generation value with construction and mutation sealed here.
public struct OperationalVersion<phantom PackageMarker: drop> has store {
    generation: u64,
}

// === Public Functions ===

/// Creates the initial operational generation used by every upgradeable consumer.
public fun new<PackageMarker: drop>(): OperationalVersion<PackageMarker> {
    OperationalVersion<PackageMarker> { generation: INITIAL_GENERATION }
}

/// Rejects bytecode whose private compiled generation differs from canonical state.
public fun assert_current<PackageMarker: drop>(
    self: &OperationalVersion<PackageMarker>,
    compiled_generation: u64,
) {
    assert!(
        self.generation == compiled_generation,
        blast_admin::errors::operational_version_mismatch!(),
    );
}

/// Proves the proposed compiled generation is exactly next before other finalizer effects.
public fun assert_next<PackageMarker: drop>(
    self: &OperationalVersion<PackageMarker>,
    compiled_generation: u64,
) {
    let _ = self.checked_next(compiled_generation);
}

/// Advances only when the consumer's new compiled generation is exactly one greater.
public fun advance<PackageMarker: drop>(
    self: &mut OperationalVersion<PackageMarker>,
    container_id: ID,
    compiled_generation: u64,
) {
    let previous_generation = self.generation;
    let new_generation = self.checked_next(compiled_generation);

    self.generation = new_generation;

    blast_admin_events::operational_version_advanced<PackageMarker>(
        container_id,
        type_name::original_id<PackageMarker>(),
        previous_generation,
        new_generation,
    );
}

// === Private Functions ===

fun checked_next<PackageMarker: drop>(
    self: &OperationalVersion<PackageMarker>,
    compiled_generation: u64,
): u64 {
    let new_generation = self
        .generation
        .checked_add(1)
        .destroy_or!(abort blast_admin::errors::operational_version_overflow!());
    assert!(
        new_generation == compiled_generation,
        blast_admin::errors::operational_version_mismatch!(),
    );
    new_generation
}

// === Test-Only Functions ===

#[test_only]
public fun generation_for_testing<PackageMarker: drop>(
    self: &OperationalVersion<PackageMarker>,
): u64 {
    self.generation
}

#[test_only]
public fun set_generation_for_testing<PackageMarker: drop>(
    self: &mut OperationalVersion<PackageMarker>,
    generation: u64,
) {
    self.generation = generation;
}

// === Imports ===

use blast_admin::blast_admin_events;

use std::type_name;
