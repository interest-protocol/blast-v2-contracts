// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::migration_rewards_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const HOLDER: address = @0xA11CE;
const PARTNER: address = @0xFEE;
const TREASURY: address = @0x7EA5;
const CLAIM_DEADLINE_MS: u64 = 1_000;

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;

// === Tests ===

#[test]
/// Each collection pays every fee recipient at once, keeps the holder share, and
/// assigns every atomic unit exactly once.
fun collected_fees_pay_recipients_and_keep_the_holder_share() {
    let mut scenario = test_scenario::begin(CREATOR);
    let presale_id = object::id_from_address(@0xCAFE);
    let presale_cap = presale::cap_for_testing(presale_id, scenario.ctx());
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        presale_id,
        object::id(&presale_cap),
        vector[
            presale::recipient_share(CREATOR, bps::new(5_000)),
            presale::recipient_share(PARTNER, bps::new(2_000)),
        ],
        bps::new(3_000),
        no_protocol_fees(),
        scenario.ctx(),
    );

    vault.collect_fees(
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        &mut scenario,
    );

    let (
        gross_meme,
        gross_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    ) = only_event<FeesCollected<MEME, QUOTE>>().fees_collected_fields();
    assert_eq!(vector[gross_meme, gross_quote], vector[101, 10]);
    assert_eq!(fee_recipient_meme, vector[51, 20]);
    assert_eq!(fee_recipient_quote, vector[5, 2]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[30, 3]);
    let (vault_meme, vault_quote) = vault.holder_rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[30, 3]);

    scenario.next_tx(CREATOR);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 51);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 5);

    scenario.next_tx(PARTNER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 20);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 2);

    vault.destroy_holding(30, 3);
    destroy(presale_cap);
    scenario.end();
}

#[test]
/// Blast's snapshotted LP share of each asset, rounded up, goes to the policy's current
/// destination before the creator's split applies to the rest.
fun collected_fees_pay_blast_its_share_first() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(scenario.ctx());
    policy.set_destination(&admin_registry, &admin_cap, TREASURY);
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        vector[
            presale::recipient_share(CREATOR, bps::new(5_000)),
            presale::recipient_share(PARTNER, bps::new(2_000)),
        ],
        bps::new(3_000),
        fee_policy::protocol_fees_for_testing(0, 0, 1_000, 2_500),
        scenario.ctx(),
    );

    vault.credit_fees_for_testing(
        &policy,
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    let event = only_event<FeesCollected<MEME, QUOTE>>();
    let (destination, protocol_meme, protocol_quote) = event.fees_collected_protocol_fields();
    assert_eq!(destination, TREASURY);
    // ceil(101 * 10%) = 11 and ceil(10 * 25%) = 3; the creator's split apportions 90 and 7.
    assert_eq!(vector[protocol_meme, protocol_quote], vector[11, 3]);

    let (
        gross_meme,
        gross_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    ) = event.fees_collected_fields();
    assert_eq!(vector[gross_meme, gross_quote], vector[101, 10]);
    assert_eq!(fee_recipient_meme, vector[45, 18]);
    assert_eq!(fee_recipient_quote, vector[4, 1]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[27, 2]);

    scenario.next_tx(TREASURY);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 11);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 3);

    vault.destroy_holding(27, 2);
    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
    scenario.end();
}

#[test]
/// Blast's administrator, not the presale creator, funds holder rounds.
fun the_admin_publishes_holder_rounds_from_the_holder_share() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(vector[], 10_000, &mut scenario);
    vault.collect_fees(
        coin::mint_for_testing<MEME>(40, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(5, scenario.ctx()).into_balance(),
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(scenario.ctx());

    rewards::publish_round(
        &mut vault,
        &admin_registry,
        &admin_cap,
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        40,
        5,
        CLAIM_DEADLINE_MS,
        &clock,
        scenario.ctx(),
    );

    let (vault_meme, vault_quote) = vault.holder_rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[0, 0]);

    scenario.next_tx(CREATOR);
    let round = scenario.take_shared<Round<MEME, QUOTE>>();
    let (round_meme, round_quote) = round.balances_for_testing();
    assert_eq!(vector[round_meme, round_quote], vector[40, 5]);

    test_scenario::return_shared(round);
    clock.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
    vault.destroy_for_testing();
    scenario.end();
}

