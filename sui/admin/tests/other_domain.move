// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Second ACL domain marker used to prove compile-time type separation.
module blast_admin::other_domain;

// === Test-Only Types ===

public struct OTHER_DOMAIN has drop {}
