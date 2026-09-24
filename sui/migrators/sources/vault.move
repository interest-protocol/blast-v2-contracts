// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed dynamic-object custody for migration positions, their protocol residuals, and the
/// balances every LP-fee collection is split into.
module blast_fun_migrators::vault;

// === Errors ===

#[error(code = 0)]
const EWrongVenue: vector<u8> = b"Venue witness must match the vault's attached position marker.";

#[error(code = 1)]
const ENothingClaimable: vector<u8> = b"No protocol migration residuals are available to claim.";

#[error(code = 2)]
const EFeeSplitUnchanged: vector<u8> = b"Fee split proposal must differ from the current split.";

#[error(code = 3)]
const ENoCreatorFees: vector<u8> = b"No creator LP fees are available to claim.";

#[error(code = 4)]
const EZeroLiquidity: vector<u8> = b"Migration position must hold liquidity.";

#[error(code = 5)]
const ENoBuybackQuote: vector<u8> = b"No burn Quote is waiting to buy Meme back.";

#[error(code = 6)]
const EBuybackBelowMinimum: vector<u8> = b"Buyback must return at least the minimum Meme.";

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
/// the current one are settled, so each fee follows the split it accrued under.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    generation: u64,
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

/// Claims the protocol-owned migration residuals under a live admin witness.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
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

/// Creates unshared vault state whose address can be bound into an external position, holding
/// the launch's fee split.
public(package) fun prepare<Meme, Quote>(
    launch: &Launch<Meme, Quote>,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    LpVault {
        id: object::new(ctx),
        pool_id: object::id_from_address(@0x0),
        protocol_meme_residual,
        protocol_quote_residual,
        generation: 0,
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
    }
}

/// Attaches the exact venue position, holding `liquidity`, while retaining owned vault construction
/// state.
public(package) fun attach<Meme, Quote, Venue, Position: key + store>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
) {
    assert!(liquidity > 0, EZeroLiquidity);

    self.pool_id = pool_id;
    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(PositionKey<Venue>(), position);

    blast_events::vault_created<Meme, Quote, Venue>(
        self.id.to_inner(),
        pool_id,
        position_id,
        self.protocol_meme_residual.value(),
        self.protocol_quote_residual.value(),
        liquidity,
        self.fee_split,
    );
}

/// Shares a fully attached vault; attachment already emitted the custody record.
public(package) fun share<Meme, Quote, Venue>(self: LpVault<Meme, Quote>, _venue: &Venue) {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );
    transfer::share_object(self);
}

/// Mutably borrows the venue position without providing a removal path.
public(package) fun position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Immutably borrows the exact attached venue position for atomic settlement validation.
public(package) fun position<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &LpVault<Meme, Quote>,
    _venue: &Venue,
): &Position {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    self.id.dynamic_object_field(PositionKey<Venue>())
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
/// then the creator, auto-LP, and rewards shares into their balances, the burn share's Meme burned
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
    let (meme_share, quote_share) = policy.shares<Meme>();
    let protocol_meme = meme_share.apply_up(gross_meme);
    let protocol_quote = quote_share.apply_up(gross_quote);
    let (creator_meme, auto_lp_meme, rewards_meme, burn_meme, recipient_meme) = self
        .fee_split
        .apportion_fee_split(gross_meme - protocol_meme);
    let (creator_quote, auto_lp_quote, rewards_quote, burn_quote, recipient_quote) = self
        .fee_split
        .apportion_fee_split(gross_quote - protocol_quote);
    let protocol_destination = policy.protocol_destination();
    let recipients = *self.fee_split.recipients();

    meme.pay(protocol_meme, protocol_destination, ctx);
    quote.pay(protocol_quote, protocol_destination, ctx);
    self.creator_meme.join(meme.split(creator_meme));
    self.creator_quote.join(quote.split(creator_quote));
    self.auto_lp_meme.join(meme.split(auto_lp_meme));
    self.auto_lp_quote.join(quote.split(auto_lp_quote));
    self.rewards_meme.join(meme.split(rewards_meme));
    self.rewards_quote.join(quote.split(rewards_quote));
    burn(currency, meme.split(burn_meme), ctx);
    self.burn_quote.join(quote.split(burn_quote));
    recipients.length().do!(|i| {
        meme.pay(recipient_meme[i], recipients[i].destination(), ctx);
        quote.pay(recipient_quote[i], recipients[i].destination(), ctx);
    });
    meme.destroy_zero();
    quote.destroy_zero();

    if (gross_meme == 0 && gross_quote == 0) return;
    blast_events::fees_collected(
        self.id.to_inner(),
        self.generation,
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
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
): Balance<Quote> {
    admin_witness.assert_role(blast_fun_domain::buyback_admin_role());
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

    burn(currency, meme, ctx);
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

/// Commits `proposed` as the next split generation under the launch's live curve-fee cap. The
/// adapter settles the fees accrued under the current split first, in the same call.
public(package) fun update_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    proposed: FeeSplit,
) {
    launch.assert_curve_fee_cap(curve_fee_cap);
    assert!(proposed != self.fee_split, EFeeSplitUnchanged);
    let old_generation = self.generation;
    let old_fee_split = self.fee_split;

    self.fee_split = proposed;
    self.generation = old_generation + 1;

    blast_events::fee_split_changed(
        self.id.to_inner(),
        old_generation,
        self.generation,
        old_fee_split,
        proposed,
    );
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

// === Private Functions ===

fun pay<T>(balance: &mut Balance<T>, amount: u64, destination: address, ctx: &mut TxContext) {
    if (amount > 0) transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
}

/// Burns `meme`, or sends it to `@0x0` when the supply is fixed, as migration does.
fun burn<Meme>(currency: &mut Currency<Meme>, mut meme: Balance<Meme>, ctx: &mut TxContext) {
    if (currency.is_supply_burn_only()) return currency.burn_balance(meme);
    let amount = meme.value();

    meme.pay(amount, @0x0, ctx);
    meme.destroy_zero();
}

// === Test-Only Functions ===

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
/// Returns the split generation stamped on every collection.
public fun generation_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.generation
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
/// Returns the Quote waiting to buy Meme back.
public fun burn_quote_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.burn_quote.value()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::FeeSplit,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    creator_authority::CurveFeeCap,
    launch::Launch,
};

use blast_fun_migrators::{
    blast_events,
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion as MigratorsVersion,
};

use sui::{balance::{Self, Balance}, coin::Coin, coin_registry::Currency, dynamic_object_field};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;

use fun dynamic_object_field::exists as UID.has_dynamic_object_field;

use fun pay as Balance.pay;
