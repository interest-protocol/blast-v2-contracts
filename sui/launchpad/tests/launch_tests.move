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

/// Where Blast's migration allocation is paid.
const BLAST: address = @0xB1A5;

const ALICE: address = @0xA11CE;

const BOB: address = @0xB0B;

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

const SELL_BURN_BPS: u64 = 1_000;

/// Blast's allocation, set once in the launch configuration.
const PROTOCOL_MEME_BPS: u64 = 750;

const PROTOCOL_QUOTE_BPS: u64 = 250;

/// The default creator plan: the curve and the pool take everything Blast does not.
const CURVE_MEME_BPS: u64 = 7_250;

const LP_MEME_BPS: u64 = 2_000;

const LP_QUOTE_BPS: u64 = 9_750;

const EXPECTED_CURVE_MEME: u64 = 725_000_000__000_000_000;

const EXPECTED_PROTOCOL_MEME: u64 = 75_000_000__000_000_000;

const EXPECTED_POOL_MEME: u64 = 200_000_000__000_000_000;

/// Blast's share of `MIGRATION_QUOTE_TARGET`.
const EXPECTED_PROTOCOL_QUOTE: u64 = 625_000;

const POOL_TICK_SPACING: u32 = 200;

const POOL_FEE_RATE: u64 = 10_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_TESTS has drop {}

public struct TEST_QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

public struct TEST_MIGRATION_WITNESS() has drop;

public struct OTHER_MIGRATION_WITNESS() has drop;

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

// --- Construction ---

#[test]
fun finalize_snapshots_the_config_and_emits_launch_created() {
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

        assert_eq!(
            bcs::to_bytes(&collect_one<events::LaunchCreated>()),
            launch_created_bytes(object::id(&launch), ticket_id),
        );
        assert_eq!(launch.sell_burn_bps_for_testing(), SELL_BURN_BPS);
        assert_eq!(launch.atomic_supply_for_testing(), INITIAL_MEME_SUPPLY);
        launch.assert_lifecycle(true, false, false);
        launch.assert_snapshot();

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
        let metadata_cap_id = ticket.metadata_cap_id_for_testing();
        let ticket_created = collect_one<events::LaunchTicketCreated>();
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        assert_eq!(launch.metadata_cap_id_for_testing(), metadata_cap_id);
        assert_eq!(
            bcs::to_bytes(&ticket_created),
            ticket_created_bytes(ticket_id, metadata_cap_id, true),
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
fun launch_snapshot_does_not_follow_later_config_updates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let admin_witness = f.sign_in();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
        f.config.set_trade_fees(&f.package_version, &admin_witness, bps::new(0), bps::new(0));

        launch.assert_snapshot();

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
        let routes = allocation::fee_split(
            bps::new(0),
            bps::new(0),
            bps::new(0),
            bps::new(0),
            vector[allocation::route(LAUNCHER, bps::new(10_000))],
        );
        initializer.set_virtual_quote(VIRTUAL_QUOTE);
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

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_a_graduation_target() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_virtual_quote(VIRTUAL_QUOTE);
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_a_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidVirtualQuote, location = blast_fun::launch)]
fun finalize_rejects_a_zero_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_virtual_quote(0);
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test]
fun the_creator_picks_the_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_virtual_quote(1);
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());
        initializer.set_lp_fee_split(default_fee_split());
        let launch = f.finalize_launch(initializer);

        assert_eq!(launch.virtual_quote_for_testing(), 1);

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_an_allocation_plan() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_virtual_quote(VIRTUAL_QUOTE);
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_lp_fee_split(default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_lp_fee_split() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
        initializer.set_virtual_quote(VIRTUAL_QUOTE);
        initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(default_plan());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_the_protocol_allocation() {
    let mut fixture = start_unallocated();

    fixture.next_tx!(LAUNCHER, |f| destroy(f.new_default_launch(CREATOR)));

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
/// The creator's Meme shares sum to 10,000 on their own, so Blast's share overflows them.
fun finalize_adds_blast_before_checking_the_meme_shares() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(8_000),
            bps::new(LP_MEME_BPS),
            bps::new(LP_QUOTE_BPS),
            vector[],
        );

        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, plan));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
/// The creator's Quote shares sum to 10,000 on their own, so Blast's share overflows them.
fun finalize_adds_blast_before_checking_the_quote_shares() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(CURVE_MEME_BPS),
            bps::new(LP_MEME_BPS),
            bps::new(10_000),
            vector[],
        );

        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, plan));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ERecipientCapacityReached, location = blast_fun::allocation)]
/// Sixteen creator recipients plus Blast exceed the sixteen-recipient bound.
fun finalize_rejects_a_seventeenth_recipient() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, recipients_plan(16)));
    });

    fixture.end();
}

#[test]
fun launches_choose_their_own_graduation_target() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET * 3, default_plan());

        assert_eq!(launch.graduation_target_for_testing(), MIGRATION_QUOTE_TARGET * 3);

        destroy(launch);
    });

    fixture.end();
}

#[test]
/// Blast takes ceil(2 * 250 / 10,000) = 1 and the pool keeps 1.
fun smallest_target_that_leaves_the_pool_quote_is_accepted() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(2, default_plan());

        assert_eq!(launch.graduation_target_for_testing(), 2);

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidGraduationTarget, location = blast_fun::launch)]
/// Blast's rounded-up share takes the only atomic unit.
fun target_that_leaves_the_pool_no_quote_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| destroy(f.new_launch_with(1, default_plan())));

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidGraduationTarget, location = blast_fun::launch)]
/// A zero pool Quote share leaves the pool no Quote at any target.
fun zero_lp_quote_share_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(CURVE_MEME_BPS),
            bps::new(LP_MEME_BPS),
            bps::new(0),
            vector[allocation::recipient(ALICE, bps::new(0), bps::new(LP_QUOTE_BPS))],
        );

        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, plan));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EDecimalsNotAllowed, location = blast_fun::launch_config)]
