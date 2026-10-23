// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed dynamic-object custody for migration positions, their protocol residuals, and the
/// balances every LP-fee collection is split into.
module blast_fun_migrators::vault;

// === Public Types ===

/// A sealed field name that binds one venue position type to one vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// A sealed field name for the separate position auto-LP adds to on venues whose migration
/// position cannot receive more liquidity (Cetus burns it).
public struct AutoLpPositionKey<phantom Venue>() has copy, drop, store;

/// Shared per-launch custody for one position, its protocol migration residuals, and the balances
/// its LP fees are split into.
///
/// Every collection pays Blast's live share from `LpFeePolicy`, then splits the rest by the
/// creator's `FeeSplit`: the creator share accrues here until the live curve-fee cap claims it,
/// the auto-LP share goes back into the position in the same call (any part the pool does not
/// take waits here for the next call), the rewards share funds holder-reward rounds, and every
/// recipient is paid at once. The burn share's Meme is burned at once and its Quote waits here until
/// a buyback admin swaps it for Meme to burn. The split changes only after the fees accrued under
/// the current one are settled, so each fee follows the split it accrued under. When the launch
/// named a partner, Blast's live share waits here instead, until
/// `claim_protocol_lp_fees_with_partner` pays the partner its cut and Blast the rest.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    /// The Blast partner the launch named, paid its cut of Blast's LP fees. It never changes.
    partner_id: Option<ID>,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    unpaid_protocol_meme: Balance<Meme>,
    unpaid_protocol_quote: Balance<Quote>,
    fee_split: FeeSplit,
    creator_meme: Balance<Meme>,
    creator_quote: Balance<Quote>,
    auto_lp_meme: Balance<Meme>,
    auto_lp_quote: Balance<Quote>,
    rewards_meme: Balance<Meme>,
    rewards_quote: Balance<Quote>,
    burn_quote: Balance<Quote>,
    next_round: u64,
    last_checkpoint: Option<u64>,
}

// === Public Functions ===

/// Claims the protocol-owned migration residuals under a treasury admin.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<TreasuryAdmin>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    assert!(
        self.protocol_meme_residual.value() > 0 || self.protocol_quote_residual.value() > 0,
        ENothingClaimable,
    );

    let meme = self.protocol_meme_residual.withdraw_all().into_coin(ctx);
    let quote = self.protocol_quote_residual.withdraw_all().into_coin(ctx);

    blast_events::protocol_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Pays the Blast LP fees this vault holds for its launch's partner: the partner its cut of each
/// asset in force now, rounded down, then the `LpFeePolicy`'s current protocol destination the
/// rest. Anyone may claim, since both payees are fixed. Holding nothing is valid, moves nothing,
/// and emits nothing, so a claim can follow any collection.
public fun claim_protocol_lp_fees_with_partner<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    partner: &Partner,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.partner_id.contains(&object::id(partner)), EPartnerMismatch);
    if (self.unpaid_protocol_meme.value() == 0 && self.unpaid_protocol_quote.value() == 0) return;

    let protocol_destination = policy.protocol_destination();
    let mut protocol_meme = self.unpaid_protocol_meme.withdraw_all();
    let mut protocol_quote = self.unpaid_protocol_quote.withdraw_all();
    let partner_meme = partner.pay(&mut protocol_meme, clock, ctx);
    let partner_quote = partner.pay(&mut protocol_quote, clock, ctx);
    let paid_meme = protocol_meme.value();
    let paid_quote = protocol_quote.value();

    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);

    blast_events::protocol_lp_fees_claimed(
        self.id.to_inner(),
        protocol_destination,
        paid_meme,
        paid_quote,
        partner_meme,
        partner_quote,
    );
}

/// Claims the creator's accrued LP-fee share with the launch's live curve-fee cap.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    launch.assert_curve_fee_cap(curve_fee_cap);
    assert!(self.creator_meme.value() > 0 || self.creator_quote.value() > 0, ENoCreatorFees);

    let meme = self.creator_meme.withdraw_all().into_coin(ctx);
    let quote = self.creator_quote.withdraw_all().into_coin(ctx);

    blast_events::creator_fees_claimed(self.id.to_inner(), meme.value(), quote.value());

    (meme, quote)
}

// === Package Functions ===

/// Creates and shares the launch's vault, holding its fee split and the protocol residuals, with
/// `position`, holding `liquidity` in pool `pool_id`, attached under the venue's sealed key.
public(package) fun create<Meme, Quote, Venue, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
) {
    transfer::share_object(
        new(
            launch,
            venue,
            pool_id,
            position,
            liquidity,
            protocol_meme_residual,
            protocol_quote_residual,
            ctx,
        ),
    );
}

