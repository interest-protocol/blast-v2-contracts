// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the payout's abort location.
#[allow(lint(abort_without_constant))]
/// How a successful presale's raise, after Blast's fee, is paid out: to recipients by share, and
/// optionally a share into a DEX pool at the creator's listing price, through one admitted adapter.
module blast_presale::payout;

// === Public Types ===

/// One recipient of `bps` of the raise after Blast's fee.
public struct Recipient has copy, drop, store {
    destination: address,
    bps: u64,
}

/// `bps` of the raise after Blast's fee goes into a new `token`/`quote` pool that opens at
/// `listing_quote` Quote per `listing_tokens` tokens, through the adapter that constructs `venue`,
/// at its pool tier in that venue's units.
public struct LiquidityTerms has copy, drop, store {
    token: TypeName,
    quote: TypeName,
    venue: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    bps: u64,
    listing_quote: u64,
    listing_tokens: u64,
}

/// The terms one adapter issued for one presale's pool. It cannot be copied, so an adapter's
/// venue reservation backs at most one presale.
public struct Liquidity(LiquidityTerms) has drop, store;

// === Public Functions ===

public fun recipient(destination: address, bps: u64): Recipient {
    assert!(destination != @0x0 && bps > 0, blast_presale::errors::invalid_recipient!());

    Recipient { destination, bps }
}

/// Liquidity for a `Token`/`Quote` pool through the adapter that constructs `Witness`. Only a
/// presale of that pair accepts it, and only when Blast admits that adapter.
public fun liquidity<Token, Quote, Witness: drop>(
    _: Witness,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    bps: u64,
    listing_quote: u64,
    listing_tokens: u64,
): Liquidity {
    assert!(
        bps > 0 && bps <= constants::basis_points_denominator!()
            && listing_quote > 0 && listing_tokens > 0,
        blast_presale::errors::invalid_liquidity!(),
    );

    Liquidity(LiquidityTerms {
        token: type_name::with_original_ids<Token>(),
        quote: type_name::with_original_ids<Quote>(),
        venue: type_name::with_original_ids<Witness>(),
        pool_tick_spacing,
        pool_fee_rate,
        bps,
        listing_quote,
        listing_tokens,
    })
}

/// The `(tick_spacing, fee_rate)` pool tier, in the adapter's venue units.
public fun pool_tier(self: &Liquidity): (u32, u64) {
    (self.0.pool_tick_spacing, self.0.pool_fee_rate)
}

// === Package Functions ===

public(package) fun terms(self: &Liquidity): LiquidityTerms {
    self.0
}

public(package) fun venue(self: &Liquidity): TypeName {
    self.0.venue
}

/// Whether the liquidity is for a `Token`/`Quote` pool.
public(package) fun is_for<Token, Quote>(self: &Liquidity): bool {
    self.0.token == type_name::with_original_ids<Token>()
        && self.0.quote == type_name::with_original_ids<Quote>()
}

/// Aborts unless there are at most sixteen recipients and their shares and the liquidity's sum to
/// exactly 10,000.
public(package) fun assert_shares(recipients: &vector<Recipient>, liquidity: &Option<Liquidity>) {
    let mut total = liquidity.map_ref!(|liquidity| liquidity.0.bps).destroy_or!(0);
    recipients.do_ref!(|recipient| total = total + recipient.bps);

    assert!(
        recipients.length() <= constants::max_recipients!()
            && total == constants::basis_points_denominator!(),
        blast_presale::errors::invalid_payout!(),
    );
}

/// The tokens the creator deposits for the pool: enough for the liquidity share of `max_quote`,
/// the most the tranches can raise, at the listing price, rounded down. Zero without liquidity.
public(package) fun reserve_down(liquidity: &Option<Liquidity>, max_quote: u64): u64 {
    liquidity
        .map_ref!(|liquidity| liquidity.tokens_down(liquidity.share_down(max_quote)))
        .destroy_or!(0)
}

/// Splits `net` Quote: each recipient and the liquidity get their share, rounded down, and the
/// first recipient also takes the remainder. Without recipients the liquidity takes all of `net`.
/// Returns each recipient's amount, in order, and the liquidity's.
public(package) fun split_down(
    recipients: &vector<Recipient>,
    liquidity: &Option<Liquidity>,
    net: u64,
): (vector<u64>, u64) {
    let pool_quote = liquidity.map_ref!(|liquidity| liquidity.share_down(net)).destroy_or!(0);
    let mut amounts = recipients.map_ref!(|recipient| {
        net.mul_div(recipient.bps, constants::basis_points_denominator!())
    });
    let mut paid = pool_quote;
    amounts.do_ref!(|amount| paid = paid + *amount);
    if (!amounts.is_empty()) *&mut amounts[0] = amounts[0] + (net - paid);

    (amounts, pool_quote)
}

/// The tokens `quote` buys at the listing price, rounded down.
public(package) fun tokens_down(self: &Liquidity, quote: u64): u64 {
    quote.mul_div(self.0.listing_tokens, self.0.listing_quote)
}

public(package) fun destination(self: &Recipient): address {
    self.destination
}

// === Private Functions ===

/// The liquidity's share of `quote`, rounded down.
fun share_down(self: &Liquidity, quote: u64): u64 {
    quote.mul_div(self.0.bps, constants::basis_points_denominator!())
}

// === Imports ===

use blast_presale::constants;

use std::type_name::{Self, TypeName};
