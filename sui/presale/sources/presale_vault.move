// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Custody for one LP position, migrated from a presale or provided directly, its residuals, and its
/// holder-reward fee share.
module blast_presale::presale_vault;

// === Public Types ===

/// Sealed field name binding one venue position type to a vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared custody for one LP position and its immutable fee split: a presale's, after migration, or
/// an owner's own position locked here directly, with zero presale and creator-capability IDs.
///
/// Each collection first takes Blast's LP fees of each asset at the vault's
/// rates, snapshotted at creation and changeable only by the AdminCap, then
/// pays every fee recipient its share of the rest at once; the holder-reward
/// share accrues here until Blast's rewards administrator funds a round.
/// Blast's LP fees go to the protocol destination at once, unless the sale named
/// a partner: then they wait here for `pay_protocol_lp_fees_with_partner`.
public struct Vault<phantom Meme, phantom Quote> has key {
    id: UID,
    presale_id: ID,
    presale_cap_id: ID,
    pool_id: ID,
    fee_split: FeeSplit,
    protocol_fees: ProtocolFees,
    /// The Blast partner the sale named, paid its cut of Blast's LP fees. It never changes.
    partner_id: Option<ID>,
    unpaid_protocol_meme: Balance<Meme>,
    unpaid_protocol_quote: Balance<Quote>,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    holder_rewards_meme: Balance<Meme>,
    holder_rewards_quote: Balance<Quote>,
    next_round: u64,
    last_checkpoint: Option<u64>,
}

// === Public Functions ===

/// Claims the pool's one-time migration residuals with the creator capability.
public fun claim_migration_residuals<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
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

/// Sets Blast's share of each asset in this vault's later LP-fee collections. Fees still in the
/// pool are split at the new rates when collected; the creator's split of the rest is unchanged.
public fun set_protocol_lp_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    admin_registry: &AdminRegistry,
    admin_cap: &AdminCap,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
) {
    admin_registry.assert_admin_cap(admin_cap);
    let protocol_fees = self.protocol_fees.with_lp_fees(lp_fee_meme_bps, lp_fee_quote_bps);
    assert!(protocol_fees != self.protocol_fees, EProtocolLpFeesUnchanged);

    self.protocol_fees = protocol_fees;

    event::emit(ProtocolLpFeesChanged<Meme, Quote> {
        vault_id: self.id.to_inner(),
        protocol_lp_fee_meme_bps: lp_fee_meme_bps.value(),
        protocol_lp_fee_quote_bps: lp_fee_quote_bps.value(),
    });
}

/// Pays the Blast LP fees this vault holds for its partner: the partner its cut of each asset in
/// force now, rounded down, then the fee policy's current destination the rest. Anyone may call
/// it, since both payees are fixed. Holding nothing is valid, moves nothing, and emits nothing,
/// so it can follow any collection.
public fun pay_protocol_lp_fees_with_partner<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
    partner: &Partner,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.partner_id.contains(&object::id(partner)), EWrongPartner);
    if (self.unpaid_protocol_meme.value() == 0 && self.unpaid_protocol_quote.value() == 0) return;

    let protocol_destination = fee_policy.destination();
    let mut protocol_meme = self.unpaid_protocol_meme.withdraw_all();
    let mut protocol_quote = self.unpaid_protocol_quote.withdraw_all();
    let partner_meme = partner.pay(&mut protocol_meme, clock);
    let partner_quote = partner.pay(&mut protocol_quote, clock);
    let paid_meme = protocol_meme.value();
    let paid_quote = protocol_quote.value();

    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);

    event::emit(ProtocolLpFeesPaid<Meme, Quote> {
        vault_id: self.id.to_inner(),
        protocol_destination,
        protocol_meme: paid_meme,
        protocol_quote: paid_quote,
        partner_meme,
        partner_quote,
    });
}

// === Package Functions ===

/// Creates and shares a migrated presale's vault, with its venue position sealed as a dynamic
/// object field, the presale's immutable LP-fee split and partner, and its snapshotted Blast rates.
public(package) fun create<Meme, Quote, Venue, Position: key + store>(
    sale: &Presale<Meme, Quote>,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let (presale_id, presale_cap_id, fee_split, protocol_fees, partner_id) = sale.vault_config();

    share_new(
        presale_id,
        presale_cap_id,
        fee_split,
        protocol_fees,
        partner_id,
        venue,
        pool_id,
        position,
        liquidity,
        migration_meme_residual,
        migration_quote_residual,
        ctx,
    );
}

