#[test_only]
module blast_fun::launch_ticket_tests;

use blast_fun::{events, launch_ticket::{Self, LaunchTicket}};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario;

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;

// === Test-Only Types ===

public struct LAUNCH_TICKET_TESTS() has drop;
public struct INVALID_OTW(bool) has drop;

// === Tests ===

#[test]
fun address_ticket_returns_empty_capabilities_and_replay_complete_event() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let ticket = launch_ticket::new_address(
        LAUNCH_TICKET_TESTS(),
        9,
        b"TICKET".to_string(),
        b"Ticket Test".to_string(),
        b"Address launch ticket".to_string(),
        b"https://blast.fun/ticket.png".to_string(),
        CREATOR,
        false,
        scenario.ctx(),
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
    destroy(scenario);
}

#[test]
fun x_ticket_is_composable_and_records_burn_only_selection() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let x_identity_hash = x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211";
    let ticket = launch_ticket::new_x(
        LAUNCH_TICKET_TESTS(),
        6,
        b"XTICKET".to_string(),
        b"X Ticket Test".to_string(),
        b"X launch ticket".to_string(),
        b"".to_string(),
        x_identity_hash,
        true,
        scenario.ctx(),
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

    transfer::public_transfer(ticket, CREATOR);

    let effects = scenario.next_tx(CREATOR);
    assert_eq!(effects.num_user_events(), 1);
    let ticket = scenario.take_from_sender<LaunchTicket<LAUNCH_TICKET_TESTS>>();
    assert_eq!(object::id(&ticket), ticket_id);

    let (treasury_cap, metadata_cap, creator_authority, burnable) =
        ticket.into_parts();

    assert_eq!(object::id(&treasury_cap), treasury_cap_id);
    assert_eq!(object::id(&metadata_cap), metadata_cap_id);
    assert_eq!(treasury_cap.total_supply(), 0);
    assert!(burnable);

    destroy(treasury_cap);
    destroy(metadata_cap);
    destroy(creator_authority);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 9)]
fun address_ticket_rejects_zero_creator_before_currency_creation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let ticket = launch_ticket::new_address(
        LAUNCH_TICKET_TESTS(),
        9,
        b"TICKET".to_string(),
        b"Ticket Test".to_string(),
        b"Invalid creator".to_string(),
        b"".to_string(),
        @0x0,
        false,
        scenario.ctx(),
    );

    destroy(ticket);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 10)]
fun x_ticket_rejects_invalid_identity_before_currency_creation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let ticket = launch_ticket::new_x(
        LAUNCH_TICKET_TESTS(),
        9,
        b"XTICKET".to_string(),
        b"X Ticket Test".to_string(),
        b"Invalid X identity".to_string(),
        b"".to_string(),
        x"1122",
        true,
        scenario.ctx(),
    );

    destroy(ticket);
    destroy(scenario);
}

#[test]
#[expected_failure]
fun ticket_rejects_a_non_otw_type() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let ticket = launch_ticket::new_address(
        INVALID_OTW(false),
        9,
        b"INVALID".to_string(),
        b"Invalid OTW".to_string(),
        b"Not a one-time witness".to_string(),
        b"".to_string(),
        CREATOR,
        false,
        scenario.ctx(),
    );

    destroy(ticket);
    destroy(scenario);
}
