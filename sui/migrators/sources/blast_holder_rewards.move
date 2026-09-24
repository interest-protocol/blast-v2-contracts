// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Holder rewards: rounds funded from a vault's rewards share and paid by Merkle proof.
///
/// Blast's off-chain system turns checkpointed holder balances into a Merkle allocation, and a
/// Blast administrator publishes it as a round that reserves its budget from the vault. Anyone can
/// relay a proof afterwards; each leaf pays its committed beneficiary once.
module blast_fun_migrators::blast_holder_rewards;

// === Errors ===

#[error(code = 0)]
const EWrongRound: vector<u8> = b"Round number must match the vault's next round.";

#[error(code = 1)]
const EInvalidInterval: vector<u8> =
    b"Checkpoint interval must be nonempty and contiguous with the previous round.";

#[error(code = 2)]
const EInvalidCommitment: vector<u8> =
    b"Root and manifest digest must each contain exactly 32 bytes.";

#[error(code = 3)]
const EInvalidLeafCount: vector<u8> = b"Round must contain between 1 and 65,536 leaves.";

#[error(code = 4)]
const EEmptyBudget: vector<u8> = b"At least one reward amount must be nonzero.";

#[error(code = 5)]
const EInsufficientFunds: vector<u8> = b"Both reward amounts must fit the available balances.";

#[error(code = 6)]
const EInvalidIndex: vector<u8> = b"Claim index must be less than the committed leaf count.";

#[error(code = 7)]
const EAlreadyClaimed: vector<u8> = b"This allocation has already been paid.";

#[error(code = 8)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 9)]
const EInvalidProof: vector<u8> = b"Proof must match the committed recipient, amounts and domain.";

// === Public Types ===

/// Independently funded claims that remain available without the vault or the administrator.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    vault: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    claimed: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

// === Public Functions ===

/// Reserves part of the vault's rewards balance for a committed allocation and shares the round.
public fun publish_round<Meme, Quote>(
    vault: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
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
    migrators_version.assert_current();
    assert!(number == vault.next_round(), EWrongRound);
    assert!(
        start_checkpoint < end_checkpoint
            && vault.last_checkpoint().is_none_or!(|last| *last == start_checkpoint),
        EInvalidInterval,
    );
    assert!(
        root.length() == constants::digest_length!()
            && manifest_digest.length() == constants::digest_length!(),
        EInvalidCommitment,
    );
    assert!(leaf_count > 0 && leaf_count <= constants::max_reward_leaves!(), EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    let (meme_available, quote_available) = vault.rewards_balances();
    assert!(
        meme_amount <= meme_available && quote_amount <= quote_available,
        EInsufficientFunds,
    );
    let vault_id = object::id(vault);

    let (meme, quote) = vault.fund_round(end_checkpoint, meme_amount, quote_amount);
    let round = Round {
        id: object::new(ctx),
        vault: vault_id,
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        claimed: vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256),
        meme,
        quote,
    };
    let round_id = round.id.to_inner();
    let (meme_unallocated, quote_unallocated) = vault.rewards_balances();
    transfer::share_object(round);

    blast_events::round_published(
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
    );
}

/// Anyone may relay a proof; delivery is only to its committed beneficiary.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(index < self.leaf_count, EInvalidIndex);
    let word = index / 256;
    let bit = 1u256 << ((index % 256) as u8);
    assert!(self.claimed[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    assert!(
        meme_amount <= self.meme.value() && quote_amount <= self.quote.value(),
        EInsufficientFunds,
    );
    let leaf = merkle::leaf(self.vault, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(merkle::verify(self.root, leaf, index, self.leaf_count, &proof), EInvalidProof);

    *&mut self.claimed[word] = self.claimed[word] | bit;
    if (meme_amount > 0)
        transfer::public_transfer(self.meme.split(meme_amount).into_coin(ctx), beneficiary);
    if (quote_amount > 0)
        transfer::public_transfer(self.quote.split(quote_amount).into_coin(ctx), beneficiary);

    blast_events::reward_paid(
        self.id.to_inner(),
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        self.meme.value(),
        self.quote.value(),
    );
}

// === Test-Only Functions ===

#[test_only]
public fun round_balances_for_testing<Meme, Quote>(self: &Round<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

#[test_only]
public fun is_claimed_for_testing<Meme, Quote>(self: &Round<Meme, Quote>, index: u64): bool {
    self.claimed[index / 256] & (1u256 << ((index % 256) as u8)) != 0
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::blast_fun_domain::BLAST_FUN_DOMAIN;

use blast_fun_migrators::{
    blast_events,
    constants,
    merkle,
    package_version::PackageVersion as MigratorsVersion,
    vault::LpVault,
};

use sui::balance::Balance;
