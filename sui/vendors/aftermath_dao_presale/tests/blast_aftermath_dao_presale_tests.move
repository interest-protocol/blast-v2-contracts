// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_aftermath_dao_presale::blast_aftermath_dao_presale_tests;

// === Constants ===

/// The package's compiled treasury, which receives every sale's PresaleCap and every pool's DAO
/// fees and owner cap.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;
const PUBLISHER: address = @0xB1A57;
const KEEPER: address = @0x4EE9;
const PARTNER_RECIPIENT: address = @0x9A27;

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
fun finalize_creates_a_sale_for_the_treasury() {
    let mut scenario = publish();
    let creation_policy = allowing<Witness>(scenario.ctx());

    create_sale(&mut scenario, creation_policy);

    let (
        witness,
        fee_recipients,
        fee_recipient_bps,
        holder_rewards_bps,
    ) = last_event<PresaleCreated<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>>()
        .created_migration_fields();
    assert_eq!(witness, type_name::with_original_ids<Witness>());
    assert_eq!(fee_recipients, vector[TREASURY]);
    assert_eq!(fee_recipient_bps, vector[10_000]);
    assert_eq!(holder_rewards_bps, 0);

    scenario.next_tx(KEEPER);
    assert!(test_scenario::has_most_recent_for_address<PresaleCap>(TREASURY));
    scenario.end();
}

#[test]
/// `finalize` shares one pool creation for the LP coin, bound to the sale it created.
fun finalize_binds_a_shared_pool_creation_to_its_sale() {
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
/// The AdminCap holder may name a Blast partner on the sale `new` starts, before finalizing it.
fun a_vendor_sale_can_name_a_partner_before_it_is_finalized() {
    let mut scenario = publish();
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, 4_000, scenario.ctx());
    let mut creation_policy = allowing<Witness>(scenario.ctx());
    creation_policy.add_partner(&fee_admin(), &partner);
    let clock = clock::create_for_testing(scenario.ctx());

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let (mut initializer, currency) = start_sale(&mut scenario, &admin_cap, &creation_policy);
    initializer.set_partner(&creation_policy, &partner, &clock);
    let (sale, _) = finalize_sale(&mut scenario, &admin_cap, initializer, currency);
    sale.share(0, &clock);

    let opened = last_event<PresaleOpened<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>>();
    assert_eq!(opened.opened_partner_id(), option::some(object::id(&partner)));
    scenario.return_to_sender(admin_cap);
    destroy(partner);
    destroy(clock);
    destroy(creation_policy);
    scenario.end();
}

