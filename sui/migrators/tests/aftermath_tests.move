// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Aftermath launch start with its DAO-fee tier, the reservation `finalize` binds to the launch,
/// the vault's owner-cap custody, and fee collection and settled split updates from coins
/// Aftermath sends to the vault's address. The venue interface is an `abort 0` link stub, so
/// migration itself is proven on mainnet dev-inspect instead.
module blast_fun_migrators::aftermath_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct AFTERMATH_TESTS has drop {}

public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

/// The fresh Aftermath LP coin a launch's pool creation is reserved for.
public struct LP() has drop;

/// The vault fixture's launch witness, which is also its vault venue marker.
public struct TestVenue() has drop;

public struct OtherVenue() has drop;

public struct TestPosition has key, store { id: UID }

public struct A() has drop;

public struct AB() has drop;

/// Launch intake under an admitted policy, for the start tests.
public struct StartFixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    config: LaunchConfig,
}

/// One shared launch under a test venue, its creator's curve-fee cap, and the vault it migrated
/// into, for the collection tests.
public struct VaultFixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    runtime: RuntimeConfig,
    clock: Clock,
    policy: LpFeePolicy,
    launch_id: ID,
    currency: Currency<AFTERMATH_TESTS>,
    vault: LpVault<AFTERMATH_TESTS, QUOTE>,
}

// === Tests ===

// Launch Start

#[test]
fun new_records_aftermath_with_no_tick_spacing_and_the_dao_fee_as_the_fee_rate() {
    let mut f = start();
    f.admit_aftermath();

    let launch = f.open_launch(DAO_FEE_BPS);

    assert_eq!(
        launch.migration_witness_for_testing(),
        type_name::with_original_ids<aftermath::Witness>(),
    );
    let (tick_spacing, fee_rate) = launch.pool_tier();
    assert_eq!(tick_spacing, 0);
    assert_eq!(fee_rate, 200);
    destroy(launch);
    f.end();
}

#[test]
fun new_accepts_the_whole_amount_as_the_dao_fee() {
    let mut f = start();
    f.admit_aftermath();

    let launch = f.open_launch(10_000);

    let (_, fee_rate) = launch.pool_tier();
    assert_eq!(fee_rate, 10_000);
    destroy(launch);
    f.end();
}

#[test, expected_failure(
    abort_code = aftermath::EInvalidDaoFee,
    location = blast_fun_migrators::aftermath,
)]
fun new_rejects_a_zero_dao_fee() {
    start_rejected_fee(0)
}

#[test, expected_failure(
    abort_code = aftermath::EInvalidDaoFee,
    location = blast_fun_migrators::aftermath,
)]
fun new_rejects_a_dao_fee_above_the_whole_amount() {
    start_rejected_fee(10_001)
}

#[test]
/// `finalize` shares one reservation bound to the launch it finalized, holding the capability
/// `new` received, and announces it.
fun finalize_binds_a_shared_reservation_to_its_launch() {
    let mut f = start();
    f.admit_aftermath();
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(f.scenario.ctx());
    let create_pool_cap_id = object::id(&create_pool_cap);

    let launch = f.open_launch_with(create_pool_cap, DAO_FEE_BPS);

    let reservations = event::events_by_type<blast_events::AftermathPoolReserved>();
    assert_eq!(reservations.length(), 1);
    // Decoded in ABI order, consuming every byte: three type names, then three IDs.
    let mut r = bcs::new(bcs::to_bytes(&reservations[0]));
    assert_eq!(r.peel_vec_u8(), type_name::with_original_ids<LP>().into_string().into_bytes());
    assert_eq!(
        r.peel_vec_u8(),
        type_name::with_original_ids<AFTERMATH_TESTS>().into_string().into_bytes(),
    );
    assert_eq!(r.peel_vec_u8(), type_name::with_original_ids<QUOTE>().into_string().into_bytes());
    assert_eq!(object::id_from_address(r.peel_address()), object::id(&launch));
    let pool_creation_id = object::id_from_address(r.peel_address());
    assert_eq!(object::id_from_address(r.peel_address()), create_pool_cap_id);
    assert!(r.into_remainder_bytes().is_empty());

    f.scenario.next_tx(KEEPER);
    let pool_creation = f.scenario.take_shared_by_id<PoolCreation<LP, AFTERMATH_TESTS, QUOTE>>(
        pool_creation_id,
    );
    assert_eq!(pool_creation.pool_creation_launch_id_for_testing(), object::id(&launch));
    test_scenario::return_shared(pool_creation);

    destroy(launch);
    f.end();
}

