// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical package provenance witness for the presale package.
///
/// The marker only types this package's upgrade custody. Administration roles live in
/// `blast_presale_domain`.
module blast_presale::blast_presale_package;

// === Public Types ===

/// One-time witness used only to claim this package's Publisher.
public struct BLAST_PRESALE_PACKAGE has drop {}

// === Private Initialization ===

fun init(otw: BLAST_PRESALE_PACKAGE, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Claims the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST_PRESALE_PACKAGE {}, ctx)
}