#[test]
/// In the transaction that creates a sale, Blast's presale `FeeAdmin` can replace that sale's Blast rates
/// before sharing it, without touching any other sale.
fun a_vendor_sale_can_change_its_blast_rates_before_its_share() {
    let mut scenario = publish();
    let creation_policy = allowing<Witness>(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    let (mut sale, _) = new_sale(&mut scenario, &creation_policy);
    sale.set_protocol_fees(
        &fee_admin(),
        bps::new(1_000),
        bps::new(100),
        bps::new(0),
        bps::new(0),
        &clock,
    );

    let (presale_id, rates, protocol_quote, protocol_tokens, token_allocation) = last_event<
        ProtocolFeesChanged<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>,
    >().protocol_fees_changed_fields();
    assert_eq!(presale_id, object::id(&sale));
    assert_eq!(rates, vector[1_000, 100, 0, 0]);
    // 1,000,000 * 1,000 / 10,000 = 100,000 Quote out of the LP's, and 1,000,000,000 * 100 / 10,000
    // = 10,000,000 tokens out of the buyers' 500,000,000.
    assert_eq!(
        vector[protocol_quote, protocol_tokens, token_allocation],
        vector[100_000, 10_000_000, 490_000_000],
    );

    sale.share(0, &clock);
    destroy(clock);
    destroy(creation_policy);
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
/// The vendor's `finalize` pays the whole LP-fee split to the treasury, whatever split was set.
fun finalize_overrides_any_lp_fee_split() {
    let mut scenario = publish();
    let creation_policy = allowing<Witness>(scenario.ctx());

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let (mut initializer, currency) = start_sale(&mut scenario, &admin_cap, &creation_policy);
    initializer.set_fee_split(
        presale::fee_split(vector[presale::recipient_share(KEEPER, bps::new(10_000))], bps::new(0)),
    );
    let (sale, _) = finalize_sale(&mut scenario, &admin_cap, initializer, currency);

    let (_, fee_recipients, fee_recipient_bps, _) = last_event<
        PresaleCreated<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>,
    >().created_migration_fields();
    assert_eq!(fee_recipients, vector[TREASURY]);
    assert_eq!(fee_recipient_bps, vector[10_000]);
    scenario.return_to_sender(admin_cap);
    destroy(sale);
    destroy(creation_policy);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = migrator::EWrongMigrator,
    location = blast_aftermath_dao_presale::blast_aftermath_dao_presale,
)]
/// The vendor finalizes only sales its own `new` started: another migrator's sale could never
/// consume the pool creation.
fun finalize_rejects_another_migrators_sale() {
    let mut scenario = publish();
    let creation_policy = allowing<OTHER_MIGRATOR>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let (treasury_cap, mut currency) = new_currency(&mut scenario);
    let initializer = presale::new<_, QUOTE, _>(
        treasury_cap,
        OTHER_MIGRATOR(),
        &creation_policy,
        &fee_policy,
    );

    let _sale = migrator::finalize<LP, _, _>(
        &admin_cap,
        initializer,
        &mut currency,
        amm_pool::create_pool_cap_for_testing(scenario.ctx()),
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
    // The standard library's 0x1 sorts before the framework's 0x2, whatever address this
    // package builds at: under `--build-env mainnet` it is the published address, not 0x0.
    assert!(sorts_before_for_testing<std::ascii::String, SUI>());
    assert!(!sorts_before_for_testing<SUI, std::ascii::String>());
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
    let clock = clock::create_for_testing(scenario.ctx());
    let (sale, pool_creation_id) = new_sale(scenario, &creation_policy);
    let presale_id = object::id(&sale);

    sale.share(0, &clock);
    destroy(clock);
    destroy(creation_policy);

    (presale_id, pool_creation_id)
}

/// The publisher's AdminCap creates a sale whose pool creation is reserved for `LP`, returning
/// the unshared sale and its pool-creation ID.
fun new_sale(
    scenario: &mut Scenario,
    creation_policy: &CreationPolicy,
): (Presale<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>, ID) {
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let (initializer, currency) = start_sale(scenario, &admin_cap, creation_policy);
    let (sale, pool_creation_id) = finalize_sale(scenario, &admin_cap, initializer, currency);

    scenario.return_to_sender(admin_cap);
    (sale, pool_creation_id)
}

/// The publisher's AdminCap starts a single-wallet sale and sets everything but its LP-fee split,
/// returning it with the sale token's currency.
fun start_sale(
    scenario: &mut Scenario,
    admin_cap: &AdminCap,
    creation_policy: &CreationPolicy,
): (
    PresaleInitializer<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>,
    Currency<BLAST_AFTERMATH_DAO_PRESALE_TESTS>,
) {
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let (treasury_cap, currency) = new_currency(scenario);

    let mut initializer = migrator::new<_, QUOTE>(
        admin_cap,
        treasury_cap,
        creation_policy,
        &fee_policy,
    );
    initializer.set_supply(TOKEN_SUPPLY, false);
    initializer.set_token_allocations(bps::new(5_000), bps::new(5_000), vector[]);
    initializer.set_raise(RAISE_TARGET, vector[]);
    initializer.set_windows(DURATION_MS, LIQUIDITY_WINDOW_MS);
    initializer.set_eligibility(presale::open_eligibility(RAISE_TARGET, 1, RAISE_TARGET));

    destroy(fee_policy);

    (initializer, currency)
}

/// A fresh sale token's zero-supply treasury cap and currency.
fun new_currency(
    scenario: &mut Scenario,
): (TreasuryCap<BLAST_AFTERMATH_DAO_PRESALE_TESTS>, Currency<BLAST_AFTERMATH_DAO_PRESALE_TESTS>) {
    let (currency_initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_AFTERMATH_DAO_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );

    (treasury_cap, coin_registry::unwrap_for_testing(currency_initializer))
}

/// The publisher's AdminCap finalizes `initializer` with a pool creation reserved for `LP`,
/// returning the unshared sale and its pool-creation ID.
fun finalize_sale(
    scenario: &mut Scenario,
    admin_cap: &AdminCap,
    initializer: PresaleInitializer<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>,
    mut currency: Currency<BLAST_AFTERMATH_DAO_PRESALE_TESTS>,
): (Presale<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>, ID) {
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());

    let sale = migrator::finalize<LP, _, _>(
        admin_cap,
        initializer,
        &mut currency,
        create_pool_cap,
        scenario.ctx(),
    );

    let (presale_id, pool_creation_id) = last_event<
        PoolCreationReserved<LP, BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>,
    >().pool_creation_reserved_fields();
    assert_eq!(presale_id, object::id(&sale));

    destroy(currency);

    (sale, pool_creation_id)
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use amm::{pool as amm_pool, pool_registry};

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_aftermath_dao_presale::blast_aftermath_dao_presale::{
    Self as migrator,
    AdminCap,
    PoolCreation,
    PoolCreationReserved,
    Witness,
    sorts_before_for_testing,
};

use blast_partners::blast_partners as partners;

use blast_presale::{
    blast_presale::{
        Self as presale,
        Presale,
        PresaleCap,
        PresaleCreated,
        PresaleInitializer,
        PresaleOpened,
        ProtocolFeesChanged,
    },
    blast_presale_domain::FeeAdmin,
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy,
};

use dao_fee_amm::version;

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{clock, coin::TreasuryCap, coin_registry::{Self, Currency}, event, sui::SUI, test_scenario::{Self, Scenario}, test_utils};
