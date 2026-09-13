#[test_only]
module blast_fun::launch_tests;

use blast_admin::acl::{Authority, AdminCap, AdminWitness};
use blast_fun::{
    bps,
    creator_authority,
    curve,
    domain_fixture,
    events,
    launch::{Self, Launch},
    launch_config,
    launch_ticket::{Self, LaunchTicket},
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version::{Self, PackageVersion},
    runtime_config,
};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    test_scenario::{Self, Scenario},
};

use fun launch_ctx as LaunchFixture.ctx;
use fun launch_end as LaunchFixture.end;
use fun launch_new_ticket as LaunchFixture.new_ticket;
use fun launch_new_ticket_with_mode as LaunchFixture.new_ticket_with_mode;
use fun launch_next_tx as LaunchFixture.next_tx;
use fun launch_sign_in as LaunchFixture.sign_in;
use fun launch_take_currency as LaunchFixture.take_currency;
use fun launch_take_fixed_disposal as LaunchFixture.take_fixed_disposal;
use fun launch_take_shared as LaunchFixture.take_launch;
use fun assert_launch_snapshot as Launch.assert_snapshot;
use fun reach_migration_after_sell as Launch.reach_migration_after_sell;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const LAUNCHER: address = @0xB1A57;
const CREATOR: address = @0xC0FFEE;
const PROTOCOL_ADMIN: address = @0xAD;
/// `sui::object::SUI_COIN_REGISTRY_OBJECT_ID` at the pinned framework revision.
const COIN_REGISTRY: address = @0xc;
const INITIAL_MEME_SUPPLY: u64 = 1_000_000_000__000_000_000;
const VIRTUAL_QUOTE: u64 = 5_000_000;
const MIGRATION_QUOTE_TARGET: u64 = 25_000_000;
const QUOTE_FEE_BPS: u64 = 100;
const MEME_FEE_BPS: u64 = 250;
const QUOTE_MIGRATION_FEE_BPS: u64 = 250;
const PROTOCOL_MEME_GRADUATION_FEE_BPS: u64 = 750;
const MEME_LIQUIDITY_PROVISION_BPS: u64 = 2_000;
const SELL_BURN_BPS: u64 = 1_000;
const EXPECTED_CURVE_MEME: u64 = 725_000_000__000_000_000;
const EXPECTED_PROTOCOL_MEME: u64 = 75_000_000__000_000_000;
const EXPECTED_POOL_MEME: u64 = 200_000_000__000_000_000;

// === Test-Only Types ===

public struct LAUNCH_TESTS() has drop;
public struct TEST_QUOTE() has drop;
public struct OTHER_QUOTE() has drop;
public struct TEST_MIGRATION_WITNESS() has drop;
public struct OTHER_MIGRATION_WITNESS() has drop;

/// Launch construction through configured cold policy and creator custody.
public struct LaunchFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    config: launch_config::LaunchConfig,
    runtime_config: runtime_config::RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
