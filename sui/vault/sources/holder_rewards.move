// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the rewards module's abort location.
#[allow(lint(abort_without_constant))]
/// Holder rewards: rounds funded from a vault's holder-reward route and paid by Merkle proof.
///
/// Blast's off-chain system turns checkpointed holder balances into a Merkle allocation, and a
/// `RewardsAdmin` schedules it as a round on the vault. Once the vault's round delay has elapsed,
/// anyone publishes it, reserving its Meme and Quote budget from the vault. Anyone can relay a
/// proof afterwards; each leaf pays its committed beneficiary once, and anyone closes the round at
/// its deadline, returning what is left to the vault.
///
/// A claim pays by transfer, so a leaf's beneficiary must be an account: a coin sent to an object's
/// address (a pool, a vesting schedule, another vault) has no recovery path, and the claimed leaf
/// never returns to the vault. Nothing on chain tells the two apart, so the allocation leaves
/// object-held balances out.
module blast_vault::holder_rewards;

// === Public Types ===

/// A published round: independently funded claims with optional, one-shot gas custody that claims
/// never touch, returned to its vault at the claim deadline.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    vault_id: ID,
    number: u64,
    claim_deadline_at_ms: u64,
    root: vector<u8>,
    leaf_count: u64,
    claimed_bitmap: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    treasury: address,
    gas_reserve: Option<Balance<Quote>>,
}

// === Public Functions ===

/// Schedules a round's terms for publication after the vault's applied round delay, replacing
/// any scheduled round or delay change. The terms' static checks run now; the round number,
/// interval, and budget are checked against the vault now to fail fast and again at publication.
/// A zero reserve disables gas reimbursement. Gas attribution remains off chain.
public fun schedule_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    _: &AdminWitness<RewardsAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    gas_reserve_amount: u64,
    claim_window_duration_ms: u64,
    expected_treasury: address,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::admin_pause_bit!());
    let terms = vault::new_round_terms(
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        gas_reserve_amount,
        claim_window_duration_ms,
        expected_treasury,
    );
    assert_fundable(vault, &terms);

    vault.schedule_round_publication(terms, clock);
}

/// Publishes the scheduled round once its delay has elapsed: the treasury must still be the
/// expected one, and the round's number, interval, and budget must still fit the vault. Funds
/// holder claims and optional gas custody separately, with claims open for the scheduled window
/// from now, and shares the round. Anyone may call it.
public fun publish_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::admin_pause_bit!());
    let terms = vault.take_round_publication(clock);
    let treasury_address = treasury.destination();
    assert!(
        treasury_address == terms.expected_treasury(),
        blast_vault::errors::treasury_changed!(),
    );
    assert_fundable(vault, &terms);
    let claim_deadline_at_ms = clock
        .timestamp_ms()
        .checked_add(terms.claim_window_duration_ms())
        .destroy_or!(abort blast_vault::errors::claim_deadline_overflow!());

    let vault_id = object::id(vault);
    let gas_reserve_amount = terms.gas_reserve_amount();
    let (meme, mut quote) = vault.fund_round(
        terms.end_checkpoint(),
        terms.meme_amount(),
        terms.quote_amount() + gas_reserve_amount,
    );
    let gas_reserve = if (gas_reserve_amount > 0) option::some(quote.split(gas_reserve_amount))
    else option::none();
    let round = Round<Meme, Quote> {
        id: object::new(ctx),
        vault_id,
        number: terms.number(),
        claim_deadline_at_ms,
        root: terms.root(),
        leaf_count: terms.leaf_count(),
        claimed_bitmap: vector::tabulate!(terms.leaf_count().div_ceil(256), |_| 0u256),
        meme,
        quote,
        treasury: treasury_address,
        gas_reserve,
    };
    let (meme_unallocated, quote_unallocated) = vault.rewards_balances();

    blast_vault_events::round_published<Meme, Quote>(
        vault_id,
        round.id.to_inner(),
        terms.number(),
        terms.start_checkpoint(),
        terms.end_checkpoint(),
        claim_deadline_at_ms,
        terms.root(),
        terms.manifest_digest(),
        terms.leaf_count(),
        terms.meme_amount(),
        terms.quote_amount(),
        meme_unallocated,
        quote_unallocated,
        treasury_address,
        gas_reserve_amount,
    );
    transfer::share_object(round);
}