/// Mutably borrows the venue position without providing a removal path. Another venue's key
/// finds no field, so the borrow aborts.
public(package) fun position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Reports whether the auto-LP position exists under `Venue`.
public(package) fun has_auto_lp_position<Meme, Quote, Venue>(
    self: &LpVault<Meme, Quote>,
    _venue: &Venue,
): bool {
    self.id.has_dynamic_object_field(AutoLpPositionKey<Venue>())
}

/// Attaches the auto-LP position once, with no removal path.
public(package) fun attach_auto_lp_position<Meme, Quote, Venue, Position: key + store>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    position: Position,
) {
    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(AutoLpPositionKey<Venue>(), position);

    blast_events::auto_lp_position_opened(self.id.to_inner(), position_id);
}

/// Immutably borrows the auto-LP position.
public(package) fun auto_lp_position<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &LpVault<Meme, Quote>,
    _venue: &Venue,
): &Position {
    self.id.dynamic_object_field(AutoLpPositionKey<Venue>())
}

/// Mutably borrows the auto-LP position without providing a removal path.
public(package) fun auto_lp_position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(AutoLpPositionKey<Venue>())
}

/// Splits one collection of the position's fees: Blast's live share to the protocol destination,
/// or, when the launch named a partner, held for `claim_protocol_lp_fees_with_partner`; then the
/// creator, auto-LP, and rewards shares into their balances, the burn share's Meme burned
/// and its Quote kept for buyback, and every recipient paid. A zero collection is valid, moves
/// nothing, and emits nothing.
public(package) fun split_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
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

    let (protocol_meme_bps, protocol_quote_bps) = policy.shares<Meme>();
    let protocol_meme = protocol_meme_bps.apply_up(gross_meme);
    let protocol_quote = protocol_quote_bps.apply_up(gross_quote);
    let (creator_meme, auto_lp_meme, rewards_meme, burn_meme, recipient_meme) = self
        .fee_split
        .apportion_fee_split(gross_meme - protocol_meme);
    let (creator_quote, auto_lp_quote, rewards_quote, burn_quote, recipient_quote) = self
        .fee_split
        .apportion_fee_split(gross_quote - protocol_quote);
    let recipients = *self.fee_split.recipients();

    let protocol_destination = self.pay_or_hold_protocol_lp_fees(
        meme.split(protocol_meme),
        quote.split(protocol_quote),
        policy,
        ctx,
    );

    self.creator_meme.join(meme.split(creator_meme));
    self.creator_quote.join(quote.split(creator_quote));
    self.auto_lp_meme.join(meme.split(auto_lp_meme));
    self.auto_lp_quote.join(quote.split(auto_lp_quote));
    self.rewards_meme.join(meme.split(rewards_meme));
    self.rewards_quote.join(quote.split(rewards_quote));
    currency.burn(meme.split(burn_meme), ctx);
    self.burn_quote.join(quote.split(burn_quote));

    recipients.length().do!(|i| {
        meme.pay(recipient_meme[i], recipients[i].destination(), ctx);
        quote.pay(recipient_quote[i], recipients[i].destination(), ctx);
    });
    meme.destroy_zero();
    quote.destroy_zero();

    blast_events::fees_collected(
        self.id.to_inner(),
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
    );
}

/// Takes every Quote waiting to buy Meme back, under a live buyback admin.
public(package) fun take_buyback_quote<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    _: &AdminWitness<BuybackAdmin>,
): Balance<Quote> {
    assert!(self.burn_quote.value() > 0, ENoBuybackQuote);

    self.burn_quote.withdraw_all()
}

/// Burns the Meme a swap of `quote_in` returned, which must reach `min_meme_out`, and keeps the
/// Quote the pool did not take for the next buyback.
public(package) fun burn_buyback<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    currency: &mut Currency<Meme>,
    meme: Balance<Meme>,
    unspent_quote: Balance<Quote>,
    quote_in: u64,
    min_meme_out: u64,
    ctx: &mut TxContext,
) {
    let meme_burned = meme.value();
    assert!(meme_burned >= min_meme_out, EBuybackBelowMinimum);

    let quote_spent = quote_in - unspent_quote.value();
    currency.burn(meme, ctx);
    self.burn_quote.join(unspent_quote);

    blast_events::buyback_burned(
        self.id.to_inner(),
        quote_spent,
        meme_burned,
        self.burn_quote.value(),
    );
}

/// Takes every Meme and Quote waiting to be added back to the position.
public(package) fun take_auto_lp<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
): (Balance<Meme>, Balance<Quote>) {
    (self.auto_lp_meme.withdraw_all(), self.auto_lp_quote.withdraw_all())
}

