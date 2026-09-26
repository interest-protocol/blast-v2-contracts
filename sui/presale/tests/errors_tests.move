// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::errors_tests;

// === Tests ===

#[test]
fun configuration_error_registry_is_stable() {
    assert_eq!(blast_presale::errors::invalid_fee_bps!(), 0);
    assert_eq!(blast_presale::errors::invalid_destination!(), 1);
    assert_eq!(blast_presale::errors::unchanged!(), 2);
}

#[test]
fun creation_error_registry_is_stable() {
    assert_eq!(blast_presale::errors::invalid_token_quote_pair!(), 3);
    assert_eq!(blast_presale::errors::invalid_tranche_count!(), 4);
    assert_eq!(blast_presale::errors::invalid_tranche!(), 5);
    assert_eq!(blast_presale::errors::invalid_whitelist!(), 6);
    assert_eq!(blast_presale::errors::tranche_already_ended!(), 7);
    assert_eq!(blast_presale::errors::token_deposit_mismatch!(), 8);
    assert_eq!(blast_presale::errors::invalid_claim_time!(), 9);
    assert_eq!(blast_presale::errors::invalid_min_raise!(), 10);
}

#[test]
fun commit_error_registry_is_stable() {
    assert_eq!(blast_presale::errors::unknown_tranche!(), 11);
    assert_eq!(blast_presale::errors::tranche_access_mismatch!(), 12);
    assert_eq!(blast_presale::errors::tranche_not_open!(), 13);
    assert_eq!(blast_presale::errors::zero_commit!(), 14);
    assert_eq!(blast_presale::errors::invalid_whitelist_proof!(), 15);
    assert_eq!(blast_presale::errors::tranche_sold_out!(), 16);
    assert_eq!(blast_presale::errors::wallet_cap_reached!(), 17);
    assert_eq!(blast_presale::errors::zero_purchase!(), 22);
}

#[test]
fun settlement_error_registry_is_stable() {
    assert_eq!(blast_presale::errors::presale_not_ended!(), 18);
    assert_eq!(blast_presale::errors::presale_finalized!(), 19);
    assert_eq!(blast_presale::errors::presale_not_finalized!(), 20);
    assert_eq!(blast_presale::errors::nothing_to_claim!(), 21);
}

#[test]
fun payout_error_registry_is_stable() {
    assert_eq!(blast_presale::errors::invalid_recipient!(), 23);
    assert_eq!(blast_presale::errors::invalid_payout!(), 24);
    assert_eq!(blast_presale::errors::invalid_liquidity!(), 25);
    assert_eq!(blast_presale::errors::adapter_not_allowed!(), 26);
    assert_eq!(blast_presale::errors::no_liquidity!(), 27);
    assert_eq!(blast_presale::errors::invalid_adapter!(), 28);
    assert_eq!(blast_presale::errors::liquidity_not_open!(), 29);
}

// === Imports ===

use std::unit_test::assert_eq;
