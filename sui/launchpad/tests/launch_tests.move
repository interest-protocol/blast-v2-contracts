// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const LAUNCHER: address = @0xB1A57;

const CREATOR: address = @0xC0FFEE;

const PROTOCOL_ADMIN: address = @0xAD;

const NEW_CREATOR: address = @0xC7;

const ROLE_LESS_ADMIN: address = @0xBAD;

const MEME_DECIMALS: u8 = 9;

const INITIAL_MEME_SUPPLY: u64 = 1_000_000_000__000_000_000;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const MIGRATION_QUOTE_TARGET: u64 = 25_000_000;

/// A Meme symbol exactly at the 32-byte launch intake bound.
const MAX_LENGTH_SYMBOL: vector<u8> = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345";

const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 250;

const PROTOCOL_QUOTE_MIGRATION_FEE_BPS: u64 = 250;

const PROTOCOL_MEME_GRADUATION_FEE_BPS: u64 = 750;

const MEME_LIQUIDITY_PROVISION_BPS: u64 = 2_000;

const SELL_BURN_BPS: u64 = 1_000;

const EXPECTED_CURVE_MEME: u64 = 725_000_000__000_000_000;

const EXPECTED_PROTOCOL_MEME: u64 = 75_000_000__000_000_000;

const EXPECTED_POOL_MEME: u64 = 200_000_000__000_000_000;

const POOL_TICK_SPACING: u32 = 200;

const POOL_FEE_RATE: u64 = 10_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_TESTS has drop {}

public struct TEST_QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

public struct TEST_MIGRATION_WITNESS() has drop;

public struct OTHER_MIGRATION_WITNESS() has drop;

/// Test-only permanent custody proving the adapter, not its caller, retains every source atom.
public struct MockMigrationVault<phantom Meme, phantom Quote> has key {
    id: UID,
    supplied_meme: Balance<Meme>,
    supplied_quote: Balance<Quote>,
    residual_meme: Balance<Meme>,
    residual_quote: Balance<Quote>,
}

/// Launch construction through configured cold policy and creator custody.
public struct LaunchFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    config: launch_config::LaunchConfig,
    runtime_config: runtime_config::RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
fun launch_partitions_meme_into_curve_and_pooled_allocations() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let plan = external_plan();
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            plan,
        );
        let (curve, _, _, allocated) = launch.balances_for_testing();
        assert_eq!(curve, 700_000_000__000_000_000);
        assert_eq!(curve + allocated, INITIAL_MEME_SUPPLY);
        assert_eq!(launch.atomic_supply(), INITIAL_MEME_SUPPLY);
        f.share_launch(launch);
    });
    fixture.end();
}

#[test]
fun migration_pays_every_allocation_to_its_immutable_destination() {
    let mut fixture = start();
    let launch_id;
    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            external_plan(),
        );
        launch_id = object::id(&launch);
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let quote = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme, refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote,
            1,
            &f.clock,
            f.ctx!(),
        );
        destroy(meme);
        destroy(refund);
        launch.put_back();
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.complete_migration(&mut launch);
        let (curve, quote, burn, allocated) = launch.balances_for_testing();
        assert_eq!(curve, 0);
        assert_eq!(quote, 0);
        assert_eq!(burn, 0);
        assert_eq!(allocated, 0);
        let paid = events::collect<events::MigrationAllocationPaid>();
        assert_eq!(paid.length(), 3);
        assert_eq!(bcs::to_bytes(&paid[0]), allocation_paid_bytes(launch_id, 1, PROTOCOL_ADMIN, EXPECTED_PROTOCOL_MEME, 625_000));
        assert_eq!(bcs::to_bytes(&paid[1]), allocation_paid_bytes(launch_id, 3, CREATOR, 0, 1_875_000));
        assert_eq!(bcs::to_bytes(&paid[2]), allocation_paid_bytes(launch_id, 4, CREATOR, 25_000_000__000_000_000, 0));
        launch.put_back();
    });
    fixture.next_tx!(CREATOR, |f| {
        assert_eq!(f.take_destination_quote().burn_for_testing(), 1_875_000);
        assert_eq!(f.take_destination_meme().burn_for_testing(), 25_000_000__000_000_000);
    });
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.take_destination_quote().burn_for_testing(), 625_000);
        assert_eq!(f.take_destination_meme().burn_for_testing(), EXPECTED_PROTOCOL_MEME);
    });
    fixture.end();
}

#[test]
fun launch_consumes_ticket_and_emits_complete_initial_state() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let ticket_id = object::id(&ticket);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let launch_id = object::id(&launch);
        let created = events::collect_one<events::LaunchCreated>(0);

        assert_eq!(bcs::to_bytes(&created), launch_created_bytes(launch_id, ticket_id));
        assert_eq!(launch.sell_burn_bps_for_testing(), SELL_BURN_BPS);
        assert_eq!(
            EXPECTED_CURVE_MEME + EXPECTED_PROTOCOL_MEME + EXPECTED_POOL_MEME,
            INITIAL_MEME_SUPPLY,
        );
        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun public_getters_read_lifecycle_reserves_and_the_ticket_bound_witness() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        launch.assert_lifecycle(true, false, false);
        assert_eq!(launch.meme_reserve(), EXPECTED_CURVE_MEME);
        assert_eq!(launch.real_quote_reserve(), 0);
        assert_eq!(launch.virtual_quote(), VIRTUAL_QUOTE);
        assert_eq!(launch.migration_witness(), type_name::with_original_ids<TEST_MIGRATION_WITNESS>());
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let quote = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme, refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote,
            1,
            &f.clock,
            f.ctx!(),
        );
        let (meme_reserve, real_quote_reserve, _, _) = launch.balances_for_testing();

        launch.assert_lifecycle(false, true, false);
        assert_eq!(launch.meme_reserve(), meme_reserve);
        assert_eq!(launch.real_quote_reserve(), real_quote_reserve);
        assert_eq!(real_quote_reserve, MIGRATION_QUOTE_TARGET);
        destroy(meme);
        destroy(refund);
        launch.put_back();
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.complete_migration(&mut launch);

        launch.assert_lifecycle(false, false, true);
        assert_eq!(launch.meme_reserve(), 0);
        assert_eq!(launch.real_quote_reserve(), 0);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun zero_rounded_allocation_pays_nothing_and_emits_no_payout() {
    let mut fixture = start();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.open_dust_target_launch());
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.complete_migration(&mut launch);
        let paid = events::collect<events::MigrationAllocationPaid>();
        assert_eq!(paid.length(), 1);
        assert_eq!(
            bcs::to_bytes(&paid[0]),
            allocation_paid_bytes(object::id(&launch), 1, PROTOCOL_ADMIN, EXPECTED_PROTOCOL_MEME, 1),
        );
        let (_, quote, _, allocated) = launch.balances_for_testing();
        assert_eq!(quote, 0);
        assert_eq!(allocated, 0);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun maximum_plan_pays_all_fifteen_allocations_at_migration() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let plan = maximum_plan();
        assert_eq!(plan.channels().length(), 16);
        assert!(bcs::to_bytes(&plan).length() < 4_096);
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            plan,
        );
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let quote = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme, refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote,
            1,
            &f.clock,
            f.ctx!(),
        );
        destroy(meme);
        destroy(refund);
        launch.put_back();
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.complete_migration(&mut launch);
        assert_eq!(events::collect<events::MigrationAllocationPaid>().length(), 15);
        let (_, quote, _, allocated) = launch.balances_for_testing();
        assert_eq!(quote, 0);
        assert_eq!(allocated, 0);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun launch_snapshot_does_not_follow_later_config_updates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let admin_witness = f.sign_in();

        f
            .config
            .allow_quote<TEST_QUOTE>(&f.package_version, &admin_witness, VIRTUAL_QUOTE + 1);
        f.config.set_trade_fees(&f.package_version, &admin_witness, bps::new(0), bps::new(0));

        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EDecimalsNotAllowed, location = blast_fun::launch_config)]
