// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
#[allow(lint(abort_without_constant))]
/// Authenticated Aftermath/Pyth normalization and raw checkpoint comparison.
module blast_leverage_aftermath::snapshot;

use blast_leverage_aftermath::venue_account::{Self as venue_account, Binding, Checkpoint};
use blast_leverage_series_one::{observation, policy::{Self, PositionSide}};
use ifixed::ifixed;
use oracle_aggregator::{price_feed, price_feed_storage::{Self, PriceFeedStorage}};
use perpetuals::{account::{Self, Account}, clearing_house::{Self, ClearingHouse}, market, registry::Registry};
use position::position;
use pyth::{i64, price, price_feed as pyth_price_feed, price_info::{Self, PriceInfoObject}};
use sui::clock::Clock;
use std::type_name;

// === Public Types ===

/// The only recognized raw transition between authenticated checkpoints.
public enum Change has drop {
    Unchanged,
    FundingCredit(u256),
    FundingCost(u256),
    Unexpected,
}

// === Package Functions ===

/// Captures one authenticated venue and Pyth valuation pair.
///
/// The two Pyth objects are exact sources for the corresponding Aftermath
/// feeds. The interface packages are ABI ports, so this production path is
/// mechanically pinned but never executed by local unit tests.
public(package) fun capture<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
): (observation::PositionObservation, Checkpoint) {
    binding.assert_exact(
        object::id(account),
        account::account_id(account),
        object::id(registry),
        object::id(clearing_house),
        object::id(base_oracle),
        object::id(collateral_oracle),
        type_name::with_original_ids<Collateral>(),
    );

    let params = clearing_house.market_params();
    let base_source_id = market::base_source_id(params);
    let collateral_source_id = market::collateral_source_id(params);
    assert!(
        price_feed_storage::storage_id(base_oracle) == market::base_storage_id(params),
        blast_leverage_aftermath::errors::oracle_storage_mismatch!(),
    );
    assert!(
        price_feed_storage::storage_id(collateral_oracle) == market::collateral_storage_id(params),
        blast_leverage_aftermath::errors::oracle_storage_mismatch!(),
    );

    let base_feed = &base_oracle[base_source_id];
    let collateral_feed = &collateral_oracle[collateral_source_id];
    assert!(
        price_feed::source_id(base_feed) == base_source_id
            && price_feed::source_id(collateral_feed) == collateral_source_id,
        blast_leverage_aftermath::errors::oracle_source_mismatch!(),
    );

    let base_fixed = market::base_oracle_price(params, base_oracle, clock);
    let collateral_fixed = market::collateral_oracle_price(params, collateral_oracle, clock);
    let mark_fixed = clearing_house.mark_price(base_oracle, clock);
    let (base_price, base_confidence, base_timestamp) = pyth_price(base_price_info, base_feed, base_fixed);
    let (collateral_price, collateral_confidence, collateral_timestamp) = pyth_price(collateral_price_info, collateral_feed, collateral_fixed);
    let mark_price = fixed_to_u64_down_9(mark_fixed);
    let base_index = observation::new_price(base_price, base_confidence, base_timestamp);
    let collateral_index = observation::new_price(collateral_price, collateral_confidence, collateral_timestamp);
    let position = clearing_house.position(account::account_id(account));
    let (signed_base, signed_quote_notional) = position::base_and_quote_amounts(position);
    let absolute_base = fixed_to_u64_up_9(ifixed::abs(signed_base));
    let absolute_notional = fixed_to_u64_up_6(ifixed::abs(signed_quote_notional));
    let side = assert_position_signs(signed_base, signed_quote_notional, position.is_long_or_flat());
    let allocated_collateral = position.collateral();
    let (funding_snapshot_long, funding_snapshot_short) = position.funding_rate_snapshots();
    let (market_funding_long, market_funding_short) = market::cum_funding_rates(clearing_house.market_state());
    let (pending_ask_base, pending_bid_base) = position.pending_base_amounts_by_side();
    let checkpoint = venue_account::new_checkpoint(
        account.collateral_balance(),
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        market::lot_size(params),
        pending_ask_base,
        pending_bid_base,
        position.pending_order_count(),
        clearing_house.market_pause_mode(),
        clearing_house.is_frozen(),
        position.initial_margin_ratio(),
        market::margin_ratio_initial(params),
        market::margin_ratio_maintenance(params),
    );
    let effective_imr = position::effective_initial_margin_ratio(position, market::margin_ratio_initial(params));
    let free_margin = position::compute_free_collateral(position, collateral_fixed, mark_fixed, effective_imr, market::collateral_haircut(params));
    let pnl = position.unrealized_pnl(mark_fixed);
    let venue_equity = signed_equity(
        account.collateral_balance(),
        fixed_to_u64_down_6(allocated_collateral),
        pnl,
    );

    (
        observation::new_position(
            venue_equity,
            absolute_base,
            absolute_notional,
            market::lot_size(params),
            side,
            position.pending_order_count(),
            !ifixed::is_neg(free_margin),
            clearing_house.market_pause_mode() == 0 && !clearing_house.is_frozen(),
            true,
            base_index,
            collateral_index,
            mark_price,
        ),
        checkpoint,
    )
}

