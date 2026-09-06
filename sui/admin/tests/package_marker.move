#[test_only]
/// Canonical package marker used by operational-version and custody tests.
module 0xa::package_marker;

public struct PACKAGE_MARKER has drop {}

public fun marker(): PACKAGE_MARKER {
    PACKAGE_MARKER {}
}
