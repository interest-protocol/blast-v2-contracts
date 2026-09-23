// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical package provenance witness for the aggregate migrators package.
///
/// This marker types the package's own operational generation and upgrade
/// custody. It never names an administration domain: Migrators reuses the
/// Launchpad domain for membership and owns only its package-local state.
module blast_fun_migrators::blast_fun_migrators;

// === Public Types ===

/// One-time witness used only to claim this package's Publisher.
public struct BLAST_FUN_MIGRATORS has drop {}

// === Private Initialization ===

fun init(otw: BLAST_FUN_MIGRATORS, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_FUN_MIGRATORS>(), ctx);
}

#[test_only]
/// Claims the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST_FUN_MIGRATORS {}, ctx)
}
