// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_aftermath_dao_presale::blast_aftermath_dao_presale_tests;

// === Constants ===

/// The package's compiled treasury, which receives every sale's PresaleCap and every pool's DAO
/// fees, owner cap, and locked LP.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;
const PUBLISHER: address = @0xB1A57;
const KEEPER: address = @0x4EE9;

const TOKEN_SUPPLY: u64 = 1_000_000_000;
const RAISE_TARGET: u64 = 1_000_000;
const DURATION_MS: u64 = 100;
const LIQUIDITY_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct BLAST_AFTERMATH_DAO_PRESALE_TESTS() has drop;

public struct QUOTE() has drop;

/// The fresh Aftermath LP coin a sale's pool creation is reserved for.
public struct LP() has drop;

public struct OTHER_MIGRATOR() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// Publication sends the only AdminCap to the publisher.
fun publication_sends_the_admin_cap_to_the_publisher() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    migrator::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    assert!(test_scenario::has_most_recent_for_address<AdminCap>(PUBLISHER));
    assert!(!test_scenario::has_most_recent_for_address<AdminCap>(TREASURY));
    scenario.end();
}

#[test]
/// A sale created here names this migrator, pays its whole LP-fee split to the treasury, and sends
/// the treasury its PresaleCap.
fun new_creates_a_sale_for_the_treasury() {
    let mut scenario = publish();
    let creation_policy = allowing<Witness>(scenario.ctx());

    create_sale(&mut scenario, creation_policy);

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
    assert_eq!(fee_recipients, vector[TREASURY]);
    assert_eq!(fee_recipient_bps, vector[10_000]);
    assert_eq!(holder_rewards_bps, 0);

    scenario.next_tx(KEEPER);
    assert!(test_scenario::has_most_recent_for_address<PresaleCap>(TREASURY));
    scenario.end();
}

#[test]
/// `new` shares one pool creation for the LP coin, bound to the sale it created.
fun new_binds_a_shared_pool_creation_to_its_sale() {
    let mut scenario = publish();
    let creation_policy = allowing<Witness>(scenario.ctx());

    let (presale_id, pool_creation_id) = create_sale(&mut scenario, creation_policy);

    scenario.next_tx(KEEPER);
    let pool_creation = scenario.take_shared_by_id<PoolCreation<LP>>(pool_creation_id);
    assert_eq!(pool_creation.pool_creation_presale_id_for_testing(), presale_id);
    test_scenario::return_shared(pool_creation);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = migrator::EWrongPresale,
    location = blast_aftermath_dao_presale::blast_aftermath_dao_presale,
)]
/// A sale's migration cannot consume the pool creation reserved for another sale.
fun migrate_rejects_another_sales_pool_creation() {
    let mut scenario = publish();
    let creation_policy = allowing<Witness>(scenario.ctx());
    let (_, first_pool_creation_id) = create_sale(&mut scenario, creation_policy);
    scenario.next_tx(PUBLISHER);
    let creation_policy = allowing<Witness>(scenario.ctx());
    let (second_presale_id, _) = create_sale(&mut scenario, creation_policy);

    scenario.next_tx(KEEPER);
    let mut sale = scenario.take_shared_by_id<Presale<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>>(
        second_presale_id,
    );
    let pool_creation = scenario.take_shared_by_id<PoolCreation<LP>>(first_pool_creation_id);
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut pool_registry = pool_registry::new_for_testing(scenario.ctx());
    let dao_fee_version = version::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    migrator::migrate(
        &mut sale,
        pool_creation,
        &fee_policy,
        &mut pool_registry,
        &dao_fee_version,
        &clock,
        scenario.ctx(),
    );
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Blast must allow this migrator's witness before it can create a sale.
fun new_needs_blast_to_allow_the_witness() {
    let mut scenario = publish();
    let creation_policy = allowing<OTHER_MIGRATOR>(scenario.ctx());

    create_sale(&mut scenario, creation_policy);
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

/// Runs `init`, then opens the publisher's next transaction.
fun publish(): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);
    migrator::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    scenario
}

/// A creation policy that allows `QUOTE` and `MigrationWitness`.
fun allowing<MigrationWitness>(ctx: &mut TxContext): CreationPolicy {
    creation_policy::allowing_for_testing<QUOTE, MigrationWitness>(ctx)
}

/// The publisher's AdminCap creates and shares a sale whose pool creation is reserved for `LP`,
/// returning the presale and pool-creation IDs.
fun create_sale(scenario: &mut Scenario, creation_policy: CreationPolicy): (ID, ID) {
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_AFTERMATH_DAO_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let mut currency = coin_registry::unwrap_for_testing(initializer);
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());

    let sale = migrator::new<LP, _, QUOTE>(
        &admin_cap,
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
        create_pool_cap,
        &creation_policy,
        &fee_policy,
        scenario.ctx(),
    );

    let (presale_id, pool_creation_id) = last_event<
        PoolCreationReserved<LP, BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>,
    >().pool_creation_reserved_fields();
    assert_eq!(presale_id, object::id(&sale));

    sale.share(0, &clock);
    scenario.return_to_sender(admin_cap);
    destroy(currency);
    destroy(clock);
    destroy(fee_policy);
    destroy(creation_policy);

    (presale_id, pool_creation_id)
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use amm::{pool as amm_pool, pool_registry};

use blast_aftermath_dao_presale::blast_aftermath_dao_presale::{
    Self as migrator,
    AdminCap,
    PoolCreation,
    PoolCreationReserved,
    Witness,
    sorts_before_for_testing,
};

use blast_presale::{
    blast_presale::{Self as presale, Presale, PresaleCap, PresaleCreated},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy,
};

use dao_fee_amm::version;

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{clock, coin_registry, event, sui::SUI, test_scenario::{Self, Scenario}, test_utils};
