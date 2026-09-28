// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Sealed adapter-shaped fixture for LP-fee collection with auto-LP, settled fee-split updates, and
/// creator claims under the launch's live curve-fee cap.
///
/// The wrappers withdraw exactly the attached position's accrued fees, split them through the
/// vault, and add the waiting auto-LP balances back to the position in the same call, as every
/// venue adapter does; the mock venue takes an equal amount of both assets. The venue interfaces
/// are `abort 0` link stubs, so the migrators-generation guard each adapter runs first is enforced
/// by the source gate, not here.
module blast_fun_migrators::fee_split_update_tests;

// === Constants ===

/// Publishes the policy, so it is the protocol destination.
const PROTOCOL: address = @0xB1A57;

const ADMIN: address = @0xAD;

const KEEPER: address = @0xEE;

const ROUTE_A: address = @0xD1;

const ROUTE_B: address = @0xD2;

const POOL: address = @0x9001;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct FEE_SPLIT_UPDATE_TESTS has drop {}

public struct QUOTE() has drop;

/// The test adapter's launch witness, which is also its vault venue marker.
public struct Venue() has drop;

/// Venue position accruing the fees the adapter collects and holding the liquidity it adds.
public struct MockPosition has key, store {
    id: UID,
    fee_meme: Balance<FEE_SPLIT_UPDATE_TESTS>,
    fee_quote: Balance<QUOTE>,
    liquidity_meme: Balance<FEE_SPLIT_UPDATE_TESTS>,
    liquidity_quote: Balance<QUOTE>,
}

/// One shared launch, whose creator claims the curve-fee cap, and the vault it migrated into.
public struct FeeSplitFixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    runtime: RuntimeConfig,
    clock: Clock,
    policy: LpFeePolicy,
    launch_id: ID,
    currency: Currency<FEE_SPLIT_UPDATE_TESTS>,
    vault: LpVault<FEE_SPLIT_UPDATE_TESTS, QUOTE>,
}

/// Independently encoded `FeesCollected` in ABI order.
public struct ExpectedCollection has copy, drop {
    vault_id: ID,
    generation: u64,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_meme: u64,
    burn_quote: u64,
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
}

/// Independently encoded `FeeSplitChanged` in ABI order.
public struct ExpectedFeeSplitChanged has copy, drop {
    vault_id: ID,
    old_generation: u64,
    new_generation: u64,
    old_fee_split: FeeSplit,
    new_fee_split: FeeSplit,
}

/// Independently encoded `AutoLiquidityAdded` in ABI order.
public struct ExpectedAutoLiquidityAdded has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_pending: u64,
    quote_pending: u64,
}

/// Independently encoded `CreatorFeesClaimed` in ABI order.
public struct ExpectedCreatorFeesClaimed has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

// === Tests ===

// Settled Fee-Split Updates

