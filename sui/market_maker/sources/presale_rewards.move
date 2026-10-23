// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast publishes epoch allocations from all buyers' canonical presale history.
/// Creator-shared fees fund the rounds; retained trading capital never funds them implicitly.
module blast_market_maker::presale_rewards;

// === Public Types ===

/// Fully funded, independently claimable rewards. No creator withdrawal or expiry exists.
public struct BlastPresaleRewardRound<phantom Meme, phantom Quote> has key {
    id: UID,
    vault_id: ID,
    number: u64,
    root: vector<u8>,
    leaf_count: u64,
    claimed: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

// === Public Functions ===

/// RewardsAdmin commits a nonoverlapping checkpoint epoch and its off-chain allocation.
/// All core presale buyers qualify regardless of purchase path or token-claim status.
/// The publisher is trusted for eligibility, allocation completeness and root/budget agreement.
public fun publish_round<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
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
    version.assert_current();
    assert!(root.length() == DIGEST_LENGTH && manifest_digest.length() == DIGEST_LENGTH, EInvalidCommitment);
    assert!(leaf_count > 0 && leaf_count <= MAX_REWARD_LEAVES, EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    let vault_id = object::id(vault);
    let (meme, quote) = vault.fund_presale_reward_round(
        number, start_checkpoint, end_checkpoint, meme_amount, quote_amount,
    );
    let round = BlastPresaleRewardRound {
        id: object::new(ctx),
        vault_id,
        number,
        root,
        leaf_count,
        claimed: vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256),
        meme,
        quote,
    };
    let (_, _, meme_unallocated, quote_unallocated) = vault.fee_balances();

    sui::event::emit(BlastPresaleRewardRoundPublished<Meme, Quote> {
        vault_id,
        round_id: round.id.to_inner(),
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
    transfer::share_object(round);
}

/// Anyone may relay an unchanged proof. Delivery always pays the committed beneficiary.
/// Claims need neither the vault nor creator, operator, RewardsAdmin or trading availability.
public fun claim<Meme, Quote>(
    self: &mut BlastPresaleRewardRound<Meme, Quote>,
    version: &PackageVersion,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    version.assert_current();
    assert!(index < self.leaf_count, EInvalidIndex);
    let word = index / 256;
    let bit = 1u256 << ((index % 256) as u8);
    assert!(self.claimed[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyClaim);
    let digest = leaf(self.vault_id, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(verify(self.root, digest, index, self.leaf_count, &proof), EInvalidProof);
    assert!(meme_amount <= self.meme.value() && quote_amount <= self.quote.value(), EInsufficientBudget);

    *&mut self.claimed[word] = self.claimed[word] | bit;
    self.meme.pay(meme_amount, beneficiary, ctx);
    self.quote.pay(quote_amount, beneficiary, ctx);
    sui::event::emit(BlastPresaleRewardPaid<Meme, Quote> {
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

fun pay<Asset>(self: &mut Balance<Asset>, amount: u64, beneficiary: address, ctx: &mut TxContext) {
    if (amount > 0) transfer::public_transfer(self.split(amount).into_coin(ctx), beneficiary);
}

/// Positional Blake2b-256 trees use the same node encoding as Blast holder rewards.
fun verify(
    root: vector<u8>,
    mut digest: vector<u8>,
    mut index: u64,
    leaves: u64,
    proof: &vector<vector<u8>>,
): bool {
    let mut width = leaves;
    let mut depth = 0;
    while (width > 1) {
        width = width.div_ceil(2);
        depth = depth + 1;
    };
    if (proof.length() != depth || !proof.all!(|sibling| sibling.length() == DIGEST_LENGTH))
        return false;

    proof.do_ref!(|sibling| {
        digest = if (index % 2 == 0) node(digest, *sibling) else node(*sibling, digest);
        index = index / 2;
    });
    digest == root
}

fun node(left: vector<u8>, right: vector<u8>): vector<u8> {
    let mut bytes = vector[1u8];
    bytes.append(left);
    bytes.append(right);
    sui::hash::blake2b256(&bytes)
}

fun leaf(vault_id: ID, number: u64, index: u64, beneficiary: address, meme: u64, quote: u64): vector<u8> {
    let mut bytes = b"\x00blast-market-maker-presale-rewards-v1";
    bytes.append(std::bcs::to_bytes(&vault_id));
    bytes.append(std::bcs::to_bytes(&number));
    bytes.append(std::bcs::to_bytes(&index));
    bytes.append(std::bcs::to_bytes(&beneficiary));
    bytes.append(std::bcs::to_bytes(&meme));
    bytes.append(std::bcs::to_bytes(&quote));
    sui::hash::blake2b256(&bytes)
}

// === Test-Only Functions ===

#[test_only]
public fun leaf_for_testing(vault_id: ID, number: u64, index: u64, beneficiary: address, meme: u64, quote: u64): vector<u8> {
    leaf(vault_id, number, index, beneficiary, meme, quote)
}

#[test_only]
public fun node_for_testing(left: vector<u8>, right: vector<u8>): vector<u8> { node(left, right) }

#[test_only]
public fun balances_for_testing<Meme, Quote>(self: &BlastPresaleRewardRound<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

#[test_only]
public fun published_round_id<Meme, Quote>(event: &BlastPresaleRewardRoundPublished<Meme, Quote>): ID {
    event.round_id
}

// === Events ===

public struct BlastPresaleRewardRoundPublished<phantom Meme, phantom Quote> has copy, drop {
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

public struct BlastPresaleRewardPaid<phantom Meme, phantom Quote> has copy, drop {
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
const EInvalidCommitment: vector<u8> = b"The root and manifest digest must contain 32 bytes.";
#[error(code = 1)]
const EInvalidLeafCount: vector<u8> = b"An epoch must contain between 1 and 65,536 reward leaves.";
#[error(code = 2)]
const EEmptyBudget: vector<u8> = b"A reward epoch must fund a positive amount of at least one asset.";
#[error(code = 3)]
const EInvalidIndex: vector<u8> = b"The claim index must be within the committed leaf count.";
#[error(code = 4)]
const EAlreadyClaimed: vector<u8> = b"This epoch allocation has already been paid.";
#[error(code = 5)]
const EInvalidBeneficiary: vector<u8> = b"The reward beneficiary must be nonzero.";
#[error(code = 6)]
const EEmptyClaim: vector<u8> = b"A claim must pay a positive amount of at least one reward asset.";
#[error(code = 7)]
const EInvalidProof: vector<u8> = b"The proof must match this vault, epoch, index, beneficiary and amounts.";
#[error(code = 8)]
const EInsufficientBudget: vector<u8> = b"The committed claim must fit the round's remaining funded balances.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;
use blast_market_maker::{
    blast_market_maker_domain::RewardsAdmin,
    market_maker::BlastMarketMakerVault,
    package_version::BlastMarketMakerVersion as PackageVersion,
};
use sui::balance::Balance;

use fun pay as Balance.pay;
