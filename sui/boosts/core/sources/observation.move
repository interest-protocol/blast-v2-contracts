// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Linear, operation-scoped observations supplied by a venue adapter.
///
/// These values prove neither source identity nor caller authority. The adapter
/// authenticates its venue and oracle sources before it constructs them, while
/// core uses each value exactly once during the enclosing operation.
module blast_boosts_core::observation;

// === Public Types ===

/// One normalized price and its source confidence and publication time.
///
/// Constructors require a positive price for priced operations.
public struct PriceObservation {
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
}

/// One venue-position and price snapshot for a single operation.
///
/// Constructors validate the structural fields before priced operations.
public struct PositionObservation {
    venue_equity: u64,
    /// Unsigned position size in base-asset atoms; direction is `observed_side`.
    position_base: u64,
    /// The same position valued in collateral atoms, also unsigned.
    position_collateral: u64,
    lot_size: u64,
    observed_side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    checkpoint_clean: bool,
    base_oracle: PriceObservation,
    collateral_oracle: PriceObservation,
    mark_price: u64,
}

/// The normalized result of one isolated funding settlement.
public enum FundingSettlement {
    None,
    Credit(u64),
    Cost(u64),
}

// === Public Functions ===

/// Creates one positive normalized price observation.
public fun new_price(
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
): PriceObservation {
    assert!(
        price > 0,
        blast_boosts_core::errors::invalid_price!(),
    );

    PriceObservation { price, confidence, publish_time_ms }
}

/// Creates one structurally consistent normalized position observation.
///
/// A flat position has zero base and zero notional. A non-flat position has
/// both values positive and base is an exact multiple of the venue lot size.
/// `observed_side` retains the venue's direction; it has no meaning while flat.
public fun new_position(
    venue_equity: u64,
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
    observed_side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    checkpoint_clean: bool,
    base_oracle: PriceObservation,
    collateral_oracle: PriceObservation,
    mark_price: u64,
): PositionObservation {
    assert!(
        lot_size > 0,
        blast_boosts_core::errors::invalid_observation_lot_size!(),
    );
    assert!(
        mark_price > 0,
        blast_boosts_core::errors::invalid_price!(),
    );
    assert!(
        is_position_structurally_valid(position_base, position_collateral, lot_size),
        blast_boosts_core::errors::invalid_position_observation!(),
    );

    PositionObservation {
        venue_equity,
        position_base,
        position_collateral,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_oracle,
        collateral_oracle,
        mark_price,
    }
}

/// Creates the no-settlement funding outcome.
public fun no_funding(): FundingSettlement {
    FundingSettlement::None
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

/// Consumes one price observation once core has read it.
public(package) fun destroy_price(self: PriceObservation) {
    let PriceObservation { .. } = self;
}

// --- Position Observation ---

/// Returns whether base, notional, and lot size form a normalized position.
///
/// This predicate never aborts, including for a zero lot. Strict operation
/// constructors and initialization assert it.
public(package) fun is_position_structurally_valid(
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
): bool {
    lot_size > 0
        && ((position_base == 0 && position_collateral == 0)
            || (position_base > 0
                && position_collateral > 0
                && position_base % lot_size == 0))
}

public(package) fun venue_equity(self: &PositionObservation): u64 { self.venue_equity }

public(package) fun position_base(self: &PositionObservation): u64 { self.position_base }

public(package) fun position_collateral(self: &PositionObservation): u64 { self.position_collateral }

public(package) fun lot_size(self: &PositionObservation): u64 { self.lot_size }

public(package) fun observed_side(self: &PositionObservation): PositionSide { self.observed_side }

public(package) fun pending_order_count(self: &PositionObservation): u64 { self.pending_order_count }

/// Returns whether the venue reports margin at or above its maintenance requirement.
public(package) fun is_margin_safe(self: &PositionObservation): bool { self.margin_safe }

/// Returns whether the market is neither paused nor frozen.
public(package) fun is_venue_operational(self: &PositionObservation): bool { self.venue_operational }

/// Returns whether venue bookkeeping matches the last accepted checkpoint.
public(package) fun is_checkpoint_clean(self: &PositionObservation): bool { self.checkpoint_clean }

/// Borrows the base asset's oracle price observation.
public(package) fun base_oracle(self: &PositionObservation): &PriceObservation { &self.base_oracle }

/// Borrows the collateral's oracle price observation.
public(package) fun collateral_oracle(self: &PositionObservation): &PriceObservation { &self.collateral_oracle }

public(package) fun mark_price(self: &PositionObservation): u64 { self.mark_price }

/// Consumes one position observation once core has read it.
public(package) fun destroy_position(self: PositionObservation) {
    let PositionObservation { base_oracle, collateral_oracle, .. } = self;
    base_oracle.destroy();
    collateral_oracle.destroy();
}

// --- Funding Settlement ---

public(package) fun is_cost(self: &FundingSettlement): bool {
    match (self) { FundingSettlement::Cost(_) => true, _ => false }
}

/// Returns the settled amount; zero for `None`.
public(package) fun amount(self: &FundingSettlement): u64 {
    match (self) {
        FundingSettlement::None => 0,
        FundingSettlement::Credit(amount) => *amount,
        FundingSettlement::Cost(amount) => *amount,
    }
}

/// Consumes one funding settlement once core has read it.
public(package) fun destroy_funding(self: FundingSettlement) {
    match (self) {
        FundingSettlement::None => (),
        FundingSettlement::Credit(_) => (),
        FundingSettlement::Cost(_) => (),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Injects a malformed position to exercise State's independent initialization guard.
public fun with_position_base_for_testing(
    mut self: PositionObservation,
    position_base: u64,
): PositionObservation {
    self.position_base = position_base;
    self
}

// === Public Aliases ===

public use fun destroy_price as PriceObservation.destroy;
public use fun destroy_position as PositionObservation.destroy;
public use fun destroy_funding as FundingSettlement.destroy;

// === Imports ===

use blast_boosts_core::policy::PositionSide;