#[test]
fun settled_update_splits_accrued_fees_under_the_old_split_then_commits_the_next_generation() {
    let mut f = start(creator_and_a());
    let curve_fee_cap = f.claim_curve_fee_cap();

    f.accrue(10, 20);
    f.settle_exact_position(&curve_fee_cap, rewards_and_b());

    assert_eq!(f.vault.generation_for_testing(), 1);
    assert_eq!(f.vault.fee_split_for_testing(), rewards_and_b());
    assert_collection(
        ExpectedCollection {
            vault_id: object::id(&f.vault),
            generation: 0,
            gross_meme: 10,
            gross_quote: 20,
            protocol_destination: PROTOCOL,
            protocol_meme: 0,
            protocol_quote: 0,
            creator_meme: 5,
            creator_quote: 10,
            auto_lp_meme: 0,
            auto_lp_quote: 0,
            rewards_meme: 0,
            rewards_quote: 0,
            burn_meme: 0,
            burn_quote: 0,
            recipient_meme: vector[5],
            recipient_quote: vector[10],
        },
    );
    assert!(event::events_by_type<blast_events::AutoLiquidityAdded>().is_empty());
    let changes = event::events_by_type<blast_events::FeeSplitChanged>();
    assert_eq!(changes.length(), 1);
    assert_eq!(
        bcs::to_bytes(&changes[0]),
        bcs::to_bytes(
            &ExpectedFeeSplitChanged {
                vault_id: object::id(&f.vault),
                old_generation: 0,
                new_generation: 1,
                old_fee_split: creator_and_a(),
                new_fee_split: rewards_and_b(),
            },
        ),
    );

    // Collection needs no cap, and later fees follow the committed generation: 3 Meme and 4
    // Quote split 20/30/50 to auto-LP, rewards, and B, and the mock venue takes one unit of each.
    f.scenario.next_tx(KEEPER);
    f.accrue(3, 4);
    f.collect_exact_position();
    assert_collection(
        ExpectedCollection {
            vault_id: object::id(&f.vault),
            generation: 1,
            gross_meme: 3,
            gross_quote: 4,
            protocol_destination: PROTOCOL,
            protocol_meme: 0,
            protocol_quote: 0,
            creator_meme: 0,
            creator_quote: 0,
            auto_lp_meme: 1,
            auto_lp_quote: 1,
            rewards_meme: 1,
            rewards_quote: 1,
            burn_meme: 0,
            burn_quote: 0,
            recipient_meme: vector[1],
            recipient_quote: vector[2],
        },
    );
    f.assert_auto_liquidity_added(1, 1, 0, 0);
    assert_balances!(|| f.vault.creator_balances_for_testing(), 5, 10);
    assert_balances!(|| f.vault.rewards_balances(), 1, 1);
    f.assert_received(ROUTE_A, 5, 10);
    f.assert_received(ROUTE_B, 1, 2);

    destroy(curve_fee_cap);
    f.end();
}

#[test]
fun zero_fee_settlement_still_advances_exactly_once_without_a_collection_event() {
    let mut f = start(creator_and_a());
    let curve_fee_cap = f.claim_curve_fee_cap();

    f.settle_exact_position(&curve_fee_cap, rewards_and_b());

    assert_eq!(f.vault.generation_for_testing(), 1);
    assert!(event::events_by_type<blast_events::FeesCollected>().is_empty());
    assert!(event::events_by_type<blast_events::AutoLiquidityAdded>().is_empty());
    assert_eq!(event::events_by_type<blast_events::FeeSplitChanged>().length(), 1);
    destroy(curve_fee_cap);
    f.end();
}

#[test]
fun a_reassigned_curve_fee_cap_updates_the_split() {
    let mut f = start(creator_and_a());
    let retired = f.claim_curve_fee_cap();
    f.reassign_curve_fee_cap();

    let curve_fee_cap = f.take_reassigned_cap();
    f.settle_exact_position(&curve_fee_cap, rewards_and_b());

    assert_eq!(f.vault.generation_for_testing(), 1);
    destroy(retired);
    destroy(curve_fee_cap);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EFeeSplitUnchanged, location = blast_fun_migrators::vault)]
fun an_identical_proposal_is_rejected() {
    let mut f = start(creator_and_a());
    let curve_fee_cap = f.claim_curve_fee_cap();
    f.accrue(1, 1);

    f.settle_exact_position(&curve_fee_cap, creator_and_a());

    destroy(curve_fee_cap);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorCapNotLive,
    location = blast_fun::launch,
)]
fun a_retired_curve_fee_cap_cannot_update_the_split() {
    let mut f = start(creator_and_a());
    let retired = f.claim_curve_fee_cap();
    f.reassign_curve_fee_cap();

    f.settle_exact_position(&retired, rewards_and_b());

    destroy(retired);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorCapNotLive,
    location = blast_fun::launch,
)]
fun the_live_cap_is_checked_before_the_proposal() {
    let mut f = start(creator_and_a());
    let retired = f.claim_curve_fee_cap();
    f.reassign_curve_fee_cap();

    f.settle_exact_position(&retired, creator_and_a());

    destroy(retired);
    f.end();
}

// Auto-LP

