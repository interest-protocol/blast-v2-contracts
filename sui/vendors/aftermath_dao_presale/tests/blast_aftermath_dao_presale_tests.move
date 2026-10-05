// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_aftermath_dao_presale::blast_aftermath_dao_presale_tests;

// === Constants ===

/// The package's compiled treasury, which receives the AdminCap at publication.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;
const NEW_TREASURY: address = @0x7EA6;
const PUBLISHER: address = @0xB1A57;
const POOL: address = @0xF00;
const KEEPER: address = @0x4EE9;
const CREATOR: address = @0xC0FFEE;

const TOKEN_SUPPLY: u64 = 1_000_000_000;
const RAISE_TARGET: u64 = 1_000_000;
const DURATION_MS: u64 = 100;
const LIQUIDITY_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct BLAST_AFTERMATH_DAO_PRESALE_TESTS() has drop;

public struct QUOTE() has drop;

public struct OTHER_MIGRATOR() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// Publication shares a Config that pays the compiled treasury and sends it the only AdminCap.
fun publication_shares_the_config_and_sends_the_admin_cap_to_the_treasury() {
    let scenario = publish();

    let config = scenario.take_shared<Config>();
    assert_eq!(config.treasury_for_testing(), TREASURY);
    assert!(test_scenario::has_most_recent_for_address<AdminCap>(TREASURY));
    assert!(!test_scenario::has_most_recent_for_address<AdminCap>(PUBLISHER));

    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
/// The AdminCap moves the treasury, and the change emits the new one.
fun the_admin_moves_the_treasury() {
    let mut scenario = publish();

    move_treasury(&mut scenario, NEW_TREASURY);

    scenario.next_tx(KEEPER);
    let config = scenario.take_shared<Config>();
    assert_eq!(config.treasury_for_testing(), NEW_TREASURY);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = migrator::EZeroTreasury,
    location = blast_aftermath_dao_presale::blast_aftermath_dao_presale,
)]
fun the_treasury_cannot_be_the_zero_address() {
    let mut scenario = publish();

    move_treasury(&mut scenario, @0x0);
    abort
}

#[test]
#[expected_failure(
    abort_code = migrator::ETreasuryUnchanged,
    location = blast_aftermath_dao_presale::blast_aftermath_dao_presale,
)]
fun a_treasury_update_must_change_it() {
    let mut scenario = publish();

    move_treasury(&mut scenario, TREASURY);
    abort
}

#[test]
/// Anyone forwards every fee coin a pool sent to Config to the treasury, as one coin.
fun anyone_forwards_the_configs_fees_to_the_treasury() {
    let mut scenario = publish();
    let config_id = send_fees_to_config(&mut scenario, vector[300, 200]);

    scenario.next_tx(KEEPER);
    claim(&mut scenario, config_id, 2);
    let (treasury, amount) = last_event<FeesClaimed<QUOTE>>().fees_claimed_fields();
    assert_eq!(treasury, TREASURY);
    assert_eq!(amount, 500);

    scenario.next_tx(KEEPER);
    let fees = scenario.take_from_address<Coin<QUOTE>>(TREASURY);
    assert_eq!(fees.value(), 500);
    assert_eq!(test_scenario::ids_for_address<Coin<QUOTE>>(config_id.to_address()), vector[]);
    destroy(fees);
    scenario.end();
}

#[test]
/// Fees already waiting at Config go to the treasury the AdminCap set before the claim.
fun claims_follow_a_moved_treasury() {
    let mut scenario = publish();
    let config_id = send_fees_to_config(&mut scenario, vector[700]);

    move_treasury(&mut scenario, NEW_TREASURY);
    scenario.next_tx(KEEPER);
    claim(&mut scenario, config_id, 1);

    scenario.next_tx(KEEPER);
    assert!(!test_scenario::has_most_recent_for_address<Coin<QUOTE>>(TREASURY));
    let fees = scenario.take_from_address<Coin<QUOTE>>(NEW_TREASURY);
    assert_eq!(fees.value(), 700);
    destroy(fees);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = migrator::ENoFees,
    location = blast_aftermath_dao_presale::blast_aftermath_dao_presale,
)]
fun a_fee_claim_needs_a_coin() {
    let mut scenario = publish();
    let mut config = scenario.take_shared<Config>();

    config.claim_fees<QUOTE>(vector[], scenario.ctx());
    abort
}

