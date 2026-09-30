// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Custody for one migrated LP position, its residuals, and its holder-reward fee share.
module blast_presale::presale_vault;

// === Public Types ===

/// Sealed field name binding one venue position type to a vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared post-migration custody for one presale's immutable fee split.
///
/// Each collection pays every fee recipient its share at once; the holder-reward
/// share accrues here until Blast's rewards administrator funds a round.
public struct PresaleVault<phantom Meme, phantom Quote> has key {
    id: UID,
    presale_id: ID,
    presale_cap_id: ID,
    pool_id: ID,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    rewards_meme: Balance<Meme>,
    rewards_quote: Balance<Quote>,
    next_round: u64,
    last_checkpoint: Option<u64>,
}

// === Public Functions ===

/// Claims the pool's one-time migration residuals with the creator capability.
public fun claim_migration_residuals<Meme, Quote>(
    self: &mut PresaleVault<Meme, Quote>,
    cap: &PresaleCap,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    self.assert_cap(cap);
    assert!(
        self.migration_meme_residual.value() > 0
            || self.migration_quote_residual.value() > 0,
        ENoMigrationResiduals,
    );
    let meme = self.migration_meme_residual.withdraw_all().into_coin(ctx);
    let quote = self.migration_quote_residual.withdraw_all().into_coin(ctx);

    event::emit(MigrationResidualsClaimed<Meme, Quote> {
        vault_id: self.id.to_inner(),
        meme: meme.value(),
        quote: quote.value(),
    });

    (meme, quote)
}

// === Package Functions ===

/// Creates and shares a vault with its venue position sealed as a dynamic object field.
public(package) fun create<Meme, Quote, Venue, Position: key + store>(
    presale_id: ID,
    presale_cap_id: ID,
    _venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
) {
    assert!(liquidity > 0, EZeroLiquidity);

    let position_id = object::id(&position);
    let fee_recipient_addresses = presale::fee_recipient_addresses(&fee_recipients);
    let fee_recipient_bps = presale::fee_recipient_bps(&fee_recipients);
    let mut vault = PresaleVault {
        id: object::new(ctx),
        presale_id,
        presale_cap_id,
        pool_id,
        fee_recipients,
        rewards_fee_bps,
        migration_meme_residual,
        migration_quote_residual,
        rewards_meme: balance::zero(),
        rewards_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    };
    let vault_id = vault.id.to_inner();
    let migration_meme_residual = vault.migration_meme_residual.value();
    let migration_quote_residual = vault.migration_quote_residual.value();

    vault.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    transfer::share_object(vault);

    event::emit(PresaleVaultCreated<Meme, Quote, Venue> {
        vault_id,
        presale_id,
        pool_id,
        position_id,
        liquidity,
        fee_recipients: fee_recipient_addresses,
        fee_recipient_bps,
        rewards_fee_bps,
        migration_meme_residual,
        migration_quote_residual,
    });
}

