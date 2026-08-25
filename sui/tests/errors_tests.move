#[test_only]
module blast_fun::errors_tests;

use std::unit_test::assert_eq;

// === Tests ===

#[test]
fun authority_and_claim_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_admin_cap!(), 0);
    assert_eq!(blast_fun::errors::invalid_x_claim_public_key!(), 2);
    assert_eq!(blast_fun::errors::x_claim_signer_inactive!(), 3);
    assert_eq!(blast_fun::errors::invalid_x_claim_signature!(), 6);
    assert_eq!(blast_fun::errors::invalid_creator!(), 9);
    assert_eq!(blast_fun::errors::invalid_x_identity_hash!(), 10);
    assert_eq!(blast_fun::errors::unexpected_x_claim_attestation!(), 11);
    assert_eq!(blast_fun::errors::x_claim_expired!(), 14);
    assert_eq!(blast_fun::errors::invalid_super_admin_cap!(), 15);
    assert_eq!(blast_fun::errors::invalid_admin_recipient!(), 16);
    assert_eq!(blast_fun::errors::admin_capacity_reached!(), 17);
    assert_eq!(
        blast_fun::errors::invalid_super_admin_recipient!(),
        18,
    );
    assert_eq!(
        blast_fun::errors::no_pending_super_admin_transfer!(),
        19,
    );
    assert_eq!(
        blast_fun::errors::not_pending_super_admin_recipient!(),
        20,
    );
    assert_eq!(
        blast_fun::errors::super_admin_transfer_not_ready!(),
        21,
    );
    assert_eq!(
        blast_fun::errors::super_admin_transfer_time_overflow!(),
        22,
    );
    assert_eq!(blast_fun::errors::super_admin_cap_still_active!(), 23);
    assert_eq!(blast_fun::errors::x_claim_signer_unchanged!(), 24);
    assert_eq!(blast_fun::errors::missing_x_claim_attestation!(), 25);
    assert_eq!(blast_fun::errors::creator_not_sender!(), 26);
    assert_eq!(blast_fun::errors::invalid_x_claim_attestation!(), 27);
    assert_eq!(blast_fun::errors::super_admin_transfer_unchanged!(), 28);
}

#[test]
fun market_and_launch_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_curve_reserve!(), 29);
    assert_eq!(blast_fun::errors::invalid_terminal_threshold!(), 30);
    assert_eq!(blast_fun::errors::invalid_quote_fee_bps!(), 31);
    assert_eq!(blast_fun::errors::invalid_max_burn_bps!(), 32);
    assert_eq!(blast_fun::errors::zero_trade_input!(), 33);
    assert_eq!(blast_fun::errors::zero_trade_output!(), 34);
    assert_eq!(blast_fun::errors::curve_reserve_overflow!(), 35);
    assert_eq!(
        blast_fun::errors::sell_back_invariant_violated!(),
        36,
    );
    assert_eq!(blast_fun::errors::invalid_meme_fee_bps!(), 37);
    assert_eq!(blast_fun::errors::nothing_accrued!(), 38);
    assert_eq!(blast_fun::errors::zero_fee_accrual!(), 39);
    assert_eq!(
        blast_fun::errors::invalid_protocol_fee_share_bps!(),
        40,
    );
    assert_eq!(blast_fun::errors::protocol_fee_share_unchanged!(), 41);
    assert_eq!(blast_fun::errors::invalid_migration_quote_target!(), 42);
    assert_eq!(blast_fun::errors::quote_capacity_reached!(), 44);
    assert_eq!(blast_fun::errors::quote_not_allowed!(), 45);
    assert_eq!(blast_fun::errors::migration_quote_target_unchanged!(), 46);
    assert_eq!(blast_fun::errors::invalid_quote_migration_fee_bps!(), 47);
    assert_eq!(
        blast_fun::errors::invalid_meme_graduation_allocation_bps!(),
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
}

#[test]
fun package_admin_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_upgrade_cap!(), 53);
    assert_eq!(blast_fun::errors::invalid_package_digest!(), 54);
    assert_eq!(
        blast_fun::errors::admin_package_authorization_disabled!(),
        55,
    );
    assert_eq!(blast_fun::errors::invalid_package_publisher!(), 56);
    assert_eq!(
        blast_fun::errors::upgrade_policy_not_more_restrictive!(),
        57,
    );
    assert_eq!(
        blast_fun::errors::admin_package_authorization_already_disabled!(),
        58,
    );
}
