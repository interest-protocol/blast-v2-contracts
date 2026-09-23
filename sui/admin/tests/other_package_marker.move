// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Second package marker used by custody provenance tests.
module 0xa::other_package_marker;

// === Test-Only Types ===

public struct OTHER_PACKAGE_MARKER has drop {}

// === Test Helpers ===

public fun marker(): OTHER_PACKAGE_MARKER {
    OTHER_PACKAGE_MARKER {}
}
