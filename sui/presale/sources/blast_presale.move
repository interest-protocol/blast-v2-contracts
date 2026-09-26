// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical package provenance witness named after the package.
module blast_presale::blast_presale;

// === Public Types ===

/// Canonical one-time witness used only to claim this package's Publisher.
public struct BLAST_PRESALE() has drop;

// === Private Initialization ===

fun init(otw: BLAST_PRESALE, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_PRESALE(), ctx);
}

#[test_only]
/// Claims an additional canonical-module Publisher for package-administration fixture inputs.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST_PRESALE(), ctx)
}