/// Keeps what the pool did not take for the next call and records the amounts it added.
public(package) fun keep_auto_lp<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    added_meme: u64,
    added_quote: u64,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.auto_lp_meme.join(meme);
    self.auto_lp_quote.join(quote);

    if (added_meme == 0 && added_quote == 0) return;
    blast_events::auto_liquidity_added(
        self.id.to_inner(),
        added_meme,
        added_quote,
        self.auto_lp_meme.value(),
        self.auto_lp_quote.value(),
    );
}

/// Checks the launch's live curve-fee cap and that `proposed` changes the split. The adapter
/// checks first, settles the fees accrued under the current split, then calls `update_fee_split`.
public(package) fun assert_fee_split_update<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    proposed: FeeSplit,
) {
    launch.assert_curve_fee_cap(curve_fee_cap);
    assert!(proposed != self.fee_split, EFeeSplitUnchanged);
}

/// Commits `proposed`, which `assert_fee_split_update` already checked, as the vault's split.
public(package) fun update_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    proposed: FeeSplit,
) {
    let old_fee_split = self.fee_split;

    self.fee_split = proposed;

    blast_events::fee_split_changed(self.id.to_inner(), old_fee_split, proposed);
}

/// Reserves holder-reward funds for the round numbered `next_round`, ending at `end_checkpoint`.
public(package) fun fund_round<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    end_checkpoint: u64,
    meme_amount: u64,
    quote_amount: u64,
): (Balance<Meme>, Balance<Quote>) {
    self.next_round = self.next_round + 1;
    self.last_checkpoint = option::some(end_checkpoint);

    (self.rewards_meme.split(meme_amount), self.rewards_quote.split(quote_amount))
}

/// Returns the venue pool the attached position belongs to.
public(package) fun pool_id<Meme, Quote>(self: &LpVault<Meme, Quote>): ID {
    self.pool_id
}

/// Returns the number the next holder-reward round must carry.
public(package) fun next_round<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.next_round
}

/// Returns the checkpoint the next holder-reward round must start at, or none before the first.
public(package) fun last_checkpoint<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<u64> {
    self.last_checkpoint
}

/// Returns the Meme and Quote not yet reserved by a holder-reward round.
public(package) fun rewards_balances<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64) {
    (self.rewards_meme.value(), self.rewards_quote.value())
}

/// Transfers `amount` split from `balance` to `destination`, skipping empty shares.
public(package) fun pay<T>(
    balance: &mut Balance<T>,
    amount: u64,
    destination: address,
    ctx: &mut TxContext,
) {
    if (amount > 0) transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
}

// === Private Functions ===

/// Pays Blast's LP fees to the policy's protocol destination and returns it, or, on a vault whose
/// launch named a partner, holds them for `claim_protocol_lp_fees_with_partner` and returns none.
fun pay_or_hold_protocol_lp_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    protocol_meme: Balance<Meme>,
    protocol_quote: Balance<Quote>,
    policy: &LpFeePolicy,
    ctx: &mut TxContext,
): Option<address> {
    if (self.partner_id.is_some()) {
        self.unpaid_protocol_meme.join(protocol_meme);
        self.unpaid_protocol_quote.join(protocol_quote);
        return option::none()
    };

    let protocol_destination = policy.protocol_destination();
    protocol_meme.pay_all(protocol_destination, ctx);
    protocol_quote.pay_all(protocol_destination, ctx);
    option::some(protocol_destination)
}

/// Pays all of `balance` to `destination`, sending no coin when it is empty.
fun pay_all<T>(mut balance: Balance<T>, destination: address, ctx: &mut TxContext) {
    let amount = balance.value();
    balance.pay(amount, destination, ctx);
    balance.destroy_zero();
}

/// Builds the vault with the launch's fee split and empty balances, attaches `position`, and
/// announces the custody.
fun new<Meme, Quote, Venue, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    _venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    assert!(liquidity > 0, EZeroLiquidity);

    let position_id = object::id(&position);
    let mut vault = LpVault {
        id: object::new(ctx),
        pool_id,
        partner_id: launch.partner_id(),
        protocol_meme_residual,
        protocol_quote_residual,
        unpaid_protocol_meme: balance::zero(),
        unpaid_protocol_quote: balance::zero(),
        fee_split: launch.lp_fee_split(),
        creator_meme: balance::zero(),
        creator_quote: balance::zero(),
        auto_lp_meme: balance::zero(),
        auto_lp_quote: balance::zero(),
        rewards_meme: balance::zero(),
        rewards_quote: balance::zero(),
        burn_quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    };
    vault.id.add_dynamic_object_field(PositionKey<Venue>(), position);

    blast_events::vault_created<Meme, Quote, Venue>(
        vault.id.to_inner(),
        pool_id,
        position_id,
        vault.protocol_meme_residual.value(),
        vault.protocol_quote_residual.value(),
        liquidity,
        vault.fee_split,
    );

    vault
}

