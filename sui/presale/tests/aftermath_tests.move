// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Aftermath sale start, its pool-creation reservation, the vault's owner-cap custody, and fee
/// collection from coins Aftermath sends to the vault's address. The venue interface is an
/// `abort 0` link stub, so migration itself is proven on mainnet dev-inspect instead.
module blast_presale::aftermath_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const FEE_RECIPIENT: address = @0xFEE;
const KEEPER: address = @0x4EE9;
const TREASURY: address = @0x7EA5;

const TOKEN_SUPPLY: u64 = 1_000_000_000;
const RAISE_TARGET: u64 = 1_000_000;
const DURATION_MS: u64 = 100;
const LIQUIDITY_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated sale token's.
public struct AFTERMATH_TESTS() has drop;

public struct QUOTE() has drop;

/// The fresh Aftermath LP coin a sale's pool creation is reserved for.
public struct LP() has drop;

public struct OTHER_MIGRATOR() has drop;

/// The custody tests' venue marker; the module's own `Venue` is sealed.
public struct TestVenue() has drop;

public struct OtherVenue() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// A sale started here names this migrator and shares one pool creation for its LP coin, holding
/// the capability it was given.
fun new_records_the_witness_and_reserves_the_pool_creation() {
    let mut scenario = test_scenario::begin(CREATOR);
    let creation_policy = allowing<Witness>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let (treasury_cap, currency) = new_currency(&mut scenario);
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());
    let create_pool_cap_id = object::id(&create_pool_cap);

    let initializer = aftermath::new<LP, _, QUOTE>(
        treasury_cap,
        create_pool_cap,
        &creation_policy,
        &fee_policy,
        scenario.ctx(),
    );

    assert_eq!(initializer.migration_witness(), type_name::with_original_ids<Witness>());
    let (pool_creation_id, reserved_cap_id) = only_event<
        PoolCreationReserved<LP, AFTERMATH_TESTS, QUOTE>,
    >().pool_creation_reserved_fields();
    assert_eq!(reserved_cap_id, create_pool_cap_id);

    scenario.next_tx(KEEPER);
    let pool_creation = scenario.take_shared_by_id<PoolCreation<LP, AFTERMATH_TESTS, QUOTE>>(
        pool_creation_id,
    );
    test_scenario::return_shared(pool_creation);

    destroy(initializer);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);
    scenario.end();
}

#[test]
/// A sale `new` started finalizes like any other, carrying this migrator's witness.
fun a_sale_started_here_finalizes_with_the_aftermath_witness() {
    let mut scenario = test_scenario::begin(CREATOR);
    let creation_policy = allowing<Witness>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let (treasury_cap, mut currency) = new_currency(&mut scenario);

    let mut initializer = aftermath::new<LP, _, QUOTE>(
        treasury_cap,
        amm_pool::create_pool_cap_for_testing(scenario.ctx()),
        &creation_policy,
        &fee_policy,
        scenario.ctx(),
    );
    initializer.set_supply(TOKEN_SUPPLY, false);
    initializer.set_token_allocations(bps::new(5_000), bps::new(5_000), vector[]);
    initializer.set_raise(RAISE_TARGET, vector[]);
    initializer.set_windows(DURATION_MS, LIQUIDITY_WINDOW_MS);
    initializer.set_eligibility(presale::open_eligibility(RAISE_TARGET, 1, RAISE_TARGET));
    initializer.set_fee_split(
        presale::fee_split(vector[presale::recipient_share(CREATOR, bps::new(10_000))], bps::new(0)),
    );
    let (sale, cap) = initializer.finalize(&mut currency, scenario.ctx());

    let (witness, _, _, _) = only_event<PresaleCreated<AFTERMATH_TESTS, QUOTE>>()
        .created_migration_fields();
    assert_eq!(witness, type_name::with_original_ids<Witness>());

    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Blast must allow this migrator's witness before it can create a sale, and the reservation is
/// never shared for a sale that cannot start.
fun new_needs_blast_to_allow_the_witness() {
    let mut scenario = test_scenario::begin(CREATOR);
    let creation_policy = allowing<OTHER_MIGRATOR>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let (treasury_cap, _currency) = new_currency(&mut scenario);

    let _initializer = aftermath::new<LP, _, QUOTE>(
        treasury_cap,
        amm_pool::create_pool_cap_for_testing(scenario.ctx()),
        &creation_policy,
        &fee_policy,
        scenario.ctx(),
    );
    abort
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // This package sits at 0x0, so its types sort before the framework's 0x2.
    assert!(sorts_before_for_testing<QUOTE, SUI>());
    assert!(!sorts_before_for_testing<SUI, QUOTE>());
    assert!(sorts_before_for_testing<A, AB>());
    assert!(!sorts_before_for_testing<AB, A>());
    assert!(sorts_before_for_testing<AB, QUOTE>());
    assert!(!sorts_before_for_testing<A, A>());
}

#[test]
/// The DAO-fee pool's owner cap attaches once under the Aftermath venue key, apart from the
/// position and invisible to any other venue.
fun the_owner_cap_attaches_once_under_the_aftermath_venue() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(&mut scenario);
    let owner_cap = dao_fee_pool::owner_cap_for_testing<LP>(scenario.ctx());
    let owner_cap_id = object::id(&owner_cap);

    vault.attach_pool_authority(&TestVenue(), owner_cap);

    assert_eq!(vault.pool_authority_id_for_testing<_, _, TestVenue>(), option::some(owner_cap_id));
    assert_eq!(vault.pool_authority_id_for_testing<_, _, OtherVenue>(), option::none());
    assert_eq!(vault.position_id_for_testing<_, _, TestVenue>(), option::none());

    vault.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = sui::dynamic_field::EFieldAlreadyExists,
    location = sui::dynamic_field,
)]
/// A second owner cap cannot replace the first.
fun a_second_owner_cap_cannot_replace_the_first() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(&mut scenario);
    vault.attach_pool_authority(&TestVenue(), dao_fee_pool::owner_cap_for_testing<LP>(scenario.ctx()));

    vault.attach_pool_authority(&TestVenue(), dao_fee_pool::owner_cap_for_testing<LP>(scenario.ctx()));
    abort
}