fun intake_rejects_a_ticket_whose_decimals_are_no_longer_allowed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket_with_decimals(CREATOR, false, 6);
        let admin_witness = f.sign_in();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, false);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test]
fun intake_accepts_a_meme_symbol_at_the_length_bound() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(MAX_LENGTH_SYMBOL);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EMemeSymbolTooLong, location = blast_fun::launch)]
fun intake_rejects_a_meme_symbol_over_the_length_bound() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(over_length_symbol());

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EDecimalsNotAllowed, location = blast_fun::launch_config)]
fun intake_checks_the_decimals_before_the_symbol_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket_with(CREATOR, false, 6, over_length_symbol());
        let admin_witness = f.sign_in();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, false);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun intake_checks_the_version_before_the_symbol_length() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(over_length_symbol());
        f.package_version.set_for_testing(2);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun launch_delegates_quote_admission_to_launch_config() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.intake<OTHER_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun starting_checks_the_quote_before_finalize_checks_the_symbol() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_symbol(over_length_symbol());

        destroy(f.intake<OTHER_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidMemeQuotePair, location = blast_fun::launch)]
fun launch_rejects_using_the_meme_type_as_quote_before_config_lookup() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.intake<LAUNCH_TESTS, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidSellBurnBps, location = blast_fun::launch_ticket)]
fun launch_rejects_a_ticket_whose_sell_burn_exceeds_this_generations_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.set_sell_burn_bps_for_testing(5_001);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidInitialMemeSupply, location = blast_fun::launch_ticket)]
fun launch_rejects_a_ticket_without_the_canonical_supply() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.burn_meme_for_testing(1);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TEST_MIGRATION_WITNESS(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidInitialMemeSupply, location = blast_fun::launch_ticket)]
fun launch_rejects_supply_minted_through_the_lent_treasury_cap() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        f.mint_extra_supply_and_finalize(ticket);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidInitialMemeSupply, location = blast_fun::launch_ticket)]
fun launch_rejects_extra_supply_on_a_burn_only_ticket() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        f.mint_extra_supply_and_finalize(ticket);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidMigrationWitness, location = blast_fun::launch)]
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

#[test, expected_failure(abort_code = blast_fun::errors::EMigrationWitnessNotAllowed, location = blast_fun::launch_config)]
fun an_unadmitted_adapter_cannot_start_a_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.start_launch<TEST_QUOTE, _>(ticket, OTHER_MIGRATION_WITNESS()));
    });

    fixture.end();
}

// --- Buys before sharing, and sharing ---

#[test]
fun buy_before_share_emits_bought() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (quote_fee, gross, meme_fee, net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, refund) = f.buy(&mut launch, 10_000_000, net);

        assert_eq!(meme.value(), net);
        assert_eq!(refund.value(), 0);
        assert!(launch.public_start_ms_for_testing().is_none());
        launch.assert_lifecycle(true, false, false);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::Bought>()),
            u64_payload(
                object::id(&launch),
                vector[
                    10_000_000,
                    gross,
                    net,
                    0,
                    0,
                    meme_fee,
                    0,
                    quote_fee,
                    EXPECTED_CURVE_MEME - gross,
                    10_000_000 - quote_fee,
                ],
            ),
        );

        destroy(meme);
        destroy(refund);
        f.share_launch(launch);
    });

    fixture.end();
}

#[test]
/// Two buys before sharing stay below the target; the third reaches it, refunds the excess, and closes
/// the curve before the launch is shared. The shared launch then migrates.
fun buys_before_share_repeat_until_one_graduates_the_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (first, first_refund) = f.buy(&mut launch, 10_000_000, 1);
        let (second, second_refund) = f.buy(&mut launch, 10_000_000, 1);
        let (_, real_quote, _, _) = launch.balances_for_testing();

        assert_eq!(real_quote, 19_800_000);
        launch.assert_lifecycle(true, false, false);

        let (third, third_refund) = f.buy(&mut launch, 10_000_000, 1);
        let (_, real_quote, _, _) = launch.balances_for_testing();

        assert_eq!(collect<events::Bought>().length(), 3);
        assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
        assert_eq!(third_refund.value(), 10_000_000 - 5_252_526);
        launch.assert_lifecycle(false, true, false);

        destroy(vector[first, second, third]);
        destroy(vector[first_refund, second_refund, third_refund]);
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.migrate(&mut launch);

        launch.assert_lifecycle(false, false, true);

        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun buy_before_share_after_graduation_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (meme, refund) = f.buy(&mut launch, 30_000_000, 1);
        destroy(meme);
        destroy(refund);
        let (meme, refund) = f.buy(&mut launch, 1_000_000, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeOutput, location = blast_fun::launch)]