fun intake_rejects_a_ticket_whose_decimals_are_no_longer_allowed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket_with_decimals(CREATOR, false, 6);
        let admin_witness = f.sign_in();

        f.config.disallow_meme_decimals(&f.package_version, &admin_witness, 6);

        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun intake_accepts_a_meme_symbol_at_the_length_bound() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(MAX_LENGTH_SYMBOL);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EMemeSymbolTooLong, location = blast_fun::launch)]
fun intake_rejects_a_meme_symbol_over_the_length_bound() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(over_length_symbol());
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EDecimalsNotAllowed, location = blast_fun::launch_config)]
fun intake_checks_the_decimals_before_the_symbol_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket_with(CREATOR, false, 6, over_length_symbol());
        let admin_witness = f.sign_in();

        f.config.disallow_meme_decimals(&f.package_version, &admin_witness, 6);

        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun intake_checks_the_version_before_the_symbol_length() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(over_length_symbol());
        f.package_version.set_for_testing(2);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun launcher_can_designate_another_address_as_creator() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);

        destroy(creator_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun burn_only_ticket_keeps_supply_mode_authoritative_in_coin_registry() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        let ticket_id = object::id(&ticket);
        let ticket_created = events::collect_one<events::LaunchTicketCreated>(0);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let launch_created = events::collect_one<events::LaunchCreated>(0);

        assert_eq!(
            bcs::to_bytes(&ticket_created),
            ticket_created_bytes(ticket_id, launch.metadata_cap_id_for_testing(), true),
        );
        assert_eq!(
            bcs::to_bytes(&launch_created),
            launch_created_bytes(object::id(&launch), ticket_id),
        );
        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let currency = f.take_currency();

        assert!(!currency.is_supply_fixed());
        assert!(currency.is_supply_burn_only());

        destroy(currency);
    });

    fixture.end();
}

#[test]
fun creator_claim_returns_both_creator_caps_and_retains_native_metadata_cap() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let expected_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);

        assert_eq!(launch.metadata_cap_id_for_testing(), expected_metadata_cap_id);
        assert!(!launch.has_creator_authority_for_testing());
        assert_eq!(launch.curve_fee_cap_id_for_testing(), option::some(object::id(&creator_cap)));
        assert!(launch.blast_metadata_cap_id_for_testing().is_some());

        destroy(creator_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::ECreatorAuthorityUnavailable,
        location = blast_fun::launch,
    ),
]
fun creator_claim_cannot_be_repeated() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);

        destroy(creator_cap);

        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);

        destroy(creator_cap);
        destroy(launch);
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
fun launch_delegates_quote_admission_to_launch_config() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<OTHER_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMemeQuotePair,
        location = blast_fun::launch,
    ),
]
fun launch_rejects_using_the_meme_type_as_quote_before_config_lookup() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<LAUNCH_TESTS, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidSellBurnBps,
        location = blast_fun::launch,
    ),
]
fun launch_rejects_a_ticket_whose_sell_burn_exceeds_this_generations_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.set_sell_burn_bps_for_testing(5_001);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidInitialMemeSupply,
        location = blast_fun::launch_ticket,
    ),
]
fun launch_rejects_a_ticket_without_the_canonical_supply() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.burn_meme_for_testing(1);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidInitialMemeSupply,
        location = blast_fun::launch_ticket,
    ),
]
fun launch_rejects_supply_minted_through_the_lent_treasury_cap() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        destroy(initializer.treasury_cap_mut(TEST_MIGRATION_WITNESS()).mint_balance(1));
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());
        let launch = f.finalize_launch(initializer);

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidInitialMemeSupply,
        location = blast_fun::launch_ticket,
    ),
]
fun launch_rejects_extra_supply_on_a_burn_only_ticket() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        destroy(initializer.treasury_cap_mut(TEST_MIGRATION_WITNESS()).mint_balance(1));
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());
        let launch = f.finalize_launch(initializer);

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun launch_stores_the_creator_post_migration_settings_unchanged() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let (tick_spacing, fee_rate) = launch.pool_tier();

        assert_eq!(tick_spacing, POOL_TICK_SPACING);
        assert_eq!(fee_rate, POOL_FEE_RATE);
        assert_eq!(launch.lp_fee_split(), default_fee_split());
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun later_setter_calls_replace_earlier_settings() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        let routes = blast_fun::allocation::fee_split(
            bps::new(0),
            bps::new(0),
            bps::new(0),
            vector[blast_fun::allocation::route(LAUNCHER, bps::new(10_000))],
        );
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET * 2);
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(external_plan());
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());
        initializer.set_lp_fee_split(routes);
        let launch = f.finalize_launch(initializer);

        launch.assert_snapshot();
        assert_eq!(launch.lp_fee_split(), routes);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ELaunchSettingsIncomplete, location = blast_fun::launch)]
