// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Aftermath sale start with its DAO-fee tier, the reservation `finalize` binds to the sale, the
/// vault's owner-cap custody, and fee collection from coins Aftermath sends to the vault's
/// address. The venue interface is an `abort 0` link stub, so migration itself is proven on
/// mainnet dev-inspect instead.
module blast_presale::aftermath_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const FEE_RECIPIENT: address = @0xFEE;
const KEEPER: address = @0x4EE9;

const DAO_FEE_BPS: u16 = 200;
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

public struct OtherVenue() has drop;

public struct TestPosition has key, store { id: UID }

public struct OTHER_MIGRATOR() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// A sale started here names this migrator and records its DAO fee as the venue tier, with no
/// tick spacing, under the sale token's type.
fun new_records_the_witness_and_the_dao_fee_tier() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let creation_policy = allowing<Witness>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let (treasury_cap, currency) = new_currency(&mut scenario);

    let initializer = aftermath::new<_, QUOTE>(
        treasury_cap,
        &package_version,
        &creation_policy,
        &fee_policy,
        &mut venue_config,
        DAO_FEE_BPS,
    );

    assert_eq!(initializer.migration_witness(), type_name::with_original_ids<Witness>());
    let (tick_spacing, pool_fee_rate) = only_event<
        PoolTierReserved<AFTERMATH_TESTS, QUOTE, Venue>,
    >().pool_tier_reserved_fields();
    assert_eq!(tick_spacing, 0);
    assert_eq!(pool_fee_rate, 200);
    let (stored_tick_spacing, stored_fee_rate) = venue_config.pool_tier<AFTERMATH_TESTS>();
    assert_eq!(stored_tick_spacing, 0);
    assert_eq!(stored_fee_rate, 200);

    destroy(initializer);
    destroy(currency);
    destroy(venue_config);
    destroy(fee_policy);
    destroy(creation_policy);
    scenario.end();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(abort_code = aftermath::EInvalidDaoFee, location = blast_presale::aftermath)]
fun new_rejects_a_zero_dao_fee() {
    start_rejected_fee(0)
}

#[test]
#[expected_failure(abort_code = aftermath::EInvalidDaoFee, location = blast_presale::aftermath)]
fun new_rejects_a_dao_fee_above_the_whole_amount() {
    start_rejected_fee(10_001)
}

#[test]
/// `finalize` creates the sale with this migrator's witness and returns one reservation bound to
/// it, holding the capability it received, which `share` shares.
fun finalize_binds_a_shared_reservation_to_its_sale() {
    let mut scenario = test_scenario::begin(CREATOR);
    let creation_policy = allowing<Witness>(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());
    let create_pool_cap_id = object::id(&create_pool_cap);

    let (sale, cap) = new_sale(&mut scenario, &creation_policy, &mut venue_config, create_pool_cap);

    let (witness, _, _, _) = only_event<
        PresaleCreated<AFTERMATH_TESTS, QUOTE>,
    >().created_migration_fields();
    assert_eq!(witness, type_name::with_original_ids<Witness>());
    let (presale_id, pool_creation_id, reserved_cap_id) = only_event<
        PoolCreationReserved<LP, AFTERMATH_TESTS, QUOTE>,
    >().pool_creation_reserved_fields();
    assert_eq!(presale_id, object::id(&sale));
    assert_eq!(reserved_cap_id, create_pool_cap_id);

    scenario.next_tx(KEEPER);
    let pool_creation = scenario.take_shared_by_id<PoolCreation<LP, AFTERMATH_TESTS, QUOTE>>(
        pool_creation_id,
    );
    assert_eq!(pool_creation.pool_creation_presale_id_for_testing(), object::id(&sale));
    test_scenario::return_shared(pool_creation);

    destroy(sale);
    destroy(cap);
    destroy(venue_config);
    destroy(creation_policy);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = aftermath::EWrongPresale, location = blast_presale::aftermath)]
/// A sale's migration cannot consume the reservation bound to another sale, and checks that
/// before touching the sale.
fun migrate_rejects_another_sales_reservation() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let creation_policy = allowing<Witness>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let first_create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());
    let (first_sale, first_cap) = new_sale(
        &mut scenario,
        &creation_policy,
        &mut venue_config,
        first_create_pool_cap,
    );
    let (_, first_pool_creation_id, _) = only_event<
        PoolCreationReserved<LP, AFTERMATH_TESTS, QUOTE>,
    >().pool_creation_reserved_fields();
    destroy(first_sale);
    destroy(first_cap);

    scenario.next_tx(CREATOR);
    let mut other_venue_config = venue_config::new_for_testing(scenario.ctx());
    let second_create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());
    let (mut second_sale, second_cap) = new_sale(
        &mut scenario,
        &creation_policy,
        &mut other_venue_config,
        second_create_pool_cap,
    );

    scenario.next_tx(KEEPER);
    let pool_creation = scenario.take_shared_by_id<PoolCreation<LP, AFTERMATH_TESTS, QUOTE>>(
        first_pool_creation_id,
    );
    let mut pool_registry = pool_registry::new_for_testing(scenario.ctx());
    let dao_fee_version = version::new_for_testing(scenario.ctx());

    aftermath::migrate(
        &mut second_sale,
        &package_version,
        pool_creation,
        &fee_policy,
        &venue_config,
        &mut pool_registry,
        &dao_fee_version,
        &clock,
        scenario.ctx(),
    );
    destroy(second_cap);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(abort_code = aftermath::EWrongMigrator, location = blast_presale::aftermath)]
