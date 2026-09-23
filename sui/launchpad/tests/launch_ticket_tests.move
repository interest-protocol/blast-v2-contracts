// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_ticket_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const LAUNCHER: address = @0xA11CE;

const CREATOR: address = @0xC0FFEE;

const MEME_DECIMALS: u8 = 9;

const MEME_TOTAL_SUPPLY: u64 = 1_000_000_000__000_000_000;

const SIX_DECIMALS: u8 = 6;

const SIX_DECIMAL_SUPPLY: u64 = 1_000_000_000_000_000;

const SELL_BURN_BPS: u64 = 1_250;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_TICKET_TESTS has drop {}

/// A droppable type that is not a one-time witness.
public struct NotAWitness() has drop;

/// Stand-ins for two migration adapters' sealed witnesses.
public struct Adapter() has drop;

public struct OtherAdapter() has drop;

/// Stand-ins for two Quote types a ticket can be bound for.
public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

/// Transaction runner for ticket-construction tests, with a configuration admitting both adapters.
public struct TicketFixture {
    scenario: Scenario,
    config: LaunchConfig,
}

// === Tests ===

#[test]
fun address_ticket_mints_supply_and_fixes_it_at_intake() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_address(CREATOR);
        let ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_recipient,
            false,
            0,
        );
        let created = events::collect_one<events::LaunchTicketCreated>(0);

        assert_eq!(
            bcs::to_bytes(&created),
            ticket_created_bytes(
                object::id(&ticket),
                ticket.metadata_cap_id_for_testing(),
                MEME_DECIMALS,
                MEME_TOTAL_SUPPLY,
                option::some(CREATOR),
                option::none(),
                false,
                0,
            ),
        );

        transfer::public_transfer(ticket, LAUNCHER);
    });

    fixture.next_tx_expecting_events!(LAUNCHER, 1, |f| {
        let ticket = f.take_ticket();
        let mut currency = f.take_currency();

        assert!(currency.total_supply().is_none());

        let (meme, metadata_cap, creator_authority, sell_burn_bps) = ticket.destroy(
            &mut currency,
            MEME_TOTAL_SUPPLY,
        );

        assert!(currency.is_supply_fixed());
        assert!(!currency.is_supply_burn_only());
        assert_eq!(currency.decimals(), MEME_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), MEME_TOTAL_SUPPLY);
        assert_eq!(meme.value(), MEME_TOTAL_SUPPLY);
        assert_eq!(sell_burn_bps.value(), 0);
        destroy(meme);
        destroy(metadata_cap);
        destroy(creator_authority);
        destroy(currency);
    });

    fixture.end();
}

#[test]
fun account_ticket_is_composable_and_records_burn_only_selection() {
    let mut fixture = start();
    let account_commitment =
        x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211";
    let expected_ticket_id;
    let expected_metadata_cap_id;

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_account(account_commitment);
        let ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_recipient,
            true,
            SELL_BURN_BPS,
        );
        let created_ticket_id = object::id(&ticket);
        let created = events::collect_one<events::LaunchTicketCreated>(0);
        let metadata_cap_id = ticket.metadata_cap_id_for_testing();

        assert_eq!(
            bcs::to_bytes(&created),
            ticket_created_bytes(
                created_ticket_id,
                metadata_cap_id,
                MEME_DECIMALS,
                MEME_TOTAL_SUPPLY,
                option::none(),
                option::some(account_commitment),
                true,
                SELL_BURN_BPS,
            ),
        );

        expected_ticket_id = created_ticket_id;
        expected_metadata_cap_id = metadata_cap_id;

        transfer::public_transfer(ticket, CREATOR);
    });

    fixture.next_tx_expecting_events!(CREATOR, 1, |f| {
        let ticket = f.take_ticket();
        let mut currency = f.take_currency();
        assert_eq!(object::id(&ticket), expected_ticket_id);

        let (meme, metadata_cap, creator_authority, sell_burn_bps) = ticket.destroy(
            &mut currency,
            MEME_TOTAL_SUPPLY,
        );

        assert_eq!(object::id(&metadata_cap), expected_metadata_cap_id);
        assert_eq!(meme.value(), MEME_TOTAL_SUPPLY);
        assert_eq!(sell_burn_bps.value(), SELL_BURN_BPS);
        assert!(!currency.is_supply_fixed());
        assert!(currency.is_supply_burn_only());
        assert_eq!(currency.decimals(), MEME_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), MEME_TOTAL_SUPPLY);

        destroy(meme);
        destroy(metadata_cap);
        destroy(creator_authority);
        destroy(currency);
    });

    fixture.end();
}