/// Classifies only an isolated funding-snapshot and allocated-collateral change.
public(package) fun classify_change(
    before: &Checkpoint,
    after: &Checkpoint,
    funding_candidate: u256,
    active_long: bool,
): Change {
    classify_change_(before, after, ifixed::is_neg(funding_candidate), ifixed::abs(funding_candidate), active_long)
}

fun classify_change_(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_magnitude: u256,
    active_long: bool,
): Change {
    let before = *before;
    let after = *after;
    let (
        free_before, allocated_before, base_before, quote_before, long_before, short_before,
        market_long_before, market_short_before, lot_before, ask_before, bid_before,
        orders_before, pause_before, frozen_before, imr_before, market_imr_before, market_mmr_before,
    ) = before.unpack();
    let (
        free_after, allocated_after, base_after, quote_after, long_after, short_after,
        market_long_after, market_short_after, lot_after, ask_after, bid_after,
        orders_after, pause_after, frozen_after, imr_after, market_imr_after, market_mmr_after,
    ) = after.unpack();
    if (free_before == free_after && allocated_before == allocated_after && base_before == base_after
        && quote_before == quote_after && long_before == long_after && short_before == short_after
        && market_long_before == market_long_after && market_short_before == market_short_after
        && lot_before == lot_after && ask_before == ask_after && bid_before == bid_after
        && orders_before == orders_after && pause_before == pause_after && frozen_before == frozen_after
        && imr_before == imr_after && market_imr_before == market_imr_after
        && market_mmr_before == market_mmr_after) {
        return Change::Unchanged
    };
    if (free_before != free_after || base_before != base_after || quote_before != quote_after
        || market_long_before != market_long_after || market_short_before != market_short_after
        || lot_before != lot_after || ask_before != ask_after || bid_before != bid_after
        || orders_before != orders_after || pause_before != pause_after || frozen_before != frozen_after
        || imr_before != imr_after || market_imr_before != market_imr_after
        || market_mmr_before != market_mmr_after || candidate_magnitude == 0) {
        return Change::Unexpected
    };
    let active_transition = if (active_long) {
        long_before != long_after && long_after == market_long_before && short_before == short_after
    } else {
        short_before != short_after && short_after == market_short_before && long_before == long_after
    };
    if (!active_transition) { return Change::Unexpected };
    if (!candidate_negative && allocated_after > allocated_before && allocated_after - allocated_before == candidate_magnitude) {
        return Change::FundingCredit(candidate_magnitude)
    };
    if (candidate_negative && allocated_after < allocated_before && allocated_before - allocated_after == candidate_magnitude) {
        return Change::FundingCost(candidate_magnitude)
    };
    Change::Unexpected
}

// === Private Functions ===

