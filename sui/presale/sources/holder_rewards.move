// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Merkle rounds Blast's rewards administrator funds from a migrated presale
/// vault's holder-reward fee share.
module blast_presale::holder_rewards;

// === Public Types ===

/// A holder round with optional, independent one-shot gas custody.
/// Claims do not touch its gas reserve.
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
    treasury: address,
    gas_reserve: Option<Balance<Quote>>,
}

// === Public Functions ===

/// Atomically funds holder leaves and separate gas custody under the governed
/// treasury at publication. A zero reserve disables reimbursement for this round.
/// The signed expected treasury must still match the governed destination.
/// USD eligibility and gas attribution remain off chain.
public fun publish_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<RewardsAdmin>,
    fee_policy: &FeePolicy,
    expected_treasury: address,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
    claim_deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let treasury = fee_policy.destination();
    assert!(treasury == expected_treasury, ETreasuryChanged);
    assert!(number == vault.next_round(), EWrongRound);
    assert!(
        start_checkpoint < end_checkpoint
            && vault.last_checkpoint().is_none_or!(|last| *last <= start_checkpoint),
        EInvalidInterval,
    );
    assert!(
        root.length() == merkle_tree::digest_length()
            && manifest_digest.length() == merkle_tree::digest_length(),
        EInvalidCommitment,
    );
    assert!(leaf_count > 0 && leaf_count <= MAX_REWARD_LEAVES, EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    assert!(claim_deadline_at_ms > clock.timestamp_ms(), EInvalidClaimDeadline);
    let (available_meme, available_quote) = vault.holder_rewards_balances();
    assert!(
        meme_amount <= available_meme && quote_amount <= available_quote
            && gas_reserve_amount <= available_quote - quote_amount,
        EInsufficientBudget,
    );

    let vault_id = object::id(vault);
    let (meme, mut quote) = vault.fund_round(
        end_checkpoint,
        meme_amount,
        quote_amount + gas_reserve_amount,
    );
    let gas_reserve = if (gas_reserve_amount > 0) option::some(quote.split(gas_reserve_amount))
    else option::none();
    let round = Round {
        id: object::new(ctx),
        vault_id,
        number,
        claim_deadline_ms: claim_deadline_at_ms,
        root,
        leaf_count,
        claimed_bitmap: unclaimed(leaf_count),
        meme,
        quote,
        treasury,
        gas_reserve,
    };
    let (meme_unallocated, quote_unallocated) = vault.holder_rewards_balances();

    event::emit(RoundPublished<Meme, Quote> {
        vault_id,
        round_id: round.id.to_inner(),
        number,
        start_checkpoint,
        end_checkpoint,
        claim_deadline_ms: claim_deadline_at_ms,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        meme_unallocated,
        quote_unallocated,
        treasury,
        gas_reserve_amount,
    });
    transfer::share_object(round);
}

/// Pays only the committed holder balances; anyone may relay an unchanged proof.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    package_version: &PackageVersion,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(index < self.leaf_count, EInvalidIndex);
    let (word, bit) = claim_bit(index);
    assert!(self.claimed_bitmap[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyClaim);
    let digest = leaf(self.vault_id, self.number, index, beneficiary, meme_amount, quote_amount);
    assert!(merkle_tree::verify(self.root, digest, index, self.leaf_count, &proof), EInvalidProof);

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

/// RewardsAdmin settles a measured, capped reimbursement once. The committed
/// treasury receives it; all unused reserve immediately returns to this vault.
public fun settle_gas_reserve<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<RewardsAdmin>,
    vault: &mut Vault<Meme, Quote>,
    reimbursement_amount: u64,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(self.vault_id == object::id(vault), EWrongVault);
    assert!(self.gas_reserve.is_some(), EReserveSettled);
    assert!(reimbursement_amount <= self.gas_reserve.borrow().value(), EOverReserve);

    let mut reserve = self.gas_reserve.extract();
    let reserve_returned = reserve.value() - reimbursement_amount;
    reserve.pay(reimbursement_amount, self.treasury, ctx);
    vault.restore_holder_rewards(balance::zero(), reserve);
    let (_, quote_unallocated) = vault.holder_rewards_balances();
    event::emit(GasReserveSettled<Meme, Quote> {
        vault_id: self.vault_id,
        round_id: self.id.to_inner(),
        number: self.number,
        treasury: self.treasury,
        reimbursement_amount,
        reserve_returned,
        quote_unallocated,
    });
}

