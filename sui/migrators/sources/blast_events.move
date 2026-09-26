// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Typed replay facts for vault custody, the LP-fee policy and split, auto-LP, holder rewards,
/// Cetus pool reservations, and residual claims.
module blast_fun_migrators::blast_events;

// === Public Types ===

/// Blast's default pair (no `meme`) or one coin's pair changed; absent old/new pairs represent a
/// coin's own pair being created or removed.
public struct LpFeePolicyChanged has copy, drop {
    meme: Option<TypeName>,
    old_meme_bps: Option<u64>,
    old_quote_bps: Option<u64>,
    new_meme_bps: Option<u64>,
    new_quote_bps: Option<u64>,
}

/// The protocol share of every later collection pays a new address.
public struct LpFeeDestinationChanged has copy, drop {
    old_destination: address,
    new_destination: address,
}

/// Records discovery and typed position custody for one completed vault: the position's
/// `liquidity`, the handoff the venue returned as protocol residuals, and the creator's fee split
/// it holds from migration (generation zero).
public struct VaultCreated has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    fee_split: FeeSplit,
}

/// One nonzero collection split under `generation`: Blast's share, the creator, auto-LP, rewards,
/// and burn shares, and every recipient's amount in the split's recipient order. `burn_meme` was
/// burned; `burn_quote` waits for a buyback.
public struct FeesCollected has copy, drop {
    vault_id: ID,
    generation: u64,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_meme: u64,
    burn_quote: u64,
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
}

/// Auto-LP added these amounts to the position; the rest waits in the vault.
public struct AutoLiquidityAdded has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_pending: u64,
    quote_pending: u64,
}

/// A buyback admin swapped `quote_spent` of the burn Quote for `meme_burned` Meme and burned it;
/// `quote_pending` still waits.
public struct BuybackBurned has copy, drop {
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    quote_pending: u64,
}

/// The vault opened the separate position auto-LP adds to.
public struct AutoLpPositionOpened has copy, drop {
    vault_id: ID,
    position_id: ID,
}

/// The live curve-fee cap holder committed a new fee split as the next generation.
public struct FeeSplitChanged has copy, drop {
    vault_id: ID,
    old_generation: u64,
    new_generation: u64,
    old_fee_split: FeeSplit,
    new_fee_split: FeeSplit,
}

/// The live curve-fee cap holder claimed the creator's accrued LP fees.
public struct CreatorFeesClaimed has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

/// A holder-reward allocation commitment, its reserved funds, and the vault's unreserved rewards.
public struct RoundPublished has copy, drop {
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

/// A completed holder-reward payout and both remaining round balances.
public struct RewardPaid has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

/// Records a protocol migration-residual claim.
public struct ProtocolFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
}

/// Records Cetus pool creation reserved for one pair at the tick spacing its launch migration or
/// presale pool uses.
public struct CetusPoolReserved has copy, drop {
    meme: TypeName,
    quote: TypeName,
    pool_creation_cap_id: ID,
    tick_spacing: u32,
}

/// A presale's pool opened: its position, holding `liquidity` in `pool_id`, is locked in
/// `vault_id`, and the venue's residuals went to the presale's `creator`, who earns the pool's fees
/// after Blast's share.
public struct PresaleVaultCreated has copy, drop {
    vault_id: ID,
    presale_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    token: TypeName,
    quote: TypeName,
    creator: address,
    residual_token: u64,
    residual_quote: u64,
    liquidity: u128,
}

/// One collection of a presale vault's fees: Blast's live share of `gross_token` and
/// `gross_quote` went to `protocol_destination`, and the rest to the vault's creator.
public struct PresaleFeesCollected has copy, drop {
    vault_id: ID,
    gross_token: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_token: u64,
    protocol_quote: u64,
}

// === Package Functions ===

/// Emits a default or original-type partner policy mutation with complete old/new pairs.
public(package) fun lp_fee_policy_changed(
    meme: Option<TypeName>,
    old_meme_bps: Option<u64>,
    old_quote_bps: Option<u64>,
    new_meme_bps: Option<u64>,
    new_quote_bps: Option<u64>,
) {
    sui::event::emit(LpFeePolicyChanged {
        meme,
        old_meme_bps,
        old_quote_bps,
        new_meme_bps,
        new_quote_bps,
    });
}