fun buy_before_share_rejects_zero_input() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (meme, refund) = f.buy(&mut launch, 0, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun buy_before_share_enforces_the_minimum_output() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (meme, refund) = f.buy(&mut launch, 1_000_000, INITIAL_MEME_SUPPLY);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun share_starts_public_trading_and_emits_launch_shared() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let launch_id = object::id(&launch);
        f.clock.set_for_testing(250_000);
        f.share_launch(launch);

        assert_eq!(
            bcs::to_bytes(&collect_one<events::LaunchShared>()),
            u64_payload(launch_id, vector[250_000]),
        );
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        assert_eq!(launch.public_start_ms_for_testing(), option::some(250_000));

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun share_rejects_a_second_share() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let launch = f.open_launch(launch);

        f.share_launch(launch);
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
fun buy_checks_the_version_first() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.package_version.set_for_testing(2);
        let (meme, refund) = f.buy(&mut launch, 1_000, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

// --- Creator caps ---

#[test]
/// The launcher designates `CREATOR`, who claims both caps; the launch keeps the native cap.
fun designated_creator_claims_both_caps() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let native_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let mut expected = bcs::to_bytes(&type_name::with_original_ids<LAUNCH_TESTS>());
        expected.append(bcs::to_bytes(&object::id(&curve_fee_cap)));
        expected.append(bcs::to_bytes(&object::id(&metadata_cap)));

        assert_eq!(bcs::to_bytes(&collect_one<events::CreatorCapsClaimed>()), expected);
        assert_eq!(launch.metadata_cap_id_for_testing(), native_metadata_cap_id);
        assert!(!launch.has_creator_authority_for_testing());
        assert_eq!(launch.curve_fee_cap_id_for_testing(), option::some(object::id(&curve_fee_cap)));
        assert_eq!(
            launch.blast_metadata_cap_id_for_testing(),
            option::some(object::id(&metadata_cap)),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun creator_claim_cannot_be_repeated() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        destroy(curve_fee_cap);
        destroy(metadata_cap);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun creator_claim_waits_for_the_share() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorNotSender, location = blast_fun::creator_authority)]
fun launcher_cannot_claim_another_address_creators_caps() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun creator_claim_checks_the_version_before_the_sender() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.package_version.set_for_testing(2);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun admin_reassigns_claimed_creator_and_the_new_cap_claims_prior_fees() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);

        transfer::public_transfer(curve_fee_cap, CREATOR);
        destroy(metadata_cap);
        destroy(meme);
        destroy(refund);
        launch.put_back();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut launch = f.take_launch();
        let admin_witness = f.sign_in();
        let retired_cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert!(cap_id != retired_cap_id);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::CurveFeeCapReassigned>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR),
        );

        launch.put_back();
    });

    fixture.next_tx!(NEW_CREATOR, |f| {
        let mut launch = f.take_launch();
        let curve_fee_cap = f.take_curve_fee_cap();
        let (_, creator_meme, _, creator_quote) = launch.fee_totals_for_testing();
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &curve_fee_cap,
            f.ctx!(),
        );

        assert!(creator_meme > 0 && creator_quote > 0);
        assert_eq!(meme_fees.value(), creator_meme);
        assert_eq!(quote_fees.value(), creator_quote);

        destroy(curve_fee_cap);
        destroy(meme_fees);
        destroy(quote_fees);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorCapNotLive, location = blast_fun::launch)]
fun retired_creator_cap_is_rejected_before_the_empty_fee_ledger_check() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &curve_fee_cap,
            f.ctx!(),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
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
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert!(!launch.has_creator_authority_for_testing());
        assert_eq!(
            bcs::to_bytes(&collect_one<events::CurveFeeCapReassigned>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR),
        );

        launch.put_back();
    });

    fixture.next_tx!(NEW_CREATOR, |f| assert!(f.has_curve_fee_cap()));

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun reassignment_prevents_the_original_recipient_from_claiming() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorRecipient, location = blast_fun::launch)]
fun reassignment_rejects_the_zero_recipient() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let admin_witness = f.sign_in();

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, @0x0, f.ctx!());

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun reassignment_requires_the_creator_admin_role() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (authority, admin_cap) = f.new_admin_without(blast_fun_domain::creator_admin_role());
        let admin_witness = authority.sign_in(&admin_cap);

        launch.reassign_curve_fee_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        destroy(authority);
        destroy(admin_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun metadata_reassignment_requires_the_creator_admin_role() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (authority, admin_cap) = f.new_admin_without(blast_fun_domain::creator_admin_role());
        let admin_witness = authority.sign_in(&admin_cap);

        launch.reassign_metadata_cap(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        destroy(authority);
        destroy(admin_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun claiming_protocol_fees_requires_the_treasury_admin_role() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (authority, admin_cap) = f.new_admin_without(blast_fun_domain::treasury_admin_role());
        let admin_witness = authority.sign_in(&admin_cap);

        let (meme, quote) = launch.claim_protocol_fees(&f.package_version, &admin_witness, f.ctx!());

        destroy(meme);
        destroy(quote);
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
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let native_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Renamed Launch".to_string(),
        );

        let mut expected = bcs::to_bytes(&object::id(&launch));
        expected.append(bcs::to_bytes(&b"Renamed Launch".to_string()));
        expected.append(bcs::to_bytes(&b"Normalized launch state".to_string()));
        expected.append(bcs::to_bytes(&b"".to_string()));
        assert_eq!(bcs::to_bytes(&collect_one<events::MemeMetadataUpdated>()), expected);

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

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::launch)]
fun metadata_update_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

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

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorCapNotLive, location = blast_fun::launch)]
fun retired_metadata_cap_is_rejected_before_unchanged_metadata() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
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
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        curve_fee_cap.destroy_curve_fee_cap();
        metadata_cap.destroy_metadata_cap();

        destroy(launch);
    });

    fixture.end();
}

// --- Trading and fees ---

