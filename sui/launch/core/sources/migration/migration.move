// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the hand-off's abort location.
#[allow(lint(abort_without_constant))]
/// The sealed contract between a sale and the venue that migrates it.
///
/// Before supply leaves the sale's `TreasuryCap`, a venue prepares the coin and returns a
/// `VenueTicket` sealed by its witness; the product admits and stores the ticket's venue. At
/// migration the product creates a `Migration` sealed by its own witness, carrying the pool's
/// balances and the new vault's terms, and only the stored venue's witness can redeem it. Neither
/// the ticket nor the migration can be dropped, copied, or stored, so a transaction completes the
/// migration whole or aborts.
///
/// Every witness is identified by `type_name::with_original_ids`, which stays fixed across
/// upgrades of the venue or product package; allowlists that admit these names must use the same
/// form.
///
/// The module also derives the price a concentrated-liquidity venue seeds the pool at, and whether
/// both such venues can seed it, so a product can refuse a sale that could never migrate.
module blast_core::migration;

// === Public Types ===

/// What happens to the migration residuals the pool does not take.
public enum ResidualPolicy has copy, drop, store {
    /// Paid to Blast through the vault's protocol ledger.
    Protocol,
    /// Held in the vault for the sale's owner to claim.
    Owner,
}

/// Everything a new vault snapshots from the sale that sealed its terms. Sealed terms authorize a
/// vault, so products and venues must not return them by value: a venue takes them only from
/// `redeem`.
public struct VaultTerms has copy, drop, store {
    /// The launch or presale the vault belongs to; owner proofs name it.
    origin: ID,
    /// The original type of the package witness that sealed the terms; owner proofs must name it.
    package_witness: TypeName,
    fee_split: FeeSplit,
    /// Blast's share of each LP-fee collection, per asset.
    protocol_meme_bps: Bps,
    protocol_quote_bps: Bps,
    partner_id: Option<ID>,
    residuals: ResidualPolicy,
}

/// A venue's sealed ticket for the `Meme` and `Quote` pair it prepared, redeemed by the product
/// that admits it for a sale of exactly that pair. The venue keeps the pair's pool tier and any
/// reserved pool-creation authority itself (ADR 0137).
public struct VenueTicket<phantom Meme, phantom Quote> {
    venue: TypeName,
}

/// One sale's pool balances and vault terms, redeemable only by `venue`.
public struct Migration<phantom Meme, phantom Quote> {
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    venue: TypeName,
    terms: VaultTerms,
}

// === Public Functions ===

/// Residuals paid to Blast through the vault's protocol ledger.
public fun residuals_to_protocol(): ResidualPolicy { ResidualPolicy::Protocol }

/// Residuals held in the vault for the sale's owner to claim.
public fun residuals_to_owner(): ResidualPolicy { ResidualPolicy::Owner }

/// Issues a ticket for the `Meme` and `Quote` pair the venue has prepared, sealed under its
/// witness `Venue`.
public fun issue_ticket<Meme, Quote, Venue: drop>(_: Venue): VenueTicket<Meme, Quote> {
    VenueTicket { venue: type_name::with_original_ids<Venue>() }
}

/// Redeems a ticket, returning the venue witness type to admit and store.
public fun redeem_ticket<Meme, Quote>(self: VenueTicket<Meme, Quote>): TypeName {
    let VenueTicket { venue } = self;

    venue
}

/// The original type of the venue witness that issued the ticket. Called as `ticket.venue()`;
/// `redeem_ticket` stays the ticket's one consuming path.
public fun ticket_venue<Meme, Quote>(self: &VenueTicket<Meme, Quote>): TypeName { self.venue }

/// A vault's terms, sealed under the sale product's `PackageWitness` by borrowing the sale's
/// `origin` UID; owner proofs for the vault must come from the same witness. Each Blast share is at
/// most `constants::max_lp_fee_bps!()`, 3,000 basis points, so a vault trusts sealed terms.
public fun vault_terms<PackageWitness: drop>(
    _: PackageWitness,
    origin: &UID,
    fee_split: FeeSplit,
    protocol_meme_bps: Bps,
    protocol_quote_bps: Bps,
    partner_id: Option<ID>,
    residuals: ResidualPolicy,
): VaultTerms {
    assert!(
        protocol_meme_bps.value() <= constants::max_lp_fee_bps!()
            && protocol_quote_bps.value() <= constants::max_lp_fee_bps!(),
        blast_core::errors::invalid_lp_fee_bps!(),
    );

    VaultTerms {
        origin: origin.to_inner(),
        package_witness: type_name::with_original_ids<PackageWitness>(),
        fee_split,
        protocol_meme_bps,
        protocol_quote_bps,
        partner_id,
        residuals,
    }
}