#[test]
/// Fee coins Aftermath sent to the vault's address are received, joined, and split exactly like a
/// collected position's fees: under a whole-split recipient and no Blast rate, the recipient is
/// paid every unit.
fun collect_fees_receives_the_vaults_fee_coins_and_splits_them() {
    let mut scenario = test_scenario::begin(CREATOR);
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut vault = new_vault(&mut scenario);
    let vault_address = object::id(&vault).to_address();
    let meme_ids = send_coins<AFTERMATH_TESTS>(vector[60, 41], vault_address, &mut scenario);
    let quote_ids = send_coins<QUOTE>(vector[10], vault_address, &mut scenario);

    scenario.next_tx(KEEPER);
    aftermath::collect_fees(
        &mut vault,
        &fee_policy,
        meme_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<AFTERMATH_TESTS>>(id)),
        quote_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<QUOTE>>(id)),
        scenario.ctx(),
    );

    let (
        gross_meme,
        gross_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    ) = only_event<FeesCollected<AFTERMATH_TESTS, QUOTE>>().fees_collected_fields();
    assert_eq!(vector[gross_meme, gross_quote], vector[101, 10]);
    assert_eq!(fee_recipient_meme, vector[101]);
    assert_eq!(fee_recipient_quote, vector[10]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[0, 0]);

    scenario.next_tx(FEE_RECIPIENT);
    assert_eq!(scenario.take_from_sender<Coin<AFTERMATH_TESTS>>().burn_for_testing(), 101);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 10);

    vault.destroy_for_testing();
    destroy(fee_policy);
    scenario.end();
}

#[test]
/// A collection that lists no coins is valid, moves nothing, and emits nothing.
fun an_empty_collection_moves_nothing() {
    let mut scenario = test_scenario::begin(CREATOR);
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut vault = new_vault(&mut scenario);

    aftermath::collect_fees(&mut vault, &fee_policy, vector[], vector[], scenario.ctx());

    assert_eq!(event::events_by_type<FeesCollected<AFTERMATH_TESTS, QUOTE>>().length(), 0);

    vault.destroy_for_testing();
    destroy(fee_policy);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
/// A coin owned by someone else cannot be received into the vault.
fun collect_fees_receives_only_coins_the_vault_owns() {
    let mut scenario = test_scenario::begin(CREATOR);
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut vault = new_vault(&mut scenario);
    let meme_ids = send_coins<AFTERMATH_TESTS>(vector[7], KEEPER, &mut scenario);

    scenario.next_tx(KEEPER);
    aftermath::collect_fees(
        &mut vault,
        &fee_policy,
        meme_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<AFTERMATH_TESTS>>(id)),
        vector[],
        scenario.ctx(),
    );
    abort
}

// === Test Helpers ===

/// A creation policy that allows `QUOTE` and `MigrationWitness`.
fun allowing<MigrationWitness>(ctx: &mut TxContext): CreationPolicy {
    creation_policy::allowing_for_testing<QUOTE, MigrationWitness>(ctx)
}

/// A fresh sale token's zero-supply treasury cap and currency.
fun new_currency(
    scenario: &mut Scenario,
): (TreasuryCap<AFTERMATH_TESTS>, Currency<AFTERMATH_TESTS>) {
    let (currency_initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<AFTERMATH_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Aftermath presale test token".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );

    (treasury_cap, coin_registry::unwrap_for_testing(currency_initializer))
}

/// An unshared vault paying its whole split to `FEE_RECIPIENT`, with no holder share and no Blast
/// LP rate, so every received unit leaves it at once.
fun new_vault(scenario: &mut Scenario): Vault<AFTERMATH_TESTS, QUOTE> {
    let presale_id = object::id_from_address(@0xCAFE);

    vault::new_for_testing(
        presale_id,
        object::id_from_address(@0xCA9),
        presale::fee_split(
            vector[presale::recipient_share(FEE_RECIPIENT, bps::new(10_000))],
            bps::new(0),
        ),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        scenario.ctx(),
    )
}

/// Mints one coin per amount and sends each to `recipient`, returning their IDs in order.
fun send_coins<Asset>(amounts: vector<u64>, recipient: address, scenario: &mut Scenario): vector<ID> {
    amounts.map!(|amount| {
        let fee = coin::mint_for_testing<Asset>(amount, scenario.ctx());
        let id = object::id(&fee);
        transfer::public_transfer(fee, recipient);
        id
    })
}

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use amm::pool as amm_pool;

use blast_presale::{
    aftermath::{
        Self,
        PoolCreation,
        PoolCreationReserved,
        Witness,
        sorts_before_for_testing,
    },
    blast_presale::{Self as presale, PresaleCreated},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy,
    presale_vault::{Self as vault, FeesCollected, Vault},
};

use dao_fee_amm::pool as dao_fee_pool;

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, Currency},
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
    test_utils,
};