#[test]
fun buy_and_sell_move_exact_coins_accounting_and_payloads() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(LAUNCHER);
        let mut launch = f.open_launch(launch);
        let launch_id = object::id(&launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, refund) = f.buy(&mut launch, 10_000_000, meme_out_net);
        let meme_reserve = EXPECTED_CURVE_MEME - meme_out_gross;
        let real_quote = 10_000_000 - quote_fee;

        assert_eq!(meme.value(), meme_out_net);
        assert_eq!(refund.value(), 0);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::Bought>()),
            u64_payload(
                launch_id,
                vector[
                    10_000_000,
                    meme_out_gross,
                    meme_out_net,
                    0,
                    0,
                    meme_fee,
                    0,
                    quote_fee,
                    meme_reserve,
                    real_quote,
                ],
            ),
        );

        let meme_in = meme.value();
        let (
            sell_meme_fee,
            pending_burn,
            quote_out_gross,
            sell_quote_fee,
            quote_out_net,
        ) = curve::quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            meme_in,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
            bps::new(SELL_BURN_BPS),
        );
        let quote_out = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme,
            quote_out_net,
            f.ctx!(),
        );
        let meme_reserve = meme_reserve + meme_in - sell_meme_fee - pending_burn;
        let real_quote = real_quote - quote_out_gross;

        assert_eq!(quote_out.value(), quote_out_net);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::Sold>()),
            u64_payload(
                launch_id,
                vector[
                    meme_in,
                    pending_burn,
                    quote_out_gross,
                    0,
                    sell_meme_fee,
                    0,
                    sell_quote_fee,
                    meme_reserve,
                    real_quote,
                ],
            ),
        );
        let (reserve, quote_reserve, burn, _) = launch.balances_for_testing();
        assert_eq!(reserve, meme_reserve);
        assert_eq!(quote_reserve, real_quote);
        assert_eq!(burn, pending_burn);

        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &curve_fee_cap,
            f.ctx!(),
        );

        assert_eq!(meme_fees.value(), meme_fee + sell_meme_fee);
        assert_eq!(quote_fees.value(), quote_fee + sell_quote_fee);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::CreatorFeesClaimed>()),
            u64_payload(launch_id, vector[meme_fee + sell_meme_fee, quote_fee + sell_quote_fee]),
        );
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme + creator_meme + protocol_quote + creator_quote, 0);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(refund);
        destroy(quote_out);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun graduating_buy_refunds_the_excess_and_closes_the_curve() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 30_000_000, 1);
        let quote_in = 30_000_000 - refund.value();
        let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            quote_in,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();

        assert_eq!(quote_in - quote_fee, MIGRATION_QUOTE_TARGET);
        assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
        assert_eq!(meme.value(), meme_out_net);
        assert_eq!(meme_reserve, EXPECTED_CURVE_MEME - meme_out_gross);
        launch.assert_lifecycle(false, true, false);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::Bought>()),
            u64_payload(
                object::id(&launch),
                vector[
                    quote_in,
                    meme_out_gross,
                    meme_out_net,
                    refund.value(),
                    0,
                    meme_fee,
                    0,
                    quote_fee,
                    meme_reserve,
                    real_quote,
                ],
            ),
        );

        destroy(meme);
        destroy(refund);
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
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let quote_out = launch.sell(&f.package_version, &f.runtime_config, meme, 1, f.ctx!());
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();

        assert!(quote_out.value() > 0);
        assert_eq!(protocol_meme + creator_meme + protocol_quote + creator_quote, 0);

        destroy(refund);
        destroy(quote_out);
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
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();

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
        assert_eq!(
            bcs::to_bytes(&collect_one<events::ProtocolFeesClaimed>()),
            u64_payload(object::id(&launch), vector[protocol_meme, protocol_quote]),
        );

        destroy(meme);
        destroy(refund);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun buy_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (_, _, _, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, refund) = f.buy(&mut launch, 10_000_000, meme_out_net + 1);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun sell_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();
        let (_, _, _, _, quote_out_net) = curve::quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            meme.value(),
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

        destroy(refund);
        destroy(quote);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeOutput, location = blast_fun::launch)]
fun public_buy_checks_zero_output_before_slippage() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 0, std::u64::max_value!());

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun threshold_crossing_buy_closes_sell_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 30_000_000, 1);
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 0, f.ctx!());

        destroy(refund);
        destroy(quote);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun threshold_crossing_buy_closes_another_buy_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let (meme, refund) = f.buy(&mut launch, 0, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

// --- Migration ---

#[test]
/// Blast is paid first, then each creator recipient in plan order; a zero share is reported
/// but transfers nothing. The pool's share goes to the adapter.
fun migration_pays_every_recipient_blast_first() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET, external_plan());
        let (curve, _, _, allocated) = launch.balances_for_testing();

        assert_eq!(curve, 700_000_000__000_000_000);
        assert_eq!(allocated, INITIAL_MEME_SUPPLY - curve);

        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let launch_id = object::id(&launch);
        f.graduate(&mut launch);
        let mut currency = f.take_currency();
        let (meme, quote) = launch.migrate(&f.package_version, &mut currency, TEST_MIGRATION_WITNESS(), f.ctx!());
        let paid = collect<events::MigrationAllocationPaid>();
        let (curve, real_quote, pending_burn, allocated) = launch.balances_for_testing();

        assert_eq!(meme.value(), EXPECTED_POOL_MEME);
        assert_eq!(quote.value(), 22_500_000);
        assert_eq!(paid.length(), 3);
        assert_eq!(
            bcs::to_bytes(&paid[0]),
            allocation_paid_bytes(
                launch_id,
                BLAST,
                EXPECTED_PROTOCOL_MEME,
                EXPECTED_PROTOCOL_QUOTE,
            ),
        );
        assert_eq!(
            bcs::to_bytes(&paid[1]),
            allocation_paid_bytes(launch_id, CREATOR, 0, 1_875_000),
        );
        assert_eq!(
            bcs::to_bytes(&paid[2]),
            allocation_paid_bytes(launch_id, ALICE, 25_000_000__000_000_000, 0),
        );
        assert_eq!(curve + real_quote + pending_burn + allocated, 0);
        launch.assert_lifecycle(false, false, true);

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        assert_eq!(f.take_coin<LAUNCH_TESTS>(BLAST).burn_for_testing(), EXPECTED_PROTOCOL_MEME);
        assert_eq!(f.take_coin<TEST_QUOTE>(BLAST).burn_for_testing(), EXPECTED_PROTOCOL_QUOTE);
        assert_eq!(f.take_coin<TEST_QUOTE>(CREATOR).burn_for_testing(), 1_875_000);
        assert_eq!(f.take_coin<LAUNCH_TESTS>(ALICE).burn_for_testing(), 25_000_000__000_000_000);
        assert!(!f.has_coin<LAUNCH_TESTS>(CREATOR));
        assert!(!f.has_coin<TEST_QUOTE>(ALICE));
    });

    fixture.end();
}

