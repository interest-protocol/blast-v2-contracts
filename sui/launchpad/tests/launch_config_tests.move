// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 250;

const MEME_DECIMALS: u8 = 9;

// === Test-Only Types ===

public struct TEST_QUOTE() has drop;

public struct TEST_MIGRATION_WITNESS() has drop;

public struct QUOTE<phantom Marker>() has drop;

public struct Q0() has drop;

public struct Q1() has drop;

public struct Q2() has drop;

public struct Q3() has drop;

public struct Q4() has drop;

public struct Q5() has drop;

public struct Q6() has drop;

public struct Q7() has drop;

public struct Q8() has drop;

public struct Q9() has drop;

public struct Q10() has drop;

public struct Q11() has drop;

public struct Q12() has drop;

public struct Q13() has drop;

public struct Q14() has drop;

public struct Q15() has drop;

public struct Q16() has drop;

/// Package-initialization facts only; carries no ACL or admin state.
public struct InitFixture {
    scenario: Scenario,
    config: launch_config::LaunchConfig,
}

/// Cold-policy administration through the ACL sign-in seam.
public struct ConfigFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: package_version::PackageVersion,
    config: launch_config::LaunchConfig,
}

// === Tests ===

#[test]
fun package_init_creates_launch_config_with_six_and_nine_decimals() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        let (quote_fee_bps, meme_fee_bps) = f.config.rate_defaults_for_testing();

        assert_eq!(quote_fee_bps, 0);
        assert_eq!(meme_fee_bps, 0);
        assert_eq!(f.config.allowed_quote_count_for_testing(), 0);
        assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 0);
        assert_eq!(f.config.allowed_meme_decimals_count_for_testing(), 2);
    });

    fixture.end();
}

#[test]
fun protocol_allocation_is_set_once_and_emits_destination_and_rates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation(PROTOCOL_ADMIN, 500, 250);

        let destination = PROTOCOL_ADMIN;
        let mut expected = bcs::to_bytes(&destination);
        expected.append(u64_bytes(500));
        expected.append(u64_bytes(250));

        assert_eq!(bcs::to_bytes(&collect_one<events::ProtocolAllocationSet>()), expected);
        assert_eq!(
            f.config.protocol_allocation(),
            allocation::recipient(PROTOCOL_ADMIN, bps::new(500), bps::new(250)),
        );
    });

    fixture.end();
}

#[test]
fun protocol_allocation_accepts_zero_shares() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation(PROTOCOL_ADMIN, 0, 0);

        assert_eq!(
            f.config.protocol_allocation(),
            allocation::recipient(PROTOCOL_ADMIN, bps::new(0), bps::new(0)),
        );
    });

    fixture.end();
}

#[test]
fun protocol_allocation_maxima_leave_one_unit_for_the_curve_and_the_pool() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation(PROTOCOL_ADMIN, 9_998, 9_999);

        assert_eq!(
            f.config.protocol_allocation(),
            allocation::recipient(PROTOCOL_ADMIN, bps::new(9_998), bps::new(9_999)),
        );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = std::option::EOPTION_NOT_SET,
        location = std::option,
    ),
]
fun unset_protocol_allocation_rejects_launch_intake() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.protocol_allocation();
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidProtocolAllocation,
        location = blast_fun::launch_config,
    ),
]
fun protocol_allocation_cannot_be_reset() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation(PROTOCOL_ADMIN, 0, 0);
        f.set_protocol_allocation(@0x123, 1, 1);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidDestination,
        location = blast_fun::allocation,
    ),
]
fun protocol_allocation_rejects_zero_destination() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation(@0x0, 0, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidProtocolAllocation,
        location = blast_fun::launch_config,
    ),
]
fun protocol_allocation_rejects_meme_9999() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation(PROTOCOL_ADMIN, 9_999, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidProtocolAllocation,
        location = blast_fun::launch_config,
    ),
]
fun protocol_allocation_rejects_meme_10000_at_policy_surface() {
    let mut fixture = start();

    // Bps admits 10,000 inclusively; the stricter allocation policy owns this abort.
    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation(PROTOCOL_ADMIN, 10_000, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidProtocolAllocation,
        location = blast_fun::launch_config,
    ),
]
fun protocol_allocation_cannot_leave_no_pool_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation(PROTOCOL_ADMIN, 0, 10_000));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_package_version_rejects_protocol_allocation_before_its_bounds() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_for_testing(2);

        f.set_protocol_allocation(PROTOCOL_ADMIN, 10_000, 10_000);
    });

    fixture.end();
}

