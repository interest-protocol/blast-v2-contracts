#[test_only]
/// Supplies a Publisher whose original package address is not Blast's test address.
module 0xf::foreign_publisher;

public struct FOREIGN_PUBLISHER() has drop;

public fun new(ctx: &mut TxContext): Publisher {
    package::test_claim(FOREIGN_PUBLISHER(), ctx)
}

// === Tests ===

#[test]
fun publisher_has_a_foreign_original_package() {
    let mut ctx = tx_context::dummy();
    let publisher = new(&mut ctx);

    assert!(!publisher.from_package<BLAST_FUN>());

    destroy(publisher);
    destroy(ctx);
}

// === Imports ===

use blast_fun::blast_fun::BLAST_FUN;

use std::unit_test::destroy;

use sui::package::{Self, Publisher};