#[test]
/// Odd shares of an odd target: Blast's Quote rounds up, the one leftover Quote unit goes to the
/// largest remaining remainder (ALICE 7,777 over BOB 6,034 and the pool's 4,439), and every Meme
/// and Quote unit is accounted for.
fun migration_apportions_by_largest_remainder_and_conserves_both_assets() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(6_001),
            bps::new(2_333),
            bps::new(7_777),
            vector[
                allocation::recipient(ALICE, bps::new(333), bps::new(1_111)),
                allocation::recipient(BOB, bps::new(583), bps::new(862)),
            ],
        );
        let launch = f.new_launch_with(25_000_007, plan);
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let launch_id = object::id(&launch);
        let (bought, refund) = f.buy(&mut launch, 30_000_000, 1);
        let (curve, real_quote, pending_burn, allocated) = launch.balances_for_testing();
        let (protocol_fee, creator_fee, _, _) = launch.fee_totals_for_testing();

        assert_eq!(real_quote, 25_000_007);
        assert_eq!(
            curve + pending_burn + allocated + bought.value() + protocol_fee + creator_fee,
            INITIAL_MEME_SUPPLY,
        );

        let mut currency = f.take_currency();
        let (meme, quote) = launch.migrate(&f.package_version, &mut currency, TEST_MIGRATION_WITNESS(), f.ctx!());
        let paid = collect<events::MigrationAllocationPaid>();

        assert_eq!(
            bcs::to_bytes(&paid[0]),
            allocation_paid_bytes(launch_id, BLAST, EXPECTED_PROTOCOL_MEME, 625_001),
        );
        assert_eq!(
            bcs::to_bytes(&paid[1]),
            allocation_paid_bytes(launch_id, ALICE, 33_300_000__000_000_000, 2_777_501),
        );
        assert_eq!(
            bcs::to_bytes(&paid[2]),
            allocation_paid_bytes(launch_id, BOB, 58_300_000__000_000_000, 2_155_000),
        );
        assert_eq!(meme.value(), 233_300_000__000_000_000);
        assert_eq!(quote.value(), 19_442_505);
        assert_eq!(
            meme.value() + EXPECTED_PROTOCOL_MEME + 33_300_000__000_000_000
                + 58_300_000__000_000_000,
            allocated,
        );
        assert_eq!(quote.value() + 625_001 + 2_777_501 + 2_155_000, real_quote);

        destroy(bought);
        destroy(refund);
        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun migration_pays_sixteen_recipients() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET, recipients_plan(15));
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.graduate(&mut launch);
        f.migrate(&mut launch);
        let (_, real_quote, _, allocated) = launch.balances_for_testing();

        assert_eq!(collect<events::MigrationAllocationPaid>().length(), 16);
        assert_eq!(real_quote + allocated, 0);

        launch.put_back();
    });

    fixture.end();
}

#[test]
fun fixed_supply_migration_sends_the_disposal_to_zero() {
    let mut fixture = start();
    let disposed_meme;

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        disposed_meme = f.reach_migration_after_sell(&mut launch);
        let mut currency = f.take_currency();
        let supply = currency.total_supply().destroy_some();
        let (meme, quote) = launch.migrate(&f.package_version, &mut currency, TEST_MIGRATION_WITNESS(), f.ctx!());

        assert_eq!(meme.value(), EXPECTED_POOL_MEME);
        assert_eq!(currency.total_supply().destroy_some(), supply);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::Migrated>()),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                disposed_meme,
                supply,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        assert_eq!(f.take_coin<LAUNCH_TESTS>(@0x0).burn_for_testing(), disposed_meme);
    });

    fixture.end();
}

