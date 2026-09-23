// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const VIRTUAL_QUOTE: u64 = 5_000_000;
const UPDATED_VIRTUAL_QUOTE: u64 = 8_000_000;
const MIGRATION_QUOTE_TARGET: u64 = 25_000_000;
const UPDATED_MIGRATION_QUOTE_TARGET: u64 = 40_000_000;
const QUOTE_FEE_BPS: u64 = 100;
const MEME_FEE_BPS: u64 = 250;
const PROTOCOL_QUOTE_MIGRATION_FEE_BPS: u64 = 250;
const PROTOCOL_MEME_GRADUATION_FEE_BPS: u64 = 750;
const MEME_LIQUIDITY_PROVISION_BPS: u64 = 2_000;

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
fun package_init_creates_empty_launch_config() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        let (
            quote_fee_bps,
            meme_fee_bps,
            protocol_quote_migration_fee_bps,
            protocol_meme_graduation_fee_bps,
            meme_liquidity_provision_bps,
        ) = f.config.rate_defaults_for_testing();

        assert_eq!(quote_fee_bps, 0);
        assert_eq!(meme_fee_bps, 0);
        assert_eq!(protocol_quote_migration_fee_bps, 0);
        assert_eq!(protocol_meme_graduation_fee_bps, 0);
        assert_eq!(meme_liquidity_provision_bps, 0);
        assert_eq!(f.config.allowed_quote_count_for_testing(), 0);
        assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 0);
    });

    fixture.end();
}

#[test]
fun admin_allows_migration_witness_for_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );

        let (_, _, _, _, _, _, _, migration_witness) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

        assert_eq!(
            migration_witness,
            std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
        );
    });

    fixture.end();
}

#[test]
fun admin_allows_quote_and_launch_snapshot_uses_its_parameters() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE,
            MIGRATION_QUOTE_TARGET,
        );
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );

        let (virtual_quote, target, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let allowed = events::collect_one<events::QuoteAllowed>(0);

        assert_eq!(virtual_quote, VIRTUAL_QUOTE);
        assert_eq!(target, MIGRATION_QUOTE_TARGET);
        assert_eq!(
            bcs::to_bytes(&allowed),
            quote_parameter_bytes(VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET),
        );
        assert!(event::events_by_type<events::QuoteAllowed>().is_empty());
    });

    fixture.end();
}

#[test]
fun allowing_an_existing_quote_updates_only_the_next_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );
        let _ = events::collect_one<events::QuoteAllowed>(0);
        let (first_virtual_quote, first_target, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE,
            UPDATED_MIGRATION_QUOTE_TARGET,
        );

        let (next_virtual_quote, next_target, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let changed = events::collect_one<events::QuoteParametersChanged>(0);

        assert_eq!(first_virtual_quote, VIRTUAL_QUOTE);
        assert_eq!(first_target, MIGRATION_QUOTE_TARGET);
        assert_eq!(next_virtual_quote, VIRTUAL_QUOTE);
        assert_eq!(next_target, UPDATED_MIGRATION_QUOTE_TARGET);
        assert_eq!(
            bcs::to_bytes(&changed),
            quote_parameter_bytes(VIRTUAL_QUOTE, UPDATED_MIGRATION_QUOTE_TARGET),
        );
    });

    fixture.end();
}

#[test]
fun allowing_an_existing_quote_can_update_only_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE,
            MIGRATION_QUOTE_TARGET,
        );
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );
        let _ = events::collect_one<events::QuoteAllowed>(0);

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            UPDATED_VIRTUAL_QUOTE,
            MIGRATION_QUOTE_TARGET,
        );

        let (virtual_quote, target, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let changed = events::collect_one<events::QuoteParametersChanged>(0);

        assert_eq!(virtual_quote, UPDATED_VIRTUAL_QUOTE);
        assert_eq!(target, MIGRATION_QUOTE_TARGET);
        assert_eq!(
            bcs::to_bytes(&changed),
            quote_parameter_bytes(UPDATED_VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET),
        );
    });

    fixture.end();
}

#[test]
fun admin_disallows_quote_from_future_launch_admission() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        let _ = events::collect_one<events::QuoteAllowed>(0);

        f.config.disallow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness);

        let disallowed = events::collect_one<events::QuoteDisallowed>(0);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 0);
        assert_eq!(
            bcs::to_bytes(&disallowed),
            bcs::to_bytes(&std::type_name::with_original_ids<TEST_QUOTE>()),
        );
    });

    fixture.end();
}