fun finalize_requires_a_graduation_target() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());
        let launch = f.finalize_launch(initializer);

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ELaunchSettingsIncomplete, location = blast_fun::launch)]
fun finalize_requires_an_allocation_plan() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_lp_fee_split(default_fee_split());
        let launch = f.finalize_launch(initializer);

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ELaunchSettingsIncomplete, location = blast_fun::launch)]
fun finalize_requires_lp_fee_split() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());
        let launch = f.finalize_launch(initializer);

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitness,
        location = blast_fun::launch,
    ),
]
fun only_the_starting_adapter_borrows_the_treasury_cap() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.treasury_cap_mut(OTHER_MIGRATION_WITNESS());

        destroy(initializer);
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
fun an_unadmitted_adapter_cannot_start_a_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let initializer = f.start_launch<TEST_QUOTE, _>(ticket, OTHER_MIGRATION_WITNESS());

        destroy(initializer);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun starting_checks_the_quote_before_finalize_checks_the_symbol() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(over_length_symbol());
        let launch = f.intake<OTHER_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun buy_and_sell_all_bought_meme_move_exact_coins_and_accounting() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(LAUNCHER);
        let mut launch = f.open_launch(launch);
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);
        let quote_in_gross = 10_000_000;
        let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            quote_in_gross,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(quote_in_gross, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            meme_out_net,
            &f.clock,
            f.ctx!(),
        );

        assert_eq!(meme_bought.value(), meme_out_net);
        assert_eq!(quote_refund.value(), 0);
        let bought = events::collect_one<events::Bought>(0);
        let (
            protocol_meme_fee,
            creator_meme_fee,
            protocol_quote_fee,
            creator_quote_fee,
        ) = launch.fee_totals_for_testing();
        assert_eq!(
            bcs::to_bytes(&bought),
            bought_bytes(
                object::id(&launch),
                quote_in_gross,
                meme_out_gross,
                protocol_meme_fee,
                creator_meme_fee,
                protocol_quote_fee,
                creator_quote_fee,
                EXPECTED_CURVE_MEME - meme_out_gross,
                quote_in_gross - quote_fee,
            ),
        );

        let meme_in_gross = meme_out_net;
        let (meme_reserve_after_buy, real_quote_after_buy, _, _) = launch.balances_for_testing();
        let (
            sell_meme_fee,
            pending_burn_delta,
            quote_out_gross,
            sell_quote_fee,
            quote_out_net,
        ) = curve::quote_sell(
            meme_reserve_after_buy,
            real_quote_after_buy,
            VIRTUAL_QUOTE,
            meme_in_gross,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
            bps::new(SELL_BURN_BPS),
        );
        let quote_out = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme_bought,
            quote_out_net,
            f.ctx!(),
        );

        assert_eq!(quote_out.value(), quote_out_net);
        let sold = events::collect_one<events::Sold>(0);
        let (
            protocol_meme_total,
            creator_meme_total,
            protocol_quote_total,
            creator_quote_total,
        ) = launch.fee_totals_for_testing();
        let mut expected_sold = bcs::to_bytes(&object::id(&launch));
        expected_sold.append(bcs::to_bytes(&meme_in_gross));
        expected_sold.append(bcs::to_bytes(&pending_burn_delta));
        expected_sold.append(bcs::to_bytes(&pending_burn_delta));
        expected_sold.append(bcs::to_bytes(&quote_out_gross));
        expected_sold.append(bcs::to_bytes(&(protocol_meme_total - protocol_meme_fee)));
        expected_sold.append(bcs::to_bytes(&(creator_meme_total - creator_meme_fee)));
        expected_sold.append(bcs::to_bytes(&(protocol_quote_total - protocol_quote_fee)));
        expected_sold.append(bcs::to_bytes(&(creator_quote_total - creator_quote_fee)));
        expected_sold.append(
            bcs::to_bytes(
                &(meme_reserve_after_buy + meme_in_gross - sell_meme_fee - pending_burn_delta),
            ),
        );
        expected_sold.append(bcs::to_bytes(&(real_quote_after_buy - quote_out_gross)));
        assert_eq!(bcs::to_bytes(&sold), expected_sold);

        let (meme_reserve, real_quote, pending_burn, _) = launch.balances_for_testing();
        assert_eq!(
            meme_reserve,
            meme_reserve_after_buy + meme_in_gross - sell_meme_fee - pending_burn_delta,
        );
        assert_eq!(real_quote, real_quote_after_buy - quote_out_gross);
        assert_eq!(pending_burn, pending_burn_delta);

        let (
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
        ) = launch.fee_totals_for_testing();
        assert_eq!(protocol_meme, 0);
        assert_eq!(protocol_quote, 0);
        assert_eq!(creator_meme, meme_fee + sell_meme_fee);
        assert_eq!(creator_quote, quote_fee + sell_quote_fee);

        let (claimed_meme, claimed_quote) = launch.claim_creator_fees(
            &f.package_version,
            &creator_cap,
            f.ctx!(),
        );
        assert_eq!(claimed_meme.value(), creator_meme);
        assert_eq!(claimed_quote.value(), creator_quote);
        let (
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
        ) = launch.fee_totals_for_testing();
        assert_eq!(protocol_meme, 0);
        assert_eq!(creator_meme, 0);
        assert_eq!(protocol_quote, 0);
        assert_eq!(creator_quote, 0);

        destroy(creator_cap);
        destroy(quote_refund);
        destroy(quote_out);
        destroy(claimed_meme);
        destroy(claimed_quote);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun zero_launch_trade_fees_sell_all_bought_meme_without_fee_balances() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_trade_fees(&f.package_version, &admin_witness, bps::new(0), bps::new(0));
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );
        let quote_out = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme_bought,
            1,
            f.ctx!(),
        );

        assert!(quote_out.value() > 0);
        let (
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
        ) = launch.fee_totals_for_testing();
        assert_eq!(protocol_meme, 0);
        assert_eq!(creator_meme, 0);
        assert_eq!(protocol_quote, 0);
        assert_eq!(creator_quote, 0);

        destroy(quote_refund);
        destroy(quote_out);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun creator_claim_returns_trade_fees_as_composable_coins() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );
        let (_, creator_meme_before, _, creator_quote_before) = launch.fee_totals_for_testing();
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &creator_cap,
            f.ctx!(),
        );

        assert_eq!(meme_fees.value(), creator_meme_before);
        assert_eq!(quote_fees.value(), creator_quote_before);
        let claimed = events::collect_one<events::CreatorFeesClaimed>(0);
        assert_eq!(
            bcs::to_bytes(&claimed),
            fee_claim_bytes(object::id(&launch), creator_meme_before, creator_quote_before),
        );

        destroy(creator_cap);
        destroy(meme_bought);
        destroy(quote_refund);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun live_protocol_share_routes_and_claims_launch_trade_fees() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f
            .runtime_config
            .set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(2_500));
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );
        let (
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
        ) = launch.fee_totals_for_testing();

        assert!(protocol_meme > 0);
        assert!(creator_meme > protocol_meme);
        assert!(protocol_quote > 0);
        assert!(creator_quote > protocol_quote);

        let (meme_fees, quote_fees) = launch.claim_protocol_fees(
            &f.package_version,
            &admin_witness,
            f.ctx!(),
        );
        assert_eq!(meme_fees.value(), protocol_meme);
        assert_eq!(quote_fees.value(), protocol_quote);

        let claimed = events::collect_one<events::ProtocolFeesClaimed>(0);
        assert_eq!(
            bcs::to_bytes(&claimed),
            fee_claim_bytes(object::id(&launch), protocol_meme, protocol_quote),
        );

        destroy(meme_bought);
        destroy(quote_refund);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun fixed_migration_sends_terminal_disposal_to_zero_without_reducing_supply() {
    let mut fixture = start();
    let expected_disposed_meme;

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );
        let ready = launch.is_migration_ready();
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();
        let bought = events::collect_one<events::Bought>(0);
        let quote_in_gross = 30_000_000 - quote_refund.value();
        let (_, meme_out_gross, _, _) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            quote_in_gross,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (
            protocol_meme_fee,
            creator_meme_fee,
            protocol_quote_fee,
            creator_quote_fee,
        ) = launch.fee_totals_for_testing();

        assert!(ready);
        assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
        assert!(quote_refund.value() > 0);
        assert_eq!(
            bcs::to_bytes(&bought),
            bought_bytes(
                object::id(&launch),
                quote_in_gross,
                meme_out_gross,
                protocol_meme_fee,
                creator_meme_fee,
                protocol_quote_fee,
                creator_quote_fee,
                meme_reserve,
                real_quote,
            ),
        );
        destroy(meme_bought);
        destroy(quote_refund);
        launch.put_back();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let (meme_reserve, _, pending_burn, _) = launch.balances_for_testing();
        let (meme, quote) = f.mock_atomic_migration(&mut launch, &mut currency);
        let migrated = launch.is_migrated();
        let migration = events::collect_one<events::Migrated>(0);
        let disposed_meme = meme_reserve + pending_burn;

        assert!(migrated);
        assert_eq!(meme.value(), EXPECTED_POOL_MEME);
        assert!(disposed_meme > 0);
        assert_eq!(currency.total_supply().destroy_some(), initial_supply);
        assert_eq!(
            bcs::to_bytes(&migration),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                disposed_meme,
                false,
                initial_supply,
            ),
        );
        expected_disposed_meme = disposed_meme;
        assert_eq!(
            bcs::to_bytes(&events::collect_one<events::MigrationAllocationPaid>(0)),
            allocation_paid_bytes(object::id(&launch), 1, PROTOCOL_ADMIN, EXPECTED_PROTOCOL_MEME, 625_000),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.next_tx!(@0x0, |f| {
        let disposal = f.take_fixed_disposal();

        assert_eq!(disposal.value(), expected_disposed_meme);
        destroy(disposal);
    });

    fixture.end();
}

