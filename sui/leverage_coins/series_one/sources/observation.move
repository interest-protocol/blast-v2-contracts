/// Linear, operation-scoped observations supplied by a venue adapter.
///
/// These values prove neither source identity nor caller authority. The adapter
/// authenticates its venue and oracle sources before it constructs them, while
/// Series1 uses each value exactly once during the enclosing operation.
module blast_leverage_series_one::observation;

use blast_leverage_series_one::policy::PositionSide;

// === Errors ===

#[error(code = 75)]
const EInvalidObservationPrice: vector<u8> = b"A normalized price observation must be positive.";

#[error(code = 76)]
const EInvalidObservationLotSize: vector<u8> = b"A normalized position observation must use a positive venue lot size.";

#[error(code = 77)]
const EInvalidPositionObservation: vector<u8> = b"A normalized position must be flat or use positive, lot-aligned base and notional.";

// === Public Types ===

/// One normalized price and its source confidence and publication time.
///
/// Constructors require a positive price for priced operations.
public struct PriceObservation {
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
}

/// One venue-position and valuation snapshot for a single operation.
///
/// Constructors validate the structural fields before priced operations.
public struct PositionObservation {
    venue_equity: u64,
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
    observed_side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    checkpoint_clean: bool,
    base_index: PriceObservation,
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
        EInvalidObservationPrice,
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
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
    observed_side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    checkpoint_clean: bool,
    base_index: PriceObservation,
    collateral_oracle: PriceObservation,
    mark_price: u64,
): PositionObservation {
    assert!(
        lot_size > 0,
        EInvalidObservationLotSize,
    );
    assert!(
        mark_price > 0,
        EInvalidObservationPrice,
    );
    assert!(
        is_position_structurally_valid(absolute_base, absolute_notional, lot_size),
        EInvalidPositionObservation,
    );

    PositionObservation {
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
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

/// Returns whether base, notional, and lot size form a normalized position.
///
/// This predicate never aborts, including for a zero lot. Strict operation
/// constructors and Series1 initialization assert it.
public(package) fun is_position_structurally_valid(
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
): bool {
    lot_size > 0
        && ((absolute_base == 0 && absolute_notional == 0)
            || (absolute_base > 0
                && absolute_notional > 0
                && absolute_base % lot_size == 0))
}

/// Consumes one price observation inside Series1.
public(package) fun unpack_price(self: PriceObservation): (u64, u64, u64) {
    let PriceObservation {
        price,
        confidence,
        publish_time_ms,
    } = self;

    (price, confidence, publish_time_ms)
}

/// Consumes one position observation inside Series1.
public(package) fun unpack_position(
    self: PositionObservation,
): (
    u64,
    u64,
    u64,
    u64,
    PositionSide,
    u64,
    bool,
    bool,
    bool,
    PriceObservation,
    PriceObservation,
    u64,
) {
    let PositionObservation {
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    } = self;

    (
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    )
}

/// Consumes one funding outcome as its mutually exclusive classification flags and amount.
public(package) fun unpack_funding(self: FundingSettlement): (bool, bool, u64) {
    match (self) {
        FundingSettlement::None => (false, false, 0),
        FundingSettlement::Credit(amount) => (true, false, amount),
        FundingSettlement::Cost(amount) => (false, true, amount),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Injects malformed exposure to exercise State's independent initialization guard.
public fun with_absolute_base_for_testing(
    mut self: PositionObservation,
    absolute_base: u64,
): PositionObservation {
    self.absolute_base = absolute_base;
    self
}

#[test_only]
/// Consumes an isolated price observation at the end of a unit test.
public fun destroy_price_for_testing(self: PriceObservation) {
    let PriceObservation {
        price: _,
        confidence: _,
        publish_time_ms: _,
    } = self;
}

#[test_only]
/// Consumes an isolated position observation at the end of a unit test.
public fun destroy_position_for_testing(self: PositionObservation) {
    let PositionObservation {
        venue_equity: _,
        absolute_base: _,
        absolute_notional: _,
        lot_size: _,
        observed_side: _,
        pending_order_count: _,
        margin_safe: _,
        venue_operational: _,
        checkpoint_clean: _,
        base_index,
        collateral_oracle,
        mark_price: _,
    } = self;

    destroy_price_for_testing(base_index);
    destroy_price_for_testing(collateral_oracle);
}

#[test_only]
/// Consumes an isolated funding outcome at the end of a unit test.
public fun destroy_funding_for_testing(self: FundingSettlement) {
    match (self) {
        FundingSettlement::None => (),
        FundingSettlement::Credit(_) => (),
        FundingSettlement::Cost(_) => (),
    };
}