#[test]
/// Equal fractional remainders favor the fee recipient over the holder-reward share.
fun a_remainder_tie_goes_to_the_fee_recipient_before_holders() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(vector[presale::recipient_share(CREATOR, bps::new(5_000))], 5_000, &mut scenario);

    vault.collect_fees(
        coin::mint_for_testing<MEME>(3, scenario.ctx()).into_balance(),
        balance::zero<QUOTE>(),
        &mut scenario,
    );

    let (_, _, fee_recipient_meme, _, holder_rewards_meme, _) = only_event<
        FeesCollected<MEME, QUOTE>,
    >().fees_collected_fields();
    assert_eq!(fee_recipient_meme, vector[2]);
    assert_eq!(holder_rewards_meme, 1);

    scenario.next_tx(CREATOR);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 2);

    vault.destroy_holding(1, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongPresaleCap, location = blast_presale::presale_vault)]
/// Only the presale's own creator capability reaches the migration residuals.
fun another_presale_cap_cannot_claim_migration_residuals() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(vector[], 10_000, &mut scenario);
    let other_cap = presale::cap_for_testing(object::id_from_address(@0xD1FF), scenario.ctx());

    let (meme, quote) = vault.claim_migration_residuals(&other_cap, scenario.ctx());
    destroy(meme);
    destroy(quote);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EWrongRound, location = blast_presale::holder_rewards)]
fun a_round_must_use_the_vaults_next_number() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);

    vault.publish_round(1, 0, 10, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidInterval, location = blast_presale::holder_rewards)]
/// Each round must start exactly where the previous round ended.
fun a_round_cannot_skip_checkpoints() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);

    vault.publish_round(1, 11, 20, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EAlreadyClaimed, location = blast_presale::holder_rewards)]
fun a_holder_reward_cannot_be_claimed_twice() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(20, 0, &mut scenario);
    rewards::claim(&mut round, 0, HOLDER, 20, 0, vector[], scenario.ctx());

    rewards::claim(&mut round, 0, HOLDER, 20, 0, vector[], scenario.ctx());
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EEmptyClaim, location = blast_presale::holder_rewards)]
/// A claim leaf must pay something; an empty one is a claim error, not a round-budget one.
fun a_holder_reward_claim_must_pay_a_positive_amount() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(0, 0, &mut scenario);

    rewards::claim(&mut round, 0, HOLDER, 0, 0, vector[], scenario.ctx());
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_presale::holder_rewards)]
/// A relayer cannot redirect a committed reward to another beneficiary.
fun a_holder_reward_cannot_be_redirected() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(40, 0, &mut scenario);

    rewards::claim(&mut round, 0, PARTNER, 40, 0, vector[], scenario.ctx());
    abort
}

#[test]
/// Once the claim deadline passes, anyone may return a round's unclaimed rewards to the vault.
fun an_unclaimed_round_returns_to_the_vault_after_its_deadline() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);
    let (meme_after_publish, _) = vault.holder_rewards_balances();
    assert_eq!(meme_after_publish, 39);

    vault.close_round_at(CLAIM_DEADLINE_MS, &mut scenario);

    let (vault_meme, vault_quote) = vault.holder_rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[40, 0]);

    vault.destroy_holding(40, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = rewards::EClaimsStillOpen, location = blast_presale::holder_rewards)]
fun a_round_cannot_close_before_its_claim_deadline() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);

    vault.close_round_at(CLAIM_DEADLINE_MS - 1, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EWrongVault, location = blast_presale::holder_rewards)]
/// A round's leftovers can only return to the vault that funded it.
fun a_round_cannot_close_into_another_vault() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);
    let mut other_vault = new_vault(vector[], 10_000, &mut scenario);

    other_vault.close_round_at(CLAIM_DEADLINE_MS, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidClaimDeadline, location = blast_presale::holder_rewards)]
fun a_round_needs_a_future_claim_deadline() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(CLAIM_DEADLINE_MS);
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(scenario.ctx());

    rewards::publish_round(
        &mut vault,
        &admin_registry,
        &admin_cap,
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        1,
        0,
        CLAIM_DEADLINE_MS,
        &clock,
        scenario.ctx(),
    );
    abort
}

#[test]
fun anyone_can_relay_a_holder_reward_to_the_committed_holder() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(40, 5, &mut scenario);

    rewards::claim(&mut round, 0, HOLDER, 40, 5, vector[], scenario.ctx());

    scenario.next_tx(HOLDER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 40);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 5);

    round.destroy_for_testing();
    scenario.end();
}

