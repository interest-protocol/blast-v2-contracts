#[test_only]
module blast_fun::launch_ticket_tests;

use blast_fun::{creator_authority, events, launch_ticket::{Self, LaunchTicket}};
use std::unit_test::{assert_eq, destroy};
use sui::{coin_registry::Currency, test_scenario::{Self, Scenario}};

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;
/// `sui::object::SUI_COIN_REGISTRY_OBJECT_ID` at the pinned framework revision.
const COIN_REGISTRY: address = @0xc;
const MEME_DECIMALS: u8 = 9;
const MEME_TOTAL_SUPPLY: u64 = 1_000_000_000__000_000_000;
const SELL_BURN_BPS: u64 = 1_250;

// === Test-Only Types ===

public struct LAUNCH_TICKET_TESTS() has drop;
public struct INVALID_OTW(bool) has drop;

/// Bare transaction runner for ticket-construction tests.
public struct TicketFixture {
    scenario: Scenario,
}

// === Tests ===

#[test]
fun address_ticket_mints_fixed_supply_and_emits_replay_complete_event() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_address(CREATOR);
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            b"TICKET".to_string(),
            b"Ticket Test".to_string(),
            b"Address launch ticket".to_string(),
            b"https://blast.fun/ticket.png".to_string(),
            creator_recipient,
            false,
            0,
            f.ctx!(),
        );
        let ticket_id = object::id(&ticket);

        let created = events::collect_one<events::LaunchTicketCreated>(0);
        let (
            emitted_ticket_id,
            meme,
            initial_supply,
            metadata_cap_id,
            creator,
            account_commitment,
            burnable,
            sell_burn_bps,
        ) = created.launch_ticket_created_fields();

        assert_eq!(emitted_ticket_id, ticket_id);
        assert_eq!(
            meme,
            std::type_name::with_original_ids<LAUNCH_TICKET_TESTS>(),
        );
        assert_eq!(creator.destroy_some(), CREATOR);
        assert!(account_commitment.is_none());
        assert!(!burnable);
        assert_eq!(sell_burn_bps, 0);
        assert_eq!(initial_supply, MEME_TOTAL_SUPPLY);

        let (meme, metadata_cap, creator_authority, sell_burn_bps) =
            ticket.destroy();

        assert_eq!(object::id(&metadata_cap), metadata_cap_id);
        assert_eq!(meme.value(), MEME_TOTAL_SUPPLY);
        assert_eq!(sell_burn_bps.value(), 0);
        destroy(meme);
        destroy(metadata_cap);
        destroy(creator_authority);
    });

    fixture.next_tx_expecting_events!(LAUNCHER, 1, |f| {
        let currency = f.take_currency<LAUNCH_TICKET_TESTS>();

        assert!(currency.is_supply_fixed());
        assert!(!currency.is_supply_burn_only());
        assert_eq!(currency.decimals(), MEME_DECIMALS);
        assert_eq!(currency.total_supply().destroy_some(), MEME_TOTAL_SUPPLY);

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
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            b"ACCOUNT".to_string(),
            b"Account Ticket Test".to_string(),
            b"Account launch ticket".to_string(),
            b"".to_string(),
            creator_recipient,
            true,
            SELL_BURN_BPS,
            f.ctx!(),
        );
        let created_ticket_id = object::id(&ticket);
        let created = events::collect_one<events::LaunchTicketCreated>(0);
        let (
            ticket_id,
            _,
            initial_supply,
            metadata_cap_id,
            creator,
            emitted_account_commitment,
            burnable,
            sell_burn_bps,
        ) = created.launch_ticket_created_fields();

        assert_eq!(ticket_id, created_ticket_id);
        assert!(creator.is_none());
        assert_eq!(emitted_account_commitment.destroy_some(), account_commitment);
        assert!(burnable);
        assert_eq!(sell_burn_bps, SELL_BURN_BPS);
        assert_eq!(initial_supply, MEME_TOTAL_SUPPLY);

        expected_ticket_id = ticket_id;
        expected_metadata_cap_id = metadata_cap_id;

        transfer::public_transfer(ticket, CREATOR);
    });

    fixture.next_tx_expecting_events!(CREATOR, 1, |f| {
        let ticket = f.take_ticket();
        assert_eq!(object::id(&ticket), expected_ticket_id);

        let (meme, metadata_cap, creator_authority, sell_burn_bps) =
            ticket.destroy();

        assert_eq!(object::id(&metadata_cap), expected_metadata_cap_id);
        assert_eq!(meme.value(), MEME_TOTAL_SUPPLY);
        assert_eq!(sell_burn_bps.value(), SELL_BURN_BPS);
        let currency = f.take_currency<LAUNCH_TICKET_TESTS>();

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
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            b"MAXBURN".to_string(),
            b"Maximum Burn".to_string(),
            b"Maximum valid sell burn".to_string(),
            b"".to_string(),
            creator_recipient,
            false,
            5_000,
            f.ctx!(),
        );
        let created = events::collect_one<events::LaunchTicketCreated>(0);
        let (_, _, _, _, _, _, _, sell_burn_bps) =
            created.launch_ticket_created_fields();
        let (meme, metadata_cap, creator_authority, stored_sell_burn_bps) =
            ticket.destroy();

        assert_eq!(sell_burn_bps, 5_000);
        assert_eq!(stored_sell_burn_bps.value(), 5_000);
        destroy(meme);
        destroy(metadata_cap);
        destroy(creator_authority);
    });

    fixture.next_tx_expecting_events!(LAUNCHER, 1, |f| {
        let currency = f.take_currency<LAUNCH_TICKET_TESTS>();

        assert!(currency.is_supply_fixed());
        destroy(currency);
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
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            b"TICKET".to_string(),
            b"Ticket Test".to_string(),
            b"Invalid creator".to_string(),
            b"".to_string(),
            creator_recipient,
            false,
            0,
            f.ctx!(),
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
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            b"ACCOUNT".to_string(),
            b"Account Ticket Test".to_string(),
            b"Invalid account commitment".to_string(),
            b"".to_string(),
            creator_recipient,
            true,
            SELL_BURN_BPS,
            f.ctx!(),
        );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = sui::coin_registry::ENotOneTimeWitness,
    location = sui::coin_registry,
)]
fun ticket_rejects_a_non_otw_type() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_recipient = creator_authority::new_address(CREATOR);
        let ticket = launch_ticket::new(
            INVALID_OTW(false),
            b"INVALID".to_string(),
            b"Invalid OTW".to_string(),
            b"Not a one-time witness".to_string(),
            b"".to_string(),
            creator_recipient,
            false,
            0,
            f.ctx!(),
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
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            b"TICKET".to_string(),
            b"Ticket Test".to_string(),
            b"Invalid sell burn".to_string(),
            b"".to_string(),
            creator_recipient,
            false,
            5_001,
            f.ctx!(),
        );

        destroy(ticket);
    });

    fixture.end();
}

// === Private Test Helpers ===

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

macro fun ctx($fixture: &mut TicketFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): TicketFixture {
    TicketFixture { scenario: test_scenario::begin(LAUNCHER) }
}

fun take_ticket(self: &TicketFixture): LaunchTicket<LAUNCH_TICKET_TESTS> {
    self.scenario.take_from_sender()
}

fun take_currency<Meme>(self: &TicketFixture): Currency<Meme> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun end(self: TicketFixture) {
    destroy(self);
}