/// Cancels the scheduled round, even a ready one; nothing was reserved, so no balance moves.
public fun cancel_round<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::version!());

    vault.cancel_round_publication();
}

/// Schedules a new round delay after the applied one, replacing any scheduled round.
public fun schedule_round_delay<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    _: &AdminWitness<RewardsAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::admin_pause_bit!());

    vault.schedule_round_publication_delay(delay_ms, clock);
}

/// Applies a ready round-delay change; anyone may call it.
public fun apply_round_delay<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::admin_pause_bit!());

    vault.apply_round_publication_delay(clock);
}

/// Cancels the pending round-delay change, even a ready one.
public fun cancel_round_delay<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::version!());

    vault.cancel_round_publication_delay();
}

/// Pays one committed allocation before the claim deadline, only to its committed beneficiary;
/// anyone may relay an unchanged proof. Claims never pause.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());
    assert!(
        clock.timestamp_ms() < self.claim_deadline_at_ms,
        blast_vault::errors::claims_closed!(),
    );
    assert!(index < self.leaf_count, blast_vault::errors::invalid_index!());
    let (word, bit) = claim_bit(index);
    assert!(self.claimed_bitmap[word] & bit == 0, blast_vault::errors::already_claimed!());
    assert!(beneficiary != @0x0, blast_vault::errors::invalid_beneficiary!());
    assert!(meme_amount > 0 || quote_amount > 0, blast_vault::errors::empty_claim!());
    let digest = reward_leaf(
        self.vault_id,
        self.number,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
    );
    assert!(
        merkle::verify(self.root, digest, index, self.leaf_count, &proof),
        blast_vault::errors::invalid_proof!(),
    );

    let claimed_word = &mut self.claimed_bitmap[word];
    *claimed_word = *claimed_word | bit;
    payout::pay(&mut self.meme, meme_amount, beneficiary, ctx);
    payout::pay(&mut self.quote, quote_amount, beneficiary, ctx);

    blast_vault_events::reward_claimed<Meme, Quote>(
        self.id.to_inner(),
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        self.meme.value(),
        self.quote.value(),
    );
}

/// Settles a measured, capped gas reimbursement once: the round's treasury receives it, and all
/// unused reserve returns to the vault at once.
public fun settle_gas_reserve<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    _: &AdminWitness<RewardsAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    vault: &mut Vault<Meme, Quote>,
    reimbursement_amount: u64,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::admin_pause_bit!());
    assert!(self.vault_id == object::id(vault), blast_vault::errors::wrong_vault!());
    assert!(self.gas_reserve.is_some(), blast_vault::errors::reserve_settled!());
    assert!(
        reimbursement_amount <= self.gas_reserve.borrow().value(),
        blast_vault::errors::over_reserve!(),
    );

    let mut reserve = self.gas_reserve.extract();
    let reserve_returned = reserve.value() - reimbursement_amount;
    payout::pay(&mut reserve, reimbursement_amount, self.treasury, ctx);
    vault.restore_rewards(balance::zero(), reserve);
    let (_, quote_unallocated) = vault.rewards_balances();

    blast_vault_events::gas_reserve_settled<Meme, Quote>(
        self.vault_id,
        self.id.to_inner(),
        self.number,
        self.treasury,
        reimbursement_amount,
        reserve_returned,
        quote_unallocated,
    );
}