fun launch_consumes_ticket_and_emits_complete_initial_state() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let ticket_id = object::id(&ticket);
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let launch_id = object::id(&launch);
        let created = events::collect_one<events::LaunchCreated>(0);
        let (
            emitted_launch_id,
            emitted_ticket_id,
            quote,
            migration_witness,
        ) = created.launch_created_identity_fields();
        let (curve_meme, protocol_meme, pool_meme) =
            created.launch_created_balance_fields();
        let (
            virtual_quote,
            migration_quote_target,
            quote_fee_bps,
            meme_fee_bps,
            quote_migration_fee_bps,
            protocol_meme_graduation_fee_bps,
            meme_liquidity_provision_bps,
        ) = created.launch_created_policy_fields();

        assert_eq!(emitted_launch_id, launch_id);
        assert_eq!(emitted_ticket_id, ticket_id);
        assert_eq!(quote, type_name::with_original_ids<TEST_QUOTE>());
        assert_eq!(
            migration_witness,
            type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
        );
        assert_eq!(launch.sell_burn_bps_for_testing(), SELL_BURN_BPS);
        assert_eq!(curve_meme, EXPECTED_CURVE_MEME);
        assert_eq!(protocol_meme, EXPECTED_PROTOCOL_MEME);
        assert_eq!(pool_meme, EXPECTED_POOL_MEME);
        assert_eq!(curve_meme + protocol_meme + pool_meme, INITIAL_MEME_SUPPLY);
        assert_eq!(virtual_quote, VIRTUAL_QUOTE);
        assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
        assert_eq!(quote_fee_bps, QUOTE_FEE_BPS);
        assert_eq!(meme_fee_bps, MEME_FEE_BPS);
        assert_eq!(quote_migration_fee_bps, QUOTE_MIGRATION_FEE_BPS);
        assert_eq!(
            protocol_meme_graduation_fee_bps,
            PROTOCOL_MEME_GRADUATION_FEE_BPS,
        );
        assert_eq!(
            meme_liquidity_provision_bps,
            MEME_LIQUIDITY_PROVISION_BPS,
        );
        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun launch_snapshot_does_not_follow_later_config_updates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let admin_witness = f.sign_in();

        f.config.allow_quote<TEST_QUOTE>(
            &f.package_version,
            &admin_witness,
            VIRTUAL_QUOTE + 1,
            MIGRATION_QUOTE_TARGET + 1,
        );
        f.config.set_graduation_defaults(
            &f.package_version,
            &admin_witness,
            0,
            0,
            1_000,
        );
        f.config.set_trade_fees(&f.package_version, &admin_witness, 0, 0);

        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun launch_share_publishes_the_key_only_launch_for_later_transactions() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.take_launch();

        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun launcher_can_designate_another_address_as_creator() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        launch.share();
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let (creator_cap, metadata_cap) = launch.claim_creator_cap(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        destroy(creator_cap);
        destroy(metadata_cap);
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
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let ticket_created = events::collect_one<events::LaunchTicketCreated>(0);
        let (
            emitted_ticket_id,
            _,
            _,
            _,
            _,
            _,
            burnable,
            sell_burn_bps,
        ) = ticket_created.launch_ticket_created_fields();
        let launch_created = events::collect_one<events::LaunchCreated>(0);
        let (_, source_ticket_id, _, _) =
            launch_created.launch_created_identity_fields();

        assert_eq!(emitted_ticket_id, ticket_id);
        assert_eq!(source_ticket_id, ticket_id);
        assert!(burnable);
        assert_eq!(sell_burn_bps, SELL_BURN_BPS);
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
fun creator_claim_returns_cap_and_native_metadata_cap_separately() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let expected_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (creator_cap, metadata_cap) = launch.claim_creator_cap(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        assert_eq!(object::id(&metadata_cap), expected_metadata_cap_id);
        assert!(!launch.has_creator_authority_for_testing());
        assert!(!launch.has_metadata_cap_for_testing());

        destroy(creator_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorAuthorityUnavailable,
    location = blast_fun::launch,
)]
fun creator_claim_cannot_be_repeated() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let (creator_cap, metadata_cap) = launch.claim_creator_cap(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        destroy(creator_cap);
        destroy(metadata_cap);

        let (creator_cap, metadata_cap) = launch.claim_creator_cap(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );

        destroy(creator_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EQuoteNotAllowed,
    location = blast_fun::launch_config,
)]
fun launch_delegates_quote_admission_to_launch_config() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = launch::new<LAUNCH_TESTS, OTHER_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeQuotePair,
    location = blast_fun::launch,
)]
fun launch_rejects_using_the_meme_type_as_quote_before_config_lookup() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = launch::new<
            LAUNCH_TESTS,
            LAUNCH_TESTS,
            TEST_MIGRATION_WITNESS,
        >(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidInitialMemeSupply,
    location = blast_fun::launch,
)]
fun launch_rejects_a_ticket_that_does_not_hold_the_canonical_supply() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.truncate_supply_for_testing(1);
        let launch = launch::new<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun buy_and_sell_all_bought_meme_move_exact_coins_and_accounting() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(LAUNCHER);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let (creator_cap, metadata_cap) = launch.claim_creator_cap(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
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
            f.ctx!(),
        );

        assert_eq!(meme_bought.value(), meme_out_net);
        assert_eq!(quote_refund.value(), 0);
        let bought = events::collect_one<events::Bought>(0);
        assert_bought_event(
            &bought,
            object::id(&launch),
            quote_in_gross,
            0,
            meme_out_gross,
        );

        let meme_in_gross = meme_out_net;
        let (meme_reserve_after_buy, real_quote_after_buy, _, _, _) =
            launch.initial_balances_for_testing();
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
            sold_launch_id,
            emitted_meme_in_gross,
            emitted_pending_burn_delta,
            emitted_pending_burn_total,
            emitted_quote_out_gross,
            protocol_fee_share_bps,
        ) = sold.sold_trade_fields();
        assert_eq!(sold_launch_id, object::id(&launch));
        assert_eq!(emitted_meme_in_gross, meme_in_gross);
        assert_eq!(emitted_pending_burn_delta, pending_burn_delta);
        assert_eq!(emitted_pending_burn_total, pending_burn_delta);
        assert_eq!(emitted_quote_out_gross, quote_out_gross);
        assert_eq!(protocol_fee_share_bps, 0);

        let (meme_reserve, real_quote, pending_burn, _, _) =
            launch.initial_balances_for_testing();
        assert_eq!(
            meme_reserve,
            meme_reserve_after_buy + meme_in_gross - sell_meme_fee - pending_burn_delta,
        );
        assert_eq!(real_quote, real_quote_after_buy - quote_out_gross);
        assert_eq!(pending_burn, pending_burn_delta);

        let (protocol_meme, creator_meme, protocol_quote, creator_quote) =
            launch.fee_totals_for_testing();
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
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) =
            launch.fee_totals_for_testing();
        assert_eq!(protocol_meme, 0);
        assert_eq!(creator_meme, 0);
        assert_eq!(protocol_quote, 0);
        assert_eq!(creator_quote, 0);

        destroy(creator_cap);
        destroy(metadata_cap);
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
        f.config.set_trade_fees(&f.package_version, &admin_witness, 0, 0);
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());
        let quote_out = launch.sell(&f.package_version, &f.runtime_config, meme_bought, 1, f.ctx!());

        assert!(quote_out.value() > 0);
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) =
            launch.fee_totals_for_testing();
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
fun creator_claim_drains_trade_fees_as_composable_coins() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let (creator_cap, metadata_cap) = launch.claim_creator_cap(
            &f.package_version,
            &f.runtime_config,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());
        let (_, creator_meme_before, _, creator_quote_before) =
            launch.fee_totals_for_testing();
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &creator_cap,
            f.ctx!(),
        );

        assert_eq!(meme_fees.value(), creator_meme_before);
        assert_eq!(quote_fees.value(), creator_quote_before);
        let claimed = events::collect_one<events::CreatorFeesClaimed>(0);
        let (launch_id, meme_amount, quote_amount) =
            claimed.creator_fees_claimed_fields();
        assert_eq!(launch_id, object::id(&launch));
        assert_eq!(meme_amount, creator_meme_before);
        assert_eq!(quote_amount, creator_quote_before);

        destroy(creator_cap);
        destroy(metadata_cap);
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
        f.runtime_config.set_protocol_fee_share(&f.package_version, &admin_witness, 2_500);
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) =
            launch.fee_totals_for_testing();

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
        let (launch_id, meme_amount, quote_amount) =
            claimed.protocol_fees_claimed_fields();
        assert_eq!(launch_id, object::id(&launch));
        assert_eq!(meme_amount, protocol_meme);
        assert_eq!(quote_amount, protocol_quote);

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
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());
        let (_, ready, _) = launch.lifecycle_for_testing();
        let (_, real_quote, _, _, _) = launch.initial_balances_for_testing();
        let bought = events::collect_one<events::Bought>(0);

        assert!(ready);
        assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
        assert!(quote_refund.value() > 0);
        assert_terminal_bought_event(
            &bought,
            object::id(&launch),
            quote_refund.value(),
        );
        destroy(meme_bought);
        destroy(quote_refund);
        launch.share();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let admin_witness = f.sign_in();
        let initial_supply = currency.total_supply().destroy_some();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(TEST_MIGRATION_WITNESS());
        let (_, _, migrated) = launch.lifecycle_for_testing();
        let migration = events::collect_one<events::Migrated>(0);
        let (
            launch_id,
            migration_meme,
            migration_quote,
            disposed_meme,
            native_supply_burned,
            total_supply_after,
            protocol_meme_fee,
            quote_migration_fee,
        ) = migration.migrated_balance_fields();

        assert!(migrated);
        assert_eq!(launch_id, object::id(&launch));
        assert!(!native_supply_burned);
        assert_eq!(migration_meme, EXPECTED_POOL_MEME);
        assert_eq!(migration_meme, meme.value());
        assert_eq!(migration_quote, quote.value());
        assert!(disposed_meme > 0);
        expected_disposed_meme = disposed_meme;
        assert_eq!(protocol_meme_fee, EXPECTED_PROTOCOL_MEME);
        assert!(quote_migration_fee > 0);
        assert_eq!(total_supply_after, initial_supply);
        assert_eq!(currency.total_supply().destroy_some(), initial_supply);

        let (protocol_meme, protocol_quote) = launch.claim_protocol_fees(
            &f.package_version,
            &admin_witness,
            f.ctx!(),
        );
        assert_eq!(protocol_meme.value(), protocol_meme_fee);
        assert_eq!(protocol_quote.value(), quote_migration_fee);

        destroy(meme);
        destroy(quote);
        destroy(protocol_meme);
        destroy(protocol_quote);
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
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());

        destroy(meme_bought);
        destroy(quote_refund);
        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(TEST_MIGRATION_WITNESS());
        let migration = events::collect_one<events::Migrated>(0);
        let (
            _,
            _,
            _,
            disposed_meme,
            native_supply_burned,
            total_supply_after,
            _,
            _,
        ) = migration.migrated_balance_fields();

        assert!(native_supply_burned);
        assert_eq!(total_supply_after, initial_supply - disposed_meme);
        assert_eq!(
            currency.total_supply().destroy_some(),
            initial_supply - disposed_meme,
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
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        expected_disposed_meme = launch.reach_migration_after_sell(
            &f.package_version,
            &f.runtime_config,
            f.ctx!(),
        );
        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(TEST_MIGRATION_WITNESS());
        let migration = events::collect_one<events::Migrated>(0);
        let (
            _,
            _,
            _,
            disposed_meme,
            native_supply_burned,
            total_supply_after,
            _,
            _,
        ) = migration.migrated_balance_fields();

        assert_eq!(disposed_meme, expected_disposed_meme);
        assert!(!native_supply_burned);
        assert_eq!(total_supply_after, initial_supply);
        assert_eq!(currency.total_supply().destroy_some(), initial_supply);

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
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        expected_disposed_meme = launch.reach_migration_after_sell(
            &f.package_version,
            &f.runtime_config,
            f.ctx!(),
        );
        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let initial_supply = currency.total_supply().destroy_some();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(TEST_MIGRATION_WITNESS());
        let migration = events::collect_one<events::Migrated>(0);
        let (
            _,
            _,
            _,
            disposed_meme,
            native_supply_burned,
            total_supply_after,
            _,
            _,
        ) = migration.migrated_balance_fields();

        assert_eq!(disposed_meme, expected_disposed_meme);
        assert!(native_supply_burned);
        assert_eq!(total_supply_after, initial_supply - expected_disposed_meme);
        assert_eq!(
            currency.total_supply().destroy_some(),
            initial_supply - expected_disposed_meme,
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
    location = blast_fun::launch,
)]
fun threshold_crossing_buy_closes_sell_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());
        destroy(quote_refund);
        let quote_out = launch.sell(&f.package_version, &f.runtime_config, meme_bought, 0, f.ctx!());

        destroy(quote_out);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
    location = blast_fun::launch,
)]
fun threshold_crossing_buy_closes_another_buy_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let terminal_quote =
            coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) = launch.buy(
            &f.package_version,
            &f.runtime_config,
            terminal_quote,
            1,
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
            f.ctx!(),
        );

        destroy(meme_bought);
        destroy(quote_refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
    location = blast_fun::launch,
)]
fun migration_rejects_a_live_launch_before_witness_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            OTHER_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(OTHER_MIGRATION_WITNESS());

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
    location = blast_fun::launch,
)]
fun migration_cannot_be_repeated_after_terminal_disposal() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());

        destroy(meme_bought);
        destroy(quote_refund);
        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(TEST_MIGRATION_WITNESS());

        destroy(meme);
        destroy(quote);

        let repeated_payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            TEST_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) =
            repeated_payload.redeem_migration(TEST_MIGRATION_WITNESS());

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ESlippageExceeded,
    location = blast_fun::launch,
)]
fun buy_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
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
            f.ctx!(),
        );

        destroy(meme);
        destroy(quote_refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ESlippageExceeded,
    location = blast_fun::launch,
)]
fun sell_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, f.ctx!());
        let (meme, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());
        destroy(quote_refund);
        let meme_in_gross = meme.value();
        let (meme_reserve, real_quote, _, _, _) =
            launch.initial_balances_for_testing();
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
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_aborts_before_zero_trade_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        f.package_version.set_for_testing(2);
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(0, f.ctx!());
        let (meme, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 0, f.ctx!());

        destroy(meme);
        destroy(quote_refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_aborts_migration_before_lifecycle_and_witness_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );

        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        f.package_version.set_for_testing(2);
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            OTHER_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(OTHER_MIGRATION_WITNESS());

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMigrationWitness,
    location = blast_fun::launch,
)]
fun migration_rejects_a_witness_type_not_selected_at_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, false);
        let mut launch = launch::new<LAUNCH_TESTS, TEST_QUOTE, TEST_MIGRATION_WITNESS>(
            ticket,
            &f.package_version,
            &f.config,
            f.ctx!(),
        );
        let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, f.ctx!());
        let (meme_bought, quote_refund) =
            launch.buy(&f.package_version, &f.runtime_config, quote_in, 1, f.ctx!());

        destroy(meme_bought);
        destroy(quote_refund);
        launch.share();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let payload = launch.migrate<
            LAUNCH_TESTS,
            TEST_QUOTE,
            OTHER_MIGRATION_WITNESS,
        >(
            &f.package_version,
            &mut currency,
            f.ctx!(),
        );
        let (meme, quote) = payload.redeem_migration(OTHER_MIGRATION_WITNESS());

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

