// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical package provenance witness for the DEX package.
///
/// This marker types the package's own operational generation and upgrade
/// custody. It never names an administration domain: `dex_domain` owns the
/// authority, and this module owns only package identity.
module blast_fun_dex::package_marker;

// === Public Types ===

/// One-time witness used only to claim this package's Publisher.
public struct PACKAGE_MARKER has drop {}

// === Private Initialization ===

fun init(otw: PACKAGE_MARKER, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<PACKAGE_MARKER>(), ctx);
}

#[test_only]
/// Claims the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(PACKAGE_MARKER {}, ctx)
}
