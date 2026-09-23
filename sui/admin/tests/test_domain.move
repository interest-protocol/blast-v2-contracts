// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Canonical ACL domain marker used by foundational package tests.
module blast_admin::test_domain;

public struct TEST_DOMAIN has drop {}

public struct NOT_AN_OTW has drop {}

public fun otw(): TEST_DOMAIN {
    TEST_DOMAIN {}
}

public fun invalid_witness(): NOT_AN_OTW {
    NOT_AN_OTW {}
}