#[test]
fun burn_only_migration_destroys_terminal_disposal_from_native_supply() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );

        destroy(meme_bought);
        destroy(quote_refund);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let (meme_reserve, _, pending_burn, _) = launch.balances_for_testing();
        let (meme, quote) = f.mock_atomic_migration(&mut launch, &mut currency);
        let migration = events::collect_one<events::Migrated>(0);
        let disposed_meme = meme_reserve + pending_burn;

        assert_eq!(currency.total_supply().destroy_some(), initial_supply - disposed_meme);
        assert_eq!(
            bcs::to_bytes(&migration),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                disposed_meme,
                true,
                initial_supply - disposed_meme,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun fixed_migration_sends_accumulated_sell_burn_to_zero_address() {
    let mut fixture = start();
    let expected_disposed_meme;

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();

        expected_disposed_meme =
            launch.reach_migration_after_sell(
                &f.package_version,
                &f.runtime_config,
                &f.clock,
                f.ctx!(),
            );
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let (meme_reserve, _, pending_burn, _) = launch.balances_for_testing();
        let (meme, quote) = f.mock_atomic_migration(&mut launch, &mut currency);
        let migration = events::collect_one<events::Migrated>(0);

        assert_eq!(meme_reserve + pending_burn, expected_disposed_meme);
        assert_eq!(currency.total_supply().destroy_some(), initial_supply);
        assert_eq!(
            bcs::to_bytes(&migration),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                expected_disposed_meme,
                false,
                initial_supply,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.next_tx!(@0x0, |f| {
        let disposal = f.take_fixed_disposal();

        assert_eq!(disposal.value(), expected_disposed_meme);
        destroy(disposal);
    });

    fixture.end();
}

#[test]
fun burn_only_migration_burns_accumulated_sell_burn_from_native_supply() {
    let mut fixture = start();
    let expected_disposed_meme;

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();

        expected_disposed_meme =
            launch.reach_migration_after_sell(
                &f.package_version,
                &f.runtime_config,
                &f.clock,
                f.ctx!(),
            );
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let (meme_reserve, _, pending_burn, _) = launch.balances_for_testing();
        let (meme, quote) = f.mock_atomic_migration(&mut launch, &mut currency);
        let migration = events::collect_one<events::Migrated>(0);

        assert_eq!(meme_reserve + pending_burn, expected_disposed_meme);
        assert_eq!(currency.total_supply().destroy_some(), initial_supply - expected_disposed_meme);
        assert_eq!(
            bcs::to_bytes(&migration),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                expected_disposed_meme,
                true,
                initial_supply - expected_disposed_meme,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun threshold_crossing_buy_closes_sell_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );
        destroy(quote_refund);
        let quote_out = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme_bought,
            0,
            f.ctx!(),
        );

        destroy(quote_out);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun threshold_crossing_buy_closes_another_buy_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let terminal_quote = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            terminal_quote,
            1,
            &f.clock,
            f.ctx!(),
        );
        destroy(meme_bought);
        destroy(quote_refund);

        let zero_quote = coin::mint_for_testing<TEST_QUOTE>(0, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            zero_quote,
            0,
            &f.clock,
            f.ctx!(),
        );

        destroy(meme_bought);
        destroy(quote_refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun migration_rejects_a_live_launch_before_witness_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let (meme, quote, migration) = launch.begin_migration(
            &f.package_version,
            OTHER_MIGRATION_WITNESS(),
        );
        destroy(meme);
        destroy(quote);
        destroy(migration);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun migration_cannot_be_repeated_after_terminal_disposal() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );

        destroy(meme_bought);
        destroy(quote_refund);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (meme, quote) = f.mock_atomic_migration(&mut launch, &mut currency);

        destroy(meme);
        destroy(quote);

        let (meme, quote, migration) = launch.begin_migration(
            &f.package_version,
            TEST_MIGRATION_WITNESS(),
        );
        destroy(meme);
        destroy(quote);
        destroy(migration);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun buy_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (_, _, _, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            meme_out_net + 1,
            &f.clock,
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote_refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun sell_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );
        destroy(quote_refund);
        let meme_in_gross = meme.value();
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();
        let (_, _, _, _, quote_out_net) = curve::quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            meme_in_gross,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
            bps::new(SELL_BURN_BPS),
        );
        let quote = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme,
            quote_out_net + 1,
            f.ctx!(),
        );

        destroy(quote);
        destroy(launch);
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
fun stale_package_version_aborts_before_zero_trade_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        f.package_version.set_for_testing(2);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(0, f.ctx!());
        let (meme, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            0,
            &f.clock,
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote_refund);
        destroy(launch);
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
fun stale_package_version_aborts_migration_before_lifecycle_and_witness_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.package_version.set_for_testing(2);
        let (meme, quote, migration) = launch.begin_migration(
            &f.package_version,
            OTHER_MIGRATION_WITNESS(),
        );
        destroy(meme);
        destroy(quote);
        destroy(migration);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitness,
        location = blast_fun::launch,
    ),
]
fun migration_rejects_a_witness_type_not_stored_at_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        f.share_launch(launch);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );

        destroy(meme_bought);
        destroy(quote_refund);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let (meme, quote, migration) = launch.begin_migration(
            &f.package_version,
            OTHER_MIGRATION_WITNESS(),
        );
        destroy(meme);
        destroy(quote);
        destroy(migration);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun admin_reassigns_claimed_creator_and_the_new_cap_claims_prior_fees() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            1,
            &f.clock,
            f.ctx!(),
        );

        transfer::public_transfer(creator_cap, CREATOR);
        destroy(meme_bought);
        destroy(quote_refund);
        launch.put_back();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut launch = f.take_launch();
        let admin_witness = f.sign_in();
        let retired_creator_cap_id = launch.curve_fee_cap_id_for_testing();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        let reassigned = events::collect_one<events::CurveFeeCapReassigned>(0);
        let creator_cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert!(retired_creator_cap_id.is_some());
        assert!(retired_creator_cap_id != option::some(creator_cap_id));
        assert_eq!(
            bcs::to_bytes(&reassigned),
            cap_reassigned_bytes(
                object::id(&launch),
                retired_creator_cap_id,
                creator_cap_id,
                NEW_CREATOR,
            ),
        );

        launch.put_back();
    });

    fixture.next_tx!(NEW_CREATOR, |f| {
        let mut launch = f.take_launch();
        let creator_cap = f.take_curve_fee_cap();
        let (_, creator_meme, _, creator_quote) = launch.fee_totals_for_testing();
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &creator_cap,
            f.ctx!(),
        );

        assert!(creator_meme > 0 && creator_quote > 0);
        assert_eq!(meme_fees.value(), creator_meme);
        assert_eq!(quote_fees.value(), creator_quote);

        destroy(creator_cap);
        destroy(meme_fees);
        destroy(quote_fees);
        launch.put_back();
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::ECurveFeeCapNotLive,
        location = blast_fun::launch,
    ),
]
fun retired_creator_cap_is_rejected_before_the_empty_fee_ledger_check() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &creator_cap,
            f.ctx!(),
        );

        destroy(creator_cap);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun admin_reassigns_an_unclaimed_creator_and_removes_the_pending_claim() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        let reassigned = events::collect_one<events::CurveFeeCapReassigned>(0);
        let creator_cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert!(!launch.has_creator_authority_for_testing());
        assert_eq!(
            bcs::to_bytes(&reassigned),
            cap_reassigned_bytes(object::id(&launch), option::none(), creator_cap_id, NEW_CREATOR),
        );

        destroy(launch);
    });

    fixture.next_tx!(NEW_CREATOR, |f| {
        assert!(f.has_curve_fee_cap());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::ECreatorAuthorityUnavailable,
        location = blast_fun::launch,
    ),
]
fun reassignment_prevents_the_original_recipient_from_claiming() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let (creator_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(metadata_cap);

        destroy(creator_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidCreatorRecipient,
        location = blast_fun::launch,
    ),
]
fun reassignment_rejects_the_zero_recipient() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, @0x0, f.ctx!());

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EAdminRoleNotGranted,
        location = blast_admin::acl,
    ),
]
fun reassignment_requires_the_creator_admin_role() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let (authority, admin_cap) = f.new_role_less_admin();
        let admin_witness = authority.sign_in(&admin_cap);

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        destroy(authority);
        destroy(admin_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun metadata_cap_holder_updates_coin_metadata_through_the_launch() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let native_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Renamed Launch".to_string(),
        );

        let updated = events::collect_one<events::MemeMetadataUpdated>(0);
        let mut expected = bcs::to_bytes(&object::id(&launch));
        expected.append(bcs::to_bytes(&b"Renamed Launch".to_string()));
        expected.append(bcs::to_bytes(&b"Normalized launch state".to_string()));
        expected.append(bcs::to_bytes(&b"".to_string()));
        assert_eq!(bcs::to_bytes(&updated), expected);

        launch.set_description(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Community owned".to_string(),
        );
        launch.set_icon_url(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"https://blast.fun/icon.png".to_string(),
        );

        assert_eq!(currency.name(), b"Renamed Launch".to_string());
        assert_eq!(currency.description(), b"Community owned".to_string());
        assert_eq!(currency.icon_url(), b"https://blast.fun/icon.png".to_string());
        assert_eq!(launch.metadata_cap_id_for_testing(), native_metadata_cap_id);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EMetadataUnchanged,
        location = blast_fun::launch,
    ),
]
fun metadata_update_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Launch Test".to_string(),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EMetadataCapNotLive,
        location = blast_fun::launch,
    ),
]
fun retired_metadata_cap_is_rejected_before_unchanged_metadata() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        let admin_witness = f.sign_in();

        launch.reassign_metadata_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Launch Test".to_string(),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun holders_destroy_curve_fee_and_metadata_capabilities() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        curve_fee_cap.destroy_curve_fee_cap();
        metadata_cap.destroy_metadata_cap();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun pre_share_buy_reuses_curve_accounting_and_emits_only_its_complete_disclosure() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.clock.set_for_testing(50_000);
        assert!(launch.public_start_ms().is_none());
        assert!(!launch.pre_share_buy_completed());
        let (quote_fee, gross, meme_fee, net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let quote = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme, refund) = launch.pre_share_buy(
            &f.package_version,
            &f.runtime_config,
            quote,
            net,
            f.ctx!(),
        );
        assert_eq!(meme.value(), net);
        assert_eq!(refund.value(), 0);
        assert!(launch.pre_share_buy_completed());
        assert!(launch.public_start_ms().is_none());
        launch.assert_lifecycle(true, false, false);
        let (
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
        ) = launch.fee_totals_for_testing();
        assert_eq!(protocol_meme + creator_meme, meme_fee);
        assert_eq!(protocol_quote + creator_quote, quote_fee);
        let mut expected = bought_bytes(
            object::id(&launch),
            10_000_000,
            gross,
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
            EXPECTED_CURVE_MEME - gross,
            10_000_000 - quote_fee,
        );
        expected.append(u64_bytes(net));
        expected.append(u64_bytes(0));
        assert_eq!(bcs::to_bytes(&events::collect_one<events::PreShareBought>(0)), expected);
        assert!(events::collect<events::Bought>().is_empty());
        transfer::public_transfer(meme, CREATOR);
        refund.destroy_zero();
        f.share_launch(launch);
    });
    fixture.end();
}