#[test]
fun auto_lp_keeps_what_the_venue_does_not_take_and_announces_only_real_additions() {
    let mut f = start(auto_lp_only());

    f.scenario.next_tx(KEEPER);
    f.accrue(5, 2);
    f.collect_exact_position();
    f.assert_auto_liquidity_added(2, 2, 3, 0);
    assert_balances!(|| f.vault.auto_lp_balances_for_testing(), 3, 0);

    f.scenario.next_tx(KEEPER);
    f.accrue(0, 4);
    f.collect_exact_position();
    f.assert_auto_liquidity_added(3, 3, 0, 1);
    assert_balances!(|| f.vault.auto_lp_balances_for_testing(), 0, 1);

    // Nothing to pair with the waiting Quote: no addition and no event.
    f.scenario.next_tx(KEEPER);
    f.collect_exact_position();
    assert_eq!(event::num_events(), 0);
    assert_balances!(|| f.vault.auto_lp_balances_for_testing(), 0, 1);
    assert_balances!(|| f.position_liquidity(), 5, 5);

    f.end();
}

// Creator Claims

#[test]
fun the_live_cap_claims_exactly_the_creator_balances() {
    let mut f = start(creator_and_a());
    let curve_fee_cap = f.claim_curve_fee_cap();
    f.scenario.next_tx(KEEPER);
    f.accrue(10, 21);
    f.collect_exact_position();

    // The 21st Quote unit is dust at equal remainders and goes to the creator, the earlier part.
    let (meme, quote) = f.claim_creator_fees(&curve_fee_cap);

    assert_eq!(meme.burn_for_testing(), 5);
    assert_eq!(quote.burn_for_testing(), 11);
    assert_balances!(|| f.vault.creator_balances_for_testing(), 0, 0);
    let claims = event::events_by_type<blast_events::CreatorFeesClaimed>();
    assert_eq!(claims.length(), 1);
    assert_eq!(
        bcs::to_bytes(&claims[0]),
        bcs::to_bytes(
            &ExpectedCreatorFeesClaimed {
                vault_id: object::id(&f.vault),
                meme_amount: 5,
                quote_amount: 11,
            },
        ),
    );
    f.assert_received(ROUTE_A, 5, 10);

    destroy(curve_fee_cap);
    f.end();
}

#[test]
fun a_reassigned_cap_claims_the_creator_fees_accrued_before_the_reassignment() {
    let mut f = start(creator_and_a());
    let retired = f.claim_curve_fee_cap();
    f.scenario.next_tx(KEEPER);
    f.accrue(4, 0);
    f.collect_exact_position();
    f.reassign_curve_fee_cap();

    let curve_fee_cap = f.take_reassigned_cap();
    let (meme, quote) = f.claim_creator_fees(&curve_fee_cap);

    assert_eq!(meme.burn_for_testing(), 2);
    assert_eq!(quote.burn_for_testing(), 0);
    destroy(retired);
    destroy(curve_fee_cap);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorCapNotLive,
    location = blast_fun::launch,
)]
fun a_retired_cap_cannot_claim_creator_fees() {
    let mut f = start(creator_and_a());
    let retired = f.claim_curve_fee_cap();
    f.scenario.next_tx(KEEPER);
    f.accrue(4, 4);
    f.collect_exact_position();
    f.reassign_curve_fee_cap();

    let (meme, quote) = f.claim_creator_fees(&retired);

    destroy(meme);
    destroy(quote);
    destroy(retired);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::ENoCreatorFees, location = blast_fun_migrators::vault)]
fun an_empty_creator_claim_is_rejected() {
    let mut f = start(creator_and_a());
    let curve_fee_cap = f.claim_curve_fee_cap();

    let (meme, quote) = f.claim_creator_fees(&curve_fee_cap);

    destroy(meme);
    destroy(quote);
    destroy(curve_fee_cap);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::ENoCreatorFees, location = blast_fun_migrators::vault)]
