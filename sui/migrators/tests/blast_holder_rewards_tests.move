// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Holder-reward rounds funded from a vault's rewards balance under the Blast admin witness, and
/// Merkle claims that pay each committed beneficiary once.
module blast_fun_migrators::blast_holder_rewards_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;

const ADMIN: address = @0xAD;

const ALICE: address = @0xA;

const BOB: address = @0xB0B;

const BOT: address = @0xB07;

const POOL: address = @0x9001;

/// Rewards the fixture vault holds before any round.
const FUNDED_MEME: u64 = 1_000;

const FUNDED_QUOTE: u64 = 2_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct BLAST_HOLDER_REWARDS_TESTS has drop {}

public struct QUOTE() has drop;

/// The test adapter's launch witness, which is also its vault venue marker.
public struct TestVenue() has drop;

public struct TestPosition has key, store { id: UID }

/// One vault whose whole fee split funds holder rewards.
public struct RewardsFixture {
    scenario: Scenario,
    migrators_version: MigratorsVersion,
    vault: LpVault<BLAST_HOLDER_REWARDS_TESTS, QUOTE>,
}

/// Independently encoded `RoundPublished` in ABI order.
public struct ExpectedRoundPublished has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
}

/// Independently encoded `RewardPaid` in ABI order.
public struct ExpectedRewardPaid has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

// === Tests ===

// Publication

#[test]
fun publication_reserves_its_budget_from_the_rewards_balance_and_announces_the_commitment() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 10, 20);

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, root, digest(), 1, 10, 20);

    let published = event::events_by_type<blast_events::RoundPublished>();
    assert_eq!(published.length(), 1);
    let round_id = round_id_of(published[0]);
    assert_eq!(
        bcs::to_bytes(&published[0]),
        bcs::to_bytes(
            &ExpectedRoundPublished {
                vault_id: object::id(&f.vault),
                round_id,
                number: 0,
                start_checkpoint: 0,
                end_checkpoint: 10,
                root,
                manifest_digest: digest(),
                leaf_count: 1,
                meme_amount: 10,
                quote_amount: 20,
                meme_unallocated: FUNDED_MEME - 10,
                quote_unallocated: FUNDED_QUOTE - 20,
            },
        ),
    );
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 10, FUNDED_QUOTE - 20);
    assert_eq!(f.vault.next_round(), 1);
    assert_eq!(f.vault.last_checkpoint(), option::some(10));

    f.scenario.next_tx(BOT);
    let round = f.take_round(round_id);
    assert_balances!(|| round.round_balances_for_testing(), 10, 20);
    assert!(!round.is_claimed_for_testing(0));
    test_scenario::return_shared(round);

    f.end();
}

#[test]
fun a_round_may_reserve_the_whole_rewards_balance_of_one_asset() {
    let mut f = start();

    let round_id = f.round(0, FUNDED_MEME, 0);

    assert_balances!(|| f.vault.rewards_balances(), 0, FUNDED_QUOTE);
    f.claim(round_id, 0, ALICE, FUNDED_MEME, 0, vector[]);
    f.assert_received(ALICE, FUNDED_MEME, 0);

    f.end();
}