/// Burns `meme`, or sends it to `@0x0` when the supply is fixed, as migration does.
fun burn<Meme>(currency: &mut Currency<Meme>, mut meme: Balance<Meme>, ctx: &mut TxContext) {
    if (currency.is_supply_burn_only()) return currency.burn_balance(meme);

    let meme_amount = meme.value();
    meme.pay(meme_amount, @0x0, ctx);
    meme.destroy_zero();
}

// === Test-Only Functions ===

#[test_only]
/// Builds the vault `create` shares, left unshared for focused tests.
public fun new_for_testing<Meme, Quote, Venue, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    new(
        launch,
        venue,
        pool_id,
        position,
        liquidity,
        protocol_meme_residual,
        protocol_quote_residual,
        ctx,
    )
}

#[test_only]
/// Returns the ID of the position attached under `Venue`, or none for any other venue.
public fun position_id_for_testing<Meme, Quote, Venue>(self: &LpVault<Meme, Quote>): Option<ID> {
    dynamic_object_field::id(&self.id, PositionKey<Venue>())
}

#[test_only]
/// Returns the ID of the auto-LP position attached under `Venue`, or none before its first use.
public fun auto_lp_position_id_for_testing<Meme, Quote, Venue>(
    self: &LpVault<Meme, Quote>,
): Option<ID> {
    dynamic_object_field::id(&self.id, AutoLpPositionKey<Venue>())
}

#[test_only]
/// Returns the unclaimed protocol-owned Meme residual that migration left in the vault.
public fun protocol_meme_residual_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.protocol_meme_residual.value()
}

#[test_only]
/// Returns the unclaimed protocol-owned Quote residual that migration left in the vault.
public fun protocol_quote_residual_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.protocol_quote_residual.value()
}

#[test_only]
/// Returns the creator's current split of every collection after Blast's share.
public fun fee_split_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): FeeSplit {
    self.fee_split
}

#[test_only]
/// Returns the creator's unclaimed Meme and Quote LP fees.
public fun creator_balances_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64) {
    (self.creator_meme.value(), self.creator_quote.value())
}

#[test_only]
/// Returns the Meme and Quote waiting to be added back to the position.
public fun auto_lp_balances_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): (u64, u64) {
    (self.auto_lp_meme.value(), self.auto_lp_quote.value())
}

#[test_only]
/// Returns the partner the vault inherited from its launch.
public fun partner_id_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<ID> {
    self.partner_id
}

#[test_only]
/// Returns Blast's Meme and Quote LP fees held for the partner claim.
public fun unpaid_protocol_lp_fees_for_testing<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): (u64, u64) {
    (self.unpaid_protocol_meme.value(), self.unpaid_protocol_quote.value())
}

#[test_only]
/// Returns the Quote waiting to buy Meme back.
public fun burn_quote_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.burn_quote.value()
}

// === Errors ===

#[error(code = 0)]
const ENothingClaimable: vector<u8> = b"No protocol migration residuals are available to claim.";

#[error(code = 1)]
const EFeeSplitUnchanged: vector<u8> = b"Fee split proposal must differ from the current split.";

#[error(code = 2)]
const ENoCreatorFees: vector<u8> = b"No creator LP fees are available to claim.";

#[error(code = 3)]
const EZeroLiquidity: vector<u8> = b"Migration position must hold liquidity.";

#[error(code = 4)]
const ENoBuybackQuote: vector<u8> = b"No burn Quote is waiting to buy Meme back.";

#[error(code = 5)]
const EBuybackBelowMinimum: vector<u8> = b"Buyback must return at least the minimum Meme.";

#[error(code = 6)]
const EPartnerMismatch: vector<u8> = b"The partner is not the one the vault's launch named at creation.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::{
    allocation::FeeSplit,
    blast_fun_domain::{BuybackAdmin, TreasuryAdmin},
    creator_authority::CurveFeeCap,
    launch::Launch,
};

use blast_fun_migrators::{
    blast_events,
    lp_fee_policy::LpFeePolicy,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
};

use blast_partners::blast_partners::Partner;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    dynamic_object_field,
};

use fun pay as Balance.pay;
use fun pay_all as Balance.pay_all;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
use fun dynamic_object_field::exists as UID.has_dynamic_object_field;

use fun burn as Currency.burn;
