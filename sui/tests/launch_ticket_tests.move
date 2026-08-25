#[test_only]
module blast_fun::launch_ticket_tests;

use blast_fun::{creator_authority, events, launch_ticket::{Self, LaunchTicket}};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;

// === Test-Only Types ===

public struct LAUNCH_TICKET_TESTS() has drop;
public struct INVALID_OTW(bool) has drop;

/// Bare transaction runner for ticket-construction tests.
public struct TicketFixture {
    scenario: Scenario,
}

// === Tests ===

#[test]
fun address_ticket_returns_empty_capabilities_and_replay_complete_event() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_identity = creator_authority::new_address(CREATOR);
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            9,
            b"TICKET".to_string(),
            b"Ticket Test".to_string(),
            b"Address launch ticket".to_string(),
            b"https://blast.fun/ticket.png".to_string(),
            creator_identity,
            false,
            f.ctx!(),
        );
        let ticket_id = object::id(&ticket);

        let created = events::collect_one<events::LaunchTicketCreated>(0);
        let (
            emitted_ticket_id,
            meme,
            treasury_cap_id,
            metadata_cap_id,
            launcher,
            creator,
            x_identity_hash,
            burnable,
        ) = created.launch_ticket_created_fields();

        assert_eq!(emitted_ticket_id, ticket_id);
        assert_eq!(
            meme,
            std::type_name::with_original_ids<LAUNCH_TICKET_TESTS>(),
        );
        assert_eq!(launcher, LAUNCHER);
        assert_eq!(creator.destroy_some(), CREATOR);
        assert!(x_identity_hash.is_none());
        assert!(!burnable);

        let (treasury_cap, metadata_cap, creator_authority, burnable) =
            ticket.into_parts();

        assert_eq!(object::id(&treasury_cap), treasury_cap_id);
        assert_eq!(object::id(&metadata_cap), metadata_cap_id);
        assert_eq!(treasury_cap.total_supply(), 0);
        assert!(!burnable);

        destroy(treasury_cap);
        destroy(metadata_cap);
        destroy(creator_authority);
    });

    fixture.end();
}

#[test]
fun x_ticket_is_composable_and_records_burn_only_selection() {
    let mut fixture = start();
    let x_identity_hash =
        x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211";
    let expected_ticket_id;
    let expected_treasury_cap_id;
    let expected_metadata_cap_id;

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_identity = creator_authority::new_x(x_identity_hash);
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            6,
            b"XTICKET".to_string(),
            b"X Ticket Test".to_string(),
            b"X launch ticket".to_string(),
            b"".to_string(),
            creator_identity,
            true,
            f.ctx!(),
        );
        let created_ticket_id = object::id(&ticket);
        let created = events::collect_one<events::LaunchTicketCreated>(0);
        let (
            ticket_id,
            _,
            treasury_cap_id,
            metadata_cap_id,
            launcher,
            creator,
            emitted_x_identity_hash,
            burnable,
        ) = created.launch_ticket_created_fields();

        assert_eq!(ticket_id, created_ticket_id);
        assert_eq!(launcher, LAUNCHER);
        assert!(creator.is_none());
        assert_eq!(emitted_x_identity_hash.destroy_some(), x_identity_hash);
        assert!(burnable);

        expected_ticket_id = ticket_id;
        expected_treasury_cap_id = treasury_cap_id;
        expected_metadata_cap_id = metadata_cap_id;

        transfer::public_transfer(ticket, CREATOR);
    });

    fixture.next_tx_expecting_events!(CREATOR, 1, |f| {
        let ticket = f.take_ticket();
        assert_eq!(object::id(&ticket), expected_ticket_id);

        let (treasury_cap, metadata_cap, creator_authority, burnable) =
            ticket.into_parts();

        assert_eq!(object::id(&treasury_cap), expected_treasury_cap_id);
        assert_eq!(object::id(&metadata_cap), expected_metadata_cap_id);
        assert_eq!(treasury_cap.total_supply(), 0);
        assert!(burnable);

        destroy(treasury_cap);
        destroy(metadata_cap);
        destroy(creator_authority);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 9, location = blast_fun::creator_authority)]
fun address_ticket_rejects_zero_creator_before_currency_creation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_identity = creator_authority::new_address(@0x0);
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            9,
            b"TICKET".to_string(),
            b"Ticket Test".to_string(),
            b"Invalid creator".to_string(),
            b"".to_string(),
            creator_identity,
            false,
            f.ctx!(),
        );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 10, location = blast_fun::creator_authority)]
fun x_ticket_rejects_invalid_identity_before_currency_creation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let creator_identity = creator_authority::new_x(x"1122");
        let ticket = launch_ticket::new(
            LAUNCH_TICKET_TESTS(),
            9,
            b"XTICKET".to_string(),
            b"X Ticket Test".to_string(),
            b"Invalid X identity".to_string(),
            b"".to_string(),
            creator_identity,
            true,
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
        let creator_identity = creator_authority::new_address(CREATOR);
        let ticket = launch_ticket::new(
            INVALID_OTW(false),
            9,
            b"INVALID".to_string(),
            b"Invalid OTW".to_string(),
            b"Not a one-time witness".to_string(),
            b"".to_string(),
            creator_identity,
            false,
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

fun end(self: TicketFixture) {
    destroy(self);
}
