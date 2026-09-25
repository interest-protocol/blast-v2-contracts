// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::errors_tests;

// === Tests ===

#[test]
fun configuration_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_bps!(), 0);
    assert_eq!(blast_fun::errors::invalid_trade_fee_bps!(), 1);
    assert_eq!(blast_fun::errors::decimals_not_allowed!(), 2);
    assert_eq!(blast_fun::errors::migration_witness_not_allowed!(), 3);
    assert_eq!(blast_fun::errors::invalid_migration_witness_type!(), 4);
    assert_eq!(blast_fun::errors::unchanged!(), 23);
}

#[test]
fun allocation_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_protocol_allocation!(), 5);
    assert_eq!(blast_fun::errors::invalid_destination!(), 6);
    assert_eq!(blast_fun::errors::invalid_shares!(), 7);
    assert_eq!(blast_fun::errors::recipient_capacity_reached!(), 8);
    assert_eq!(blast_fun::errors::duplicate_destination!(), 24);
}

#[test]
fun launch_intake_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_sell_burn_bps!(), 9);
    assert_eq!(blast_fun::errors::invalid_initial_meme_supply!(), 10);
    assert_eq!(blast_fun::errors::invalid_meme_quote_pair!(), 11);
    assert_eq!(blast_fun::errors::meme_symbol_too_long!(), 12);
    assert_eq!(blast_fun::errors::invalid_protection!(), 13);
    assert_eq!(blast_fun::errors::invalid_graduation_target!(), 14);
    assert_eq!(blast_fun::errors::invalid_launch_lifecycle!(), 15);
}

#[test]
fun trade_and_fee_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::slippage_exceeded!(), 16);
    assert_eq!(blast_fun::errors::zero_trade_output!(), 17);
    assert_eq!(blast_fun::errors::per_transaction_limit_exceeded!(), 18);
    assert_eq!(blast_fun::errors::cumulative_limit_exceeded!(), 19);
    assert_eq!(blast_fun::errors::nothing_accrued!(), 20);
}

#[test]
fun migration_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_migration_witness!(), 21);
}

#[test]
fun creator_authority_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::creator_cap_not_live!(), 22);
    assert_eq!(blast_fun::errors::invalid_creator_recipient!(), 25);
    assert_eq!(blast_fun::errors::invalid_account_commitment!(), 26);
    assert_eq!(blast_fun::errors::invalid_creator_claim_public_key!(), 27);
    assert_eq!(blast_fun::errors::invalid_creator_claim_attestation!(), 28);
    assert_eq!(blast_fun::errors::creator_claim_expired!(), 29);
    assert_eq!(blast_fun::errors::creator_not_sender!(), 30);
    assert_eq!(blast_fun::errors::invalid_creator_claim_signature!(), 31);
    assert_eq!(blast_fun::errors::quote_not_allowed!(), 32);
    assert_eq!(blast_fun::errors::invalid_virtual_quote!(), 33);
}

// === Imports ===

use std::unit_test::assert_eq;