/// Closes the round at or after its claim deadline, returning every unclaimed holder balance and
/// any unsettled reserve to its vault, so missing settlement authority cannot strand custody.
/// Anyone may call it.
public fun close_round<Meme, Quote>(
    self: Round<Meme, Quote>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    vault: &mut Vault<Meme, Quote>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());
    assert!(self.vault_id == object::id(vault), blast_vault::errors::wrong_vault!());
    assert!(
        clock.timestamp_ms() >= self.claim_deadline_at_ms,
        blast_vault::errors::claims_still_open!(),
    );

    let Round { id, vault_id, number, meme, mut quote, gas_reserve, .. } = self;
    let (meme_returned, quote_returned) = (meme.value(), quote.value());
    let reserve = gas_reserve.destroy_or!(balance::zero());
    let gas_reserve_returned = reserve.value();
    quote.join(reserve);
    vault.restore_rewards(meme, quote);

    blast_vault_events::round_closed<Meme, Quote>(
        vault_id,
        id.to_inner(),
        number,
        meme_returned,
        quote_returned,
        gas_reserve_returned,
    );
    id.delete();
}

// === Private Functions ===

/// Checks `terms` against the vault: the next round number, an interval at or after the previous
/// round's end, and a holder budget plus gas reserve within the unreserved rewards.
fun assert_fundable<Meme, Quote>(vault: &Vault<Meme, Quote>, terms: &RoundTerms) {
    assert!(terms.number() == vault.next_round(), blast_vault::errors::wrong_round!());
    assert!(
        vault.last_checkpoint().is_none_or!(|prior_end| *prior_end <= terms.start_checkpoint()),
        blast_vault::errors::overlapping_interval!(),
    );
    let (available_meme, available_quote) = vault.rewards_balances();
    assert!(
        terms.meme_amount() <= available_meme
            && terms.quote_amount() <= available_quote
            && terms.gas_reserve_amount() <= available_quote - terms.quote_amount(),
        blast_vault::errors::insufficient_budget!(),
    );
}

/// Locates leaf `index` in the claim bitmap as its word and the bit within that word, 256 leaves
/// per word.
fun claim_bit(index: u64): (u64, u256) {
    (index / 256, 1u256 << ((index % 256) as u8))
}

/// The digest of one beneficiary's allocation; the unique vault ID and its increasing round
/// number separate every round's leaves.
fun reward_leaf(
    vault_id: ID,
    round_number: u64,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
): vector<u8> {
    let mut payload = bcs::to_bytes(&vault_id);
    payload.append(bcs::to_bytes(&round_number));
    payload.append(bcs::to_bytes(&index));
    payload.append(bcs::to_bytes(&beneficiary));
    payload.append(bcs::to_bytes(&meme_amount));
    payload.append(bcs::to_bytes(&quote_amount));

    merkle::leaf(constants::reward_leaf_domain!(), payload)
}

// === Test-Only Functions ===

#[test_only]
/// The leaf digest a claim verifies, for building expected roots.
public fun reward_leaf_for_testing(
    vault_id: ID,
    round_number: u64,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
): vector<u8> {
    reward_leaf(vault_id, round_number, index, beneficiary, meme_amount, quote_amount)
}

#[test_only]
/// The Meme and Quote the round still holds for unpaid leaves, and its pending gas reserve.
public fun round_balances_for_testing<Meme, Quote>(
    self: &Round<Meme, Quote>,
): (u64, u64, Option<u64>) {
    (self.meme.value(), self.quote.value(), self.gas_reserve.map_ref!(|reserve| reserve.value()))
}

#[test_only]
/// Whether leaf `index` has been paid.
public fun is_claimed_for_testing<Meme, Quote>(self: &Round<Meme, Quote>, index: u64): bool {
    let (word, bit) = claim_bit(index);
    self.claimed_bitmap[word] & bit != 0
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion};

use blast_core::{
    blast_domain::{CancelAdmin, RewardsAdmin},
    blast_treasury::Treasury,
    merkle,
    payout
};

use blast_vault::{
    blast_vault_events,
    blast_vault_package::BLAST_VAULT_PACKAGE,
    constants,
    vault::{Self, RoundTerms, Vault}
};

use std::bcs;

use sui::{balance::{Self, Balance}, clock::Clock};