#[test, expected_failure(
    abort_code = aftermath::EWrongLaunch,
    location = blast_fun_migrators::aftermath,
)]
/// A launch's migration cannot consume a reservation bound to another launch, and checks that
/// before touching the launch.
fun migrate_rejects_another_launches_reservation() {
    let mut f = start();
    f.admit_aftermath();
    let mut launch = f.open_launch(DAO_FEE_BPS);
    let other_reservation = aftermath::pool_creation_for_testing<LP, AFTERMATH_TESTS, QUOTE>(
        object::id_from_address(@0x0B5E),
        amm_pool::create_pool_cap_for_testing(f.scenario.ctx()),
        f.scenario.ctx(),
    );
    let mut pool_registry = pool_registry::new_for_testing(f.scenario.ctx());
    let dao_fee_version = version::new_for_testing(f.scenario.ctx());

    f.scenario.next_tx(KEEPER);
    let mut currency = f.scenario.take_from_address<Currency<AFTERMATH_TESTS>>(COIN_REGISTRY);
    aftermath::migrate(
        &mut launch,
        &f.migrators_version,
        &f.version,
        &mut currency,
        other_reservation,
        &mut pool_registry,
        &dao_fee_version,
        f.scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun new_checks_the_migrators_generation_before_the_fee() {
    let mut f = start();
    f.admit_aftermath();
    f.migrators_version.set_for_testing(2);
    let ticket = f.new_ticket();

    let (_initializer, _pending) = aftermath::new<LP, _, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        amm_pool::create_pool_cap_for_testing(f.scenario.ctx()),
        0,
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EMigrationWitnessNotAllowed,
    location = blast_fun::launch_config,
)]
fun new_aborts_until_the_config_admits_aftermath() {
    let mut f = start();
    let ticket = f.new_ticket();

    let (_initializer, _pending) = aftermath::new<LP, _, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        amm_pool::create_pool_cap_for_testing(f.scenario.ctx()),
        DAO_FEE_BPS,
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EQuoteNotAllowed,
    location = blast_fun::launch_config,
)]
fun new_admits_only_an_allowed_quote() {
    let mut f = start();
    f.admit_aftermath();
    let ticket = f.new_ticket();

    let (_initializer, _pending) = aftermath::new<LP, _, OTHER_QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        amm_pool::create_pool_cap_for_testing(f.scenario.ctx()),
        DAO_FEE_BPS,
    );

    abort EUnexpectedSuccess
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // This package sits at 0x0, so its types sort before the framework's 0x2.
    assert!(aftermath::sorts_before_for_testing<QUOTE, SUI>());
    assert!(!aftermath::sorts_before_for_testing<SUI, QUOTE>());
    assert!(aftermath::sorts_before_for_testing<A, AB>());
    assert!(!aftermath::sorts_before_for_testing<AB, A>());
    assert!(aftermath::sorts_before_for_testing<AB, QUOTE>());
    assert!(!aftermath::sorts_before_for_testing<A, A>());
}

// Owner-Cap Custody

#[test]
fun the_pool_authority_attaches_once_under_its_venue_apart_from_the_position() {
    let mut f = start_vault(creator_only());
    let owner_cap = dao_fee_pool::owner_cap_for_testing<LP>(f.scenario.ctx());
    let owner_cap_id = object::id(&owner_cap);
    let position_id = f.vault.position_id_for_testing<_, _, TestVenue>();

    f.vault.attach_pool_authority(&TestVenue(), owner_cap);

    assert_eq!(f.vault.pool_authority_id_for_testing<_, _, TestVenue>(), option::some(owner_cap_id));
    assert_eq!(f.vault.pool_authority_id_for_testing<_, _, OtherVenue>(), option::none());
    assert_eq!(f.vault.position_id_for_testing<_, _, TestVenue>(), position_id);
    assert!(position_id != option::some(owner_cap_id));
    f.end();
}

#[test, expected_failure(
    abort_code = sui::dynamic_field::EFieldAlreadyExists,
    location = sui::dynamic_field,
)]
fun a_second_pool_authority_cannot_replace_the_first() {
    let mut f = start_vault(creator_only());
    f.vault.attach_pool_authority(&TestVenue(), dao_fee_pool::owner_cap_for_testing<LP>(f.scenario.ctx()));

    f.vault.attach_pool_authority(&TestVenue(), dao_fee_pool::owner_cap_for_testing<LP>(f.scenario.ctx()));

    abort EUnexpectedSuccess
}

// Fee Collection