#[test]
fun admin_removes_and_readds_decimal_precision_for_future_tickets() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, false);

        assert_eq!(f.config.allowed_meme_decimals_count_for_testing(), 1);
        assert_eq!(bcs::to_bytes(&collect_one<events::MemeDecimalsSet>()), vector[6, 0]);

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, true);
        let set = collect<events::MemeDecimalsSet>();

        assert_eq!(f.config.allowed_meme_decimals_count_for_testing(), 2);
        assert_eq!(set.length(), 2);
        assert_eq!(bcs::to_bytes(&set[1]), vector[6, 1]);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyAlreadyExists,
        location = sui::vec_set,
    ),
]
fun allowing_an_admitted_decimal_rejects_the_unchanged_set() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyDoesNotExist,
        location = sui::vec_set,
    ),
]
fun disallowing_an_unlisted_decimal_rejects_the_unchanged_set() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 8, false);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_package_version_rejects_decimals_before_the_unchanged_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EDecimalsNotAllowed,
        location = blast_fun::launch_config,
    ),
]
fun launch_snapshot_rejects_disallowed_decimals() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_migration_witness(&admin_witness);
        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, MEME_DECIMALS, false);
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);
    });

    fixture.end();
}

#[test]
fun admin_allows_migration_witness_for_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_migration_witness(&admin_witness);

        let (quote_fee_bps, meme_fee_bps) = f
            .config
            .snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);

        assert_eq!(quote_fee_bps.value(), 0);
        assert_eq!(meme_fee_bps.value(), 0);
    });

    fixture.end();
}

#[test]
fun admin_allows_quote_for_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_migration_witness(&admin_witness);

        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 1);
        assert_eq!(bcs::to_bytes(&collect_one<events::QuoteSet>()), quote_set_bytes(true));
    });

    fixture.end();
}

#[test]
fun disallowing_a_quote_removes_it_from_future_launches() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);

        let set = collect<events::QuoteSet>();

        assert_eq!(f.config.allowed_quote_count_for_testing(), 0);
        assert_eq!(set.length(), 2);
        assert_eq!(bcs::to_bytes(&set[1]), quote_set_bytes(false));
    });

    fixture.end();
}

#[test]
fun admin_can_readd_a_disallowed_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_migration_witness(&admin_witness);

        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 1);
    });

    fixture.end();
}

#[test]
fun many_quotes_can_be_admitted() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<QUOTE<Q0>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q1>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q2>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q3>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q4>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q5>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q6>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q7>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q8>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q9>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q10>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q11>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q12>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q13>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q14>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q15>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q16>>(&f.package_version, &admin_witness, true);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 17);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::dynamic_field::EFieldAlreadyExists,
        location = sui::dynamic_field,
    ),
]
fun allowing_an_admitted_quote_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::dynamic_field::EFieldDoesNotExist,
        location = sui::dynamic_field,
    ),
]
fun disallowing_an_unlisted_quote_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_package_version_rejects_quote_before_the_set_update() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EQuoteNotAllowed,
        location = blast_fun::launch_config,
    ),
]
fun launch_snapshot_rejects_disallowed_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
        f.allow_test_migration_witness(&admin_witness);
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);
    });

    fixture.end();
}