#[test]
fun admin_can_readd_a_disallowed_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE,
            MIGRATION_QUOTE_TARGET,
        );
        f.config.disallow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
        );
        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            UPDATED_VIRTUAL_QUOTE,
            UPDATED_MIGRATION_QUOTE_TARGET,
        );
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(
            &f.package_version,
            &admin_witness,
        );
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );

        let (virtual_quote, target, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

        assert_eq!(f.config.allowed_quote_count_for_testing(), 1);
        assert_eq!(virtual_quote, UPDATED_VIRTUAL_QUOTE);
        assert_eq!(target, UPDATED_MIGRATION_QUOTE_TARGET);
    });

    fixture.end();
}

#[test]
fun admin_sets_graduation_defaults_for_future_launch_snapshots() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        let _ = events::collect_one<events::QuoteAllowed>(0);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(PROTOCOL_QUOTE_MIGRATION_FEE_BPS),
            bps::new(PROTOCOL_MEME_GRADUATION_FEE_BPS),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );

        let (
            virtual_quote,
            migration_quote_target,
            quote_fee_bps,
            meme_fee_bps,
            protocol_quote_migration_fee_bps,
            protocol_meme_graduation_fee_bps,
            meme_liquidity_provision_bps,
            migration_witness,
        ) = f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let changed = events::collect_one<events::GraduationDefaultsChanged>(0);

        assert_eq!(virtual_quote, VIRTUAL_QUOTE);
        assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
        assert_eq!(quote_fee_bps.value(), 0);
        assert_eq!(meme_fee_bps.value(), 0);
        assert_eq!(protocol_quote_migration_fee_bps.value(), PROTOCOL_QUOTE_MIGRATION_FEE_BPS);
        assert_eq!(
            protocol_meme_graduation_fee_bps.value(),
            PROTOCOL_MEME_GRADUATION_FEE_BPS,
        );
        assert_eq!(
            meme_liquidity_provision_bps.value(),
            MEME_LIQUIDITY_PROVISION_BPS,
        );
        assert_eq!(
            migration_witness,
            std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
        );
        let mut expected = u64_bytes(PROTOCOL_QUOTE_MIGRATION_FEE_BPS);
        expected.append(u64_bytes(PROTOCOL_MEME_GRADUATION_FEE_BPS));
        expected.append(u64_bytes(MEME_LIQUIDITY_PROVISION_BPS));
        assert_eq!(bcs::to_bytes(&changed), expected);
    });

    fixture.end();
}

#[test]
fun admin_sets_trade_fees_for_future_launch_snapshots() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE,
            MIGRATION_QUOTE_TARGET,
        );
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );
        f.config.set_trade_fees(&f.package_version,
            &admin_witness, bps::new(QUOTE_FEE_BPS), bps::new(MEME_FEE_BPS));

        let (
            _,
            _,
            quote_fee_bps,
            meme_fee_bps,
            _,
            _,
            _,
            _,
        ) = f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let changed = events::collect_one<events::LaunchTradeFeesChanged>(0);

        assert_eq!(quote_fee_bps.value(), QUOTE_FEE_BPS);
        assert_eq!(meme_fee_bps.value(), MEME_FEE_BPS);
        let mut expected = u64_bytes(QUOTE_FEE_BPS);
        expected.append(u64_bytes(MEME_FEE_BPS));
        assert_eq!(bcs::to_bytes(&changed), expected);
    });

    fixture.end();
}

#[test]
fun trade_fees_accept_zero_and_launch_ceiling_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_trade_fees(
            &f.package_version,
            &admin_witness,
            bps::new(constants::max_launch_fee_bps!()),
            bps::new(constants::max_launch_fee_bps!()),
        );
        f.config.set_trade_fees(&f.package_version,
            &admin_witness, bps::new(0), bps::new(0));
        f.config.set_trade_fees(&f.package_version,
            &admin_witness, bps::new(0), bps::new(1));

        let changes = events::collect<events::LaunchTradeFeesChanged>();

        assert_eq!(changes.length(), 3);
    });

    fixture.end();
}