#[test]
fun burn_only_migration_burns_the_disposal_from_native_supply() {
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
        let disposed_meme = f.reach_migration_after_sell(&mut launch);
        let mut currency = f.take_currency();
        let supply = currency.total_supply().destroy_some();
        let (meme, quote) = launch.migrate(&f.package_version, &mut currency, TEST_MIGRATION_WITNESS(), f.ctx!());

        assert_eq!(currency.total_supply().destroy_some(), supply - disposed_meme);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::Migrated>()),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                disposed_meme,
                supply - disposed_meme,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun migration_rejects_a_live_launch_before_witness_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let mut currency = f.take_currency();
        let (meme, quote) = launch.migrate(
            &f.package_version,
            &mut currency,
            OTHER_MIGRATION_WITNESS(),
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun migration_cannot_be_repeated() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let mut currency = f.take_currency();
        let (meme, quote) = launch.migrate(
            &f.package_version,
            &mut currency,
            TEST_MIGRATION_WITNESS(),
            f.ctx!(),
        );
        destroy(meme);
        destroy(quote);
        let (meme, quote) = launch.migrate(
            &f.package_version,
            &mut currency,
            TEST_MIGRATION_WITNESS(),
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidMigrationWitness, location = blast_fun::launch)]
fun migration_rejects_a_witness_type_not_stored_at_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let mut currency = f.take_currency();
        let (meme, quote) = launch.migrate(
            &f.package_version,
            &mut currency,
            OTHER_MIGRATION_WITNESS(),
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_package_version_aborts_migration_before_lifecycle_and_witness_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.package_version.set_for_testing(2);
        let mut currency = f.take_currency();
        let (meme, quote) = launch.migrate(
            &f.package_version,
            &mut currency,
            OTHER_MIGRATION_WITNESS(),
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

// === Test Helpers ===

// --- Fixture ---

/// The fixture with Blast's protocol allocation set.
fun start(): LaunchFixture {
    let mut fixture = start_unallocated();
    let admin_witness = fixture.sign_in();
    let f = &mut fixture;

    f
        .config
        .set_protocol_allocation(
            &f.package_version,
            &admin_witness,
            BLAST,
            bps::new(PROTOCOL_MEME_BPS),
            bps::new(PROTOCOL_QUOTE_BPS),
        );

    fixture
}

/// Configured launch policy without Blast's protocol allocation.
fun start_unallocated(): LaunchFixture {
    let mut scenario = test_scenario::begin(@0x0);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::creator_admin_role()
            | blast_fun_domain::treasury_admin_role()
            | blast_fun_domain::fee_admin_role()
            | blast_fun_domain::listing_admin_role()
            | blast_fun_domain::adapter_admin_role(),
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

    config.set_quote_allowed<TEST_QUOTE>(&package_version, &admin_witness, true);
    config.set_migration_witness_allowed<TEST_MIGRATION_WITNESS>(
        &package_version,
        &admin_witness,
        true,
    );
    config.set_trade_fees(
        &package_version,
        &admin_witness,
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
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

fun launch_sign_in(self: &LaunchFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

/// Live administration holding every role except `role`.
fun new_admin_without(
    self: &mut LaunchFixture,
    role: u64,
): (Authority<BLAST_FUN_DOMAIN>, AdminCap<BLAST_FUN_DOMAIN>) {
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(self.scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        role.bitwise_not(),
        ROLE_LESS_ADMIN,
        self.scenario.ctx(),
    );
    destroy(super_admin_cap);
    self.scenario.next_tx(ROLE_LESS_ADMIN);
    let admin_cap = self.scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    (authority, admin_cap)
}

fun launch_end(self: LaunchFixture) {
    destroy(self);
}

// --- Plans ---

/// Blast's allocation added to the default creator plan, as `finalize` stores it.
fun default_plan_with_blast(): AllocationPlan {
    allocation::plan(
        bps::new(CURVE_MEME_BPS),
        bps::new(LP_MEME_BPS),
        bps::new(LP_QUOTE_BPS),
        vector[
            allocation::recipient(BLAST, bps::new(PROTOCOL_MEME_BPS), bps::new(PROTOCOL_QUOTE_BPS)),
        ],
    )
}

fun default_plan(): AllocationPlan {
    allocation::plan(
        bps::new(CURVE_MEME_BPS),
        bps::new(LP_MEME_BPS),
        bps::new(LP_QUOTE_BPS),
        vector[],
    )
}

/// A Quote-only recipient and a Meme-only recipient beside Blast.
fun external_plan(): AllocationPlan {
    allocation::plan(
        bps::new(7_000),
        bps::new(LP_MEME_BPS),
        bps::new(9_000),
        vector[
            allocation::recipient(CREATOR, bps::new(0), bps::new(750)),
            allocation::recipient(ALICE, bps::new(250), bps::new(0)),
        ],
    )
}

/// `count` one-BPS creator recipients carved from the curve's and the pool's default shares.
fun recipients_plan(count: u64): AllocationPlan {
    allocation::plan(
        bps::new(CURVE_MEME_BPS - count),
        bps::new(LP_MEME_BPS),
        bps::new(LP_QUOTE_BPS - count),
        vector::tabulate!(count, |_| allocation::recipient(CREATOR, bps::new(1), bps::new(1))),
    )
}

fun default_fee_split(): FeeSplit {
    allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[])
}

// --- Construction ---

fun launch_new_ticket(self: &mut LaunchFixture, creator: address): LaunchTicket<LAUNCH_TESTS> {
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

/// A Meme symbol one byte over the launch intake bound.
fun over_length_symbol(): vector<u8> {
    let mut symbol = MAX_LENGTH_SYMBOL;
    symbol.push_back(b"X"[0]);
    symbol
}

/// Starts the launch for `witness`, sets the target, plan, and default fee split, and finalizes it
/// without an opening round.
fun launch_intake<Quote, MigrationWitness: drop>(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
    witness: MigrationWitness,
    target: u64,
    plan: AllocationPlan,
): Launch<LAUNCH_TESTS, Quote> {
    let mut initializer = self.start_launch<Quote, _>(ticket, witness);
    initializer.set_virtual_quote(VIRTUAL_QUOTE);
    initializer.set_graduation_target(target);
    initializer.set_allocation_plan(plan);
    initializer.set_lp_fee_split(default_fee_split());
    self.finalize_launch(initializer)
}

/// An unshared launch for `creator` with the default target and plan.
fun new_default_launch(
    self: &mut LaunchFixture,
    creator: address,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket(creator);
    self.intake(ticket, TEST_MIGRATION_WITNESS(), MIGRATION_QUOTE_TARGET, default_plan())
}

/// An unshared launch for `CREATOR` with this target and plan.
fun launch_new_launch_with(
    self: &mut LaunchFixture,
    target: u64,
    plan: AllocationPlan,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket(CREATOR);
    self.intake(ticket, TEST_MIGRATION_WITNESS(), target, plan)
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
    let launch = initializer.finalize(&mut currency, &self.config, self.scenario.ctx());
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

/// Mints one extra unit through the lent treasury cap, then finalizes.
fun launch_mint_extra_supply_and_finalize(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
) {
    let mut initializer = self.start_launch<TEST_QUOTE, _>(ticket, TEST_MIGRATION_WITNESS());
    destroy(initializer.treasury_cap_mut(TEST_MIGRATION_WITNESS()).mint_balance(1));
    initializer.set_virtual_quote(VIRTUAL_QUOTE);
    initializer.set_graduation_target(MIGRATION_QUOTE_TARGET);
    initializer.set_allocation_plan(default_plan());
    initializer.set_lp_fee_split(default_fee_split());
    destroy(self.finalize_launch(initializer));
}

fun share_launch(self: &LaunchFixture, launch: Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    launch.share(&self.clock);
}

/// Shares the launch and takes it back in the next transaction from the same sender.
fun open_launch(
    self: &mut LaunchFixture,
    launch: Launch<LAUNCH_TESTS, TEST_QUOTE>,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let sender = self.scenario.ctx().sender();
    self.share_launch(launch);
    self.scenario.next_tx(sender);
    self.take_launch()
}

// --- Trading ---

fun launch_buy(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
    amount: u64,
    min_meme_out: u64,
): (Coin<LAUNCH_TESTS>, Coin<TEST_QUOTE>) {
    let quote = coin::mint_for_testing<TEST_QUOTE>(amount, self.scenario.ctx());
    launch.buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        min_meme_out,
        self.scenario.ctx(),
    )
}

/// Buys past the default target; the excess is refunded.
fun launch_graduate(self: &mut LaunchFixture, launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let (meme, refund) = self.buy(launch, 30_000_000, 1);
    destroy(meme);
    destroy(refund);
}

/// Buys, sells everything back to accrue a sell burn, then graduates. Returns the Meme that
/// migration will dispose of: the curve's unsold reserve plus the pending burn.
fun reach_migration_after_sell(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
): u64 {
    let (meme, refund) = self.buy(launch, 10_000_000, 1);
    let quote = launch.sell(
        &self.package_version,
        &self.runtime_config,
        meme,
        1,
        self.scenario.ctx(),
    );
    let (_, _, pending_burn_after_sell, _) = launch.balances_for_testing();
    destroy(refund);
    destroy(quote);
    self.graduate(launch);
    let (meme_reserve, _, pending_burn, _) = launch.balances_for_testing();

    assert!(pending_burn_after_sell > 0);
    assert_eq!(pending_burn, pending_burn_after_sell);
    assert!(meme_reserve > 0);
    assert!(launch.is_migration_ready_for_testing());

    meme_reserve + pending_burn
}

fun launch_claim(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
): (CurveFeeCap<LAUNCH_TESTS>, BlastMetadataCap<LAUNCH_TESTS>) {
    launch.claim_creator_caps(
        &self.package_version,
        &self.runtime_config,
        option::none(),
        &self.clock,
        self.scenario.ctx(),
    )
}

// --- Migration ---

/// Migrates as the stored adapter and discards the pool's share.
fun migrate(self: &mut LaunchFixture, launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let mut currency = self.take_currency();
    let (meme, quote) = launch.migrate(
        &self.package_version,
        &mut currency,
        TEST_MIGRATION_WITNESS(),
        self.scenario.ctx(),
    );
    destroy(meme);
    destroy(quote);
    destroy(currency);
}

// --- Storage ---

/// The one-time-witness path delivers the currency to the Coin Registry address.
fun launch_take_currency(self: &LaunchFixture): Currency<LAUNCH_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun launch_take_coin<T>(self: &LaunchFixture, owner: address): Coin<T> {
    self.scenario.take_from_address(owner)
}

fun launch_has_coin<T>(_: &LaunchFixture, owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<T>>(owner)
}

fun launch_take_shared(self: &LaunchFixture): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    self.scenario.take_shared<Launch<LAUNCH_TESTS, TEST_QUOTE>>()
}

fun launch_take_curve_fee_cap(self: &LaunchFixture): CurveFeeCap<LAUNCH_TESTS> {
    self.scenario.take_from_sender<CurveFeeCap<LAUNCH_TESTS>>()
}

fun launch_has_curve_fee_cap(self: &LaunchFixture): bool {
    self.scenario.has_most_recent_for_sender<CurveFeeCap<LAUNCH_TESTS>>()
}

/// Returns a taken launch to shared storage for a later transaction.
fun launch_put_back(launch: Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    test_scenario::return_shared(launch);
}

// --- Assertions ---

fun assert_launch_snapshot(launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let (curve_meme, real_quote, pending_burn, allocated_meme) = launch.balances_for_testing();
    let (quote_fee_bps, meme_fee_bps) = launch.policy_for_testing();

    assert_eq!(curve_meme, EXPECTED_CURVE_MEME);
    assert_eq!(real_quote, 0);
    assert_eq!(pending_burn, 0);
    assert_eq!(allocated_meme, EXPECTED_PROTOCOL_MEME + EXPECTED_POOL_MEME);
    assert_eq!(launch.virtual_quote_for_testing(), VIRTUAL_QUOTE);
    assert_eq!(launch.graduation_target_for_testing(), MIGRATION_QUOTE_TARGET);
    assert_eq!(quote_fee_bps, QUOTE_FEE_BPS);
    assert_eq!(meme_fee_bps, MEME_FEE_BPS);
    assert_eq!(*launch.allocation_plan_for_testing(), default_plan_with_blast());
    assert_eq!(
        launch.migration_witness_for_testing(),
        type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );
}

fun assert_launch_lifecycle(
    launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>,
    live: bool,
    migration_ready: bool,
    migrated: bool,
) {
    assert_eq!(launch.is_live_for_testing(), live);
    assert_eq!(launch.is_migration_ready_for_testing(), migration_ready);
    assert_eq!(launch.is_migrated_for_testing(), migrated);
}

// --- Events ---

/// Every `T` payload emitted in this transaction, unwrapped from the package event envelope.
fun collect<T: copy + drop>(): vector<T> {
    event::events_by_type<Event<T>>().map!(|event| event.unwrap())
}

fun collect_one<T: copy + drop>(): T {
    let mut payloads = collect<T>();
    assert_eq!(payloads.length(), 1);
    payloads.pop_back()
}

/// Expected bytes of a payload whose fields after the launch ID are all `u64`: `Bought`, `Sold`,
/// `LaunchShared`, and both fee claims.
fun u64_payload(launch_id: ID, fields: vector<u64>): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    fields.do!(|field| expected.append(bcs::to_bytes(&field)));
    expected
}

/// Expected `LaunchTicketCreated` bytes for a fixture ticket designating `CREATOR` by address.
fun ticket_created_bytes(ticket_id: ID, metadata_cap_id: ID, burnable: bool): vector<u8> {
    let decimals = MEME_DECIMALS;
    let mut expected = bcs::to_bytes(&ticket_id);
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LAUNCH_TESTS>()));
    expected.append(bcs::to_bytes(&decimals));
    expected.append(bcs::to_bytes(&metadata_cap_id));
    expected.append(bcs::to_bytes(&creator_authority::new_address(CREATOR)));
    expected.append(bcs::to_bytes(&burnable));
    expected.append(u64_bytes(SELL_BURN_BPS));
    expected
}

/// Expected `LaunchCreated` bytes for the fixture's cold policy, without an opening round, with Blast
/// first.
fun launch_created_bytes(launch_id: ID, ticket_id: ID): vector<u8> {
    let pool_tick_spacing = POOL_TICK_SPACING;
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&ticket_id));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TEST_QUOTE>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TEST_MIGRATION_WITNESS>()));
    expected.append(bcs::to_bytes(&pool_tick_spacing));
    expected.append(u64_bytes(POOL_FEE_RATE));
    expected.append(bcs::to_bytes(&default_fee_split()));
    expected.append(u64_bytes(VIRTUAL_QUOTE));
    expected.append(u64_bytes(MIGRATION_QUOTE_TARGET));
    expected.append(u64_bytes(QUOTE_FEE_BPS));
    expected.append(u64_bytes(MEME_FEE_BPS));
    expected.append(bcs::to_bytes(&default_plan_with_blast()));
    expected.append(u64_bytes(0));
    expected
}

