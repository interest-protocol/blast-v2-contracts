#[test_only]
module blast_fun::errors_tests;

use std::unit_test::assert_eq;

// === Tests ===

#[test]
fun authority_and_claim_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_creator_claim_public_key!(), 2);
    assert_eq!(blast_fun::errors::creator_claim_signer_inactive!(), 3);
    assert_eq!(blast_fun::errors::invalid_creator_claim_signature!(), 6);
    assert_eq!(blast_fun::errors::invalid_creator_recipient!(), 9);
    assert_eq!(blast_fun::errors::invalid_account_commitment!(), 10);
    assert_eq!(blast_fun::errors::unexpected_creator_claim_attestation!(), 11);
    assert_eq!(blast_fun::errors::creator_claim_expired!(), 14);
    assert_eq!(blast_fun::errors::creator_claim_signer_unchanged!(), 24);
    assert_eq!(blast_fun::errors::missing_creator_claim_attestation!(), 25);
    assert_eq!(blast_fun::errors::creator_not_sender!(), 26);
    assert_eq!(blast_fun::errors::invalid_creator_claim_attestation!(), 27);
}

#[test]
fun market_and_launch_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_curve_reserve!(), 29);
    assert_eq!(blast_fun::errors::invalid_quote_fee_bps!(), 31);
    assert_eq!(blast_fun::errors::zero_trade_input!(), 33);
    assert_eq!(blast_fun::errors::zero_trade_output!(), 34);
    assert_eq!(
        blast_fun::errors::sell_back_invariant_violated!(),
        36,
    );
    assert_eq!(blast_fun::errors::invalid_meme_fee_bps!(), 37);
    assert_eq!(blast_fun::errors::nothing_accrued!(), 38);
    assert_eq!(blast_fun::errors::zero_fee_accrual!(), 39);
    assert_eq!(blast_fun::errors::protocol_fee_share_unchanged!(), 41);
    assert_eq!(blast_fun::errors::invalid_migration_quote_target!(), 42);
    assert_eq!(blast_fun::errors::quote_not_allowed!(), 45);
    assert_eq!(blast_fun::errors::invalid_protocol_quote_migration_fee_bps!(), 47);
    assert_eq!(
        blast_fun::errors::invalid_protocol_meme_graduation_fee_bps!(),
        48,
    );
    assert_eq!(blast_fun::errors::graduation_defaults_unchanged!(), 49);
    assert_eq!(
        blast_fun::errors::migration_witness_already_allowed!(),
        50,
    );
    assert_eq!(
        blast_fun::errors::migration_witness_capacity_reached!(),
        51,
    );
    assert_eq!(blast_fun::errors::migration_witness_not_allowed!(), 52);
    assert_eq!(blast_fun::errors::invalid_meme_liquidity_provision_bps!(), 59);
    assert_eq!(blast_fun::errors::invalid_meme_supply_partition_bps!(), 60);
    assert_eq!(blast_fun::errors::invalid_virtual_quote!(), 64);
    assert_eq!(blast_fun::errors::quote_parameters_unchanged!(), 65);
    assert_eq!(blast_fun::errors::creator_authority_unavailable!(), 66);
    assert_eq!(blast_fun::errors::trade_fee_defaults_unchanged!(), 67);
    assert_eq!(blast_fun::errors::invalid_launch_lifecycle!(), 70);
    assert_eq!(blast_fun::errors::slippage_exceeded!(), 71);
    assert_eq!(blast_fun::errors::invalid_migration_witness!(), 72);
    assert_eq!(blast_fun::errors::invalid_bps!(), 75);
    assert_eq!(blast_fun::errors::invalid_meme_quote_pair!(), 76);
    assert_eq!(blast_fun::errors::invalid_initial_meme_supply!(), 77);
    assert_eq!(blast_fun::errors::invalid_migration_witness_type!(), 78);
    assert_eq!(blast_fun::errors::invalid_sell_burn_bps!(), 83);
    assert_eq!(
        blast_fun::errors::constant_product_invariant_decreased!(),
        84,
    );
    assert_eq!(blast_fun::errors::invalid_curve_fee!(), 94);
}

#[test]
fun creator_authority_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::curve_fee_cap_not_live!(), 88);
    assert_eq!(blast_fun::errors::metadata_unchanged!(), 89);
    assert_eq!(blast_fun::errors::creator_fees_locked!(), 90);
    assert_eq!(blast_fun::errors::creator_custodian_mismatch!(), 91);
    assert_eq!(blast_fun::errors::metadata_cap_not_live!(), 92);
    assert_eq!(blast_fun::errors::invalid_fee_custodian!(), 93);
}

#[test]
/// Only Blast's own module-provenance rule remains local; every reusable
/// custody, policy, and generation code now belongs to `blast_admin`.
fun package_admin_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_package_publisher!(), 56);
}
