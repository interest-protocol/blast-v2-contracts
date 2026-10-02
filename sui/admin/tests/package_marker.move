// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Canonical package marker used by operational-version and custody tests.
module 0xa::package_marker;

// === Test-Only Types ===

public struct PACKAGE_MARKER has drop {}

/// A key type from the marker's package, for provenance-gated feature tests such as Display.
public struct Receipt has key {
    id: UID,
}

// === Test Helpers ===

public fun marker(): PACKAGE_MARKER {
    PACKAGE_MARKER {}
}
