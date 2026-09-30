// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::migration_rewards_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const HOLDER: address = @0xA11CE;
const PARTNER: address = @0xFEE;

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
    let cap = presale::cap_for_testing(presale_id, scenario.ctx());
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        presale_id,
        object::id(&cap),
        vector[
            presale::fee_recipient(CREATOR, 5_000),
            presale::fee_recipient(PARTNER, 2_000),
        ],
        3_000,
        scenario.ctx(),
    );

    vault.credit_fees_for_testing(
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    let (_, _, recipients, recipient_meme, recipient_quote, rewards_meme, rewards_quote) =
        only_event<FeesCollected<MEME, QUOTE>>().fees_collected_fields();
    assert_eq!(recipients, vector[CREATOR, PARTNER]);
    assert_eq!(recipient_meme, vector[51, 20]);
    assert_eq!(recipient_quote, vector[5, 2]);
    assert_eq!(vector[rewards_meme, rewards_quote], vector[30, 3]);
    let (vault_meme, vault_quote) = vault.rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[30, 3]);
    scenario.next_tx(CREATOR);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 51);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 5);
    scenario.next_tx(PARTNER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 20);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 2);

    let (reward_meme, reward_quote) = vault.fund_round(10, 30, 3);
    reward_meme.destroy_for_testing();
    reward_quote.destroy_for_testing();
    vault.destroy_for_testing();
    destroy(cap);
    scenario.end();
}

#[test]
/// Blast's rewards administrator, not the presale creator, funds holder rounds.
fun the_rewards_admin_publishes_holder_rounds_from_the_holder_share() {
    let mut scenario = test_scenario::begin(CREATOR);
    let presale_id = object::id_from_address(@0xCAFE);
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        presale_id,
        object::id_from_address(@0xCA9),
        vector[],
        10_000,
        scenario.ctx(),
    );
    vault.credit_fees_for_testing(
        coin::mint_for_testing<MEME>(40, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(5, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    rewards::publish_round(
        &mut vault,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        40,
        5,
        scenario.ctx(),
    );

    let (vault_meme, vault_quote) = vault.rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[0, 0]);
    vault.destroy_for_testing();
    scenario.next_tx(CREATOR);
    let round = scenario.take_shared<Round<MEME, QUOTE>>();
    let (round_meme, round_quote) = round.balances_for_testing();
    assert_eq!(vector[round_meme, round_quote], vector[40, 5]);
    test_scenario::return_shared(round);
    scenario.end();
}

#[test]
fun anyone_can_relay_a_holder_reward_to_the_committed_holder() {
    let mut scenario = test_scenario::begin(CREATOR);
    let vault_id = object::id_from_address(@0xBEEF);
    let root = rewards::leaf_for_testing(vault_id, 0, 0, HOLDER, 40, 5);
    let mut round = rewards::new_for_testing(
        vault_id,
        0,
        root,
        1,
        coin::mint_for_testing<MEME>(40, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(5, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    rewards::claim(&mut round, 0, HOLDER, 40, 5, vector[], scenario.ctx());
    round.destroy_for_testing();
    scenario.next_tx(HOLDER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 40);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 5);
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

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use blast_admin::blast_acl;

use blast_presale::{
    blast_presale as presale,
    blast_presale_domain::RewardsAdmin,
    holder_rewards::{Self as rewards, Round},
    merkle_tree,
    presale_vault::{Self as vault, FeesCollected},
};

use std::unit_test::{assert_eq, destroy};

use sui::{coin::{Self, Coin}, event, hash, test_scenario};
