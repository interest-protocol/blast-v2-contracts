// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Supplies a Publisher whose original package address is not Blast's test address.
module 0xf::presale_foreign_publisher;

// === Test-Only Types ===

public struct PRESALE_FOREIGN_PUBLISHER() has drop;

// === Tests ===

#[test]
fun publisher_has_a_foreign_original_package() {
    let mut ctx = tx_context::dummy();
    let publisher = new(&mut ctx);

    assert!(!publisher.from_package<BLAST_PRESALE>());

    destroy(publisher);
    destroy(ctx);
}

// === Test Helpers ===

public fun new(ctx: &mut TxContext): Publisher {
    package::test_claim(PRESALE_FOREIGN_PUBLISHER(), ctx)
}

// === Imports ===

use blast_presale::blast_presale::BLAST_PRESALE;

use std::unit_test::destroy;

use sui::package::{Self, Publisher};