fun pyth_price(price_info_object: &PriceInfoObject, aftermath_feed: &price_feed::PriceFeed, venue_price: u256): (u64, u64, u64) {
    assert!(
        price_info::uid_to_inner(price_info_object) == price_feed::from(aftermath_feed),
        blast_leverage_aftermath::errors::pyth_price_info_mismatch!(),
    );
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let pyth_price = pyth_price_feed::get_price(price_info::get_price_feed(&price_info));
    let price_i64 = price::get_price(&pyth_price);
    assert!(
        !i64::get_is_negative(&price_i64),
        blast_leverage_aftermath::errors::invalid_pyth_price!(),
    );
    let expo = price::get_expo(&pyth_price);
    let normalized_price = normalize_pyth_component(i64::get_magnitude_if_positive(&price_i64), &expo, false);
    let normalized_confidence = normalize_pyth_component(price::get_conf(&pyth_price), &expo, true);
    let (aftermath_price, aftermath_timestamp) = price_feed::price_and_timestamp_ms(aftermath_feed);
    assert!(
        normalize_feed_price(aftermath_price) == normalized_price
            && fixed_to_u64_down_9(venue_price) == normalized_price
            && aftermath_timestamp == checked_seconds_to_millis(price::get_timestamp(&pyth_price)),
        blast_leverage_aftermath::errors::oracle_observation_mismatch!(),
    );

    (normalized_price, normalized_confidence, aftermath_timestamp)
}

