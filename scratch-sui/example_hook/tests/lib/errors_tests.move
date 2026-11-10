// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex_example_hook::errors_tests;

// === Tests ===

#[test]
fun error_registry_is_stable() {
    let codes = vector[
        errors::wrong_version!(),
        errors::fee_too_high!(),
        errors::no_fees_collected!(),
    ];
    assert_eq!(codes.length(), 3);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_fun_dex_example_hook::errors;

use std::unit_test::assert_eq;
