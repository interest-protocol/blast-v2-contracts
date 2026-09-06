#[test_only]
/// Supplies a Publisher whose original package address is outside `blast_admin`.
module 0xf::foreign_package_marker;

use sui::package::{Self, Publisher};

public struct FOREIGN_PACKAGE_MARKER has drop {}

public fun publisher(ctx: &mut TxContext): Publisher {
    package::test_claim(FOREIGN_PACKAGE_MARKER {}, ctx)
}