#[test]
fun terminal_share_alone_starts_public_time_and_freezes_disclosure() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.clock.set_for_testing(250_000);
        let mut expected = bcs::to_bytes(&object::id(&launch));
        expected.append(u64_bytes(250_000));
        expected.append(bcs::to_bytes(&false));
        launch.share(&f.package_version, &f.clock);
        assert_eq!(bcs::to_bytes(&events::collect_one<events::LaunchShared>(0)), expected);
    });
    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        assert_eq!(launch.public_start_ms(), option::some(250_000));
        assert!(!launch.pre_share_buy_completed());
        let (curve, metadata) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        transfer::public_transfer(curve, CREATOR);
        transfer::public_transfer(metadata, CREATOR);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPreShareBuyAlreadyCompleted, location = blast_fun::launch)]
fun second_pre_share_buy_precedes_zero_input_validation() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pre_buy(&mut launch, 1_000_000, 1);
        f.pre_buy(&mut launch, 0, 0);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ELaunchAlreadyShared, location = blast_fun::launch)]
fun shared_launch_rejects_pre_share_buy_before_zero_input() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.pre_buy(&mut launch, 0, 0);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPreShareBuyWouldGraduate, location = blast_fun::launch)]
fun exact_target_pre_share_buy_aborts_before_custody_changes() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let exact = MIGRATION_QUOTE_TARGET.mul_div_ceil(10_000, 10_000 - QUOTE_FEE_BPS);
        f.pre_buy(&mut launch, exact, 1);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPreShareBuyWouldGraduate, location = blast_fun::launch)]
fun excess_target_pre_share_buy_cannot_commit_a_refund_or_fee() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pre_buy(&mut launch, 30_000_000, 1);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun pre_share_buy_one_atomic_unit_below_target_remains_live() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let exact = MIGRATION_QUOTE_TARGET.mul_div_ceil(10_000, 10_000 - QUOTE_FEE_BPS);
        f.pre_buy(&mut launch, exact - 1, 1);
        let (_, quote, _, _) = launch.balances_for_testing();
        assert_eq!(quote, MIGRATION_QUOTE_TARGET - 1);
        launch.assert_lifecycle(true, false, false);
        f.share_launch(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun pre_share_buy_enforces_the_same_minimum_output() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pre_buy(&mut launch, 1_000_000, INITIAL_MEME_SUPPLY);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun owned_launch_rejects_public_buy_before_zero_input() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let quote = coin::zero<TEST_QUOTE>(f.ctx!());
        let (meme, refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote,
            0,
            &f.clock,
            f.ctx!(),
        );
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun owned_launch_rejects_public_sell_before_zero_input() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let meme = coin::zero<LAUNCH_TESTS>(f.ctx!());
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 0, f.ctx!());
        destroy(quote);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_version_precedes_duplicate_pre_share_buy() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pre_buy(&mut launch, 1_000_000, 1);
        f.package_version.set_for_testing(2);
        f.pre_buy(&mut launch, 0, 0);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun setup_claim_cannot_consume_creator_rights_before_terminal_share() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (curve, metadata) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(curve);
        destroy(metadata);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorAuthorityUnavailable, location = blast_fun::launch)]
fun pre_share_admin_revocation_cannot_strand_wrapped_setup_authority() {
    let mut fixture = start();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let admin = f.sign_in();
        launch.reassign_curve_fee_cap(&f.package_version, &admin, NEW_CREATOR, f.ctx!());
        f.share_launch(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorNotSender, location = blast_fun::creator_authority)]
fun launcher_cannot_claim_another_address_creators_caps() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve, metadata) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(curve);
        destroy(metadata);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ELaunchAlreadyShared, location = blast_fun::launch)]
fun terminal_share_rejects_a_second_share() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let launch = f.open_launch(launch);
        launch.share(&f.package_version, &f.clock);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeInput, location = blast_fun::curve)]
fun first_pre_share_buy_preserves_zero_input_rejection() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pre_buy(&mut launch, 0, 0);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun public_buy_checks_the_version_before_the_shared_state() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.package_version.set_for_testing(2);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(1_000, f.ctx!());
        let (meme, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            0,
            &f.clock,
            f.ctx!(),
        );
        destroy(meme);
        destroy(quote_refund);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeInput, location = blast_fun::curve)]