#[test]
fun admin_allows_migration_witness_and_emits_its_original_type_name() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);

        let allowed = events::collect_one<events::MigrationWitnessAllowed>(0);
        let migration_witness =
            std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>();

        assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 1);
        assert_eq!(bcs::to_bytes(&allowed), bcs::to_bytes(&migration_witness));
    });

    fixture.end();
}

#[test]
fun graduation_defaults_accept_fee_zeros_and_liquidity_provision_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        let _ = events::collect_one<events::QuoteAllowed>(0);

        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(constants::max_protocol_quote_migration_fee_bps!()),
            bps::new(constants::max_protocol_meme_graduation_fee_bps!()),
            bps::new(constants::basis_points_denominator!()
                - constants::max_protocol_meme_graduation_fee_bps!()
                - 1),
        );
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(constants::max_protocol_quote_migration_fee_bps!()),
            bps::new(0),
            bps::new(constants::basis_points_denominator!()
                - constants::max_protocol_meme_graduation_fee_bps!()
                - 1),
        );
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(constants::max_protocol_meme_graduation_fee_bps!()),
            bps::new(constants::basis_points_denominator!()
                - constants::max_protocol_meme_graduation_fee_bps!()
                - 1),
        );
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(constants::max_protocol_quote_migration_fee_bps!()),
            bps::new(0),
            bps::new(constants::basis_points_denominator!() - 1),
        );
        f.config.set_graduation_defaults(&f.package_version,
            &admin_witness, bps::new(0), bps::new(0), bps::new(1));

        let (
            _,
            _,
            _,
            _,
            protocol_quote_migration_fee_bps,
            protocol_meme_graduation_fee_bps,
            meme_liquidity_provision_bps,
            _,
        ) = f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let changes = events::collect<events::GraduationDefaultsChanged>();

        assert_eq!(protocol_quote_migration_fee_bps.value(), 0);
        assert_eq!(protocol_meme_graduation_fee_bps.value(), 0);
        assert_eq!(meme_liquidity_provision_bps.value(), 1);
        assert_eq!(changes.length(), 5);
    });

    fixture.end();
}

#[test]
fun disallowing_migration_witness_does_not_change_an_existing_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(MEME_LIQUIDITY_PROVISION_BPS),
        );
        let (_, _, _, _, _, _, _, snapshotted_migration_witness) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
        let _ = events::collect_one<events::MigrationWitnessAllowed>(0);

        f.config.disallow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);

        let disallowed = events::collect_one<events::MigrationWitnessDisallowed>(0);

        assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 0);
        assert_eq!(
            bcs::to_bytes(&disallowed),
            bcs::to_bytes(&snapshotted_migration_witness),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidQuoteFeeBps,
    location = blast_fun::launch_config,
)]
fun trade_fees_reject_quote_rate_above_ceiling_first() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_trade_fees(
            &f.package_version,
            &admin_witness,
            bps::new(constants::max_launch_fee_bps!() + 1),
            bps::new(constants::max_launch_fee_bps!() + 1),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeFeeBps,
    location = blast_fun::launch_config,
)]
fun trade_fees_reject_meme_rate_above_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_trade_fees(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(constants::max_launch_fee_bps!() + 1),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ETradeFeeDefaultsUnchanged,
    location = blast_fun::launch_config,
)]
fun trade_fees_reject_unchanged_pair() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_trade_fees(&f.package_version,
            &admin_witness, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidQuoteMigrationFeeBps,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_quote_rate_above_ceiling_first() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(constants::max_protocol_quote_migration_fee_bps!() + 1),
            bps::new(constants::max_protocol_meme_graduation_fee_bps!() + 1),
            bps::new(0),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidProtocolMemeGraduationFeeBps,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_meme_rate_above_ceiling_before_provision() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(constants::max_protocol_meme_graduation_fee_bps!() + 1),
            bps::new(0),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeLiquidityProvisionBps,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_zero_liquidity_provision() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(&f.package_version,
            &admin_witness, bps::new(0), bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeLiquidityProvisionBps,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_liquidity_provision_above_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(0),
            bps::new(constants::basis_points_denominator!()),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeLiquidityProvisionBps,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_provision_ceiling_before_partition() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(constants::max_protocol_meme_graduation_fee_bps!()),
            bps::new(constants::basis_points_denominator!()),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeSupplyPartitionBps,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_partition_without_curve_inventory() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            bps::new(0),
            bps::new(constants::max_protocol_meme_graduation_fee_bps!()),
            bps::new(constants::basis_points_denominator!()
                - constants::max_protocol_meme_graduation_fee_bps!()),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeLiquidityProvisionBps,
    location = blast_fun::launch_config,
)]
fun launch_snapshot_rejects_unconfigured_liquidity_provision() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        let (_, _, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EGraduationDefaultsUnchanged,
    location = blast_fun::launch_config,
)]
fun graduation_defaults_reject_unchanged_triple() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_graduation_defaults(&f.package_version,
            &admin_witness, bps::new(0), bps::new(0), bps::new(1));
        let _ = events::collect_one<events::GraduationDefaultsChanged>(0);
        f.config.set_graduation_defaults(&f.package_version,
            &admin_witness, bps::new(0), bps::new(0), bps::new(1));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
    location = blast_fun::launch_config,
)]
fun disallowing_migration_witness_rejects_unlisted_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.disallow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessAlreadyAllowed,
    location = blast_fun::launch_config,
)]
fun allowing_migration_witness_rejects_duplicate_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
        f.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&f.package_version,
            &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMigrationWitnessType,
    location = blast_fun::launch_config,
)]
fun allowing_migration_witness_rejects_a_primitive_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_migration_witness<bool>(
            &f.package_version,
            &admin_witness,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMigrationWitnessType,
    location = blast_fun::launch_config,
)]
fun allowing_migration_witness_rejects_a_vector_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_migration_witness<vector<u8>>(
            &f.package_version,
            &admin_witness,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMigrationQuoteTarget,
    location = blast_fun::launch_config,
)]
fun allowing_quote_rejects_zero_target_before_type_lookup() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMigrationQuoteTarget,
    location = blast_fun::launch_config,
)]
fun allowing_quote_rejects_one_atom_target() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 1);
    });

    fixture.end();
}