/// Creates and shares a vault for a position its owner provides directly, with no presale, so its presale and
/// creator-capability IDs are zero, no `PresaleCap` matches it, and it holds no residuals. Its
/// position is sealed for good, its LP-fee split is immutable, and Blast's rates are the
/// `FeePolicy`'s now.
public(package) fun create_without_presale<Meme, Quote, Venue, Position: key + store>(
    fee_split: FeeSplit,
    fee_policy: &FeePolicy,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    ctx: &mut TxContext,
) {
    share_new<Meme, Quote, _, _>(
        object::id_from_address(@0x0),
        object::id_from_address(@0x0),
        fee_split,
        fee_policy.fees(),
        option::none(),
        venue,
        pool_id,
        position,
        liquidity,
        balance::zero(),
        balance::zero(),
        ctx,
    );
}

/// Borrows the custodied venue position without exposing a removal path.
public(package) fun position_mut<Meme, Quote, Venue, Position: key + store>(
    self: &mut Vault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Splits collected LP fees: Blast's LP fees at the vault's current rates, rounded up, are paid
/// to the current protocol destination or, on a partnered vault, held for
/// `pay_protocol_lp_fees_with_partner`; under the immutable creation-time BPS, every fee recipient
/// is paid its share of the rest at once, and the holder-reward share stays in the vault. A zero
/// collection is valid, moves nothing, and emits nothing.
public(package) fun split_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
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

    let protocol_meme = self.protocol_fees.lp_fee_meme_bps().apply_up(gross_meme);
    let protocol_quote = self.protocol_fees.lp_fee_quote_bps().apply_up(gross_quote);
    let (fee_recipient_meme, holder_rewards_meme) = self.fee_amounts(gross_meme - protocol_meme);
    let (fee_recipient_quote, holder_rewards_quote) = self.fee_amounts(
        gross_quote - protocol_quote,
    );
    let recipients = self.fee_split.fee_recipients().recipients();

    let protocol_destination = self.pay_or_hold_protocol_lp_fees(
        meme.split(protocol_meme),
        quote.split(protocol_quote),
        fee_policy,
        ctx,
    );
    recipients.length().do!(|i| {
        meme.pay(fee_recipient_meme[i], recipients[i], ctx);
        quote.pay(fee_recipient_quote[i], recipients[i], ctx);
    });
    self.holder_rewards_meme.join(meme);
    self.holder_rewards_quote.join(quote);

    event::emit(FeesCollected<Meme, Quote> {
        vault_id: self.id.to_inner(),
        gross_meme,
        gross_quote,
        protocol_destination,
        protocol_meme,
        protocol_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    });
}

public(package) fun assert_cap<Meme, Quote>(
    self: &Vault<Meme, Quote>,
    cap: &PresaleCap,
) {
    assert!(object::id(cap) == self.presale_cap_id, EWrongPresaleCap);
}

public(package) fun pool_id<Meme, Quote>(self: &Vault<Meme, Quote>): ID {
    self.pool_id
}

public(package) fun next_round<Meme, Quote>(self: &Vault<Meme, Quote>): u64 {
    self.next_round
}

public(package) fun last_checkpoint<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): Option<u64> {
    self.last_checkpoint
}

public(package) fun holder_rewards_balances<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): (u64, u64) {
    (self.holder_rewards_meme.value(), self.holder_rewards_quote.value())
}

public(package) fun fund_round<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    end_checkpoint: u64,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    self.next_round = self.next_round + 1;
    self.last_checkpoint = option::some(end_checkpoint);

    (self.holder_rewards_meme.split(meme_amount), self.holder_rewards_quote.split(quote_amount))
}

/// Returns a closed round's unclaimed rewards to the holder-reward balances.
public(package) fun restore_holder_rewards<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.holder_rewards_meme.join(meme);
    self.holder_rewards_quote.join(quote);
}

// === Private Functions ===