fun allocation_paid_bytes(launch_id: ID, destination: address, meme: u64, quote: u64): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&destination));
    expected.append(u64_bytes(meme));
    expected.append(u64_bytes(quote));
    expected
}

/// Expected bytes shared by `CurveFeeCapReassigned` and `MetadataCapReassigned`.
fun cap_reassigned_bytes(launch_id: ID, cap_id: ID, recipient: address): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&cap_id));
    expected.append(bcs::to_bytes(&recipient));
    expected
}

/// Expected `Migrated` bytes.
fun migrated_bytes(
    launch_id: ID,
    meme: u64,
    quote: u64,
    disposed_meme: u64,
    total_supply_after: u64,
): vector<u8> {
    u64_payload(launch_id, vector[meme, quote, disposed_meme, total_supply_after])
}

/// Serializes one constant by value, so no test borrows a constant in place.
fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, AdminWitness};

use blast_fun::{
    allocation::{Self, AllocationPlan, FeeSplit},
    blast_events::Event,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority::{Self, BlastMetadataCap, CurveFeeCap},
    curve,
    domain_fixture,
    events,
    launch::{Self, Launch, LaunchInitializer},
    launch_config,
    launch_ticket::{Self, LaunchTicket},
    package_version::{Self, PackageVersion},
    runtime_config,
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun launch_ctx as LaunchFixture.ctx;

use fun launch_end as LaunchFixture.end;

use fun launch_next_tx as LaunchFixture.next_tx;

use fun launch_sign_in as LaunchFixture.sign_in;

use fun launch_new_ticket as LaunchFixture.new_ticket;

use fun launch_new_ticket_with_mode as LaunchFixture.new_ticket_with_mode;

use fun launch_new_ticket_with_decimals as LaunchFixture.new_ticket_with_decimals;

use fun launch_new_ticket_with_symbol as LaunchFixture.new_ticket_with_symbol;

use fun launch_new_ticket_with as LaunchFixture.new_ticket_with;

use fun launch_intake as LaunchFixture.intake;

use fun launch_new_launch_with as LaunchFixture.new_launch_with;

use fun launch_start as LaunchFixture.start_launch;

use fun launch_finalize as LaunchFixture.finalize_launch;

use fun launch_mint_extra_supply_and_finalize as LaunchFixture.mint_extra_supply_and_finalize;

use fun launch_buy as LaunchFixture.buy;

use fun launch_graduate as LaunchFixture.graduate;

use fun launch_claim as LaunchFixture.claim;

use fun launch_take_currency as LaunchFixture.take_currency;

use fun launch_take_coin as LaunchFixture.take_coin;

use fun launch_has_coin as LaunchFixture.has_coin;

use fun launch_take_shared as LaunchFixture.take_launch;

use fun launch_take_curve_fee_cap as LaunchFixture.take_curve_fee_cap;

use fun launch_has_curve_fee_cap as LaunchFixture.has_curve_fee_cap;

use fun assert_launch_snapshot as Launch.assert_snapshot;

use fun assert_launch_lifecycle as Launch.assert_lifecycle;

use fun launch_put_back as Launch.put_back;