fun public_buy_checks_the_curve_before_slippage() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(0, f.ctx!());
        let (meme, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            quote_in,
            std::u64::max_value!(),
            &f.clock,
            f.ctx!(),
        );
        destroy(meme);
        destroy(quote_refund);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun setup_claim_checks_version_before_wrong_sender() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.package_version.set_for_testing(2);
        let (curve, metadata) = launch.claim_creator_caps(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        destroy(curve);
        destroy(metadata);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun launches_choose_their_own_graduation_target() {
    let mut fixture = start();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_launch_at_target(CREATOR, MIGRATION_QUOTE_TARGET * 3);
        assert_eq!(launch.graduation_target(), MIGRATION_QUOTE_TARGET * 3);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun smallest_target_that_leaves_liquidity_quote_is_accepted() {
    let mut fixture = start();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        // Protocol takes ceil(2 * 250 / 10_000) = 1 and the liquidity channel keeps 1.
        let launch = f.new_launch_at_target(CREATOR, 2);
        assert_eq!(launch.graduation_target(), 2);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidGraduationTarget, location = blast_fun::launch)]
fun target_that_rounds_the_liquidity_quote_to_zero_is_rejected() {
    let mut fixture = start();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        // One atomic unit is taken entirely by the protected protocol share.
        destroy(f.new_launch_at_target(CREATOR, 1));
    });
    fixture.end();
}

// === Test Helpers ===

fun pre_buy(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
    amount: u64,
    min: u64,
) {
    let quote = coin::mint_for_testing<TEST_QUOTE>(amount, self.scenario.ctx());
    let (meme, refund) = launch.pre_share_buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        min,
        self.scenario.ctx(),
    );
    transfer::public_transfer(meme, CREATOR);
    transfer::public_transfer(refund, LAUNCHER);
}

/// Serializes one protocol constant by value, so no test borrows a constant in place.
fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

macro fun launch_next_tx(
    $fixture: &mut LaunchFixture,
    $sender: address,
    $fn: |&mut LaunchFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun launch_ctx($fixture: &mut LaunchFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun default_plan(): blast_fun::allocation::AllocationPlan {
    blast_fun::allocation::new(
        vector[
            blast_fun::allocation::channel(
                1,
                blast_fun::allocation::protocol_role(),
                PROTOCOL_ADMIN,
            ),
            blast_fun::allocation::channel(2, blast_fun::allocation::liquidity_role(), LAUNCHER),
        ],
        vector[
            blast_fun::allocation::weight(0, bps::new(7_250)),
            blast_fun::allocation::weight(1, bps::new(PROTOCOL_MEME_GRADUATION_FEE_BPS)),
            blast_fun::allocation::weight(2, bps::new(MEME_LIQUIDITY_PROVISION_BPS)),
        ],
        vector[
            blast_fun::allocation::weight(1, bps::new(PROTOCOL_QUOTE_MIGRATION_FEE_BPS)),
            blast_fun::allocation::weight(2, bps::new(9_750)),
        ],
    )
}

fun external_plan(): blast_fun::allocation::AllocationPlan {
    let base = default_plan();
    let mut channels = *base.channels();
    channels.push_back(
        blast_fun::allocation::channel(3, blast_fun::allocation::external_role(), CREATOR),
    );
    channels.push_back(
        blast_fun::allocation::channel(4, blast_fun::allocation::external_role(), CREATOR),
    );
    blast_fun::allocation::new(
        channels,
        vector[
            blast_fun::allocation::weight(0, bps::new(7_000)),
            blast_fun::allocation::weight(1, bps::new(750)),
            blast_fun::allocation::weight(2, bps::new(2_000)),
            blast_fun::allocation::weight(4, bps::new(250)),
        ],
        vector[
            blast_fun::allocation::weight(1, bps::new(250)),
            blast_fun::allocation::weight(2, bps::new(9_000)),
            blast_fun::allocation::weight(3, bps::new(750)),
        ],
    )
}

fun maximum_plan(): blast_fun::allocation::AllocationPlan {
    let base = default_plan();
    let mut channels = *base.channels();
    let mut meme = vector[
        blast_fun::allocation::weight(0, bps::new(7_236)),
        blast_fun::allocation::weight(1, bps::new(750)),
        blast_fun::allocation::weight(2, bps::new(2_000)),
    ];
    let mut quote = vector[
        blast_fun::allocation::weight(1, bps::new(250)),
        blast_fun::allocation::weight(2, bps::new(9_736)),
    ];
    14u64.do!(|i| {
        channels.push_back(
            blast_fun::allocation::channel(i + 3, blast_fun::allocation::external_role(), CREATOR),
        );
        meme.push_back(blast_fun::allocation::weight(i + 3, bps::new(1)));
        quote.push_back(blast_fun::allocation::weight(i + 3, bps::new(1)));
    });
    blast_fun::allocation::new(channels, meme, quote)
}

fun start(): LaunchFixture {
    let mut scenario = test_scenario::begin(@0x0);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::creator_admin_role(),
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    launch_config::init_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let mut config = scenario.take_shared<launch_config::LaunchConfig>();
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&package_version, &admin_witness, VIRTUAL_QUOTE);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(
        &package_version,
        &admin_witness,
    );
    config.set_trade_fees(
        &package_version,
        &admin_witness,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
    );
    config.set_protocol_allocation(
        &package_version,
        &admin_witness,
        1,
        PROTOCOL_ADMIN,
        bps::new(PROTOCOL_MEME_GRADUATION_FEE_BPS),
        bps::new(PROTOCOL_QUOTE_MIGRATION_FEE_BPS),
    );

    LaunchFixture {
        scenario,
        package_version,
        authority,
        admin_cap,
        config,
        runtime_config,
        clock,
    }
}

fun launch_new_ticket(
    self: &mut LaunchFixture,
    creator: address,
): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with_mode(creator, false)
}

fun launch_new_ticket_with_mode(
    self: &mut LaunchFixture,
    creator: address,
    burnable: bool,
): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with_decimals(creator, burnable, MEME_DECIMALS)
}

fun launch_new_ticket_with_decimals(
    self: &mut LaunchFixture,
    creator: address,
    burnable: bool,
    decimals: u8,
): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with(creator, burnable, decimals, b"LAUNCH")
}

/// A Meme symbol one byte over the launch intake bound.
fun over_length_symbol(): vector<u8> {
    let mut symbol = MAX_LENGTH_SYMBOL;
    symbol.push_back(b"X"[0]);
    symbol
}

fun launch_new_ticket_with_symbol(
    self: &mut LaunchFixture,
    symbol: vector<u8>,
): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with(CREATOR, false, MEME_DECIMALS, symbol)
}

fun launch_new_ticket_with(
    self: &mut LaunchFixture,
    creator: address,
    burnable: bool,
    decimals: u8,
    symbol: vector<u8>,
): LaunchTicket<LAUNCH_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_TESTS>(),
        decimals,
        symbol.to_string(),
        b"Launch Test".to_string(),
        b"Normalized launch state".to_string(),
        b"".to_string(),
        creator_authority::new_address(creator),
        burnable,
        SELL_BURN_BPS,
        self.scenario.ctx(),
    )
}

/// Live administration holding every role except the creator-admin role.
fun new_role_less_admin(
    self: &mut LaunchFixture,
): (Authority<BLAST_FUN_DOMAIN>, AdminCap<BLAST_FUN_DOMAIN>) {
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(self.scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::package_admin_role(),
        ROLE_LESS_ADMIN,
        self.scenario.ctx(),
    );
    destroy(super_admin_cap);
    self.scenario.next_tx(ROLE_LESS_ADMIN);
    let admin_cap = self.scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    (authority, admin_cap)
}

fun launch_sign_in(self: &LaunchFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun default_fee_split(): blast_fun::allocation::FeeSplit {
    blast_fun::allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), vector[])
}

fun share_launch(self: &LaunchFixture, launch: Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    launch.share(&self.package_version, &self.clock);
}