fun a_drained_creator_balance_cannot_be_claimed_again() {
    let mut f = start(creator_and_a());
    let curve_fee_cap = f.claim_curve_fee_cap();
    f.scenario.next_tx(KEEPER);
    f.accrue(2, 2);
    f.collect_exact_position();
    let (meme, quote) = f.claim_creator_fees(&curve_fee_cap);
    destroy(meme);
    destroy(quote);

    let (meme, quote) = f.claim_creator_fees(&curve_fee_cap);

    destroy(meme);
    destroy(quote);
    destroy(curve_fee_cap);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_the_creator_claim_before_the_cap_and_balance_checks() {
    let mut f = start(creator_and_a());
    let retired = f.claim_curve_fee_cap();
    f.reassign_curve_fee_cap();
    f.migrators_version.set_for_testing(2);

    let (meme, quote) = f.claim_creator_fees(&retired);

    destroy(meme);
    destroy(quote);
    destroy(retired);
    f.end();
}

// === Test Helpers ===

/// Opens and shares a launch holding `fee_split`, and builds its vault.
fun start(fee_split: FeeSplit): FeeSplitFixture {
    let mut scenario = test_scenario::begin(PROTOCOL);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    launch_fixture::admit<QUOTE, Venue>(&mut config, &version);
    let (launch, currency) = launch_fixture::open_launch<_, QUOTE, _>(
        &mut scenario,
        test_utils::create_one_time_witness<FEE_SPLIT_UPDATE_TESTS>(),
        &version,
        &config,
        Venue(),
        fee_split,
        false,
    );
    let launch_id = object::id(&launch);
    let position = MockPosition {
        id: object::new(scenario.ctx()),
        fee_meme: balance::zero(),
        fee_quote: balance::zero(),
        liquidity_meme: balance::zero(),
        liquidity_quote: balance::zero(),
    };
    let vault = vault::new_for_testing(
        &launch,
        &Venue(),
        object::id_from_address(POOL),
        position,
        1,
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );
    launch.share(&clock);
    destroy(config);

    FeeSplitFixture {
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

/// Claims the creator capabilities as the creator recipient and keeps the curve-fee cap.
fun claim_curve_fee_cap(self: &mut FeeSplitFixture): CurveFeeCap<FEE_SPLIT_UPDATE_TESTS> {
    self.scenario.next_tx(launch_fixture::creator());
    let mut launch = self.take_launch();
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

/// Retires the live curve-fee cap and delivers a fresh one to the creator.
fun reassign_curve_fee_cap(self: &mut FeeSplitFixture) {
    self.scenario.next_tx(ADMIN);
    let admin = blast_acl::witness_for_testing<CreatorAdmin>();
    let mut launch = self.take_launch();
    launch.reassign_curve_fee_cap(
        &self.version,
        &admin,
        launch_fixture::creator(),
        self.scenario.ctx(),
    );
    test_scenario::return_shared(launch);
}

/// Takes the cap a reassignment delivered to the creator.
fun take_reassigned_cap(self: &mut FeeSplitFixture): CurveFeeCap<FEE_SPLIT_UPDATE_TESTS> {
    self.scenario.next_tx(launch_fixture::creator());
    self.scenario.take_from_sender()
}

/// Accrues venue fees on the attached position.
fun accrue(self: &mut FeeSplitFixture, meme: u64, quote: u64) {
    let position = self.vault.position_mut<_, _, _, MockPosition>(&Venue());
    position.fee_meme.join(balance::create_for_testing(meme));
    position.fee_quote.join(balance::create_for_testing(quote));
}

/// Adapter-only wrapper: withdraws the attached position's fees, splits them, and adds the
/// waiting auto-LP balances back to the position in the same call.
fun collect_exact_position(self: &mut FeeSplitFixture) {
    let position = self.vault.position_mut<_, _, _, MockPosition>(&Venue());
    let meme = position.fee_meme.withdraw_all();
    let quote = position.fee_quote.withdraw_all();

    self.vault.split_fees(&self.policy, &mut self.currency, meme, quote, self.scenario.ctx());
    self.compound();
}

/// Adapter-only wrapper: checks `curve_fee_cap` and `proposed`, collects under the current split,
/// then commits `proposed`, all in one creator transaction.
fun settle_exact_position(
    self: &mut FeeSplitFixture,
    curve_fee_cap: &CurveFeeCap<FEE_SPLIT_UPDATE_TESTS>,
    proposed: FeeSplit,
) {
    self.scenario.next_tx(launch_fixture::creator());
    let launch = self.take_launch();
    self.vault.assert_fee_split_update(&launch, curve_fee_cap, proposed);

    self.collect_exact_position();
    self.vault.update_fee_split(proposed);
    test_scenario::return_shared(launch);
}

/// The mock venue adds an equal amount of both waiting assets, as much as the scarcer side allows.
fun compound(self: &mut FeeSplitFixture) {
    let (mut meme, mut quote) = self.vault.take_auto_lp();
    let added = meme.value().min(quote.value());
    let position = self.vault.position_mut<_, _, _, MockPosition>(&Venue());
    position.liquidity_meme.join(meme.split(added));
    position.liquidity_quote.join(quote.split(added));

    self.vault.keep_auto_lp(added, added, meme, quote);
}

/// Claims the creator's accrued fees in a creator transaction.
fun claim_creator_fees(
    self: &mut FeeSplitFixture,
    curve_fee_cap: &CurveFeeCap<FEE_SPLIT_UPDATE_TESTS>,
): (Coin<FEE_SPLIT_UPDATE_TESTS>, Coin<QUOTE>) {
    self.scenario.next_tx(launch_fixture::creator());
    let launch = self.take_launch();
    let (meme, quote) = self
        .vault
        .claim_creator_fees(&self.migrators_version, &launch, curve_fee_cap, self.scenario.ctx());
    test_scenario::return_shared(launch);

    (meme, quote)
}

fun take_launch(self: &FeeSplitFixture): Launch<FEE_SPLIT_UPDATE_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.launch_id)
}

/// Returns the liquidity the mock venue holds for the position.
fun position_liquidity(self: &mut FeeSplitFixture): (u64, u64) {
    let position = self.vault.position_mut<_, _, _, MockPosition>(&Venue());

    (position.liquidity_meme.value(), position.liquidity_quote.value())
}

/// Compares this transaction's only `FeesCollected` with its independent encoding.
fun assert_collection(expected: ExpectedCollection) {
    let events = event::events_by_type<blast_events::FeesCollected>();

    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
}

/// Compares this transaction's only `AutoLiquidityAdded` with its independent encoding.
fun assert_auto_liquidity_added(
    self: &FeeSplitFixture,
    meme_amount: u64,
    quote_amount: u64,
    meme_pending: u64,
    quote_pending: u64,
) {
    let events = event::events_by_type<blast_events::AutoLiquidityAdded>();

    assert_eq!(events.length(), 1);
    assert_eq!(
        bcs::to_bytes(&events[0]),
        bcs::to_bytes(
            &ExpectedAutoLiquidityAdded {
                vault_id: object::id(&self.vault),
                meme_amount,
                quote_amount,
                meme_pending,
                quote_pending,
            },
        ),
    );
}

/// Asserts the Meme and Quote amounts `$balances` reads.
macro fun assert_balances($balances: || -> (u64, u64), $meme: u64, $quote: u64) {
    let (meme_balance, quote_balance) = $balances();

    assert_eq!(meme_balance, $meme);
    assert_eq!(quote_balance, $quote);
}

/// Asserts `owner` received exactly one coin per nonzero asset since its last check.
fun assert_received(self: &mut FeeSplitFixture, owner: address, meme: u64, quote: u64) {
    self.scenario.next_tx(owner);
    if (meme > 0) {
        let coin = self.scenario.take_from_sender<Coin<FEE_SPLIT_UPDATE_TESTS>>();
        assert_eq!(coin.burn_for_testing(), meme);
    };
    if (quote > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    };
    assert!(!self.scenario.has_most_recent_for_sender<Coin<FEE_SPLIT_UPDATE_TESTS>>());
    assert!(!self.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

fun end(self: FeeSplitFixture) {
    destroy(self);
}

/// Half to the creator, half to recipient A.
fun creator_and_a(): FeeSplit {
    allocation::fee_split(
        bps::new(5_000),
        bps::new(0),
        bps::new(0),
        bps::new(0),
        vector[allocation::route(ROUTE_A, bps::new(5_000))],
    )
}

/// Auto-LP 20%, rewards 30%, recipient B 50%.
fun rewards_and_b(): FeeSplit {
    allocation::fee_split(
        bps::new(0),
        bps::new(2_000),
        bps::new(3_000),
        bps::new(0),
        vector[allocation::route(ROUTE_B, bps::new(5_000))],
    )
}

fun auto_lp_only(): FeeSplit {
    allocation::fee_split(bps::new(0), bps::new(10_000), bps::new(0), bps::new(0), vector[])
}

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    allocation::{Self, FeeSplit},
    blast_fun_domain::CreatorAdmin,
    bps,
    creator_authority::CurveFeeCap,
    launch::Launch,
    launch_config,
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_migrators::{
    blast_events,
    launch_fixture,
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::Coin,
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};