// === Private Test Helpers ===

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

fun start(): LaunchFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    launch_config::init_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let mut config = scenario.take_shared<launch_config::LaunchConfig>();
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(
        &package_version,
        &admin_witness,
        VIRTUAL_QUOTE,
        MIGRATION_QUOTE_TARGET,
    );
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(
        &package_version,
        &admin_witness,
    );
    config.set_trade_fees(
        &package_version,
        &admin_witness,
        QUOTE_FEE_BPS,
        MEME_FEE_BPS,
    );
    config.set_graduation_defaults(
        &package_version,
        &admin_witness,
        QUOTE_MIGRATION_FEE_BPS,
        PROTOCOL_MEME_GRADUATION_FEE_BPS,
        MEME_LIQUIDITY_PROVISION_BPS,
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
    launch_ticket::new(
        LAUNCH_TESTS(),
        b"LAUNCH".to_string(),
        b"Launch Test".to_string(),
        b"Normalized launch state".to_string(),
        b"".to_string(),
        creator_authority::new_address(creator),
        burnable,
        SELL_BURN_BPS,
        self.scenario.ctx(),
    )
}

fun launch_sign_in(self: &LaunchFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun launch_take_currency(self: &LaunchFixture): Currency<LAUNCH_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun launch_take_fixed_disposal(self: &LaunchFixture): Coin<LAUNCH_TESTS> {
    self.scenario.take_from_address(@0x0)
}

fun launch_take_shared(
    self: &LaunchFixture,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    self.scenario.take_shared<Launch<LAUNCH_TESTS, TEST_QUOTE>>()
}

fun assert_launch_snapshot(launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let (
        curve_meme,
        real_quote,
        pending_burn,
        protocol_meme,
        pool_meme,
    ) = launch.initial_balances_for_testing();
    let (
        virtual_quote,
        migration_quote_target,
        quote_fee_bps,
        meme_fee_bps,
        quote_migration_fee_bps,
        migration_witness,
    ) = launch.policy_for_testing();

    assert_eq!(curve_meme, EXPECTED_CURVE_MEME);
    assert_eq!(real_quote, 0);
    assert_eq!(pending_burn, 0);
    assert_eq!(protocol_meme, EXPECTED_PROTOCOL_MEME);
    assert_eq!(pool_meme, EXPECTED_POOL_MEME);
    assert_eq!(virtual_quote, VIRTUAL_QUOTE);
    assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
    assert_eq!(quote_fee_bps, QUOTE_FEE_BPS);
    assert_eq!(meme_fee_bps, MEME_FEE_BPS);
    assert_eq!(quote_migration_fee_bps, QUOTE_MIGRATION_FEE_BPS);
    assert_eq!(
        migration_witness,
        type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );
}

fun assert_bought_event(
    bought: &events::Bought,
    launch_id: ID,
    quote_in_gross: u64,
    quote_refund: u64,
    meme_out_gross: u64,
) {
    let (
        emitted_launch_id,
        emitted_quote_in_gross,
        emitted_quote_refund,
        emitted_meme_out_gross,
        protocol_fee_share_bps,
    ) = bought.bought_trade_fields();

    assert_eq!(emitted_launch_id, launch_id);
    assert_eq!(emitted_quote_in_gross, quote_in_gross);
    assert_eq!(emitted_quote_refund, quote_refund);
    assert_eq!(emitted_meme_out_gross, meme_out_gross);
    assert_eq!(protocol_fee_share_bps, 0);
}

fun assert_terminal_bought_event(
    bought: &events::Bought,
    launch_id: ID,
    quote_refund: u64,
) {
    let (emitted_launch_id, quote_in_gross, emitted_quote_refund, _, _) =
        bought.bought_trade_fields();

    assert_eq!(emitted_launch_id, launch_id);
    assert_eq!(quote_in_gross + emitted_quote_refund, 30_000_000);
    assert_eq!(emitted_quote_refund, quote_refund);
}

fun reach_migration_after_sell(
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
    package_version: &PackageVersion,
    runtime_config: &runtime_config::RuntimeConfig,
    ctx: &mut TxContext,
): u64 {
    let quote_in = coin::mint_for_testing<TEST_QUOTE>(10_000_000, ctx);
    let (meme_bought, quote_refund) =
        launch.buy(package_version, runtime_config, quote_in, 1, ctx);
    let quote_out = launch.sell(
        package_version,
        runtime_config,
        meme_bought,
        1,
        ctx,
    );
    let (_, _, pending_burn_before_terminal_buy, _, _) =
        launch.initial_balances_for_testing();

    assert_eq!(quote_refund.value(), 0);
    assert!(quote_out.value() > 0);
    assert!(pending_burn_before_terminal_buy > 0);
    destroy(quote_refund);
    destroy(quote_out);

    let quote_in = coin::mint_for_testing<TEST_QUOTE>(30_000_000, ctx);
    let (meme_bought, quote_refund) =
        launch.buy(package_version, runtime_config, quote_in, 1, ctx);
    let (meme_reserve, real_quote, pending_burn, _, _) =
        launch.initial_balances_for_testing();
    let (_, ready, _) = launch.lifecycle_for_testing();

    assert!(ready);
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