#[test]
fun ticket_accepts_fifty_percent_sell_burn() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_address(CREATOR);
        let ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_recipient,
            false,
            5_000,
        );
        let created = events::collect_one<events::LaunchTicketCreated>(0);

        assert_eq!(
            bcs::to_bytes(&created),
            ticket_created_bytes(
                object::id(&ticket),
                ticket.metadata_cap_id_for_testing(),
                MEME_DECIMALS,
                MEME_TOTAL_SUPPLY,
                option::some(CREATOR),
                option::none(),
                false,
                5_000,
            ),
        );
        assert_eq!(ticket.sell_burn_bps().value(), 5_000);
        destroy(ticket);
    });

    fixture.end();
}

#[test]
fun bound_adapter_borrows_the_treasury_cap_until_rebound() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_authority::new_address(CREATOR),
            false,
            0,
        );

        assert!(ticket.migration_witness<_, QUOTE>().is_none());
        ticket.bind_migration_witness<_, QUOTE, _>(&f.config, Adapter());
        assert_eq!(ticket.treasury_cap_mut(&f.config, Adapter()).total_supply(), MEME_TOTAL_SUPPLY);
        ticket.bind_migration_witness<_, OTHER_QUOTE, _>(&f.config, OtherAdapter());
        assert!(ticket.migration_witness<_, QUOTE>().is_none());
        assert_eq!(
            ticket.migration_witness<_, OTHER_QUOTE>(),
            option::some(type_name::with_original_ids<OtherAdapter>()),
        );
        assert_eq!(ticket.treasury_cap_mut(&f.config, OtherAdapter()).total_supply(), MEME_TOTAL_SUPPLY);

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitness,
        location = blast_fun::launch_ticket,
    ),
]
fun unbound_ticket_lends_no_treasury_cap() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_authority::new_address(CREATOR),
            false,
            0,
        );

        ticket.treasury_cap_mut(&f.config, Adapter());

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitness,
        location = blast_fun::launch_ticket,
    ),
]
fun replaced_adapter_loses_the_treasury_cap() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_authority::new_address(CREATOR),
            false,
            0,
        );

        ticket.bind_migration_witness<_, QUOTE, _>(&f.config, Adapter());
        ticket.bind_migration_witness<_, QUOTE, _>(&f.config, OtherAdapter());
        ticket.treasury_cap_mut(&f.config, Adapter());

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidCreatorRecipient,
    location = blast_fun::creator_authority,
)]
fun address_ticket_rejects_zero_creator_before_currency_creation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_address(@0x0);
        let ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_recipient,
            false,
            0,
        );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidAccountCommitment,
    location = blast_fun::creator_authority,
)]
fun account_ticket_rejects_invalid_commitment_before_currency_creation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_account(x"1122");
        let ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_recipient,
            true,
            SELL_BURN_BPS,
        );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidSellBurnBps,
    location = blast_fun::launch_ticket,
)]
fun ticket_rejects_the_first_sell_burn_above_fifty_percent() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_address(CREATOR);
        let ticket = f.new_ticket(
            MEME_DECIMALS,
            creator_recipient,
            false,
            5_001,
        );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
fun six_decimal_ticket_mints_exactly_one_billion_whole_tokens() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(
            SIX_DECIMALS,
            creator_authority::new_address(CREATOR),
            false,
            0,
        );

        assert_eq!(ticket.decimals(), SIX_DECIMALS);

        transfer::public_transfer(ticket, LAUNCHER);
    });

    fixture.next_tx_expecting_events!(LAUNCHER, 1, |f| {
        let mut currency = f.take_currency();
        let (meme, metadata_cap, creator_authority, _) = f
            .take_ticket()
            .destroy(&mut currency, SIX_DECIMAL_SUPPLY);

        assert_eq!(currency.decimals(), SIX_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), SIX_DECIMAL_SUPPLY);

        destroy(meme);
        destroy(metadata_cap);
        destroy(creator_authority);
        destroy(currency);
    });

    fixture.end();
}