#[test]
fun quote_table_admits_more_than_the_previous_vector_limit() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<QUOTE<Q0>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q1>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q2>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q3>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q4>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q5>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q6>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q7>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q8>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q9>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q10>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q11>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q12>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q13>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q14>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q15>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);
        f.config.allow_quote<QUOTE<Q16>>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, 2);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 17);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EQuoteParametersUnchanged,
    location = blast_fun::launch_config,
)]
fun allowing_quote_rejects_unchanged_parameter_pair() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE,
            MIGRATION_QUOTE_TARGET,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidVirtualQuote,
    location = blast_fun::launch_config,
)]
fun allowing_quote_rejects_zero_virtual_quote_before_target() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, 0, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_rejects_launch_config_before_policy_validation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            0,
            0,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EQuoteNotAllowed,
    location = blast_fun::launch_config,
)]
fun disallowing_quote_rejects_quote_that_is_not_allowed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.disallow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EQuoteNotAllowed,
    location = blast_fun::launch_config,
)]
fun launch_snapshot_rejects_disallowed_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        f.config.disallow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness);
        let (_, _, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
    location = blast_fun::launch_config,
)]
fun launch_snapshot_rejects_unlisted_migration_witness() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(&f.package_version,
            &admin_witness, VIRTUAL_QUOTE, MIGRATION_QUOTE_TARGET);
        let (_, _, _, _, _, _, _, _) =
            f.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    });

    fixture.end();
}

// === Private Test Helpers ===

/// Serializes one protocol constant by value, so no test borrows a constant in place.
fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

/// Expected bytes shared by `QuoteAllowed` and `QuoteParametersChanged` for the test quote.
fun quote_parameter_bytes(virtual_quote: u64, migration_quote_target: u64): vector<u8> {
    let mut expected = bcs::to_bytes(&std::type_name::with_original_ids<TEST_QUOTE>());
    expected.append(bcs::to_bytes(&virtual_quote));
    expected.append(bcs::to_bytes(&migration_quote_target));
    expected
}

macro fun init_next_tx(
    $fixture: &mut InitFixture,
    $sender: address,
    $fn: |&mut InitFixture|,
) {
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

fun init_end(self: InitFixture) {
    destroy(self);
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, AdminWitness};

use blast_fun::{
    bps,
    constants,
    domain_fixture,
    events,
    launch_config,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    package_version,
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;

use fun config_next_tx as ConfigFixture.next_tx;

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;