#[test]
/// Fee coins Aftermath sent to the vault's address are received, joined, and split exactly like a
/// collected position's fees: under a creator-only split and no Blast share, the creator balance
/// takes every unit, and nothing waits for auto-LP.
fun collect_fees_receives_the_vaults_fee_coins_and_splits_them() {
    let mut f = start_vault(creator_only());
    let meme_ids = f.send_coins<AFTERMATH_TESTS>(vector[60, 41]);
    let quote_ids = f.send_coins<QUOTE>(vector[10]);

    f.scenario.next_tx(KEEPER);
    f.collect(meme_ids, quote_ids);

    let collections = event::events_by_type<blast_events::FeesCollected>();
    assert_eq!(collections.length(), 1);
    let (creator_meme, creator_quote) = f.vault.creator_balances_for_testing();
    assert_eq!(creator_meme, 101);
    assert_eq!(creator_quote, 10);
    let (auto_lp_meme, auto_lp_quote) = f.vault.auto_lp_balances_for_testing();
    assert_eq!(auto_lp_meme, 0);
    assert_eq!(auto_lp_quote, 0);
    f.end();
}

#[test]
/// A collection that lists no coins is valid, moves nothing, and emits nothing.
fun an_empty_collection_moves_nothing() {
    let mut f = start_vault(creator_only());

    f.scenario.next_tx(KEEPER);
    f.collect(vector[], vector[]);

    assert!(event::events_by_type<blast_events::FeesCollected>().is_empty());
    let (creator_meme, creator_quote) = f.vault.creator_balances_for_testing();
    assert_eq!(creator_meme, 0);
    assert_eq!(creator_quote, 0);
    f.end();
}

#[test, expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_the_collection_before_receiving() {
    let mut f = start_vault(creator_only());
    let meme_ids = f.send_coins<AFTERMATH_TESTS>(vector[7]);
    f.migrators_version.set_for_testing(2);

    f.scenario.next_tx(KEEPER);
    f.collect(meme_ids, vector[]);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
/// A coin owned by someone else cannot be received into the vault.
fun collect_fees_receives_only_coins_the_vault_owns() {
    let mut f = start_vault(creator_only());
    let keeper_coin = coin::mint_for_testing<AFTERMATH_TESTS>(7, f.scenario.ctx());
    let keeper_coin_id = object::id(&keeper_coin);
    transfer::public_transfer(keeper_coin, KEEPER);

    f.scenario.next_tx(KEEPER);
    f.collect(vector[keeper_coin_id], vector[]);

    abort EUnexpectedSuccess
}

// Settled Fee-Split Updates

#[test]
/// A settled update splits the listed coins under the old split, then commits the new one.
fun settled_update_receives_under_the_old_split_then_commits_the_next_split() {
    let mut f = start_vault(creator_only());
    let curve_fee_cap = f.claim_curve_fee_cap();
    let meme_ids = f.send_coins<AFTERMATH_TESTS>(vector[10]);
    let quote_ids = f.send_coins<QUOTE>(vector[20]);

    f.scenario.next_tx(launch_fixture::creator());
    f.settle_and_update(&curve_fee_cap, meme_ids, quote_ids, rewards_only());

    assert_eq!(f.vault.fee_split_for_testing(), rewards_only());
    let (creator_meme, creator_quote) = f.vault.creator_balances_for_testing();
    assert_eq!(creator_meme, 10);
    assert_eq!(creator_quote, 20);
    let (rewards_meme, rewards_quote) = f.vault.rewards_balances();
    assert_eq!(rewards_meme, 0);
    assert_eq!(rewards_quote, 0);
    assert_eq!(event::events_by_type<blast_events::FeesCollected>().length(), 1);
    assert_eq!(event::events_by_type<blast_events::FeeSplitChanged>().length(), 1);
    destroy(curve_fee_cap);
    f.end();
}

#[test, expected_failure(abort_code = vault::EFeeSplitUnchanged, location = blast_fun_migrators::vault)]
/// The proposal is checked before any coin is received.
fun a_settled_update_rejects_the_current_split_before_receiving() {
    let mut f = start_vault(creator_only());
    let curve_fee_cap = f.claim_curve_fee_cap();
    let meme_ids = f.send_coins<AFTERMATH_TESTS>(vector[10]);

    f.scenario.next_tx(launch_fixture::creator());
    f.settle_and_update(&curve_fee_cap, meme_ids, vector[], creator_only());

    abort EUnexpectedSuccess
}

// === Test Helpers ===