/// Only a sale this module's `new` started can be finalized here: another migrator's sale could
/// never consume the reservation.
fun finalize_rejects_another_migrators_sale() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let creation_policy = allowing<OTHER_MIGRATOR>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let (treasury_cap, mut currency) = new_currency(&mut scenario);
    let initializer = presale::new<_, QUOTE, _>(
        treasury_cap,
        &package_version,
        OTHER_MIGRATOR(),
        &creation_policy,
        &fee_policy,
    );

    let (_sale, _cap, _pool_creation) = aftermath::finalize<LP, _, _>(
        initializer,
        &package_version,
        &mut currency,
        amm_pool::create_pool_cap_for_testing(scenario.ctx()),
        scenario.ctx(),
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Blast must allow this migrator's witness before it can create a sale.
fun new_needs_blast_to_allow_the_witness() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let creation_policy = allowing<OTHER_MIGRATOR>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let (treasury_cap, _currency) = new_currency(&mut scenario);

    let _initializer = aftermath::new<_, QUOTE>(
        treasury_cap,
        &package_version,
        &creation_policy,
        &fee_policy,
        &mut venue_config,
        DAO_FEE_BPS,
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
/// A vault built before its position has none, announces nothing, and lands shared with the
/// position it is given, as `create` does in one call.
fun a_vault_built_before_its_position_shares_with_it_and_announces_the_custody() {
    let mut scenario = test_scenario::begin(CREATOR);
    let creation_policy = allowing<Witness>(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());
    let (sale, cap) = new_sale(&mut scenario, &creation_policy, &mut venue_config, create_pool_cap);
    let vault = vault::new(
        &sale,
        object::id_from_address(@0xB00),
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );
    let vault_id = object::id(&vault);
    assert!(!vault.has_position(&OtherVenue()));
    assert_eq!(
        event::events_by_type<VaultCreated<AFTERMATH_TESTS, QUOTE, OtherVenue>>().length(),
        0,
    );
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let position_id = object::id(&position);

    vault.share_with_position(&OtherVenue(), position, 1);

    let created = event::events_by_type<VaultCreated<AFTERMATH_TESTS, QUOTE, OtherVenue>>();
    assert_eq!(created.length(), 1);
    let (
        created_vault_id,
        created_presale_id,
        created_pool_id,
        created_position_id,
        liquidity,
    ) = created[0].vault_created_fields();
    assert_eq!(created_vault_id, vault_id);
    assert_eq!(created_presale_id, object::id(&sale));
    assert_eq!(created_pool_id, object::id_from_address(@0xB00));
    assert_eq!(created_position_id, position_id);
    assert_eq!(liquidity, 1);
    scenario.next_tx(KEEPER);
    let shared = scenario.take_shared_by_id<Vault<AFTERMATH_TESTS, QUOTE>>(vault_id);
    assert!(shared.has_position(&OtherVenue()));
    assert_eq!(shared.position_id_for_testing<_, _, OtherVenue>(), option::some(position_id));
    test_scenario::return_shared(shared);

    destroy(sale);
    destroy(cap);
    destroy(venue_config);
    destroy(creation_policy);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EZeroLiquidity, location = blast_presale::presale_vault)]
/// A position holding no liquidity cannot be attached, so no vault is shared around one.
fun a_vault_cannot_share_with_an_empty_position() {
    let mut scenario = test_scenario::begin(CREATOR);
    let creation_policy = allowing<Witness>(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());
    let (sale, _cap) = new_sale(
        &mut scenario,
        &creation_policy,
        &mut venue_config,
        create_pool_cap,
    );
    let vault = vault::new(
        &sale,
        object::id_from_address(@0xB00),
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );

    vault.share_with_position(&OtherVenue(), TestPosition { id: object::new(scenario.ctx()) }, 0);
    abort
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // The standard library's 0x1 sorts before the framework's 0x2, whatever address this
    // package builds at.
    assert!(sorts_before_for_testing<std::ascii::String, SUI>());
    assert!(!sorts_before_for_testing<SUI, std::ascii::String>());
    assert!(sorts_before_for_testing<A, AB>());
    assert!(!sorts_before_for_testing<AB, A>());
    assert!(sorts_before_for_testing<AB, QUOTE>());
    assert!(!sorts_before_for_testing<A, A>());
}

#[test]
/// Fee coins Aftermath sent to the vault's address are received, joined, and split exactly like a
/// collected position's fees: under a whole-split recipient and no Blast rate, the recipient is
/// paid every unit.
fun collect_fees_receives_the_vaults_fee_coins_and_splits_them() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut vault = new_vault(&mut scenario);
    let vault_address = object::id(&vault).to_address();
    let meme_ids = send_coins<AFTERMATH_TESTS>(vector[60, 41], vault_address, &mut scenario);
    let quote_ids = send_coins<QUOTE>(vector[10], vault_address, &mut scenario);

    scenario.next_tx(KEEPER);
    aftermath::collect_fees(
        &mut vault,
        &package_version,
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

    std::unit_test::destroy(package_version);
}

#[test]
/// The DAO-fee pool's owner cap is a vault position like any other: sealed under the Aftermath
/// venue and invisible to any other venue.
fun the_owner_cap_is_the_vaults_position_under_the_aftermath_venue() {
    let mut scenario = test_scenario::begin(CREATOR);
    let owner_cap = dao_fee_pool::owner_cap_for_testing<LP>(scenario.ctx());
    let owner_cap_id = object::id(&owner_cap);

    let vault = aftermath::vault_for_testing<AFTERMATH_TESTS, QUOTE, _>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        whole_split_to_fee_recipient(),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        owner_cap,
        1,
        scenario.ctx(),
    );

    assert_eq!(vault.position_id_for_testing<_, _, Venue>(), option::some(owner_cap_id));
    assert_eq!(vault.position_id_for_testing<_, _, OtherVenue>(), option::none());

    vault.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = aftermath::EWrongVault, location = blast_presale::aftermath)]
