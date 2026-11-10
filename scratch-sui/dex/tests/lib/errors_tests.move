// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::errors_tests;

// === Tests ===

#[test]
fun error_registry_is_stable() {
    let codes = vector[
        errors::identical_tokens!(),
        errors::invalid_tick_spacing!(),
        errors::invalid_sqrt_price!(),
        errors::invalid_hook_flags!(),
        errors::hook_slot_taken!(),
        errors::invalid_tick_range!(),
        errors::position_not_empty!(),
        errors::pool_in_operation!(),
        errors::wrong_pool!(),
        errors::wrong_position!(),
        errors::zero_amount!(),
        errors::invalid_price_limit!(),
        errors::zero_liquidity!(),
        errors::insufficient_liquidity!(),
        errors::hook_not_bound!(),
        errors::already_approved!(),
        errors::missing_approval!(),
        errors::insufficient_payment!(),
        errors::insufficient_output!(),
        errors::curve_math_unavailable!(),
        errors::primitive_witness!(),
        errors::version_not_increasing!(),
        errors::not_fee_tier!(),
        errors::invalid_max_fee!(),
        errors::invalid_sensitivity!(),
        errors::magnitude_too_large!(),
    ];
    assert_eq!(codes.length(), 26);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_fun_dex::errors;

use std::unit_test::assert_eq;