#[test]
fun admin_sets_trade_fees_for_future_launch_snapshots() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_migration_witness(&admin_witness);
        f
            .config
            .set_trade_fees(
                &f.package_version,
                &admin_witness,
                bps::new(QUOTE_FEE_BPS),
                bps::new(MEME_FEE_BPS),
            );

        let (quote_fee_bps, meme_fee_bps) = f
            .config
            .snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);
        let mut expected = u64_bytes(QUOTE_FEE_BPS);
        expected.append(u64_bytes(MEME_FEE_BPS));

        assert_eq!(quote_fee_bps.value(), QUOTE_FEE_BPS);
        assert_eq!(meme_fee_bps.value(), MEME_FEE_BPS);
        assert_eq!(bcs::to_bytes(&collect_one<events::LaunchTradeFeesChanged>()), expected);
    });

    fixture.end();
}

#[test]
fun trade_fees_accept_zero_and_launch_ceiling_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_trade_fees(
                &f.package_version,
                &admin_witness,
                bps::new(constants::max_launch_fee_bps!()),
                bps::new(constants::max_launch_fee_bps!()),
            );
        f.config.set_trade_fees(&f.package_version, &admin_witness, bps::new(0), bps::new(0));
        f.config.set_trade_fees(&f.package_version, &admin_witness, bps::new(0), bps::new(1));

        let (quote_fee_bps, meme_fee_bps) = f.config.rate_defaults_for_testing();

        assert_eq!(collect<events::LaunchTradeFeesChanged>().length(), 3);
        assert_eq!(quote_fee_bps, 0);
        assert_eq!(meme_fee_bps, 1);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidTradeFeeBps,
        location = blast_fun::launch_config,
    ),
]
fun trade_fees_reject_quote_rate_above_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_trade_fees(
                &f.package_version,
                &admin_witness,
                bps::new(constants::max_launch_fee_bps!() + 1),
                bps::new(0),
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidTradeFeeBps,
        location = blast_fun::launch_config,
    ),
]
fun trade_fees_reject_meme_rate_above_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_trade_fees(
                &f.package_version,
                &admin_witness,
                bps::new(0),
                bps::new(constants::max_launch_fee_bps!() + 1),
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EUnchanged,
        location = blast_fun::launch_config,
    ),
]
fun trade_fees_reject_unchanged_pair() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_trade_fees(&f.package_version, &admin_witness, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_package_version_rejects_trade_fees_before_their_bounds() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f
            .config
            .set_trade_fees(
                &f.package_version,
                &admin_witness,
                bps::new(constants::max_launch_fee_bps!() + 1),
                bps::new(0),
            );
    });

    fixture.end();
}

#[test]
fun admin_allows_migration_witness_and_emits_its_original_type_name() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.allow_test_migration_witness(&admin_witness);

        let mut expected = bcs::to_bytes(&test_witness());
        expected.append(bcs::to_bytes(&true));

        assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 1);
        assert_eq!(bcs::to_bytes(&collect_one<events::MigrationWitnessSet>()), expected);
    });

    fixture.end();
}

