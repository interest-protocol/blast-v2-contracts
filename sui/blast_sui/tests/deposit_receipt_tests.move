// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::deposit_receipt_tests;

// === Tests ===

#[test]
fun receipt_display_v2_has_complete_nonempty_wallet_metadata() {
    let (fields, values) = deposit_receipt::display_metadata_for_testing();

    assert_eq!(fields.length(), 4);
    assert_eq!(values.length(), 4);
    assert_eq!(fields[0], b"name".to_string());
    assert_eq!(fields[1], b"description".to_string());
    assert_eq!(fields[2], b"image_url".to_string());
    assert_eq!(fields[3], b"link".to_string());
    values.do_ref!(|value| assert!(!value.as_bytes().is_empty()));
}

// === Imports ===

use blast_sui::deposit_receipt;

use std::unit_test::assert_eq;