fun start(): StartFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_package_version::new_for_testing(scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    config.set_quote_allowed<QUOTE>(&version, &blast_acl::witness_for_testing<ListingAdmin>(), true);
    config.set_trade_fees(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(100),
        bps::new(100),
    );
    StartFixture { scenario, version, migrators_version, config }
}

/// Starts an Aftermath launch at `dao_fee_bps`; the start must abort.
fun start_rejected_fee(dao_fee_bps: u16) {
    let mut f = start();
    f.admit_aftermath();
    let ticket = f.new_ticket();

    let (_initializer, _pending) = aftermath::new<LP, _, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        amm_pool::create_pool_cap_for_testing(f.scenario.ctx()),
        dao_fee_bps,
    );

    abort EUnexpectedSuccess
}

fun admit_aftermath(f: &mut StartFixture) {
    let admin = blast_acl::witness_for_testing<AdapterAdmin>();
    f.config.set_migration_witness_allowed<aftermath::Witness>(&f.version, &admin, true);
}

fun new_ticket(f: &mut StartFixture): LaunchTicket<AFTERMATH_TESTS> {
    launch_ticket::new(
        test_utils::create_one_time_witness<AFTERMATH_TESTS>(),
        9,
        b"AFTR".to_string(),
        b"Aftermath launch".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        f.scenario.ctx(),
    )
}

/// Starts an Aftermath launch in `QUOTE` at `dao_fee_bps` with a fresh test capability and
/// finalizes it through this module's `finalize`.
fun open_launch(f: &mut StartFixture, dao_fee_bps: u16): Launch<AFTERMATH_TESTS, QUOTE> {
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(f.scenario.ctx());

    f.open_launch_with(create_pool_cap, dao_fee_bps)
}

/// Starts an Aftermath launch in `QUOTE` at `dao_fee_bps` reserving `create_pool_cap`, and
/// finalizes it through this module's `finalize` once the Coin Registry holds the currency.
fun open_launch_with(
    f: &mut StartFixture,
    create_pool_cap: CreatePoolCapV2,
    dao_fee_bps: u16,
): Launch<AFTERMATH_TESTS, QUOTE> {
    let ticket = f.new_ticket();
    f.scenario.next_tx(ADMIN);
    let mut currency = f.scenario.take_from_address<Currency<AFTERMATH_TESTS>>(COIN_REGISTRY);
    let (mut initializer, pending) = aftermath::new<LP, _, QUOTE>(
        ticket,
        &f.migrators_version,
        &f.version,
        &f.config,
        create_pool_cap,
        dao_fee_bps,
    );
    initializer.set_virtual_quote(&f.version, 5_000_000);
    initializer.set_graduation_target(&f.version, TARGET);
    initializer.set_allocation_plan(&f.version,
        allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[]),
    );
    initializer.set_lp_fee_split(&f.version, creator_only());
    let creation_fee = coin::zero(f.scenario.ctx());
    let launch = aftermath::finalize(
        initializer,
        pending,
        &f.migrators_version,
        &f.version,
        &mut currency,
        &f.config,
        creation_fee,
        f.scenario.ctx(),
    );
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

fun end_start(f: StartFixture) {
    destroy(f);
}

/// Opens and shares a launch holding `fee_split` under the test venue, and builds its vault with
/// a one-unit position.
fun start_vault(fee_split: FeeSplit): VaultFixture {
    let mut scenario = test_scenario::begin(PROTOCOL);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_package_version::new_for_testing(scenario.ctx());
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    launch_fixture::admit<QUOTE, TestVenue>(&mut config, &version);
    let (launch, currency) = launch_fixture::open_launch<_, QUOTE, _>(
        &mut scenario,
        test_utils::create_one_time_witness<AFTERMATH_TESTS>(),
        &version,
        &config,
        TestVenue(),
        fee_split,
        false,
    );
    let launch_id = object::id(&launch);
    let vault = vault::new_for_testing(
        &launch,
        &TestVenue(),
        object::id_from_address(POOL),
        TestPosition { id: object::new(scenario.ctx()) },
        1,
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );
    launch.share(&version, &clock);
    destroy(config);

    VaultFixture {
        scenario,
        version,
        migrators_version,
        runtime,
        clock,
        policy,
        launch_id,
        currency,
        vault,
    }
}

/// Mints one coin per amount and sends each to the vault's address, returning their IDs in order.
fun send_coins<Asset>(self: &mut VaultFixture, amounts: vector<u64>): vector<ID> {
    let vault_address = object::id(&self.vault).to_address();

    amounts.map!(|amount| {
        let fee = coin::mint_for_testing<Asset>(amount, self.scenario.ctx());
        let id = object::id(&fee);
        transfer::public_transfer(fee, vault_address);
        id
    })
}