#[test]
fun atomic_supply_is_one_billion_whole_tokens_at_each_precision() {
    assert_eq!(launch_ticket::atomic_supply(SIX_DECIMALS), SIX_DECIMAL_SUPPLY);
    assert_eq!(launch_ticket::atomic_supply(MEME_DECIMALS), MEME_TOTAL_SUPPLY);
    assert_eq!(launch_ticket::atomic_supply(10), 10_000_000_000_000_000_000);
}

#[test, expected_failure(arithmetic_error, location = blast_fun::launch_ticket)]
fun supply_that_exceeds_u64_aborts() {
    launch_ticket::atomic_supply(11);
}

#[test]
#[expected_failure(abort_code = sui::coin_registry::ENotOneTimeWitness, location = sui::coin_registry)]
fun ticket_rejects_a_type_that_is_not_a_one_time_witness() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = launch_ticket::new(
            NotAWitness(),
            MEME_DECIMALS,
            b"TICKET".to_string(),
            b"Ticket Test".to_string(),
            b"Launch ticket".to_string(),
            b"".to_string(),
            creator_authority::new_address(CREATOR),
            false,
            0,
            f.ctx!(),
        );

        destroy(ticket);
    });

    fixture.end();
}

// === Test Helpers ===

/// Expected `LaunchTicketCreated` bytes in payload order for the canonical generated supply.
fun ticket_created_bytes(
    ticket_id: ID,
    metadata_cap_id: ID,
    decimals: u8,
    atomic_supply: u64,
    creator_address: Option<address>,
    account_commitment: Option<vector<u8>>,
    burnable: bool,
    sell_burn_bps: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&ticket_id);
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LAUNCH_TICKET_TESTS>()));
    expected.append(bcs::to_bytes(&decimals));
    expected.append(bcs::to_bytes(&atomic_supply));
    expected.append(bcs::to_bytes(&metadata_cap_id));
    expected.append(bcs::to_bytes(&creator_address));
    expected.append(bcs::to_bytes(&account_commitment));
    expected.append(bcs::to_bytes(&burnable));
    expected.append(bcs::to_bytes(&sell_burn_bps));
    expected
}

macro fun next_tx(
    $fixture: &mut TicketFixture,
    $sender: address,
    $fn: |&mut TicketFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun next_tx_expecting_events(
    $fixture: &mut TicketFixture,
    $sender: address,
    $count: u64,
    $fn: |&mut TicketFixture|,
) {
    let fixture = $fixture;

    assert_eq!(fixture.scenario.next_tx($sender).num_user_events(), $count);
    $fn(fixture);
}

fun start(): TicketFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::creator_admin_role(),
        LAUNCHER,
        scenario.ctx(),
    );

    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let admin_witness = authority.sign_in(&admin_cap);
    let mut config = launch_config::new_for_testing(scenario.ctx());
    config.allow_migration_witness<Adapter>(&package_version, &admin_witness);
    config.allow_migration_witness<OtherAdapter>(&package_version, &admin_witness);
    destroy(super_admin_cap);
    destroy(authority);
    destroy(admin_cap);
    destroy(package_version);

    scenario.next_tx(LAUNCHER);
    TicketFixture { scenario, config }
}

macro fun ctx($fixture: &mut TicketFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun new_ticket(
    self: &mut TicketFixture,
    decimals: u8,
    creator_recipient: creator_authority::CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
): LaunchTicket<LAUNCH_TICKET_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_TICKET_TESTS>(),
        decimals,
        b"TICKET".to_string(),
        b"Ticket Test".to_string(),
        b"Launch ticket".to_string(),
        b"".to_string(),
        creator_recipient,
        burnable,
        sell_burn_bps,
        self.ctx!(),
    )
}

fun take_ticket(self: &TicketFixture): LaunchTicket<LAUNCH_TICKET_TESTS> {
    self.scenario.take_from_sender()
}

/// The one-time-witness path delivers the currency to the Coin Registry address.
fun take_currency(self: &TicketFixture): Currency<LAUNCH_TICKET_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun end(self: TicketFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::AdminCap;

use blast_fun::{
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    creator_authority,
    domain_fixture,
    events,
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    package_version,
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{coin_registry::Currency, test_scenario::{Self, Scenario}, test_utils};