#[test]
fun generic_merkle_proofs_preserve_left_and_right_order() {
    let left = hash::blake2b256(&b"left");
    let right = hash::blake2b256(&b"right");
    let root = merkle_tree::node(left, right);

    assert!(merkle_tree::verify(root, left, 0, 2, &vector[right]));
    assert!(merkle_tree::verify(root, right, 1, 2, &vector[left]));
    assert!(!merkle_tree::verify(root, right, 2, 2, &vector[left]));
}

// === Test Helpers ===

fun new_vault(
    fee_recipients: vector<RecipientShare>,
    holder_rewards_bps: u64,
    scenario: &mut Scenario,
): PresaleVault<MEME, QUOTE> {
    vault::new_for_testing<MEME, QUOTE>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        fee_recipients,
        bps::new(holder_rewards_bps),
        no_protocol_fees(),
        scenario.ctx(),
    )
}

fun no_protocol_fees(): ProtocolFees {
    fee_policy::protocol_fees_for_testing(0, 0, 0, 0)
}

/// Collects fees under a zero-rate policy, as every vault without a Blast LP share does.
fun collect_fees(
    self: &mut PresaleVault<MEME, QUOTE>,
    meme: Balance<MEME>,
    quote: Balance<QUOTE>,
    scenario: &mut Scenario,
) {
    let policy = fee_policy::new_for_testing(scenario.ctx());
    self.credit_fees_for_testing(&policy, meme, quote, scenario.ctx());
    policy.destroy_for_testing();
}

/// A vault whose holder share is 40 Meme and no Quote.
fun funded_holder_vault(scenario: &mut Scenario): PresaleVault<MEME, QUOTE> {
    let mut vault = new_vault(vector[], 10_000, scenario);
    vault.collect_fees(
        coin::mint_for_testing<MEME>(40, scenario.ctx()).into_balance(),
        balance::zero<QUOTE>(),
        scenario,
    );
    vault
}

/// Publishes a one-leaf round that pays 1 Meme from the holder share.
fun publish_round(
    self: &mut PresaleVault<MEME, QUOTE>,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    scenario: &mut Scenario,
) {
    let clock = clock::create_for_testing(scenario.ctx());
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(scenario.ctx());
    rewards::publish_round(
        self,
        &admin_registry,
        &admin_cap,
        number,
        start_checkpoint,
        end_checkpoint,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        1,
        0,
        CLAIM_DEADLINE_MS,
        &clock,
        scenario.ctx(),
    );
    clock.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

fun close_round_at(self: &mut PresaleVault<MEME, QUOTE>, now_ms: u64, scenario: &mut Scenario) {
    scenario.next_tx(CREATOR);
    let round = scenario.take_shared<Round<MEME, QUOTE>>();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(now_ms);

    rewards::close_round(round, self, &clock);

    clock.destroy_for_testing();
}

/// A one-leaf round funded with 40 Meme and `quote` Quote, owing `HOLDER` the given amounts.
/// With a single leaf, that leaf is the Merkle root.
fun round_owing_holder(meme: u64, quote: u64, scenario: &mut Scenario): Round<MEME, QUOTE> {
    let vault_id = object::id_from_address(@0xBEEF);
    let root = rewards::leaf_for_testing(vault_id, 0, 0, HOLDER, meme, quote);

    rewards::new_for_testing(
        vault_id,
        0,
        CLAIM_DEADLINE_MS,
        root,
        1,
        balance::create_for_testing<MEME>(40),
        balance::create_for_testing<QUOTE>(quote),
        scenario.ctx(),
    )
}

/// Pays out the holder share as a round would, so destruction aborts unless the share is
/// exactly `meme` and `quote`.
fun destroy_holding(mut self: PresaleVault<MEME, QUOTE>, meme: u64, quote: u64) {
    let (round_meme, round_quote) = self.fund_round(0, meme, quote);
    round_meme.destroy_for_testing();
    round_quote.destroy_for_testing();
    self.destroy_for_testing();
}

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use blast_presale::{
    blast_presale as presale,
    blast_presale_admin,
    bps,
    fee_policy::{Self, ProtocolFees},
    holder_rewards::{Self as rewards, Round},
    merkle_tree,
    presale_vault::{Self as vault, FeesCollected, PresaleVault},
    blast_presale::RecipientShare,
};

use std::unit_test::{assert_eq, destroy};

use sui::{
    balance::{Self, Balance},
    clock,
    coin::{Self, Coin},
    event,
    hash,
    test_scenario::{Self, Scenario},
};

use fun close_round_at as PresaleVault.close_round_at;
use fun collect_fees as PresaleVault.collect_fees;
use fun destroy_holding as PresaleVault.destroy_holding;
use fun publish_round as PresaleVault.publish_round;