/// Collects the listed coins, by ID, as fee coins owned by the vault.
fun collect(self: &mut VaultFixture, meme_ids: vector<ID>, quote_ids: vector<ID>) {
    aftermath::collect_fees(
        &mut self.vault,
        &self.migrators_version,
        &self.policy,
        &mut self.currency,
        meme_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<AFTERMATH_TESTS>>(id)),
        quote_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<QUOTE>>(id)),
        self.scenario.ctx(),
    );
}

/// Settles the listed coins under the current split and commits `proposed`.
fun settle_and_update(
    self: &mut VaultFixture,
    curve_fee_cap: &CurveFeeCap<AFTERMATH_TESTS>,
    meme_ids: vector<ID>,
    quote_ids: vector<ID>,
    proposed: FeeSplit,
) {
    let launch = self.scenario.take_shared_by_id<Launch<AFTERMATH_TESTS, QUOTE>>(self.launch_id);
    aftermath::settle_and_update_fee_split(
        &mut self.vault,
        &self.migrators_version,
        &self.policy,
        &launch,
        curve_fee_cap,
        &mut self.currency,
        meme_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<AFTERMATH_TESTS>>(id)),
        quote_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<QUOTE>>(id)),
        proposed,
        self.scenario.ctx(),
    );
    test_scenario::return_shared(launch);
}

/// Claims the creator capabilities as the creator recipient and keeps the curve-fee cap.
fun claim_curve_fee_cap(self: &mut VaultFixture): CurveFeeCap<AFTERMATH_TESTS> {
    self.scenario.next_tx(launch_fixture::creator());
    let mut launch = self.scenario.take_shared_by_id<Launch<AFTERMATH_TESTS, QUOTE>>(self.launch_id);
    let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
        &self.version,
        &self.runtime,
        option::none(),
        &self.clock,
        self.scenario.ctx(),
    );
    destroy(metadata_cap);
    test_scenario::return_shared(launch);

    curve_fee_cap
}

fun end_vault(self: VaultFixture) {
    let VaultFixture {
        scenario,
        version,
        migrators_version,
        runtime,
        clock,
        policy,
        launch_id: _,
        currency,
        vault,
    } = self;
    destroy(vault);
    destroy(currency);
    destroy(policy);
    destroy(runtime);
    destroy(migrators_version);
    destroy(version);
    destroy(clock);
    scenario.end();
}

fun creator_only(): FeeSplit {
    allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[])
}

fun rewards_only(): FeeSplit {
    allocation::fee_split(bps::new(0), bps::new(0), bps::new(10_000), bps::new(0), vector[])
}

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

/// Publishes the policy, so it is the protocol destination.
const PROTOCOL: address = @0xB1A57;

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const KEEPER: address = @0xEE;

const POOL: address = @0x9001;

const TARGET: u64 = 25_000_000;

const DAO_FEE_BPS: u16 = 200;

// === Errors ===

#[error]
const EUnexpectedSuccess: vector<u8> = b"The guarded operation unexpectedly returned.";

// === Imports ===

use amm::{pool::{Self as amm_pool, CreatePoolCapV2}, pool_registry};

use blast_admin::blast_acl;

use blast_fun::{
    allocation::{Self, FeeSplit},
    blast_fun_domain::{AdapterAdmin, FeeAdmin, ListingAdmin},
    bps,
    creator_authority::{Self, CurveFeeCap},
    launch::Launch,
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    blast_fun::{Self as package_version, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_migrators::{
    aftermath::{Self, PoolCreation},
    blast_events,
    launch_fixture,
    lp_fee_policy::{Self, LpFeePolicy},
    blast_fun_migrators::{Self as migrators_package_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use dao_fee_amm::{pool as dao_fee_pool, version};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance,
    bcs,
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun admit_aftermath as StartFixture.admit_aftermath;
use fun claim_curve_fee_cap as VaultFixture.claim_curve_fee_cap;
use fun collect as VaultFixture.collect;
use fun end_start as StartFixture.end;
use fun end_vault as VaultFixture.end;
use fun new_ticket as StartFixture.new_ticket;
use fun open_launch as StartFixture.open_launch;
use fun open_launch_with as StartFixture.open_launch_with;
use fun send_coins as VaultFixture.send_coins;
use fun settle_and_update as VaultFixture.settle_and_update;