fun new_launch_at_target(
    self: &mut LaunchFixture,
    creator: address,
    target: u64,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket(creator);
    self.intake<TEST_QUOTE, _>(
        ticket,
        TEST_MIGRATION_WITNESS(),
        target,
        default_plan(),
    )
}

fun open_launch(
    self: &mut LaunchFixture,
    launch: Launch<LAUNCH_TESTS, TEST_QUOTE>,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let sender = self.scenario.ctx().sender();
    self.share_launch(launch);
    self.scenario.next_tx(sender);
    self.take_launch()
}

fun new_default_launch(
    self: &mut LaunchFixture,
    creator: address,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket(creator);
    self.intake(ticket, TEST_MIGRATION_WITNESS(), MIGRATION_QUOTE_TARGET, default_plan())
}

fun take_destination_quote(self: &LaunchFixture): Coin<TEST_QUOTE> {
    self.scenario.take_from_sender()
}

fun take_destination_meme(self: &LaunchFixture): Coin<LAUNCH_TESTS> {
    self.scenario.take_from_sender()
}

fun complete_migration(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
) {
    let mut currency = self.take_currency();
    let (meme, quote) = self.mock_atomic_migration(launch, &mut currency);
    destroy(meme);
    destroy(quote);
    destroy(currency);
}

/// Sealed provider-neutral mock adapter: the whole principal enters a mock position with no residual.
fun mock_atomic_migration(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
    currency: &mut Currency<LAUNCH_TESTS>,
): (Balance<LAUNCH_TESTS>, Balance<TEST_QUOTE>) {
    let (meme, quote, migration) = launch.begin_migration(
        &self.package_version,
        TEST_MIGRATION_WITNESS(),
    );
    let vault = MockMigrationVault {
        id: object::new(self.scenario.ctx()),
        supplied_meme: meme,
        supplied_quote: quote,
        residual_meme: balance::zero(),
        residual_quote: balance::zero(),
    };
    launch.complete_migration(
        &self.package_version,
        currency,
        migration,
        TEST_MIGRATION_WITNESS(),
        vault.supplied_meme.value(),
        vault.supplied_quote.value(),
        &vault.residual_meme,
        &vault.residual_quote,
        1,
        self.scenario.ctx(),
    );
    let MockMigrationVault {
        id,
        supplied_meme: meme,
        supplied_quote: quote,
        residual_meme,
        residual_quote,
    } = vault;
    id.delete();
    residual_meme.destroy_zero();
    residual_quote.destroy_zero();
    (meme, quote)
}

/// A two-unit target: the one-BPS external Quote share and the LP Meme still round to positive
/// amounts, but the external channel rounds to nothing in both assets.
fun open_dust_target_launch(self: &mut LaunchFixture) {
    let base = default_plan();
    let mut channels = *base.channels();
    channels.push_back(
        blast_fun::allocation::channel(3, blast_fun::allocation::external_role(), CREATOR),
    );
    let plan = blast_fun::allocation::new(
        channels,
        *base.meme_weights(),
        vector[
            blast_fun::allocation::weight(1, bps::new(250)),
            blast_fun::allocation::weight(2, bps::new(9_749)),
            blast_fun::allocation::weight(3, bps::new(1)),
        ],
    );
    let ticket = self.new_ticket(CREATOR);
    let launch = self.intake<TEST_QUOTE, _>(
        ticket,
        TEST_MIGRATION_WITNESS(),
        2,
        plan,
    );
    self.share_launch(launch);
    self.scenario.next_tx(LAUNCHER);
    let mut launch = self.take_launch();
    let quote = coin::mint_for_testing<TEST_QUOTE>(10, self.scenario.ctx());
    let (meme, refund) = launch.buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        1,
        &self.clock,
        self.scenario.ctx(),
    );
    destroy(meme);
    destroy(refund);
    launch.put_back();
}

/// Starts the launch for `witness`, sets the target, plan, and default fee split, and finalizes it
/// unprotected.
fun launch_intake<Quote, MigrationWitness: drop>(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
    witness: MigrationWitness,
    target: u64,
    plan: blast_fun::allocation::AllocationPlan,
): Launch<LAUNCH_TESTS, Quote> {
    let mut initializer = self.start_launch<Quote, _>(ticket, witness);
    initializer.set_graduation_target(target);
    initializer.set_allocation_plan(plan);
    initializer.set_lp_fee_split(default_fee_split());
    self.finalize_launch(initializer)
}

/// Starts construction at the fixture tier in the next transaction, once the Coin Registry holds
/// the ticket's currency.
fun launch_start<Quote, MigrationWitness: drop>(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
    witness: MigrationWitness,
): LaunchInitializer<LAUNCH_TESTS, Quote> {
    let sender = self.scenario.sender();
    self.scenario.next_tx(sender);
    launch::new(
        ticket,
        &self.package_version,
        &self.config,
        witness,
        POOL_TICK_SPACING,
        POOL_FEE_RATE,
    )
}

/// Finalizes construction against the registered currency.
fun launch_finalize<Quote>(
    self: &mut LaunchFixture,
    initializer: LaunchInitializer<LAUNCH_TESTS, Quote>,
): Launch<LAUNCH_TESTS, Quote> {
    let mut currency = self.take_currency();
    let launch = initializer.finalize(
        &self.package_version,
        &mut currency,
        &self.config,
        self.scenario.ctx(),
    );
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

/// The one-time-witness path delivers the currency to the Coin Registry address.
fun launch_take_currency(self: &LaunchFixture): Currency<LAUNCH_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun launch_take_fixed_disposal(self: &LaunchFixture): Coin<LAUNCH_TESTS> {
    self.scenario.take_from_address(@0x0)
}

fun launch_take_shared(self: &LaunchFixture): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    self.scenario.take_shared<Launch<LAUNCH_TESTS, TEST_QUOTE>>()
}

fun launch_take_curve_fee_cap(
    self: &LaunchFixture,
): creator_authority::CurveFeeCap<LAUNCH_TESTS> {
    self.scenario.take_from_sender<creator_authority::CurveFeeCap<LAUNCH_TESTS>>()
}

fun launch_has_curve_fee_cap(self: &LaunchFixture): bool {
    self
        .scenario
        .has_most_recent_for_sender<creator_authority::CurveFeeCap<LAUNCH_TESTS>>()
}

/// Returns a taken launch to shared storage for a later transaction.
fun launch_put_back(launch: Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    test_scenario::return_shared(launch);
}

fun assert_launch_snapshot(launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let (curve_meme, real_quote, pending_burn, allocated_meme) = launch.balances_for_testing();
    let (quote_fee_bps, meme_fee_bps) = launch.policy_for_testing();

    assert_eq!(curve_meme, EXPECTED_CURVE_MEME);
    assert_eq!(real_quote, 0);
    assert_eq!(pending_burn, 0);
    assert_eq!(allocated_meme, EXPECTED_PROTOCOL_MEME + EXPECTED_POOL_MEME);
    assert_eq!(launch.virtual_quote(), VIRTUAL_QUOTE);
    assert_eq!(launch.graduation_target(), MIGRATION_QUOTE_TARGET);
    assert_eq!(quote_fee_bps, QUOTE_FEE_BPS);
    assert_eq!(meme_fee_bps, MEME_FEE_BPS);
    assert_eq!(bcs::to_bytes(launch.allocation_plan()), bcs::to_bytes(&default_plan()));
    assert_eq!(
        launch.migration_witness(),
        type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );
}

fun assert_launch_lifecycle(
    launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>,
    live: bool,
    migration_ready: bool,
    migrated: bool,
) {
    assert_eq!(launch.is_live(), live);
    assert_eq!(launch.is_migration_ready(), migration_ready);
    assert_eq!(launch.is_migrated(), migrated);
}

