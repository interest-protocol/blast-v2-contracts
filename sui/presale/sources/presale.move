// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the presale's abort location.
#[allow(lint(abort_without_constant))]
/// A fixed-price token presale in tranches.
///
/// The creator deposits exactly the tokens its tranches sell, plus, when part of the raise goes
/// into a DEX pool, the tokens that pool can need. Buyers commit Quote to open tranches. Once every
/// tranche has ended anyone finalizes the presale. If it raised its minimum, Blast takes its fee,
/// the recipients are paid their shares of the rest, and the liquidity share waits, with the
/// tokens it buys at the listing price, for the presale's adapter to open the pool from the claim
/// time; unsold and unused tokens go back to the creator. Each buyer then claims its tokens from
/// the claim time, vested per tranche, and any pro-rata refund at once. If it did not raise its
/// minimum, every token goes back to the creator and every commit back to its buyer.
module blast_presale::presale;

// === Public Types ===

public enum Status has copy, drop, store {
    Open,
    Succeeded,
    Failed,
}

/// Dynamic-field name of one buyer's position in one tranche.
public struct PositionKey(address, u64) has copy, drop, store;

/// One buyer's Quote in one tranche, and what it has claimed.
public struct Position has drop, store {
    committed: u64,
    claimed_tokens: u64,
    refunded: bool,
}

/// One presale of `Token` for `Quote`, holding the unsold tokens and the committed Quote.
public struct BlastPresale<phantom Token, phantom Quote> has key {
    id: UID,
    creator: address,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
    /// Blast's fee on the raise, snapshotted at creation.
    fee_bps: u64,
    recipients: vector<Recipient>,
    /// The pool share until the adapter takes it; none without one, after a failure, or when the
    /// raise bought no pool tokens.
    liquidity: Option<Liquidity>,
    status: Status,
    tokens: Balance<Token>,
    quote: Balance<Quote>,
    /// The tokens reserved for the pool, then, after a success, the pool's tokens.
    liquidity_tokens: Balance<Token>,
    /// The pool's Quote after a success.
    liquidity_quote: Balance<Quote>,
}

// === Public Functions ===

/// Creates a presale selling tokens through `tranches`, at Blast's current fee. It fails unless
/// the tranches raise `min_raise` in total (zero for no minimum), and buyers claim tokens from
/// `claim_ms`, which is no earlier than the last tranche's end. After Blast's fee, the raise is
/// paid to `recipients` and any `liquidity` by share. `tokens` is exactly what the tranches sell
/// plus the pool reserve: the tokens the liquidity share of the whole tranches' Quote buys at the
/// listing price. The sender is the creator.
public fun new<Token, Quote>(
    package_version: &PackageVersion,
    config: &BlastPresaleConfig,
    tokens: Coin<Token>,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
    recipients: vector<Recipient>,
    liquidity: Option<Liquidity>,
    clock: &Clock,
    ctx: &mut TxContext,
): BlastPresale<Token, Quote> {
    package_version.assert_current();
    assert!(
        type_name::with_original_ids<Token>() != type_name::with_original_ids<Quote>(),
        blast_presale::errors::invalid_token_quote_pair!(),
    );
    let count = tranches.length();
    assert!(
        count > 0 && count <= constants::max_tranches!(),
        blast_presale::errors::invalid_tranche_count!(),
    );
    let now_ms = clock.timestamp_ms();
    assert!(
        tranches.all!(|tranche| tranche.end_ms() > now_ms),
        blast_presale::errors::tranche_already_ended!(),
    );
    payout::assert_shares(&recipients, &liquidity);
    assert!(
        liquidity.map_ref!(|liquidity| liquidity.is_for<Token, Quote>()).destroy_or!(true),
        blast_presale::errors::invalid_liquidity!(),
    );
    let admitted = liquidity.map_ref!(|liquidity| config.is_adapter_allowed(liquidity.venue()));
    assert!(admitted.destroy_or!(true), blast_presale::errors::adapter_not_allowed!());
    let (mut total_tokens, mut total_quote) = (0, 0);
    tranches.do_ref!(|tranche| {
        total_tokens = total_tokens + tranche.tokens();
        total_quote = total_quote + tranche.quote();
    });
    let reserve = payout::reserve_down(&liquidity, total_quote);
    assert!(
        tokens.value() == total_tokens + reserve,
        blast_presale::errors::token_deposit_mismatch!(),
    );
    assert!(
        tranches.all!(|tranche| claim_ms >= tranche.end_ms()),
        blast_presale::errors::invalid_claim_time!(),
    );
    assert!(min_raise <= total_quote, blast_presale::errors::invalid_min_raise!());

    let mut tokens = tokens.into_balance();
    let presale = BlastPresale {
        id: object::new(ctx),
        creator: ctx.sender(),
        tranches,
        min_raise,
        claim_ms,
        fee_bps: config.fee_bps(),
        recipients,
        liquidity,
        status: Status::Open,
        liquidity_tokens: tokens.split(reserve),
        tokens,
        quote: balance::zero(),
        liquidity_quote: balance::zero(),
    };

    events::presale_created<Token, Quote>(
        presale.id.to_inner(),
        presale.tranches,
        min_raise,
        claim_ms,
        presale.fee_bps,
        presale.recipients,
        presale.liquidity,
    );

    presale
}

