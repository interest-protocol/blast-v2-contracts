#[test_only]
module blast_fun::errors_tests;

// === Tests ===

#[test]
fun package_error_registry_is_stable() {
    std::unit_test::assert_eq!(blast_fun::errors::invalid_admin_cap!(), 0);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_x_claim_public_key!(), 2);
    std::unit_test::assert_eq!(blast_fun::errors::x_claim_signer_inactive!(), 3);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_x_claim_signature!(), 6);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_creator!(), 9);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_x_identity_hash!(), 10);
    std::unit_test::assert_eq!(blast_fun::errors::unexpected_x_claim_attestation!(), 11);
    std::unit_test::assert_eq!(blast_fun::errors::x_claim_expired!(), 14);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_super_admin_cap!(), 15);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_admin_recipient!(), 16);
    std::unit_test::assert_eq!(blast_fun::errors::admin_capacity_reached!(), 17);
    std::unit_test::assert_eq!(
        blast_fun::errors::invalid_super_admin_recipient!(),
        18,
    );
    std::unit_test::assert_eq!(
        blast_fun::errors::no_pending_super_admin_transfer!(),
        19,
    );
    std::unit_test::assert_eq!(
        blast_fun::errors::not_pending_super_admin_recipient!(),
        20,
    );
    std::unit_test::assert_eq!(
        blast_fun::errors::super_admin_transfer_not_ready!(),
        21,
    );
    std::unit_test::assert_eq!(
        blast_fun::errors::super_admin_transfer_time_overflow!(),
        22,
    );
    std::unit_test::assert_eq!(blast_fun::errors::super_admin_cap_still_active!(), 23);
    std::unit_test::assert_eq!(blast_fun::errors::x_claim_signer_unchanged!(), 24);
    std::unit_test::assert_eq!(blast_fun::errors::missing_x_claim_attestation!(), 25);
    std::unit_test::assert_eq!(blast_fun::errors::creator_not_sender!(), 26);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_x_claim_attestation!(), 27);
    std::unit_test::assert_eq!(blast_fun::errors::super_admin_transfer_unchanged!(), 28);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_curve_reserve!(), 29);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_terminal_threshold!(), 30);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_quote_fee_bps!(), 31);
    std::unit_test::assert_eq!(blast_fun::errors::invalid_max_burn_bps!(), 32);
    std::unit_test::assert_eq!(blast_fun::errors::zero_trade_input!(), 33);
    std::unit_test::assert_eq!(blast_fun::errors::zero_trade_output!(), 34);
    std::unit_test::assert_eq!(blast_fun::errors::curve_reserve_overflow!(), 35);
    std::unit_test::assert_eq!(
        blast_fun::errors::sell_back_invariant_violated!(),
        36,
    );
    std::unit_test::assert_eq!(blast_fun::errors::invalid_meme_fee_bps!(), 37);
}