/// Anyone can close at the deadline, returning all unclaimed holder funds and
/// any unsettled reserve. Missing settlement authority cannot strand custody.
public fun close_round<Meme, Quote>(
    self: Round<Meme, Quote>,
    package_version: &PackageVersion,
    vault: &mut Vault<Meme, Quote>,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(self.vault_id == object::id(vault), EWrongVault);
    assert!(clock.timestamp_ms() >= self.claim_deadline_ms, EClaimsStillOpen);

    let Round { id, vault_id, number, meme, mut quote, gas_reserve, .. } = self;
    let (meme_returned, quote_returned) = (meme.value(), quote.value());
    let reserve = gas_reserve.destroy_or!(balance::zero());
    let gas_reserve_returned = reserve.value();
    quote.join(reserve);
    vault.restore_holder_rewards(meme, quote);
    event::emit(RoundClosed<Meme, Quote> {
        vault_id,
        round_id: id.to_inner(),
        number,
        meme_returned,
        quote_returned,
        gas_reserve_returned,
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
    claim_deadline_at_ms: u64,
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
        claim_deadline_ms: claim_deadline_at_ms,
        root,
        leaf_count,
        claimed_bitmap: unclaimed(leaf_count),
        meme,
        quote,
        treasury: @0x0,
        gas_reserve: option::none(),
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
        treasury: _,
        gas_reserve,
    } = self;
    gas_reserve.destroy_or!(balance::zero()).destroy_zero();
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

#[test_only]
public fun reserve_balances_for_testing<Meme, Quote>(
    self: &Round<Meme, Quote>,
): (u64, u64, Option<u64>) {
    (self.meme.value(), self.quote.value(), self.gas_reserve.map_ref!(|reserve| reserve.value()))
}

#[test_only]
public fun reserve_published_id<Meme, Quote>(payload: &RoundPublished<Meme, Quote>): ID {
    payload.round_id
}

#[test_only]
public fun reserve_published_bytes<Meme, Quote>(payload: &RoundPublished<Meme, Quote>): vector<u8> {
    bcs::to_bytes(payload)
}

#[test_only]
public fun reserve_claimed_bytes<Meme, Quote>(payload: &RewardClaimed<Meme, Quote>): vector<u8> {
    bcs::to_bytes(payload)
}

#[test_only]
public fun reserve_settled_bytes<Meme, Quote>(
    payload: &GasReserveSettled<Meme, Quote>,
): vector<u8> {
    bcs::to_bytes(payload)
}

#[test_only]
public fun reserve_closed_bytes<Meme, Quote>(payload: &RoundClosed<Meme, Quote>): vector<u8> {
    bcs::to_bytes(payload)
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
    treasury: address,
    gas_reserve_amount: u64,
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

public struct GasReserveSettled<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
}

public struct RoundClosed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
}

// === Constants ===

const MAX_REWARD_LEAVES: u64 = 65_536;

// === Errors ===

#[error(code = 0)]
const EWrongRound: vector<u8> = b"Round number must match the vault's next round.";

#[error(code = 1)]
const EInvalidInterval: vector<u8> = b"Checkpoint interval must be nonempty and must not overlap a previous round.";

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

#[error(code = 13)]
const EInsufficientBudget: vector<u8> = b"Holder funding and gas reserve must fit the vault's available balances.";

#[error(code = 14)]
const EReserveSettled: vector<u8> = b"Gas reimbursement is disabled or its reserve has already been settled.";

#[error(code = 15)]
const EOverReserve: vector<u8> = b"Reimbursement must not exceed the bound gas reserve.";

#[error(code = 16)]
const ETreasuryChanged: vector<u8> = b"The governed treasury must match the publication commitment.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_presale::{
    blast_presale,
    blast_presale_domain::RewardsAdmin,
    blast_presale_package::PackageVersion,
    fee_policy::FeePolicy,
    merkle_tree,
    presale_vault::Vault
};

use std::bcs;

use sui::{balance::{Self, Balance}, clock::Clock, event, hash};

use fun blast_presale::pay as Balance.pay;