/// Emits the protocol share redirection.
public(package) fun lp_fee_destination_changed(old_destination: address, new_destination: address) {
    sui::event::emit(LpFeeDestinationChanged { old_destination, new_destination });
}

/// Emits creation of one venue-sealed LP vault, its attached position, and its fee split.
public(package) fun vault_created<Meme, Quote, Venue>(
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    fee_split: FeeSplit,
) {
    sui::event::emit(VaultCreated {
        vault_id,
        pool_id,
        position_id,
        venue: type_name::with_original_ids<Venue>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        residual_meme,
        residual_quote,
        liquidity,
        fee_split,
    });
}

/// Emits one nonzero collection split under `generation`.
public(package) fun fees_collected(
    vault_id: ID,
    generation: u64,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_meme: u64,
    burn_quote: u64,
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
) {
    sui::event::emit(FeesCollected {
        vault_id,
        generation,
        gross_meme,
        gross_quote,
        protocol_destination,
        protocol_meme,
        protocol_quote,
        creator_meme,
        creator_quote,
        auto_lp_meme,
        auto_lp_quote,
        rewards_meme,
        rewards_quote,
        burn_meme,
        burn_quote,
        recipient_meme,
        recipient_quote,
    });
}

/// Emits one buyback and burn.
public(package) fun buyback_burned(
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    quote_pending: u64,
) {
    sui::event::emit(BuybackBurned { vault_id, quote_spent, meme_burned, quote_pending });
}

/// Emits one nonzero auto-LP addition and the amounts still waiting.
public(package) fun auto_liquidity_added(
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_pending: u64,
    quote_pending: u64,
) {
    sui::event::emit(AutoLiquidityAdded {
        vault_id,
        meme_amount,
        quote_amount,
        meme_pending,
        quote_pending,
    });
}

/// Emits the opening of a vault's auto-LP position.
public(package) fun auto_lp_position_opened(vault_id: ID, position_id: ID) {
    sui::event::emit(AutoLpPositionOpened { vault_id, position_id });
}

/// Emits a committed fee-split generation.
public(package) fun fee_split_changed(
    vault_id: ID,
    old_generation: u64,
    new_generation: u64,
    old_fee_split: FeeSplit,
    new_fee_split: FeeSplit,
) {
    sui::event::emit(FeeSplitChanged {
        vault_id,
        old_generation,
        new_generation,
        old_fee_split,
        new_fee_split,
    });
}

/// Emits a creator LP-fee claim.
public(package) fun creator_fees_claimed(vault_id: ID, meme_amount: u64, quote_amount: u64) {
    sui::event::emit(CreatorFeesClaimed { vault_id, meme_amount, quote_amount });
}

/// Emits a published holder-reward round.
public(package) fun round_published(
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
) {
    sui::event::emit(RoundPublished {
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

/// Emits one holder-reward payout.
public(package) fun reward_paid(
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
) {
    sui::event::emit(RewardPaid {
        round_id,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        meme_remaining,
        quote_remaining,
    });
}

/// Emits a protocol-owned migration-residual withdrawal.
public(package) fun protocol_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(ProtocolFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

/// Emits the Cetus pair reservation made while starting a launch.
public(package) fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32) {
    sui::event::emit(CetusPoolReserved {
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        pool_creation_cap_id,
        tick_spacing,
    });
}

public(package) fun presale_vault_created<Token, Quote, Venue>(
    vault_id: ID,
    presale_id: ID,
    pool_id: ID,
    position_id: ID,
    creator: address,
    residual_token: u64,
    residual_quote: u64,
    liquidity: u128,
) {
    sui::event::emit(PresaleVaultCreated {
        vault_id,
        presale_id,
        pool_id,
        position_id,
        venue: type_name::with_original_ids<Venue>(),
        token: type_name::with_original_ids<Token>(),
        quote: type_name::with_original_ids<Quote>(),
        creator,
        residual_token,
        residual_quote,
        liquidity,
    });
}

public(package) fun presale_fees_collected(
    vault_id: ID,
    gross_token: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_token: u64,
    protocol_quote: u64,
) {
    sui::event::emit(PresaleFeesCollected {
        vault_id,
        gross_token,
        gross_quote,
        protocol_destination,
        protocol_token,
        protocol_quote,
    });
}

// === Imports ===

use blast_fun::allocation::FeeSplit;

use std::type_name::{Self, TypeName};
