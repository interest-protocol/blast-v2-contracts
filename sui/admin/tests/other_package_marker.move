#[test_only]
/// Second package marker used by custody provenance tests.
module 0xa::other_package_marker;

public struct OTHER_PACKAGE_MARKER has drop {}

public fun marker(): OTHER_PACKAGE_MARKER {
    OTHER_PACKAGE_MARKER {}
}
