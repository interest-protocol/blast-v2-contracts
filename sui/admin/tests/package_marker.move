// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Canonical package marker used by operational-version and custody tests.
module 0xa::package_marker;

// === Test-Only Types ===

public struct PACKAGE_MARKER has drop {}

// === Test Helpers ===

public fun marker(): PACKAGE_MARKER {
    PACKAGE_MARKER {}
}