/// Shares the presale; each tranche accepts commits from its start.
public fun share<Token, Quote>(self: BlastPresale<Token, Quote>) {
    transfer::share_object(self);
}

/// Commits `quote_in` to public tranche `tranche` for the sender and returns what the tranche did
/// not accept: the excess over a first-come tranche's remaining Quote or over its wallet cap.
public fun commit<Token, Quote>(
    self: &mut BlastPresale<Token, Quote>,
    package_version: &PackageVersion,
    tranche: u64,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current();
    self.assert_committable(tranche, false, &quote_in, clock);
    let cap = self.tranches[tranche].wallet_cap();

    self.accept_commit(tranche, quote_in, cap, ctx)
}

/// Commits `quote_in` to whitelisted tranche `tranche` for the sender, proven by leaf `index`
/// allowing it `max_quote` (zero for no limit), and returns what the tranche did not accept.
public fun commit_whitelisted<Token, Quote>(
    self: &mut BlastPresale<Token, Quote>,
    package_version: &PackageVersion,
    tranche: u64,
    quote_in: Coin<Quote>,
    index: u64,
    max_quote: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current();
    self.assert_committable(tranche, true, &quote_in, clock);
    assert!(
        self.tranches[tranche].is_listed(index, ctx.sender(), max_quote, &proof),
        blast_presale::errors::invalid_whitelist_proof!(),
    );

    self.accept_commit(tranche, quote_in, max_quote, ctx)
}

/// Closes the presale once every tranche has ended. If the tranches raised the minimum, Blast's
/// fee, rounded up, goes to the configured destination, the recipients are paid their shares of
/// the rest, and the liquidity share and the tokens it buys at the listing price wait for the
/// adapter; the creator gets back the unsold tokens and the unused pool reserve. Otherwise every
/// token goes back to the creator and every commit becomes refundable. Anyone may finalize.
public fun finalize<Token, Quote>(
    self: &mut BlastPresale<Token, Quote>,
    package_version: &PackageVersion,
    config: &BlastPresaleConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    assert!(self.status == Status::Open, blast_presale::errors::presale_finalized!());
    let now_ms = clock.timestamp_ms();
    assert!(
        self.tranches.all!(|tranche| now_ms >= tranche.end_ms()),
        blast_presale::errors::presale_not_ended!(),
    );

    let (mut raised, mut sold) = (0, 0);
    self.tranches.do_ref!(|tranche| {
        raised = raised + tranche.raised();
        sold = sold + tranche.sold_down();
    });
    let succeeded = raised >= self.min_raise;
    let fee = if (succeeded) {
        raised.mul_div_ceil(self.fee_bps, constants::basis_points_denominator!())
    } else 0;
    let (amounts, pool_quote) = payout::split_down(&self.recipients, &self.liquidity, raised - fee);
    let pool_tokens = self.liquidity.map_ref!(|liquidity| liquidity.tokens_down(pool_quote));
    let pool_tokens = pool_tokens.destroy_or!(0);
    let pooled = succeeded && pool_quote > 0 && pool_tokens > 0;
    let fee_destination = config.fee_destination();
    let (presale_id, creator) = (self.id.to_inner(), self.creator);

    self.status = if (succeeded) Status::Succeeded else Status::Failed;
    let mut returned = self.tokens.withdraw_all();
    returned.join(self.liquidity_tokens.withdraw_all());
    if (succeeded) {
        self.tokens.join(returned.split(sold));
        send(self.quote.split(fee), fee_destination, ctx);
        self.recipients.length().do!(|i| {
            let destination = self.recipients[i].destination();
            send(self.quote.split(amounts[i]), destination, ctx);
            events::proceeds_paid(presale_id, destination, amounts[i]);
        });
    };
    if (pooled) {
        self.liquidity_tokens.join(returned.split(pool_tokens));
        self.liquidity_quote.join(self.quote.split(pool_quote));
    } else {
        // A failed presale or an empty pool share leaves nothing for an adapter; the pool's Quote
        // share, if any, goes to the creator.
        self.liquidity = option::none();
        if (succeeded) send(self.quote.split(pool_quote), creator, ctx);
    };
    let returned_value = returned.value();
    send(returned, creator, ctx);

    events::presale_finalized(
        presale_id,
        succeeded,
        raised,
        fee,
        fee_destination,
        returned_value,
        self.liquidity_quote.value(),
        self.liquidity_tokens.value(),
    );
}

