// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Operation-scoped observations supplied by a venue adapter.
///
/// These values prove neither source identity nor caller authority. The adapter
/// authenticates its venue and oracle sources before it constructs them; the
/// core reads them during the enclosing operation and never stores one.
module blast_boosts_core::observation;

// === Public Types ===

/// One normalized price and its source confidence and publication time.
///
/// Constructors require a positive price for priced operations.
public struct PriceObservation has drop {
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
}

/// The external facts one operation prices against: the venue position and
/// the oracle pair, as the adapter authenticated them.
///
/// The adapter has already refused a venue that is paused, under margin or
/// carrying orders; the core values what it is given.
public struct PositionObservation has drop {
    venue_equity: u64,
    /// Unsigned position size in base-asset atoms; direction is `observed_side`.
    position_base: u64,
    lot_size: u64,
    observed_side: PositionSide,
    base_oracle: PriceObservation,
    collateral_oracle: PriceObservation,
    mark_price: u64,
}

/// The normalized result of one isolated funding settlement.
public enum FundingSettlement has drop {
    Credit(u64),
    Cost(u64),
}

// === Public Functions ===

/// Creates one positive normalized price observation.
public fun new_price(
    price: u64,
    confidence: u64,
    price_published_at_ms: u64,
): PriceObservation {
    assert!(
        price > 0,
        blast_boosts_core::errors::invalid_price!(),
    );

    PriceObservation { price, confidence, publish_time_ms: price_published_at_ms }
}

/// Creates one position observation; base is whole lots and the mark is positive.
///
/// `observed_side` retains the venue's direction; it has no meaning while flat.
public fun new_position(
    venue_equity: u64,
    position_base: u64,
    lot_size: u64,
    observed_side: PositionSide,
    base_oracle: PriceObservation,
    collateral_oracle: PriceObservation,
    mark_price: u64,
): PositionObservation {
    assert!(lot_size > 0, blast_boosts_core::errors::invalid_observation_lot_size!());
    assert!(mark_price > 0, blast_boosts_core::errors::invalid_price!());
    assert!(position_base % lot_size == 0, blast_boosts_core::errors::invalid_position_observation!());

    PositionObservation { venue_equity, position_base, lot_size, observed_side, base_oracle, collateral_oracle, mark_price }
}

/// Creates a credit funding outcome.
public fun funding_credit(amount: u64): FundingSettlement {
    FundingSettlement::Credit(amount)
}

/// Creates a cost funding outcome.
public fun funding_cost(amount: u64): FundingSettlement {
    FundingSettlement::Cost(amount)
}

// === Package Functions ===

// --- Price Observation ---

public(package) fun price(self: &PriceObservation): u64 { self.price }

public(package) fun confidence(self: &PriceObservation): u64 { self.confidence }

public(package) fun publish_time_ms(self: &PriceObservation): u64 { self.publish_time_ms }

// --- Position Observation ---

public(package) fun venue_equity(self: &PositionObservation): u64 { self.venue_equity }

public(package) fun position_base(self: &PositionObservation): u64 { self.position_base }

public(package) fun lot_size(self: &PositionObservation): u64 { self.lot_size }

public(package) fun observed_side(self: &PositionObservation): PositionSide { self.observed_side }

/// Borrows the base asset's oracle price observation.
public(package) fun base_oracle(self: &PositionObservation): &PriceObservation { &self.base_oracle }

/// Borrows the collateral's oracle price observation.
public(package) fun collateral_oracle(self: &PositionObservation): &PriceObservation { &self.collateral_oracle }

public(package) fun mark_price(self: &PositionObservation): u64 { self.mark_price }

// --- Funding Settlement ---

public(package) fun is_cost(self: &FundingSettlement): bool {
    match (self) { FundingSettlement::Cost(_) => true, _ => false }
}

/// Returns the settled amount.
public(package) fun amount(self: &FundingSettlement): u64 {
    match (self) {
        FundingSettlement::Credit(amount) => *amount,
        FundingSettlement::Cost(amount) => *amount,
    }
}

// === Imports ===

use blast_boosts_core::policy::PositionSide;