#[test]
/// A sale created here names this migrator and pays its whole LP-fee split to Config.
fun new_creates_a_sale_whose_lp_fees_pay_the_config() {
    let mut scenario = publish();
    let config = scenario.take_shared<Config>();
    let fee_recipient = object::id(&config).to_address();

    create_sale(
        &config,
        creation_policy::allowing_for_testing<QUOTE, Witness>(scenario.ctx()),
        scenario.ctx(),
    );

    let (
        witness,
        tick_spacing,
        pool_fee_rate,
        fee_recipients,
        fee_recipient_bps,
        holder_rewards_bps,
    ) = last_event<PresaleCreated<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>>()
        .created_migration_fields();
    assert_eq!(witness, type_name::with_original_ids<Witness>());
    assert_eq!(tick_spacing, 0);
    assert_eq!(pool_fee_rate, 0);
    assert_eq!(fee_recipients, vector[fee_recipient]);
    assert_eq!(fee_recipient_bps, vector[10_000]);
    assert_eq!(holder_rewards_bps, 0);

    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Blast must allow this migrator's witness before it can create a sale.
fun new_needs_blast_to_allow_the_witness() {
    let mut scenario = publish();
    let config = scenario.take_shared<Config>();

    create_sale(
        &config,
        creation_policy::allowing_for_testing<QUOTE, OTHER_MIGRATOR>(scenario.ctx()),
        scenario.ctx(),
    );
    abort
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // This test package sits at 0x0, so its types sort before the framework's 0x2.
    assert!(sorts_before_for_testing<QUOTE, SUI>());
    assert!(!sorts_before_for_testing<SUI, QUOTE>());
    assert!(sorts_before_for_testing<A, AB>());
    assert!(!sorts_before_for_testing<AB, A>());
    assert!(sorts_before_for_testing<AB, QUOTE>());
    assert!(!sorts_before_for_testing<A, A>());
}

// === Test Helpers ===

/// Runs `init`, then opens the next transaction as `PUBLISHER`.
fun publish(): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);
    migrator::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    scenario
}

/// The treasury's AdminCap moves the treasury to `treasury` in its own transaction.
fun move_treasury(scenario: &mut Scenario, treasury: address) {
    scenario.next_tx(TREASURY);
    let mut config = scenario.take_shared<Config>();
    let admin_cap = scenario.take_from_sender<AdminCap>();

    config.set_treasury(&admin_cap, treasury);

    assert_eq!(last_event<TreasuryChanged>().treasury_changed_fields(), treasury);
    scenario.return_to_sender(admin_cap);
    test_scenario::return_shared(config);
}

/// A pool sends one `Coin<QUOTE>` per amount to Config's address, as Aftermath pays DAO fees.
fun send_fees_to_config(scenario: &mut Scenario, amounts: vector<u64>): ID {
    let config = scenario.take_shared<Config>();
    let config_id = object::id(&config);
    test_scenario::return_shared(config);

    scenario.next_tx(POOL);
    amounts.do!(|amount| {
        transfer::public_transfer(
            coin::mint_for_testing<QUOTE>(amount, scenario.ctx()),
            config_id.to_address(),
        );
    });

    config_id
}

/// Claims the `count` most recent fee coins sent to Config.
fun claim(scenario: &mut Scenario, config_id: ID, count: u64) {
    let mut config = scenario.take_shared<Config>();
    let ids = test_scenario::ids_for_address<Coin<QUOTE>>(config_id.to_address());
    assert_eq!(ids.length(), count);

    config.claim_fees(
        ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<QUOTE>>(id)),
        scenario.ctx(),
    );

    test_scenario::return_shared(config);
}

/// Creates a sale through this migrator under `creation_policy` and shares it.
fun create_sale(config: &Config, creation_policy: CreationPolicy, ctx: &mut TxContext) {
    let fee_policy = fee_policy::new_for_testing(ctx);
    let clock = clock::create_for_testing(ctx);
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_AFTERMATH_DAO_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        ctx,
    );
    let mut currency = coin_registry::unwrap_for_testing(initializer);

    let (sale, cap) = migrator::new<_, QUOTE>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        bps::new(5_000),
        option::none(),
        bps::new(5_000),
        vector[],
        false,
        RAISE_TARGET,
        vector[],
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(RAISE_TARGET, 1, RAISE_TARGET),
        option::none(),
        &creation_policy,
        &fee_policy,
        config,
        ctx,
    );

    sale.share(0, &clock);
    transfer::public_transfer(cap, CREATOR);
    destroy(currency);
    destroy(clock);
    destroy(fee_policy);
    destroy(creation_policy);
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_aftermath_dao_presale::blast_aftermath_dao_presale::{
    Self as migrator,
    AdminCap,
    Config,
    FeesClaimed,
    TreasuryChanged,
    Witness,
    sorts_before_for_testing,
};

use blast_presale::{
    blast_presale::{Self as presale, PresaleCreated},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy,
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock,
    coin::{Self, Coin},
    coin_registry,
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
    test_utils,
};