/// Creates a sale's migration under its `PackageWitness`, for the stored `venue`, with terms the
/// same package witness sealed.
public fun new<Meme, Quote, PackageWitness: drop>(
    _: PackageWitness,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    venue: TypeName,
    terms: VaultTerms,
): Migration<Meme, Quote> {
    assert!(
        terms.package_witness == type_name::with_original_ids<PackageWitness>(),
        blast_core::errors::wrong_package_witness!(),
    );

    Migration { meme, quote, venue, terms }
}

/// Redeems the migration under the stored venue's witness `Venue`, returning the pool's balances
/// and the vault's terms. Aborts for any other venue.
public fun redeem<Meme, Quote, Venue: drop>(
    self: Migration<Meme, Quote>,
    _: Venue,
): (Balance<Meme>, Balance<Quote>, VaultTerms) {
    let redeeming_venue = type_name::with_original_ids<Venue>();
    assert!(self.venue == redeeming_venue, blast_core::errors::wrong_venue!());

    let Migration { meme, quote, venue: _, terms } = self;

    (meme, quote, terms)
}

/// The original type of the only venue witness that can redeem the migration.
public fun venue<Meme, Quote>(self: &Migration<Meme, Quote>): TypeName { self.venue }

/// The Meme and Quote the migration carries to the pool. Only `redeem` releases them.
public fun balances<Meme, Quote>(self: &Migration<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

/// The vault's terms the migration carries. A copy authorizes nothing: an admitted venue never
/// takes terms from its caller, and each sale has one vault.
public fun terms<Meme, Quote>(self: &Migration<Meme, Quote>): &VaultTerms { &self.terms }

/// The launch or presale the vault belongs to.
public fun origin(self: &VaultTerms): ID { self.origin }

/// The original type of the package witness that sealed the terms.
public fun package_witness(self: &VaultTerms): TypeName { self.package_witness }

/// The fee split the vault starts with.
public fun fee_split(self: &VaultTerms): FeeSplit { self.fee_split }

/// Blast's share of each LP-fee collection, Meme then Quote.
public fun protocol_bps(self: &VaultTerms): (Bps, Bps) {
    (self.protocol_meme_bps, self.protocol_quote_bps)
}

/// The partner the sale named, if any.
public fun partner_id(self: &VaultTerms): Option<ID> { self.partner_id }

/// What happens to the migration residuals.
public fun residuals(self: &VaultTerms): ResidualPolicy { self.residuals }

/// Whether the policy pays residuals to Blast.
public fun is_protocol(self: &ResidualPolicy): bool { *self == ResidualPolicy::Protocol }

/// Whether the policy holds residuals for the sale's owner.
public fun is_owner(self: &ResidualPolicy): bool { *self == ResidualPolicy::Owner }

// Pool price

/// The pool's seed price from the migration's atomic amounts, `floor(sqrt(B / A) * 2^64)` in the
/// Q64.64 form concentrated-liquidity venues take: B / A is Quote / Meme when Meme is coin A, and
/// Meme / Quote otherwise. Display decimals never enter it. A zero divisor amount (Meme when it
/// is coin A, Quote otherwise) aborts with an arithmetic error.
public fun sqrt_price_x64(meme_amount: u64, quote_amount: u64, meme_is_coin_a: bool): u128 {
    let (numerator, denominator) = if (meme_is_coin_a) (quote_amount, meme_amount)
    else (meme_amount, quote_amount);
    let ratio_q128 = ((numerator as u256) << 128) / (denominator as u256);

    // A positive u64 / u64 ratio in Q128 is below 2^192, so its square root is below 2^96.
    let mut low = 0u256;
    let mut high = 1u256 << 96;
    while (low + 1 < high) {
        let middle = (low + high) / 2;
        if (middle * middle <= ratio_q128) low = middle else high = middle;
    };

    low as u128
}

/// Whether Cetus and Bluefin can both seed a full-range pool at `sqrt_price_x64`. Both venues
/// share the same `tick_math` sqrt-price bounds; halving the range keeps the price inside any
/// full range aligned inward to a tick spacing. The bounds are reciprocal, so either coin order
/// agrees.
public fun is_seedable_price(sqrt_price_x64: u128): bool {
    let min_seed = constants::min_sqrt_price_x64!() * 2;
    let max_seed = ((1u256 << 128) / ((min_seed + 1) as u256)) as u128;

    sqrt_price_x64 > min_seed && sqrt_price_x64 <= max_seed
}

// === Test-Only Types ===

#[test_only]
/// A venue witness for tests that redeem a hand-off without a venue package.
public struct TestVenue() has drop;

#[test_only]
/// A package witness for tests that seal terms and create a hand-off without a product.
public struct TestIssuer() has drop;

// === Test-Only Functions ===

#[test_only]
public fun test_venue(): TestVenue { TestVenue() }

#[test_only]
public fun test_issuer(): TestIssuer { TestIssuer() }

// === Imports ===

public use fun ticket_venue as VenueTicket.venue;

use blast_core::{bps::Bps, constants, fee_split::FeeSplit};

use std::type_name::{Self, TypeName};

use sui::balance::Balance;