/// Hands the pool's tokens and Quote, with its terms, to the adapter the presale named, once,
/// from the claim time, so the pool opens when buyers can claim.
public fun take_liquidity<Token, Quote, Adapter: drop>(
    self: &mut BlastPresale<Token, Quote>,
    package_version: &PackageVersion,
    _: Adapter,
    clock: &Clock,
): (Balance<Token>, Balance<Quote>, Liquidity) {
    package_version.assert_current();
    assert!(self.status != Status::Open, blast_presale::errors::presale_not_finalized!());
    assert!(self.liquidity.is_some(), blast_presale::errors::no_liquidity!());
    assert!(
        self.liquidity.borrow().venue() == type_name::with_original_ids<Adapter>(),
        blast_presale::errors::invalid_adapter!(),
    );
    assert!(
        clock.timestamp_ms() >= self.claim_ms,
        blast_presale::errors::liquidity_not_open!(),
    );

    let liquidity = self.liquidity.extract();
    let tokens = self.liquidity_tokens.withdraw_all();
    let quote = self.liquidity_quote.withdraw_all();

    events::liquidity_taken(self.id.to_inner(), tokens.value(), quote.value());

    (tokens, quote, liquidity)
}

/// Sends `buyer` what its position in tranche `tranche` can claim now. After a success that is its
/// vested tokens, from the claim time, and at once any pro-rata refund; after a failure, its whole
/// commit. A position that has paid everything is deleted. Anyone may claim for a buyer.
public fun claim<Token, Quote>(
    self: &mut BlastPresale<Token, Quote>,
    package_version: &PackageVersion,
    tranche: u64,
    buyer: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    assert!(self.status != Status::Open, blast_presale::errors::presale_not_finalized!());
    let key = PositionKey(buyer, tranche);
    assert!(self.id.has_position(key), blast_presale::errors::nothing_to_claim!());

    let succeeded = self.status == Status::Succeeded;
    let terms = self.tranches[tranche];
    let claim_ms = self.claim_ms;
    let position = self.id.position_mut<_, Position>(key);
    let (tokens, quote, settled) = if (succeeded) {
        let (owed, refund) = terms.owed_down(position.committed);
        let vested = terms.vested_down(owed, claim_ms, clock.timestamp_ms());
        let quote = if (position.refunded) 0 else refund;
        let tokens = vested - position.claimed_tokens;
        position.claimed_tokens = vested;
        position.refunded = true;
        (tokens, quote, vested == owed)
    } else (0, position.committed, true);
    assert!(tokens > 0 || quote > 0 || settled, blast_presale::errors::nothing_to_claim!());

    if (settled) {
        let _: Position = self.id.remove_position(key);
    };
    send(self.tokens.split(tokens), buyer, ctx);
    send(self.quote.split(quote), buyer, ctx);

    events::claimed(self.id.to_inner(), tranche, buyer, tokens, quote);
}

/// The creator, who receives the unsold tokens and, through an adapter's vault, the pool's fees.
public fun creator<Token, Quote>(self: &BlastPresale<Token, Quote>): address {
    self.creator
}

// === Private Functions ===

