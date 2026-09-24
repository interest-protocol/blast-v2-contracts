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

/// Transaction runner for ticket-construction tests.
public struct TicketFixture {
    scenario: Scenario,
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
        let created = collect_one<events::LaunchTicketCreated>();

        assert_eq!(
            bcs::to_bytes(&created),
            ticket_created_bytes(
                object::id(&ticket),
                ticket.metadata_cap_id_for_testing(),
                MEME_DECIMALS,
                creator_recipient,
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

        let (meme, metadata_cap, creator, sell_burn_bps) = ticket.destroy(
            &mut currency,
            MEME_TOTAL_SUPPLY,
        );

        assert!(currency.is_supply_fixed());
        assert!(!currency.is_supply_burn_only());
        assert_eq!(currency.decimals(), MEME_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), MEME_TOTAL_SUPPLY);
        assert_eq!(meme.value(), MEME_TOTAL_SUPPLY);
        assert_eq!(creator, creator_authority::new_address(CREATOR));
        assert_eq!(sell_burn_bps.value(), 0);
        destroy(meme);
        destroy(metadata_cap);
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
        let created = collect_one<events::LaunchTicketCreated>();
        let metadata_cap_id = ticket.metadata_cap_id_for_testing();

        assert_eq!(
            bcs::to_bytes(&created),
            ticket_created_bytes(
                created_ticket_id,
                metadata_cap_id,
                MEME_DECIMALS,
                creator_recipient,
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

        let (meme, metadata_cap, creator, sell_burn_bps) = ticket.destroy(
            &mut currency,
            MEME_TOTAL_SUPPLY,
        );

        assert_eq!(object::id(&metadata_cap), expected_metadata_cap_id);
        assert_eq!(meme.value(), MEME_TOTAL_SUPPLY);
        assert_eq!(creator, creator_authority::new_account(account_commitment));
        assert_eq!(sell_burn_bps.value(), SELL_BURN_BPS);
        assert!(!currency.is_supply_fixed());
        assert!(currency.is_supply_burn_only());
        assert_eq!(currency.decimals(), MEME_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), MEME_TOTAL_SUPPLY);

        destroy(meme);
        destroy(metadata_cap);
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
        let created = collect_one<events::LaunchTicketCreated>();

        assert_eq!(
            bcs::to_bytes(&created),
            ticket_created_bytes(
                object::id(&ticket),
                ticket.metadata_cap_id_for_testing(),
                MEME_DECIMALS,
                creator_recipient,
                false,
                5_000,
            ),
        );
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
        let (meme, metadata_cap, _, _) = f
            .take_ticket()
            .destroy(&mut currency, SIX_DECIMAL_SUPPLY);

        assert_eq!(currency.decimals(), SIX_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), SIX_DECIMAL_SUPPLY);

        destroy(meme);
        destroy(metadata_cap);
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

/// Expected `LaunchTicketCreated` bytes in payload order.
fun ticket_created_bytes(
    ticket_id: ID,
    metadata_cap_id: ID,
    decimals: u8,
    creator: CreatorRecipient,
    burnable: bool,
    sell_burn_bps: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&ticket_id);
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LAUNCH_TICKET_TESTS>()));
    expected.append(bcs::to_bytes(&decimals));
    expected.append(bcs::to_bytes(&metadata_cap_id));
    expected.append(bcs::to_bytes(&creator));
    expected.append(bcs::to_bytes(&burnable));
    expected.append(bcs::to_bytes(&sell_burn_bps));
    expected
}

fun collect_one<T: copy + drop>(): T {
    let mut payloads = event::events_by_type<Event<T>>().map!(|event| event.unwrap());
    assert_eq!(payloads.length(), 1);
    payloads.pop_back()
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
    TicketFixture { scenario: test_scenario::begin(LAUNCHER) }
}

macro fun ctx($fixture: &mut TicketFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun new_ticket(
    self: &mut TicketFixture,
    decimals: u8,
    creator_recipient: CreatorRecipient,
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

use blast_fun::{
    blast_events::Event,
    creator_authority::{Self, CreatorRecipient},
    events,
    launch_ticket::{Self, LaunchTicket},
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{coin_registry::Currency, event, test_scenario::{Self, Scenario}, test_utils};