fun share_new<Meme, Quote, Venue, Position: key + store>(
    presale_id: ID,
    presale_cap_id: ID,
    fee_split: FeeSplit,
    protocol_fees: ProtocolFees,
    partner_id: Option<ID>,
    _venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    migration_meme_residual: Balance<Meme>,
    migration_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
) {
    assert!(liquidity > 0, EZeroLiquidity);

    let mut vault = Vault {
        id: object::new(ctx),
        presale_id,
        presale_cap_id,
        pool_id,
        fee_split,
        protocol_fees,
        partner_id,
        unpaid_protocol_meme: balance::zero(),
        unpaid_protocol_quote: balance::zero(),
        migration_meme_residual,
        migration_quote_residual,
        holder_rewards_meme: balance::zero(),
        holder_rewards_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    };

    event::emit(VaultCreated<Meme, Quote, Venue> {
        vault_id: vault.id.to_inner(),
        presale_id,
        pool_id,
        position_id: object::id(&position),
        liquidity,
        fee_recipients: fee_split.fee_recipients().recipients(),
        fee_recipient_bps: fee_split.fee_recipients().bps(),
        holder_rewards_bps: fee_split.holder_rewards_bps().value(),
        protocol_lp_fee_meme_bps: protocol_fees.lp_fee_meme_bps().value(),
        protocol_lp_fee_quote_bps: protocol_fees.lp_fee_quote_bps().value(),
        migration_meme_residual: vault.migration_meme_residual.value(),
        migration_quote_residual: vault.migration_quote_residual.value(),
    });

    vault.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    transfer::share_object(vault);
}

/// Pays Blast's LP fees to the fee policy's current destination and returns it, or, on a vault
/// naming a partner, holds them for `pay_protocol_lp_fees_with_partner` and returns none.
fun pay_or_hold_protocol_lp_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    protocol_meme: Balance<Meme>,
    protocol_quote: Balance<Quote>,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): Option<address> {
    if (self.partner_id.is_some()) {
        self.unpaid_protocol_meme.join(protocol_meme);
        self.unpaid_protocol_quote.join(protocol_quote);
        return option::none()
    };

    let protocol_destination = fee_policy.destination();
    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);
    option::some(protocol_destination)
}

/// Pays all of `balance` to `recipient`, sending no coin when it is empty.
fun pay_all<Asset>(mut balance: Balance<Asset>, recipient: address, ctx: &mut TxContext) {
    let amount = balance.value();
    balance.pay(amount, recipient, ctx);
    balance.destroy_zero();
}

/// Splits `amount` under the creation-time BPS into each fee recipient's amount and the
/// holder-reward amount.
fun fee_amounts<Meme, Quote>(self: &Vault<Meme, Quote>, amount: u64): (vector<u64>, u64) {
    let mut recipient_amounts = self.fee_split.apportion_fee(amount);
    let holder_rewards = recipient_amounts.pop_back();

    (recipient_amounts, holder_rewards)
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing<Meme, Quote>(
    presale_id: ID,
    presale_cap_id: ID,
    fee_split: FeeSplit,
    protocol_fees: ProtocolFees,
    partner_id: Option<ID>,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    Vault {
        id: object::new(ctx),
        presale_id,
        presale_cap_id,
        pool_id: object::id_from_address(@0x1),
        fee_split,
        protocol_fees,
        partner_id,
        unpaid_protocol_meme: balance::zero(),
        unpaid_protocol_quote: balance::zero(),
        migration_meme_residual: balance::zero(),
        migration_quote_residual: balance::zero(),
        holder_rewards_meme: balance::zero(),
        holder_rewards_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    }
}

#[test_only]
public fun credit_fees_for_testing<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    self.split_fees(fee_policy, meme, quote, ctx)
}

#[test_only]
public fun fees_collected_fields<Meme, Quote>(
    event: &FeesCollected<Meme, Quote>,
): (u64, u64, vector<u64>, vector<u64>, u64, u64) {
    (
        event.gross_meme,
        event.gross_quote,
        event.fee_recipient_meme,
        event.fee_recipient_quote,
        event.holder_rewards_meme,
        event.holder_rewards_quote,
    )
}

#[test_only]
public fun fees_collected_protocol_fields<Meme, Quote>(
    event: &FeesCollected<Meme, Quote>,
): (Option<address>, u64, u64) {
    (event.protocol_destination, event.protocol_meme, event.protocol_quote)
}

