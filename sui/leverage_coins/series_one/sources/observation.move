// `blast_leverage_series_one::errors` centralizes package-wide abort codes through zero-cost macros.
// This narrow suppression preserves caller-local abort locations and stable codes pinned by tests.
#[allow(lint(abort_without_constant))]
/// Linear, operation-scoped observations supplied by a venue adapter.
///
/// These values prove neither source identity nor caller authority. The adapter
/// authenticates its venue and oracle sources before it constructs them, while
/// Series1 uses each value exactly once during the enclosing operation.
module blast_leverage_series_one::observation;

use blast_leverage_series_one::policy::PositionSide;

// === Public Types ===

/// One normalized price and its source confidence and publication time.
///
/// Priced-operation constructors require a positive price. Health snapshots
/// may carry zero so objective invalidity reaches the non-aborting degradation
/// path instead of aborting before the State consumes the observation.
public struct PriceObservation {
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
}

/// One venue-position and valuation snapshot for a single operation.
///
/// Strict constructors normalize the fields for priced operations. The health
/// constructor can preserve invalid live values for non-aborting degradation.
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
        blast_leverage_series_one::errors::invalid_observation_price!(),
    );

    new_health_price(price, confidence, publish_time_ms)
}

/// Creates a price snapshot for objective health synchronization.
///
/// Zero is preserved intentionally. `sync_health` uses non-aborting valuation
/// predicates and must be able to persist `Active -> ReduceOnly` when an oracle
/// source returns an invalid live value.
public fun new_health_price(
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
): PriceObservation {
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
        blast_leverage_series_one::errors::invalid_observation_lot_size!(),
    );
    assert!(
        mark_price > 0,
        blast_leverage_series_one::errors::invalid_observation_price!(),
    );
    assert!(
        is_position_structurally_valid(absolute_base, absolute_notional, lot_size),
        blast_leverage_series_one::errors::invalid_position_observation!(),
    );

    new_health_position(
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

/// Creates a raw objective-health snapshot without aborting on invalid values.
///
/// The adapter must use this path only after authenticating the live venue and
/// oracle sources. Zero price, mark, or lot values and structurally invalid
/// exposure are preserved so `sync_health` can degrade the lifecycle. Every
/// risk-increasing Series1 operation still validates the complete observation
/// before mutation.
public fun new_health_position(
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
/// constructors assert it; objective health consumes it as a degradation
/// signal when using the permissive health-observation path.
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