/// Expected `LaunchTicketCreated` bytes for a fixture ticket designating `CREATOR` by address.
fun ticket_created_bytes(ticket_id: ID, metadata_cap_id: ID, burnable: bool): vector<u8> {
    let mut expected = bcs::to_bytes(&ticket_id);
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LAUNCH_TESTS>()));
    let meme_decimals = MEME_DECIMALS;
    expected.append(bcs::to_bytes(&meme_decimals));
    expected.append(u64_bytes(INITIAL_MEME_SUPPLY));
    expected.append(bcs::to_bytes(&metadata_cap_id));
    expected.append(bcs::to_bytes(&option::some(CREATOR)));
    expected.append(bcs::to_bytes(&option::none<vector<u8>>()));
    expected.append(bcs::to_bytes(&burnable));
    expected.append(u64_bytes(SELL_BURN_BPS));
    expected
}

/// Expected `LaunchCreated` bytes for the fixture's cold policy and canonical partition.
fun launch_created_bytes(launch_id: ID, ticket_id: ID): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&ticket_id));
    let meme_decimals = MEME_DECIMALS;
    expected.append(bcs::to_bytes(&meme_decimals));
    expected.append(u64_bytes(INITIAL_MEME_SUPPLY));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TEST_QUOTE>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TEST_MIGRATION_WITNESS>()));
    let pool_tick_spacing = POOL_TICK_SPACING;
    expected.append(bcs::to_bytes(&pool_tick_spacing));
    expected.append(u64_bytes(POOL_FEE_RATE));
    expected.append(bcs::to_bytes(&default_fee_split()));
    expected.append(u64_bytes(VIRTUAL_QUOTE));
    expected.append(u64_bytes(MIGRATION_QUOTE_TARGET));
    expected.append(u64_bytes(QUOTE_FEE_BPS));
    expected.append(u64_bytes(MEME_FEE_BPS));
    expected.append(bcs::to_bytes(&default_plan()));
    expected.append(
        bcs::to_bytes(&vector[EXPECTED_CURVE_MEME, EXPECTED_PROTOCOL_MEME, EXPECTED_POOL_MEME]),
    );
    expected
}

/// Expected `MigrationAllocationPaid` bytes.
fun allocation_paid_bytes(
    launch_id: ID,
    channel_id: u64,
    destination: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(u64_bytes(channel_id));
    expected.append(bcs::to_bytes(&destination));
    expected.append(u64_bytes(meme));
    expected.append(u64_bytes(quote));
    expected
}

/// Expected `Bought` bytes: trade amounts, the four ledger deltas, then both reserves after.
fun bought_bytes(
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    meme_reserve: u64,
    real_quote_reserve: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&quote_in));
    expected.append(bcs::to_bytes(&meme_out_gross));
    expected.append(bcs::to_bytes(&protocol_meme_fee_delta));
    expected.append(bcs::to_bytes(&creator_meme_fee_delta));
    expected.append(bcs::to_bytes(&protocol_quote_fee_delta));
    expected.append(bcs::to_bytes(&creator_quote_fee_delta));
    expected.append(bcs::to_bytes(&meme_reserve));
    expected.append(bcs::to_bytes(&real_quote_reserve));
    expected
}

/// Expected `Migrated` bytes for the fixture mock: the whole principal is supplied, nothing is
/// residual, and the mock position reports one unit of liquidity.
fun migrated_bytes(
    launch_id: ID,
    migration_meme: u64,
    migration_quote: u64,
    disposed_meme: u64,
    native_supply_burned: bool,
    total_supply_after: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&migration_meme));
    expected.append(bcs::to_bytes(&migration_quote));
    expected.append(u64_bytes(0));
    expected.append(u64_bytes(0));
    expected.append(bcs::to_bytes(&1u128));
    expected.append(bcs::to_bytes(&disposed_meme));
    expected.append(bcs::to_bytes(&native_supply_burned));
    expected.append(bcs::to_bytes(&total_supply_after));
    expected
}

/// Expected bytes shared by `CreatorFeesClaimed` and `ProtocolFeesClaimed`.
fun fee_claim_bytes(launch_id: ID, meme_amount: u64, quote_amount: u64): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&meme_amount));
    expected.append(bcs::to_bytes(&quote_amount));
    expected
}

/// Expected bytes shared by `CurveFeeCapReassigned` and `MetadataCapReassigned`.
fun cap_reassigned_bytes(
    launch_id: ID,
    revoked_cap_id: Option<ID>,
    cap_id: ID,
    recipient: address,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&revoked_cap_id));
    expected.append(bcs::to_bytes(&cap_id));
    expected.append(bcs::to_bytes(&recipient));
    expected
}

fun reach_migration_after_sell(
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
    package_version: &PackageVersion,
    runtime_config: &runtime_config::RuntimeConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, ctx);
    let (meme_bought, quote_refund) = launch.buy(
        package_version,
        runtime_config,
        quote_in,
        1,
        clock,
        ctx,
    );
    let quote_out = launch.sell(
        package_version,
        runtime_config,
        meme_bought,
        1,
        ctx,
    );
    let (_, _, pending_burn_before_terminal_buy, _) = launch.balances_for_testing();

    assert_eq!(quote_refund.value(), 0);
    assert!(quote_out.value() > 0);
    assert!(pending_burn_before_terminal_buy > 0);
    destroy(quote_refund);
    destroy(quote_out);

    let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, ctx);
    let (meme_bought, quote_refund) = launch.buy(
        package_version,
        runtime_config,
        quote_in,
        1,
        clock,
        ctx,
    );
    let (meme_reserve, real_quote, pending_burn, _) = launch.balances_for_testing();

    assert!(launch.is_migration_ready());
    assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
    assert_eq!(pending_burn, pending_burn_before_terminal_buy);
    assert!(meme_reserve > 0);
    assert!(quote_refund.value() > 0);
    destroy(meme_bought);
    destroy(quote_refund);

    pending_burn + meme_reserve
}

fun launch_end(self: LaunchFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, AdminWitness};

use blast_fun::{
    bps,
    creator_authority,
    curve,
    domain_fixture,
    events,
    launch::{Self, Launch, LaunchInitializer},
    launch_config,
    launch_ticket::{Self, LaunchTicket},
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    package_version::{Self, PackageVersion},
    runtime_config,
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun launch_ctx as LaunchFixture.ctx;

use fun launch_end as LaunchFixture.end;

use fun launch_new_ticket as LaunchFixture.new_ticket;

use fun launch_new_ticket_with_mode as LaunchFixture.new_ticket_with_mode;

use fun launch_new_ticket_with as LaunchFixture.new_ticket_with;

use fun launch_new_ticket_with_decimals as LaunchFixture.new_ticket_with_decimals;

use fun launch_new_ticket_with_symbol as LaunchFixture.new_ticket_with_symbol;

use fun launch_next_tx as LaunchFixture.next_tx;

use fun launch_sign_in as LaunchFixture.sign_in;

use fun launch_intake as LaunchFixture.intake;

use fun launch_start as LaunchFixture.start_launch;

use fun launch_finalize as LaunchFixture.finalize_launch;

use fun launch_take_currency as LaunchFixture.take_currency;

use fun launch_take_fixed_disposal as LaunchFixture.take_fixed_disposal;

use fun launch_take_shared as LaunchFixture.take_launch;

use fun launch_take_curve_fee_cap as LaunchFixture.take_curve_fee_cap;

use fun launch_has_curve_fee_cap as LaunchFixture.has_curve_fee_cap;

use fun assert_launch_snapshot as Launch.assert_snapshot;

use fun assert_launch_lifecycle as Launch.assert_lifecycle;

use fun launch_put_back as Launch.put_back;

use fun reach_migration_after_sell as Launch.reach_migration_after_sell;