/// Borrows the custodied venue position without exposing a removal path.
public(package) fun position_mut<Meme, Quote, Venue, Position: key + store>(
    self: &mut PresaleVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Splits collected LP fees under the immutable creation-time BPS: every fee
/// recipient is paid at once and the holder-reward share stays in the vault. A
/// zero collection is valid, moves nothing, and emits nothing.
public(package) fun split_fees<Meme, Quote>(
    self: &mut PresaleVault<Meme, Quote>,
    mut meme: Balance<Meme>,
    mut quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let gross_meme = meme.value();
    let gross_quote = quote.value();
    if (gross_meme == 0 && gross_quote == 0) {
        meme.destroy_zero();
        quote.destroy_zero();
        return
    };

    let mut recipient_meme = presale::apportion_fee(
        &self.fee_recipients,
        self.rewards_fee_bps,
        gross_meme,
    );
    let mut recipient_quote = presale::apportion_fee(
        &self.fee_recipients,
        self.rewards_fee_bps,
        gross_quote,
    );
    let rewards_meme = recipient_meme.pop_back();
    let rewards_quote = recipient_quote.pop_back();
    let recipients = presale::fee_recipient_addresses(&self.fee_recipients);

    recipients.length().do!(|i| {
        meme.pay(recipient_meme[i], recipients[i], ctx);
        quote.pay(recipient_quote[i], recipients[i], ctx);
    });
    self.rewards_meme.join(meme);
    self.rewards_quote.join(quote);

    event::emit(FeesCollected<Meme, Quote> {
        vault_id: self.id.to_inner(),
        gross_meme,
        gross_quote,
        recipient_meme,
        recipient_quote,
        rewards_meme,
        rewards_quote,
    });
}

public(package) fun assert_cap<Meme, Quote>(
    self: &PresaleVault<Meme, Quote>,
    cap: &PresaleCap,
) {
    assert!(object::id(cap) == self.presale_cap_id, EWrongPresaleCap);
}

public(package) fun pool_id<Meme, Quote>(self: &PresaleVault<Meme, Quote>): ID {
    self.pool_id
}

public(package) fun next_round<Meme, Quote>(self: &PresaleVault<Meme, Quote>): u64 {
    self.next_round
}

public(package) fun last_checkpoint<Meme, Quote>(
    self: &PresaleVault<Meme, Quote>,
): Option<u64> {
    self.last_checkpoint
}

public(package) fun rewards_balances<Meme, Quote>(
    self: &PresaleVault<Meme, Quote>,
): (u64, u64) {
    (self.rewards_meme.value(), self.rewards_quote.value())
}

public(package) fun fund_round<Meme, Quote>(
    self: &mut PresaleVault<Meme, Quote>,
    end_checkpoint: u64,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    self.next_round = self.next_round + 1;
    self.last_checkpoint = option::some(end_checkpoint);

    (self.rewards_meme.split(meme_amount), self.rewards_quote.split(quote_amount))
}

// === Private Functions ===

/// Transfers `amount` split from `self` to `recipient`, skipping empty shares.
fun pay<T>(self: &mut Balance<T>, amount: u64, recipient: address, ctx: &mut TxContext) {
    if (amount > 0) transfer::public_transfer(self.split(amount).into_coin(ctx), recipient);
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing<Meme, Quote>(
    presale_id: ID,
    presale_cap_id: ID,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    ctx: &mut TxContext,
): PresaleVault<Meme, Quote> {
    PresaleVault {
        id: object::new(ctx),
        presale_id,
        presale_cap_id,
        pool_id: object::id_from_address(@0x1),
        fee_recipients,
        rewards_fee_bps,
        migration_meme_residual: balance::zero(),
        migration_quote_residual: balance::zero(),
        rewards_meme: balance::zero(),
        rewards_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    }
}

#[test_only]
public fun credit_fees_for_testing<Meme, Quote>(
    self: &mut PresaleVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    self.split_fees(meme, quote, ctx)
}

#[test_only]
public fun fees_collected_fields<Meme, Quote>(
    event: &FeesCollected<Meme, Quote>,
): (u64, u64, vector<u64>, vector<u64>, u64, u64) {
    (
        event.gross_meme,
        event.gross_quote,
        event.recipient_meme,
        event.recipient_quote,
        event.rewards_meme,
        event.rewards_quote,
    )
}

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: PresaleVault<Meme, Quote>) {
    let PresaleVault {
        id,
        presale_id: _,
        presale_cap_id: _,
        pool_id: _,
        fee_recipients: _,
        rewards_fee_bps: _,
        migration_meme_residual,
        migration_quote_residual,
        rewards_meme,
        rewards_quote,
        next_round: _,
        last_checkpoint: _,
    } = self;
    id.delete();
    migration_meme_residual.destroy_zero();
    migration_quote_residual.destroy_zero();
    rewards_meme.destroy_zero();
    rewards_quote.destroy_zero();
}

// === Events ===

public struct PresaleVaultCreated<phantom Meme, phantom Quote, phantom Venue> has copy, drop {
    vault_id: ID,
    presale_id: ID,
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    fee_recipients: vector<address>,
    fee_recipient_bps: vector<u64>,
    rewards_fee_bps: u64,
    migration_meme_residual: u64,
    migration_quote_residual: u64,
}

public struct FeesCollected<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    gross_meme: u64,
    gross_quote: u64,
    /// Aligned by index with the immutable recipients in `PresaleVaultCreated`.
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
    rewards_meme: u64,
    rewards_quote: u64,
}

public struct MigrationResidualsClaimed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme: u64,
    quote: u64,
}

// === Errors ===

#[error(code = 0)]
const ENoMigrationResiduals: vector<u8> = b"No migration residuals are available to claim.";

#[error(code = 1)]
const EZeroLiquidity: vector<u8> = b"Migration position must hold liquidity.";

#[error(code = 2)]
const EWrongPresaleCap: vector<u8> = b"The creator capability belongs to a different presale vault.";

// === Imports ===

use blast_presale::blast_presale::{Self as presale, FeeRecipient, PresaleCap};

use sui::{balance::{Self, Balance}, coin::Coin, dynamic_object_field, event};

use fun pay as Balance.pay;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
