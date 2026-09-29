// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::migration_rewards_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const HOLDER: address = @0xA11CE;

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;

// === Tests ===

#[test]
fun collected_fees_follow_the_creation_time_bps() {
    let mut ctx = tx_context::dummy();
    let presale_id = object::id_from_address(@0xCAFE);
    let cap = presale::cap_for_testing(presale_id, &mut ctx);
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        presale_id,
        object::id(&cap),
        7_000,
        3_000,
        &mut ctx,
    );
    vault.credit_fees_for_testing(
        coin::mint_for_testing<MEME>(100, &mut ctx).into_balance(),
        coin::mint_for_testing<QUOTE>(10, &mut ctx).into_balance(),
    );
    let (creator_meme, creator_quote, reward_meme, reward_quote) = vault
        .fee_balances_for_testing();
    assert_eq!(
        vector[creator_meme, creator_quote, reward_meme, reward_quote],
        vector[70, 7, 30, 3],
    );

    let (creator_meme_coin, creator_quote_coin) = vault.claim_creator_fees(&cap, &mut ctx);
    assert_eq!(creator_meme_coin.burn_for_testing(), 70);
    assert_eq!(creator_quote_coin.burn_for_testing(), 7);
    let (reward_meme, reward_quote) = vault.fund_round(10, 30, 3);
    assert_eq!(reward_meme.into_coin(&mut ctx).burn_for_testing(), 30);
    assert_eq!(reward_quote.into_coin(&mut ctx).burn_for_testing(), 3);

    vault.destroy_for_testing();
    destroy(cap);
    destroy(ctx);
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

// === Imports ===

use blast_presale::{
    blast_presale as presale,
    holder_rewards as rewards,
    merkle_tree,
    presale_vault as vault,
};

use std::unit_test::{assert_eq, destroy};

use sui::{coin::{Self, Coin}, hash, test_scenario};