/// Aftermath feeds at the bound source use the adapter's 9-decimal price unit.
fun normalize_feed_price(raw_price: u128): u64 {
    assert!(
        raw_price <= std::u64::max_value!() as u128,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    raw_price as u64
}

fun normalize_pyth_component(component: u64, expo: &i64::I64, round_up: bool): u64 {
    let magnitude = if (i64::get_is_negative(expo)) {
        i64::get_magnitude_if_negative(expo)
    } else {
        i64::get_magnitude_if_positive(expo)
    };
    assert!(magnitude <= 18, blast_leverage_aftermath::errors::pyth_normalization_overflow!());
    let raw = component as u256;
    let normalized = if (i64::get_is_negative(expo)) {
        if (magnitude <= 9) {
            checked_mul(raw, pow10(9 - magnitude))
        } else {
            let scale = pow10(magnitude - 9);
            let down = raw / scale;
            if (round_up && raw % scale != 0) { down + 1 } else { down }
        }
    } else {
        checked_mul(raw, pow10(9 + magnitude))
    };
    assert!(
        normalized <= (std::u64::max_value!() as u256),
        blast_leverage_aftermath::errors::pyth_normalization_overflow!(),
    );
    normalized as u64
}

fun checked_seconds_to_millis(seconds: u64): u64 {
    assert!(seconds <= std::u64::max_value!() / 1_000, blast_leverage_aftermath::errors::normalization_overflow!());
    seconds * 1_000
}

fun checked_mul(value: u256, factor: u256): u256 {
    assert!(
        value == 0 || value <= (std::u256::max_value!() / factor),
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    value * factor
}

fun pow10(exponent: u64): u256 {
    let mut result = 1;
    let mut remaining = exponent;
    while (remaining > 0) {
        result = result * 10;
        remaining = remaining - 1;
    };
    result
}

fun fixed_to_u64_down_9(value: u256): u64 {
    ifixed::to_balance(value, ifixed::decimal_scalar_from_decimals(9) as u256)
}

fun fixed_to_u64_up_9(value: u256): u64 {
    let down = fixed_to_u64_down_9(value);
    let scale = ifixed::decimal_scalar_from_decimals(9) as u256;
    assert!(
        value == 0 || down < std::u64::max_value!(),
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    if (value % scale == 0) { down } else { down + 1 }
}

fun fixed_to_u64_down_6(value: u256): u64 {
    ifixed::to_balance(value, ifixed::decimal_scalar_from_decimals(6) as u256)
}

fun fixed_to_u64_up_6(value: u256): u64 {
    let down = fixed_to_u64_down_6(value);
    let scale = ifixed::decimal_scalar_from_decimals(6) as u256;
    assert!(value == 0 || down < std::u64::max_value!(), blast_leverage_aftermath::errors::normalization_overflow!());
    if (value % scale == 0) { down } else { down + 1 }
}

fun signed_equity(free: u64, allocated: u64, pnl: u256): u64 {
    let assets = (free as u128) + (allocated as u128);
    let magnitude = ifixed::abs(pnl);
    let rounded = if (ifixed::is_neg(pnl)) { fixed_to_u64_up_6(magnitude) } else { fixed_to_u64_down_6(magnitude) };
    if (ifixed::is_neg(pnl)) {
        assert!(assets >= (rounded as u128), blast_leverage_aftermath::errors::normalization_overflow!());
        (assets - (rounded as u128)) as u64
    } else {
        assert!(assets <= (std::u64::max_value!() as u128) - (rounded as u128), blast_leverage_aftermath::errors::normalization_overflow!());
        (assets + (rounded as u128)) as u64
    }
}

fun assert_position_signs(base: u256, quote: u256, long_or_flat: bool): PositionSide {
    let base_negative = ifixed::is_neg(base);
    let quote_negative = ifixed::is_neg(quote);
    let base_zero = ifixed::abs(base) == 0;
    let quote_zero = ifixed::abs(quote) == 0;
    if (base_zero || quote_zero) {
        assert!(base_zero && quote_zero, blast_leverage_aftermath::errors::incoherent_position_signs!());
        return policy::long()
    };
    if (long_or_flat) {
        assert!(!base_negative && quote_negative, blast_leverage_aftermath::errors::incoherent_position_signs!());
        policy::long()
    } else {
        assert!(base_negative && !quote_negative, blast_leverage_aftermath::errors::incoherent_position_signs!());
        policy::short()
    }
}

// === Test-Only Functions ===

#[test_only]
public fun assert_test_seam_for_testing() {}

#[test_only]
public fun classify_change_for_testing(before: &Checkpoint, after: &Checkpoint): Change {
    classify_change_(before, after, false, 0, true)
}

#[test_only]
public fun classify_change_with_candidate_for_testing(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_magnitude: u256,
    active_long: bool,
): Change {
    classify_change_(before, after, candidate_negative, candidate_magnitude, active_long)
}

#[test_only]
public fun is_unchanged_for_testing(change: Change): bool {
    match (change) { Change::Unchanged => true, _ => false }
}

#[test_only]
public fun is_credit_for_testing(change: Change): bool {
    match (change) { Change::FundingCredit(_) => true, _ => false }
}

#[test_only]
public fun is_cost_for_testing(change: Change): bool {
    match (change) { Change::FundingCost(_) => true, _ => false }
}

#[test_only]
public fun is_unexpected_for_testing(change: Change): bool {
    match (change) { Change::Unexpected => true, _ => false }
}

#[test_only]
public fun normalize_raw_fixed_for_testing(value: u256, decimals: u64, round_up: bool): u64 {
    assert!(decimals <= 18, blast_leverage_aftermath::errors::normalization_overflow!());
    let scale = pow10(18 - decimals);
    let down = value / scale;
    let normalized = if (round_up && value % scale != 0) { down + 1 } else { down };
    assert!(normalized <= std::u64::max_value!() as u256, blast_leverage_aftermath::errors::normalization_overflow!());
    normalized as u64
}

#[test_only]
public fun normalize_pyth_for_testing(component: u64, expo_negative: bool, expo_magnitude: u64, round_up: bool): u64 {
    assert!(expo_magnitude <= 18, blast_leverage_aftermath::errors::pyth_normalization_overflow!());
    let raw = component as u256;
    let (down, remainder) = if (expo_negative) {
        if (expo_magnitude <= 9) {
            (checked_mul(raw, pow10(9 - expo_magnitude)), false)
        } else {
            let scale = pow10(expo_magnitude - 9);
            (raw / scale, raw % scale != 0)
        }
    } else {
        (checked_mul(raw, pow10(9 + expo_magnitude)), false)
    };
    let normalized = if (round_up && remainder) { down + 1 } else { down };
    assert!(normalized <= std::u64::max_value!() as u256, blast_leverage_aftermath::errors::pyth_normalization_overflow!());
    normalized as u64
}

#[test_only]
public fun seconds_to_millis_for_testing(seconds: u64): u64 {
    checked_seconds_to_millis(seconds)
}