#[test]
fun each_round_starts_where_the_previous_one_ended() {
    let mut f = start();
    let first = f.leaf(0, 0, ALICE, 1, 1);
    let second = f.leaf(1, 0, ALICE, 1, 1);

    f.scenario.next_tx(ADMIN);
    f.publish(0, 7, 9, first, digest(), 1, 1, 1);
    f.publish(1, 9, 30, second, digest(), 1, 1, 1);

    assert_eq!(f.vault.next_round(), 2);
    assert_eq!(f.vault.last_checkpoint(), option::some(30));
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EWrongRound,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_stale_round_number_cannot_fund_another_round() {
    let mut f = start();
    f.round(0, 10, 20);

    f.round(0, 10, 20);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EWrongRound,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_skipped_round_number_is_rejected() {
    let mut f = start();

    f.round(1, 10, 20);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidInterval,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun overlapping_intervals_are_rejected() {
    let mut f = start();
    f.round(0, 1, 1);

    f.scenario.next_tx(ADMIN);
    f.publish(1, 9, 20, digest(), digest(), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidInterval,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun gapped_intervals_are_rejected() {
    let mut f = start();
    f.round(0, 1, 1);

    f.scenario.next_tx(ADMIN);
    f.publish(1, 11, 20, digest(), digest(), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidInterval,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_empty_interval_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 10, 10, digest(), digest(), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidCommitment,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_malformed_root_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, vector::tabulate!(31, |_| 1u8), digest(), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidCommitment,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_malformed_manifest_digest_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, digest(), vector::tabulate!(33, |_| 1u8), 1, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidLeafCount,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_empty_leaf_set_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, digest(), digest(), 0, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidLeafCount,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun the_first_leaf_count_over_capacity_is_rejected() {
    let mut f = start();

    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, digest(), digest(), 65_537, 1, 1);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EEmptyBudget,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_empty_budget_is_rejected() {
    let mut f = start();

    f.round(0, 0, 0);

    f.end();
}

#[test]
#[expected_failure(abort_code = balance::ENotEnough, location = sui::balance)]
fun a_meme_budget_above_the_rewards_balance_is_rejected() {
    let mut f = start();

    f.round(0, FUNDED_MEME + 1, 0);

    f.end();
}

#[test]
#[expected_failure(abort_code = balance::ENotEnough, location = sui::balance)]
fun a_quote_budget_above_the_rewards_balance_is_rejected() {
    let mut f = start();

    f.round(0, 0, FUNDED_QUOTE + 1);

    f.end();
}

#[test]
#[expected_failure(abort_code = balance::ENotEnough, location = sui::balance)]
fun reserved_funds_cannot_back_a_second_round() {
    let mut f = start();
    f.round(0, FUNDED_MEME, 0);

    f.round(1, 1, 0);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_publication_before_every_round_check() {
    let mut f = start();
    f.migrators_version.set_for_testing(2);

    f.scenario.next_tx(ADMIN);
    f.publish(7, 10, 10, vector[], vector[], 0, 0, 0);

    f.end();
}

// Claims

#[test]
fun a_relayed_claim_pays_the_committed_beneficiary_once_and_emits_the_exact_payment() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, ALICE, 10, 20, vector[]);

    let paid = event::events_by_type<blast_events::RewardPaid>();
    assert_eq!(paid.length(), 1);
    assert_eq!(
        bcs::to_bytes(&paid[0]),
        bcs::to_bytes(
            &ExpectedRewardPaid {
                round_id,
                index: 0,
                beneficiary: ALICE,
                meme_amount: 10,
                quote_amount: 20,
                meme_remaining: 0,
                quote_remaining: 0,
            },
        ),
    );
    f.assert_round(round_id, 0, 0, 0, true);
    f.assert_received(ALICE, 10, 20);
    f.assert_received(BOT, 0, 0);

    f.end();
}

#[test]
fun a_quote_only_claim_creates_no_zero_meme_coin() {
    let mut f = start();
    let round_id = f.round(0, 0, 20);

    f.claim(round_id, 0, ALICE, 0, 20, vector[]);

    f.assert_received(ALICE, 0, 20);
    f.end();
}

#[test]
fun two_leaves_are_claimed_with_positional_proofs_and_leave_exact_remainders() {
    let mut f = start();
    let alice = f.leaf(0, 0, ALICE, 10, 0);
    let bob = f.leaf(0, 1, BOB, 5, 7);
    let root = merkle::node_for_testing(alice, bob);
    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, root, digest(), 2, 15, 7);
    let round_id = published_round_id();

    f.claim(round_id, 1, BOB, 5, 7, vector[alice]);
    let paid = event::events_by_type<blast_events::RewardPaid>();
    assert_eq!(
        bcs::to_bytes(&paid[0]),
        bcs::to_bytes(
            &ExpectedRewardPaid {
                round_id,
                index: 1,
                beneficiary: BOB,
                meme_amount: 5,
                quote_amount: 7,
                meme_remaining: 10,
                quote_remaining: 0,
            },
        ),
    );
    f.assert_round(round_id, 10, 0, 1, true);
    f.assert_round(round_id, 10, 0, 0, false);
    f.claim(round_id, 0, ALICE, 10, 0, vector[bob]);

    f.assert_round(round_id, 0, 0, 0, true);
    f.assert_received(ALICE, 10, 0);
    f.assert_received(BOB, 5, 7);
    f.end();
}

#[test]
fun a_later_round_leaves_earlier_unclaimed_entitlements_intact() {
    let mut f = start();
    let first = f.round(0, 10, 20);
    let second = f.round(1, 20, 40);

    f.claim(second, 0, ALICE, 20, 40, vector[]);
    f.claim(first, 0, ALICE, 10, 20, vector[]);

    f.assert_round(first, 0, 0, 0, true);
    f.assert_round(second, 0, 0, 0, true);
    assert_balances!(|| f.vault.rewards_balances(), FUNDED_MEME - 30, FUNDED_QUOTE - 60);
    f.end();
}

#[test]
fun the_largest_round_claims_its_last_bitmap_bit() {
    let mut f = start();
    let leaf = f.leaf(0, 65_535, ALICE, 1, 0);
    let sibling = f.leaf(0, 0, ALICE, 1, 0);
    let proof = vector::tabulate!(16, |_| sibling);
    let mut root = leaf;
    proof.do_ref!(|sibling| root = merkle::node_for_testing(*sibling, root));
    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 1, root, root, 65_536, 1, 0);
    let round_id = published_round_id();

    f.claim(round_id, 65_535, ALICE, 1, 0, proof);

    f.assert_round(round_id, 0, 0, 65_535, true);
    f.assert_round(round_id, 0, 0, 65_534, false);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EAlreadyClaimed,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_payout_cannot_be_replayed_even_after_the_budget_is_drained() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);
    f.claim(round_id, 0, ALICE, 10, 20, vector[]);

    f.claim(round_id, 0, ALICE, 10, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidProof,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_relayer_cannot_substitute_its_own_address() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, BOT, 10, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidProof,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_holder_cannot_change_an_amount() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, ALICE, 9, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidProof,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_proof_of_the_wrong_depth_is_rejected() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 0, ALICE, 10, 20, vector[digest()]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidIndex,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_index_outside_the_leaf_set_is_rejected_before_proof_work() {
    let mut f = start();
    let round_id = f.round(0, 10, 20);

    f.claim(round_id, 1, ALICE, 10, 20, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EInvalidBeneficiary,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun a_zero_beneficiary_is_rejected_before_proof_work() {
    let mut f = start();
    let round_id = f.round(0, 1, 1);

    f.claim(round_id, 0, @0x0, 1, 1, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_holder_rewards::EEmptyBudget,
    location = blast_fun_migrators::blast_holder_rewards,
)]
fun an_empty_claim_cannot_consume_a_bitmap_bit() {
    let mut f = start();
    let round_id = f.round(0, 1, 1);

    f.claim(round_id, 0, ALICE, 0, 0, vector[]);

    f.end();
}

#[test]
#[expected_failure(abort_code = balance::ENotEnough, location = sui::balance)]
fun a_claim_cannot_exceed_its_reserved_budget() {
    let mut f = start();
    let root = f.leaf(0, 0, ALICE, 2, 1);
    f.scenario.next_tx(ADMIN);
    f.publish(0, 0, 10, root, digest(), 1, 1, 1);
    let round_id = published_round_id();

    f.claim(round_id, 0, ALICE, 2, 1, vector[]);

    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_a_claim_before_every_claim_check() {
    let mut f = start();
    let round_id = f.round(0, 1, 1);
    f.migrators_version.set_for_testing(2);

    f.claim(round_id, 99, @0x0, 0, 0, vector[]);

    f.end();
}

// === Test Helpers ===

/// Opens an owned launch whose whole fee split funds rewards, attaches its vault, and splits one
/// collection into the rewards balance under the zero default Blast share.
fun start(): RewardsFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    launch_fixture::admit<QUOTE, TestVenue>(&mut config, &version);
    let (launch, mut currency) = launch_fixture::open_launch<_, QUOTE, _>(
        &mut scenario,
        test_utils::create_one_time_witness<BLAST_HOLDER_REWARDS_TESTS>(),
        &version,
        &config,
        TestVenue(),
        allocation::fee_split(bps::new(0), bps::new(0), bps::new(10_000), bps::new(0), vector[]),
        false,
    );
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let mut vault = vault::new_for_testing(
        &launch,
        &TestVenue(),
        object::id_from_address(POOL),
        position,
        1,
        scenario.ctx(),
    );
    let (protocol_meme, protocol_quote) = vault.split_fees(
        &policy,
        &mut currency,
        balance::create_for_testing(FUNDED_MEME),
        balance::create_for_testing(FUNDED_QUOTE),
        scenario.ctx(),
    );
    protocol_meme.destroy_zero();
    protocol_quote.destroy_zero();
    destroy(launch);
    destroy(currency);
    destroy(config);
    destroy(version);
    destroy(policy);

    RewardsFixture { scenario, migrators_version, vault }
}

/// The leaf the fixture vault commits for one allocation.
fun leaf(
    self: &RewardsFixture,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    merkle::leaf(object::id(&self.vault), round, index, beneficiary, meme, quote)
}

/// Publishes as the rewards admin in the current transaction.
fun publish(
    self: &mut RewardsFixture,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
) {
    let admin = blast_acl::witness_for_testing<RewardsAdmin>();

    blast_holder_rewards::publish_round(
        &mut self.vault,
        &self.migrators_version,
        &admin,
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        self.scenario.ctx(),
    );
}

/// Publishes round `number` over checkpoints [10 * number, 10 * (number + 1)) with a single leaf
/// paying Alice, and returns its ID.
fun round(self: &mut RewardsFixture, number: u64, meme: u64, quote: u64): ID {
    let root = self.leaf(number, 0, ALICE, meme, quote);
    self.scenario.next_tx(ADMIN);
    self.publish(number, number * 10, (number + 1) * 10, root, digest(), 1, meme, quote);

    published_round_id()
}

/// Returns the ID of the one round this transaction published.
fun published_round_id(): ID {
    let published = event::events_by_type<blast_events::RoundPublished>();
    assert_eq!(published.length(), 1);

    round_id_of(published[0])
}

/// Relays one claim from the bot in a fresh transaction.
fun claim(
    self: &mut RewardsFixture,
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
) {
    self.scenario.next_tx(BOT);
    let mut round = self.take_round(round_id);

    round.claim(
        &self.migrators_version,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        proof,
        self.scenario.ctx(),
    );
    test_scenario::return_shared(round);
}

fun take_round(self: &RewardsFixture, round_id: ID): Round<BLAST_HOLDER_REWARDS_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(round_id)
}

/// Asserts a round's remaining balances and whether leaf `index` is paid, in a fresh transaction.
fun assert_round(
    self: &mut RewardsFixture,
    round_id: ID,
    meme: u64,
    quote: u64,
    index: u64,
    claimed: bool,
) {
    self.scenario.next_tx(BOT);
    let round = self.take_round(round_id);

    assert_balances!(|| round.round_balances_for_testing(), meme, quote);
    assert_eq!(round.is_claimed_for_testing(index), claimed);
    test_scenario::return_shared(round);
}

/// Asserts `owner` received exactly one coin per nonzero asset since its last check.
fun assert_received(self: &mut RewardsFixture, owner: address, meme: u64, quote: u64) {
    self.scenario.next_tx(owner);
    if (meme > 0) {
        let coin = self.scenario.take_from_sender<Coin<BLAST_HOLDER_REWARDS_TESTS>>();
        assert_eq!(coin.burn_for_testing(), meme);
    };
    if (quote > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    };
    assert!(!self.scenario.has_most_recent_for_sender<Coin<BLAST_HOLDER_REWARDS_TESTS>>());
    assert!(!self.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

/// Asserts the Meme and Quote amounts `$balances` reads.
macro fun assert_balances($balances: || -> (u64, u64), $meme: u64, $quote: u64) {
    let (meme_balance, quote_balance) = $balances();

    assert_eq!(meme_balance, $meme);
    assert_eq!(quote_balance, $quote);
}

/// Reads the round ID, the second field of `RoundPublished`.
fun round_id_of(published: blast_events::RoundPublished): ID {
    let mut r = bcs::new(bcs::to_bytes(&published));
    r.peel_address();

    object::id_from_address(r.peel_address())
}

/// A well-formed 32-byte commitment.
fun digest(): vector<u8> {
    vector::tabulate!(32, |_| 1u8)
}

fun end(self: RewardsFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    allocation,
    blast_fun_domain::RewardsAdmin,
    bps,
    launch_config,
    package_version,
};

use blast_fun_migrators::{
    blast_events,
    blast_holder_rewards::{Self, Round},
    launch_fixture,
    lp_fee_policy,
    merkle,
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, bcs, coin::Coin, event, test_scenario::{Self, Scenario}, test_utils};