/// Another venue's vault settles its fees only through that venue: Aftermath's collection rejects
/// it before receiving anything.
fun collect_fees_rejects_another_venues_vault() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut other_vault = vault::new_for_testing<AFTERMATH_TESTS, QUOTE>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        whole_split_to_fee_recipient(),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        scenario.ctx(),
    );
    other_vault.attach_position_for_testing(
        &OtherVenue(),
        TestPosition { id: object::new(scenario.ctx()) },
        1,
    );

    aftermath::collect_fees(
        &mut other_vault,
        &package_version,
        &fee_policy,
        vector[],
        vector[],
        scenario.ctx(),
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
/// The DAO fee's bounds are inclusive: one basis point and the whole amount both start a sale.
fun new_accepts_one_basis_point_and_the_whole_amount() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let creation_policy = allowing<Witness>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    vector[1, 10_000].do!(|dao_fee_bps| {
        let mut venue_config = venue_config::new_for_testing(scenario.ctx());
        let (treasury_cap, currency) = new_currency(&mut scenario);

        let initializer = aftermath::new<_, QUOTE>(
            treasury_cap,
            &package_version,
            &creation_policy,
            &fee_policy,
            &mut venue_config,
            dao_fee_bps,
        );

        let (_, stored_fee_rate) = venue_config.pool_tier<AFTERMATH_TESTS>();
        assert_eq!(stored_fee_rate, dao_fee_bps as u64);
        destroy(initializer);
        destroy(currency);
        destroy(venue_config);
    });
    destroy(fee_policy);
    destroy(creation_policy);
    scenario.end();

    std::unit_test::destroy(package_version);
}

#[test]
/// A collection that lists no coins is valid, moves nothing, and emits nothing.
fun an_empty_collection_moves_nothing() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut vault = new_vault(&mut scenario);

    aftermath::collect_fees(
        &mut vault,
        &package_version,
        &fee_policy,
        vector[],
        vector[],
        scenario.ctx(),
    );

    assert_eq!(event::events_by_type<FeesCollected<AFTERMATH_TESTS, QUOTE>>().length(), 0);

    vault.destroy_for_testing();
    destroy(fee_policy);
    scenario.end();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
/// A coin owned by someone else cannot be received into the vault.
fun collect_fees_receives_only_coins_the_vault_owns() {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut vault = new_vault(&mut scenario);
    let meme_ids = send_coins<AFTERMATH_TESTS>(vector[7], KEEPER, &mut scenario);

    scenario.next_tx(KEEPER);
    aftermath::collect_fees(
        &mut vault,
        &package_version,
        &fee_policy,
        meme_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<AFTERMATH_TESTS>>(id)),
        vector[],
        scenario.ctx(),
    );
    std::unit_test::destroy(package_version);
    abort
}

