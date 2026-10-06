// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Merkle rounds Blast's rewards administrator funds from a migrated presale
/// vault's holder-reward fee share.
module blast_presale::holder_rewards;

// === Public Types ===

/// One independently claimable holder-reward allocation. Claims stay open until someone
/// closes the round after its deadline, which returns whatever is unclaimed to the vault.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    vault_id: ID,
    number: u64,
    claim_deadline_ms: u64,
    root: vector<u8>,
    leaf_count: u64,
    claimed_bitmap: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

// === Public Functions ===

/// Reserves rewards under a Blast-published holder allocation and shares the round.
public fun publish_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    admin_registry: &AdminRegistry,
    admin_cap: &AdminCap,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    claim_deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    admin_registry.assert_admin_cap(admin_cap);
    assert!(number == vault.next_round(), EWrongRound);
    assert!(
        start_checkpoint < end_checkpoint
            && vault.last_checkpoint().is_none_or!(|last| *last == start_checkpoint),
        EInvalidInterval,
    );
    assert!(
        root.length() == merkle_tree::digest_length()
            && manifest_digest.length() == merkle_tree::digest_length(),
        EInvalidCommitment,
    );
    assert!(leaf_count > 0 && leaf_count <= MAX_REWARD_LEAVES, EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    assert!(claim_deadline_ms > clock.timestamp_ms(), EInvalidClaimDeadline);

    let vault_id = object::id(vault);
    let (meme, quote) = vault.fund_round(end_checkpoint, meme_amount, quote_amount);
    let round = Round {
        id: object::new(ctx),
        vault_id,
        number,
        claim_deadline_ms,
        root,
        leaf_count,
        claimed_bitmap: unclaimed(leaf_count),
        meme,
        quote,
    };
    let (meme_unallocated, quote_unallocated) = vault.holder_rewards_balances();

    event::emit(RoundPublished<Meme, Quote> {
        vault_id,
        round_id: round.id.to_inner(),
        number,
        start_checkpoint,
        end_checkpoint,
        claim_deadline_ms,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        meme_unallocated,
        quote_unallocated,
    });

    transfer::share_object(round);
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

    let (word, bit) = claim_bit(index);
    assert!(self.claimed_bitmap[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyClaim);

    let digest = leaf(self.vault_id, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(
        merkle_tree::verify(self.root, digest, index, self.leaf_count, &proof),
        EInvalidProof,
    );

    let claimed_word = &mut self.claimed_bitmap[word];
    *claimed_word = *claimed_word | bit;
    self.meme.pay(meme_amount, beneficiary, ctx);
    self.quote.pay(quote_amount, beneficiary, ctx);

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

/// Returns a round's unclaimed rewards to its vault's holder share once the claim deadline has
/// passed. Anyone may close; the round is deleted, so an overcommitted or abandoned root can
/// never strand funds.
public fun close_round<Meme, Quote>(
    self: Round<Meme, Quote>,
    vault: &mut Vault<Meme, Quote>,
    clock: &Clock,
) {
    assert!(self.vault_id == object::id(vault), EWrongVault);
    assert!(clock.timestamp_ms() >= self.claim_deadline_ms, EClaimsStillOpen);

    let Round { id, vault_id, number, meme, quote, .. } = self;
    let (meme_returned, quote_returned) = (meme.value(), quote.value());

    vault.restore_holder_rewards(meme, quote);

    event::emit(RoundClosed<Meme, Quote> {
        vault_id,
        round_id: id.to_inner(),
        number,
        meme_returned,
        quote_returned,
    });

    id.delete();
}

// === Private Functions ===

/// A claim bitmap with every leaf's bit clear, 256 leaves per word.
fun unclaimed(leaf_count: u64): vector<u256> {
    vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256)
}

/// The bitmap word and bit recording leaf `index`'s claim.
fun claim_bit(index: u64): (u64, u256) {
    (index / 256, 1u256 << ((index % 256) as u8))
}

/// The domain-separated digest of one beneficiary's reward leaf.
fun leaf(
    vault_id: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    let mut bytes = b"\x00blast-presale-holder-rewards-v1";
    bytes.append(bcs::to_bytes(&vault_id));
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
    vault_id: ID,
    number: u64,
    claim_deadline_ms: u64,
    root: vector<u8>,
    leaf_count: u64,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
): Round<Meme, Quote> {
    Round {
        id: object::new(ctx),
        vault_id,
        number,
        claim_deadline_ms,
        root,
        leaf_count,
        claimed_bitmap: unclaimed(leaf_count),
        meme,
        quote,
    }
}

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Round<Meme, Quote>) {
    let Round {
        id,
        vault_id: _,
        number: _,
        claim_deadline_ms: _,
        root: _,
        leaf_count: _,
        claimed_bitmap: _,
        meme,
        quote,
    } = self;
    id.delete();
    meme.destroy_zero();
    quote.destroy_zero();
}

#[test_only]
public fun leaf_for_testing(
    vault_id: ID,
    round: u64,
    index: u64,
    beneficiary: address,
    meme: u64,
    quote: u64,
): vector<u8> {
    leaf(vault_id, round, index, beneficiary, meme, quote)
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
    claim_deadline_ms: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
}

public struct RoundClosed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
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
const EEmptyBudget: vector<u8> = b"A round must reserve a positive amount of at least one asset.";

#[error(code = 5)]
const EInvalidIndex: vector<u8> = b"Claim index must be less than the committed leaf count.";

#[error(code = 6)]
const EAlreadyClaimed: vector<u8> = b"This allocation has already been paid.";

#[error(code = 7)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 8)]
const EInvalidProof: vector<u8> = b"Proof must match the committed beneficiary and amounts.";

#[error(code = 9)]
const EInvalidClaimDeadline: vector<u8> = b"The claim deadline must be in the future.";

#[error(code = 10)]
const EWrongVault: vector<u8> = b"The round belongs to a different presale vault.";

#[error(code = 11)]
const EClaimsStillOpen: vector<u8> = b"The round's claim deadline has not passed.";

#[error(code = 12)]
const EEmptyClaim: vector<u8> = b"A reward claim must pay a positive amount of at least one asset.";

// === Imports ===

use blast_presale::{
    blast_presale,
    blast_presale_admin::{AdminCap, AdminRegistry},
    merkle_tree,
    presale_vault::Vault,
};

use std::bcs;

use sui::{balance::Balance, clock::Clock, event, hash};

use fun blast_presale::pay as Balance.pay;