#[test_only]
public fun protocol_lp_fees_paid_fields<Meme, Quote>(
    event: &ProtocolLpFeesPaid<Meme, Quote>,
): (ID, address, u64, u64, u64, u64) {
    (
        event.vault_id,
        event.protocol_destination,
        event.protocol_meme,
        event.protocol_quote,
        event.partner_meme,
        event.partner_quote,
    )
}

#[test_only]
public fun unpaid_protocol_lp_fees_for_testing<Meme, Quote>(
    self: &Vault<Meme, Quote>,
): (u64, u64) {
    (self.unpaid_protocol_meme.value(), self.unpaid_protocol_quote.value())
}

#[test_only]
public fun protocol_lp_fees_changed_fields<Meme, Quote>(
    event: &ProtocolLpFeesChanged<Meme, Quote>,
): (ID, u64, u64) {
    (event.vault_id, event.protocol_lp_fee_meme_bps, event.protocol_lp_fee_quote_bps)
}

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Vault<Meme, Quote>) {
    let Vault {
        id,
        presale_id: _,
        presale_cap_id: _,
        pool_id: _,
        fee_split: _,
        protocol_fees: _,
        partner_id: _,
        unpaid_protocol_meme,
        unpaid_protocol_quote,
        migration_meme_residual,
        migration_quote_residual,
        holder_rewards_meme,
        holder_rewards_quote,
        next_round: _,
        last_checkpoint: _,
    } = self;
    id.delete();
    unpaid_protocol_meme.destroy_zero();
    unpaid_protocol_quote.destroy_zero();
    migration_meme_residual.destroy_zero();
    migration_quote_residual.destroy_zero();
    holder_rewards_meme.destroy_zero();
    holder_rewards_quote.destroy_zero();
}

// === Events ===

public struct VaultCreated<phantom Meme, phantom Quote, phantom Venue> has copy, drop {
    vault_id: ID,
    /// Zero for a vault created without a presale.
    presale_id: ID,
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    fee_recipients: vector<address>,
    fee_recipient_bps: vector<u64>,
    holder_rewards_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    migration_meme_residual: u64,
    migration_quote_residual: u64,
}

public struct FeesCollected<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    gross_meme: u64,
    gross_quote: u64,
    /// Where Blast's LP fees were paid, or none when the vault holds them for its partner.
    protocol_destination: Option<address>,
    protocol_meme: u64,
    protocol_quote: u64,
    /// Aligned by index with the immutable recipients in `VaultCreated`.
    fee_recipient_meme: vector<u64>,
    fee_recipient_quote: vector<u64>,
    holder_rewards_meme: u64,
    holder_rewards_quote: u64,
}

public struct MigrationResidualsClaimed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme: u64,
    quote: u64,
}

/// A partnered vault paid the Blast LP fees it held: `partner_meme` and `partner_quote` to the
/// partner, and the rest, `protocol_meme` and `protocol_quote`, to `protocol_destination`.
public struct ProtocolLpFeesPaid<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    partner_meme: u64,
    partner_quote: u64,
}

/// Every later collection from `vault_id` pays Blast at these rates.
public struct ProtocolLpFeesChanged<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
}

// === Errors ===

#[error(code = 0)]
const ENoMigrationResiduals: vector<u8> = b"No migration residuals are available to claim.";

#[error(code = 1)]
const EZeroLiquidity: vector<u8> = b"The vault's position must hold liquidity.";

#[error(code = 2)]
const EWrongPresaleCap: vector<u8> = b"The creator capability belongs to a different presale vault.";

#[error(code = 3)]
const EProtocolLpFeesUnchanged: vector<u8> = b"An LP-fee update must change the vault's Blast rates.";

#[error(code = 4)]
const EWrongPartner: vector<u8> = b"The partner is not the one this vault's presale named at creation.";

// === Imports ===

use blast_partners::blast_partners::Partner;

use blast_presale::{
    blast_presale::{Self as presale, FeeSplit, Presale, PresaleCap},
    blast_presale_admin::{AdminCap, AdminRegistry},
    bps::Bps,
    fee_policy::{FeePolicy, ProtocolFees},
};

use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_object_field, event};

use fun presale::pay as Balance.pay;
use fun pay_all as Balance.pay_all;

use fun presale::bps_of as vector.bps;
use fun presale::recipients_of as vector.recipients;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