/// Aborts unless `tranche` exists, matches the commit's kind, is open now, and `quote_in` is not
/// zero.
fun assert_committable<Token, Quote>(
    self: &BlastPresale<Token, Quote>,
    tranche: u64,
    whitelisted: bool,
    quote_in: &Coin<Quote>,
    clock: &Clock,
) {
    assert!(tranche < self.tranches.length(), blast_presale::errors::unknown_tranche!());
    let terms = &self.tranches[tranche];
    assert!(
        terms.is_whitelisted() == whitelisted,
        blast_presale::errors::tranche_access_mismatch!(),
    );
    assert!(terms.is_open(clock.timestamp_ms()), blast_presale::errors::tranche_not_open!());
    assert!(quote_in.value() > 0, blast_presale::errors::zero_commit!());
}

/// Accepts what `tranche` takes of `quote_in` from the sender under `cap` into its position and
/// returns the rest.
fun accept_commit<Token, Quote>(
    self: &mut BlastPresale<Token, Quote>,
    tranche: u64,
    mut quote_in: Coin<Quote>,
    cap: u64,
    ctx: &TxContext,
): Coin<Quote> {
    let key = PositionKey(ctx.sender(), tranche);
    let has_position = self.id.has_position(key);
    let position = if (has_position) self.id.position<_, Position>(key).committed else 0;
    let accepted = self.tranches[tranche].accept(quote_in.value(), position, cap);

    if (has_position) {
        let position = self.id.position_mut<_, Position>(key);
        position.committed = position.committed + accepted;
    } else {
        let position = Position { committed: accepted, claimed_tokens: 0, refunded: false };
        self.id.add_position(key, position);
    };
    self.quote.join(quote_in.balance_mut().split(accepted));

    events::committed(self.id.to_inner(), tranche, accepted, self.tranches[tranche].committed());

    quote_in
}

/// Sends `balance` to `recipient` as a coin, or destroys it when empty.
fun send<T>(balance: Balance<T>, recipient: address, ctx: &mut TxContext) {
    if (balance.value() == 0) balance.destroy_zero()
    else transfer::public_transfer(balance.into_coin(ctx), recipient);
}

// === Test-Only Functions ===

#[test_only]
/// Returns the tokens and Quote the presale holds for buyers.
public fun balances_for_testing<Token, Quote>(self: &BlastPresale<Token, Quote>): (u64, u64) {
    (self.tokens.value(), self.quote.value())
}

#[test_only]
/// Returns the tokens and Quote the presale holds for the pool.
public fun liquidity_balances_for_testing<Token, Quote>(
    self: &BlastPresale<Token, Quote>,
): (u64, u64) {
    (self.liquidity_tokens.value(), self.liquidity_quote.value())
}

#[test_only]
/// Returns the position's `(committed, claimed_tokens, refunded)`, or `None` without one.
public fun position_for_testing<Token, Quote>(
    self: &BlastPresale<Token, Quote>,
    buyer: address,
    tranche: u64,
): Option<vector<u64>> {
    let key = PositionKey(buyer, tranche);

    if (!self.id.has_position(key)) option::none()
    else {
        let position = self.id.position<_, Position>(key);
        option::some(vector[
            position.committed,
            position.claimed_tokens,
            if (position.refunded) 1 else 0,
        ])
    }
}

#[test_only]
public fun is_open_for_testing<Token, Quote>(self: &BlastPresale<Token, Quote>): bool {
    self.status == Status::Open
}

#[test_only]
public fun is_succeeded_for_testing<Token, Quote>(self: &BlastPresale<Token, Quote>): bool {
    self.status == Status::Succeeded
}

#[test_only]
public fun is_failed_for_testing<Token, Quote>(self: &BlastPresale<Token, Quote>): bool {
    self.status == Status::Failed
}

#[test_only]
public fun fee_bps_for_testing<Token, Quote>(self: &BlastPresale<Token, Quote>): u64 {
    self.fee_bps
}

// === Imports ===

use blast_presale::{
    constants,
    events,
    package_version::PackageVersion,
    payout::{Self, Liquidity, Recipient},
    presale_config::BlastPresaleConfig,
    tranche::Tranche,
};

use std::type_name;

use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_field};

use fun dynamic_field::add as UID.add_position;

use fun dynamic_field::borrow as UID.position;

use fun dynamic_field::borrow_mut as UID.position_mut;

use fun dynamic_field::exists as UID.has_position;

use fun dynamic_field::remove as UID.remove_position;