// === Test Helpers ===

/// A creation policy that allows `QUOTE` and `MigrationWitness`.
fun allowing<MigrationWitness>(ctx: &mut TxContext): CreationPolicy {
    creation_policy::allowing_for_testing<QUOTE, MigrationWitness>(ctx)
}

/// Starts an Aftermath sale at `dao_fee_bps`; the start must abort.
fun start_rejected_fee(dao_fee_bps: u16) {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let creation_policy = allowing<Witness>(scenario.ctx());
    let fee_policy = fee_policy::new_for_testing(scenario.ctx());
    let mut venue_config = venue_config::new_for_testing(scenario.ctx());
    let (treasury_cap, _currency) = new_currency(&mut scenario);

    let _initializer = aftermath::new<_, QUOTE>(
        treasury_cap,
        &package_version,
        &creation_policy,
        &fee_policy,
        &mut venue_config,
        dao_fee_bps,
    );
    std::unit_test::destroy(package_version);
    abort
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

/// Starts a single-wallet sale whose pool creation is reserved for `LP` with `create_pool_cap`
/// and finalizes it here, returning the unshared sale and its cap.
fun new_sale(
    scenario: &mut Scenario,
    creation_policy: &CreationPolicy,
    venue_config: &mut VenueConfig,
    create_pool_cap: CreatePoolCapV2,
): (Presale<AFTERMATH_TESTS, QUOTE>, PresaleCap) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let (result_0, result_1) = {
        let fee_policy = fee_policy::new_for_testing(scenario.ctx());
        let (treasury_cap, mut currency) = new_currency(scenario);

        let mut initializer = aftermath::new<_, QUOTE>(
            treasury_cap,
            &package_version,
            creation_policy,
            &fee_policy,
            venue_config,
            DAO_FEE_BPS,
        );
        initializer.set_supply(&package_version, TOKEN_SUPPLY, false);
        initializer.set_token_allocations(
            &package_version,
            bps::new(5_000),
            bps::new(5_000),
            vector[],
        );
        initializer.set_raise(&package_version, RAISE_TARGET, vector[]);
        initializer.set_windows(&package_version, DURATION_MS, LIQUIDITY_WINDOW_MS);
        initializer.set_eligibility(
            &package_version,
            presale::open_eligibility(RAISE_TARGET, 1, RAISE_TARGET),
        );
        initializer.set_fee_split(
            &package_version,
            presale::fee_split(
                vector[presale::recipient_share(CREATOR, bps::new(10_000))],
                bps::new(0),
            ),
        );
        let (sale, cap, pool_creation) = aftermath::finalize<LP, _, _>(
            initializer,
            &package_version,
            &mut currency,
            create_pool_cap,
            scenario.ctx(),
        );
        // The reservation is returned unshared, bound to the sale, so the creating PTB could consume
        // it in `migrate`; these fixtures share it as a creator who waits would.
        assert_eq!(pool_creation.pool_creation_presale_id_for_testing(), object::id(&sale));
        pool_creation.share(&package_version);

        destroy(currency);
        destroy(fee_policy);

        (sale, cap)
    };
    std::unit_test::destroy(package_version);
    (result_0, result_1)
}

/// An unshared vault paying its whole split to `FEE_RECIPIENT`, with no holder share and no Blast
/// LP rate, so every received unit leaves it at once.
fun new_vault(scenario: &mut Scenario): Vault<AFTERMATH_TESTS, QUOTE> {
    aftermath::vault_for_testing(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        whole_split_to_fee_recipient(),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        TestPosition { id: object::new(scenario.ctx()) },
        1,
        scenario.ctx(),
    )
}

fun whole_split_to_fee_recipient(): FeeSplit {
    presale::fee_split(
        vector[presale::recipient_share(FEE_RECIPIENT, bps::new(10_000))],
        bps::new(0),
    )
}

/// Mints one coin per amount and sends each to `recipient`, returning their IDs in order.
fun send_coins<Asset>(
    amounts: vector<u64>,
    recipient: address,
    scenario: &mut Scenario,
): vector<ID> {
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

use amm::{pool::{Self as amm_pool, CreatePoolCapV2}, pool_registry};

use blast_presale::{
    aftermath::{Self, PoolCreation, PoolCreationReserved, Venue, Witness, sorts_before_for_testing},
    blast_presale::{Self as presale, FeeSplit, Presale, PresaleCap, PresaleCreated},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy,
    presale_vault::{Self as vault, FeesCollected, Vault, VaultCreated},
    venue_config::{Self, PoolTierReserved, VenueConfig}
};

use dao_fee_amm::{pool as dao_fee_pool, version};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance,
    clock,
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, Currency},
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
    test_utils
};
