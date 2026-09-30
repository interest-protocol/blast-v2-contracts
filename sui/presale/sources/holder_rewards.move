// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Merkle rounds Blast's rewards administrator funds from a migrated presale
/// vault's holder-reward fee share.
module blast_presale::holder_rewards;

// === Public Types ===

/// One independently claimable holder-reward allocation.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    vault: ID,
    number: u64,
    root: vector<u8>,
    leaf_count: u64,
    claimed: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

// === Public Functions ===

/// Reserves rewards under a Blast-published holder allocation and shares the round.
public fun publish_round<Meme, Quote>(
    vault: &mut PresaleVault<Meme, Quote>,
    _: &AdminWitness<RewardsAdmin>,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    ctx: &mut TxContext,
) {
    assert!(number == vault.next_round(), EWrongRound);
    assert!(
        start_checkpoint < end_checkpoint
            && vault.last_checkpoint().is_none_or!(|last| *last == start_checkpoint),
        EInvalidInterval,
    );
    assert!(
        root.length() == DIGEST_LENGTH && manifest_digest.length() == DIGEST_LENGTH,
        EInvalidCommitment,
    );
    assert!(leaf_count > 0 && leaf_count <= MAX_REWARD_LEAVES, EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    let vault_id = object::id(vault);
    let (meme, quote) = vault.fund_round(end_checkpoint, meme_amount, quote_amount);
    let round = Round {
        id: object::new(ctx),
        vault: vault_id,
        number,
        root,
        leaf_count,
        claimed: vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256),
        meme,
        quote,
    };
    let round_id = round.id.to_inner();
    let (meme_unallocated, quote_unallocated) = vault.rewards_balances();
    transfer::share_object(round);

    event::emit(RoundPublished<Meme, Quote> {
        vault_id,
        round_id,
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        meme_unallocated,
        quote_unallocated,
    });
}

/// Pays one committed beneficiary; anyone may relay the proof.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    assert!(index < self.leaf_count, EInvalidIndex);
    let word = index / 256;
    let bit = 1u256 << ((index % 256) as u8);
    assert!(self.claimed[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    let leaf = leaf(self.vault, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(
        merkle_tree::verify(self.root, leaf, index, self.leaf_count, &proof),
        EInvalidProof,
    );

    *&mut self.claimed[word] = self.claimed[word] | bit;
    if (meme_amount > 0) {
        transfer::public_transfer(self.meme.split(meme_amount).into_coin(ctx), beneficiary);
    };
    if (quote_amount > 0) {
        transfer::public_transfer(self.quote.split(quote_amount).into_coin(ctx), beneficiary);
    };

    event::emit(RewardClaimed<Meme, Quote> {
        round_id: self.id.to_inner(),
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        meme_remaining: self.meme.value(),
        quote_remaining: self.quote.value(),
    });
}

// === Private Functions ===

fun leaf(
    vault: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    let mut bytes = b"\x00blast-presale-holder-rewards-v1";
    bytes.append(bcs::to_bytes(&vault));
    bytes.append(bcs::to_bytes(&round));
    bytes.append(bcs::to_bytes(&index));
    bytes.append(bcs::to_bytes(&beneficiary));
    bytes.append(bcs::to_bytes(&meme));
    bytes.append(bcs::to_bytes(&quote));
    hash::blake2b256(&bytes)
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing<Meme, Quote>(
    vault: ID,
    number: u64,
    root: vector<u8>,
    leaf_count: u64,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
): Round<Meme, Quote> {
    Round {
        id: object::new(ctx),
        vault,
        number,
        root,
        leaf_count,
        claimed: vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256),
        meme,
        quote,
    }
}

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Round<Meme, Quote>) {
    let Round {
        id,
        vault: _,
        number: _,
        root: _,
        leaf_count: _,
        claimed: _,
        meme,
        quote,
    } = self;
    id.delete();
    meme.destroy_zero();
    quote.destroy_zero();
}

#[test_only]
public fun leaf_for_testing(
    vault: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    leaf(vault, round, index, beneficiary, meme, quote)
}

#[test_only]
public fun balances_for_testing<Meme, Quote>(self: &Round<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

// === Events ===

public struct RoundPublished<phantom Meme, phantom Quote> has copy, drop {
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

public struct RewardClaimed<phantom Meme, phantom Quote> has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

// === Constants ===

const DIGEST_LENGTH: u64 = 32;
const MAX_REWARD_LEAVES: u64 = 65_536;

// === Errors ===

#[error(code = 0)]
const EWrongRound: vector<u8> = b"Round number must match the vault's next round.";

#[error(code = 1)]
const EInvalidInterval: vector<u8> = b"Checkpoint interval must be nonempty and contiguous.";

#[error(code = 2)]
const EInvalidCommitment: vector<u8> = b"Root and manifest digest must contain 32 bytes.";

#[error(code = 3)]
const EInvalidLeafCount: vector<u8> = b"Round must contain between 1 and 65,536 leaves.";

#[error(code = 4)]
const EEmptyBudget: vector<u8> = b"At least one reward amount must be nonzero.";

#[error(code = 5)]
const EInvalidIndex: vector<u8> = b"Claim index must be less than the committed leaf count.";

#[error(code = 6)]
const EAlreadyClaimed: vector<u8> = b"This allocation has already been paid.";

#[error(code = 7)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 8)]
const EInvalidProof: vector<u8> = b"Proof must match the committed beneficiary and amounts.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_presale::{blast_presale_domain::RewardsAdmin, merkle_tree, presale_vault::PresaleVault};

use std::bcs;

use sui::{balance::Balance, event, hash};