#[test]
fun disallowing_migration_witness_does_not_change_an_existing_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_migration_witness(&admin_witness);
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);

        f
            .config
            .set_migration_witness_allowed<TEST_MIGRATION_WITNESS>(
                &f.package_version,
                &admin_witness,
                false,
            );

        let set = collect<events::MigrationWitnessSet>();
        let mut expected = bcs::to_bytes(&test_witness());
        expected.append(bcs::to_bytes(&false));

        assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 0);
        assert_eq!(set.length(), 2);
        assert_eq!(bcs::to_bytes(&set[1]), expected);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyDoesNotExist,
        location = sui::vec_set,
    ),
]
fun disallowing_migration_witness_rejects_unlisted_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_migration_witness_allowed<TEST_MIGRATION_WITNESS>(
                &f.package_version,
                &admin_witness,
                false,
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyAlreadyExists,
        location = sui::vec_set,
    ),
]
fun allowing_migration_witness_rejects_duplicate_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.allow_test_migration_witness(&admin_witness);
        f.allow_test_migration_witness(&admin_witness);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = std::type_name::ENonModuleType,
        location = std::type_name,
    ),
]
fun allowing_migration_witness_rejects_a_primitive_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        // Only module types have an origin package, so the framework rejects this one first.
        f.config.set_migration_witness_allowed<bool>(&f.package_version, &admin_witness, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = std::type_name::ENonModuleType,
        location = std::type_name,
    ),
]
fun allowing_migration_witness_rejects_a_vector_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        // Only module types have an origin package, so the framework rejects this one first.
        f
            .config
            .set_migration_witness_allowed<vector<u8>>(
                &f.package_version,
                &admin_witness,
                true,
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitnessType,
        location = blast_fun::launch_config,
    ),
]
fun allowing_migration_witness_rejects_a_standard_library_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_migration_witness_allowed<std::string::String>(
                &f.package_version,
                &admin_witness,
                true,
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitnessType,
        location = blast_fun::launch_config,
    ),
]
fun allowing_migration_witness_rejects_a_sui_framework_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_migration_witness_allowed<sui::object::ID>(
                &f.package_version,
                &admin_witness,
                true,
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitnessType,
        location = blast_fun::launch_config,
    ),
]
fun disallowing_a_framework_type_rejects_the_type_before_the_unchanged_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f
            .config
            .set_migration_witness_allowed<sui::object::ID>(
                &f.package_version,
                &admin_witness,
                false,
            );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_package_version_rejects_migration_witness_before_its_type_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.set_migration_witness_allowed<bool>(&f.package_version, &admin_witness, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
        location = blast_fun::launch_config,
    ),
]
fun launch_snapshot_rejects_unlisted_migration_witness() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_witness(), MEME_DECIMALS);
    });

    fixture.end();
}

// === Test Helpers ===

/// The binding a ticket bound to the test adapter hands to launch intake.
fun test_witness(): TypeName {
    type_name::with_original_ids<TEST_MIGRATION_WITNESS>()
}

/// Serializes one protocol constant by value, so no test borrows a constant in place.
fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

/// Expected `QuoteSet` bytes for the test quote.
fun quote_set_bytes(allowed: bool): vector<u8> {
    let mut expected = bcs::to_bytes(&type_name::with_original_ids<TEST_QUOTE>());
    expected.append(bcs::to_bytes(&allowed));
    expected
}

fun collect<T: copy + drop>(): vector<T> {
    event::events_by_type<Event<T>>().map!(|event| event.unwrap())
}

fun collect_one<T: copy + drop>(): T {
    let mut payloads = collect<T>();
    assert_eq!(payloads.length(), 1);
    payloads.pop_back()
}

macro fun init_next_tx($fixture: &mut InitFixture, $sender: address, $fn: |&mut InitFixture|) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun config_next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    launch_config::init_for_testing(scenario.ctx());

    assert_eq!(event::num_events(), 0);

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<launch_config::LaunchConfig>();

    InitFixture { scenario, config }
}

fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let config = scenario.take_shared<launch_config::LaunchConfig>();

    ConfigFixture { scenario, authority, admin_cap, package_version, config }
}

fun sign_in(self: &ConfigFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

/// Signs in and sets Blast's allocation, so bound tests state only the destination and rates.
fun set_protocol_allocation(
    self: &mut ConfigFixture,
    destination: address,
    meme_bps: u64,
    quote_bps: u64,
) {
    let admin_witness = self.sign_in();

    self
        .config
        .set_protocol_allocation(
            &self.package_version,
            &admin_witness,
            destination,
            bps::new(meme_bps),
            bps::new(quote_bps),
        );
}

fun allow_test_migration_witness(
    self: &mut ConfigFixture,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    self
        .config
        .set_migration_witness_allowed<TEST_MIGRATION_WITNESS>(
            &self.package_version,
            admin_witness,
            true,
        );
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, AdminWitness};

use blast_fun::{
    allocation,
    blast_events::Event,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    constants,
    domain_fixture,
    events,
    launch_config,
    package_version,
};

use std::{bcs, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;

use fun config_next_tx as ConfigFixture.next_tx;

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;
