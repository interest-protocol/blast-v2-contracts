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
    capture_(binding, account, registry, clearing_house, base_oracle, collateral_oracle, base_price_info, collateral_price_info, clock, false, true)
}

/// Captures authenticated live facts for objective health degradation.
///
/// Authentication and source agreement remain strict; only structural venue
/// values are retained instead of aborting so Series1 can enter ReduceOnly.
public(package) fun capture_health<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
    change: &Change,
): (observation::PositionObservation, Checkpoint) {
    capture_(binding, account, registry, clearing_house, base_oracle, collateral_oracle, base_price_info, collateral_price_info, clock, true, !is_unexpected_change(change))
}

fun capture_<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
    health: bool,
    checkpoint_clean: bool,
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

    // Identity failures precede every named Aftermath price calculation.
    assert_pyth_price_info(base_price_info, base_feed);
    assert_pyth_price_info(collateral_price_info, collateral_feed);

    let base_fixed = market::base_oracle_price(params, base_oracle, clock);
    let collateral_fixed = market::collateral_oracle_price(params, collateral_oracle, clock);
    let mark_fixed = clearing_house.mark_price(base_oracle, clock);
    let (base_price, base_confidence, base_timestamp) = pyth_price(base_price_info, base_feed, base_fixed);
    let (collateral_price, collateral_confidence, collateral_timestamp) = pyth_price(collateral_price_info, collateral_feed, collateral_fixed);
    let mark_price = fixed_to_u64_down_9(mark_fixed);
    let base_index = if (health) {
        observation::new_health_price(base_price, base_confidence, base_timestamp)
    } else {
        observation::new_price(base_price, base_confidence, base_timestamp)
    };
    let collateral_index = if (health) {
        observation::new_health_price(collateral_price, collateral_confidence, collateral_timestamp)
    } else {
        observation::new_price(collateral_price, collateral_confidence, collateral_timestamp)
    };
    let position = clearing_house.position(account::account_id(account));
    let (signed_base, signed_quote_notional) = position::base_and_quote_amounts(position);
    let (absolute_base, base_representable) = fixed_to_u64_up_health(ifixed::abs(signed_base), 9);
    let (absolute_notional, notional_representable) = usd_fixed_to_collateral_u64_up_health(ifixed::abs(signed_quote_notional), collateral_fixed);
    let side = if (health) {
        if (position.is_long_or_flat()) { policy::long() } else { policy::short() }
    } else {
        assert_position_signs(signed_base, signed_quote_notional, position.is_long_or_flat())
    };
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
    let (margin, requirement) = position::compute_margin_and_requirement(position, collateral_fixed, mark_fixed, effective_imr, market::collateral_haircut(params));
    let pnl = position.unrealized_pnl(mark_fixed);
    let (venue_equity, equity_representable) = signed_equity_health(
        account.collateral_balance(),
        allocated_collateral,
        pnl,
        collateral_fixed,
    );
    let signs_coherent = position_signs_coherent(signed_base, signed_quote_notional, position.is_long_or_flat());
    let economics_valid = !ifixed::is_neg(allocated_collateral)
        && signs_coherent && base_representable && notional_representable && equity_representable;

    (
        if (health) { observation::new_health_position(
            venue_equity,
            absolute_base,
            absolute_notional,
            market::lot_size(params),
            side,
            position.pending_order_count(),
            economics_valid && margin_safe(margin, requirement),
            clearing_house.market_pause_mode() == 0 && !clearing_house.is_frozen(),
            checkpoint_clean,
            base_index,
            collateral_index,
            mark_price,
        ) } else { observation::new_position(
            venue_equity,
            absolute_base,
            absolute_notional,
            market::lot_size(params),
            side,
            position.pending_order_count(),
            economics_valid && margin_safe(margin, requirement),
            clearing_house.market_pause_mode() == 0 && !clearing_house.is_frozen(),
            checkpoint_clean,
            base_index,
            collateral_index,
            mark_price,
        ) },
        checkpoint,
    )
}

/// Classifies only an isolated funding-snapshot and allocated-collateral change.
public(package) fun classify_change(
    before: &Checkpoint,
    after: &Checkpoint,
    funding_candidate: u256,
    collateral_price: u256,
): Change {
    classify_change_(
        before,
        after,
        ifixed::is_neg(funding_candidate),
        usd_fixed_to_collateral_fixed(ifixed::abs(funding_candidate), collateral_price, ifixed::is_neg(funding_candidate)),
    )
}

fun classify_change_(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
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
        || market_mmr_before != market_mmr_after || candidate_collateral_magnitude == 0) {
        return Change::Unexpected
    };
    let snapshots_refreshed = long_after == market_long_before
        && short_after == market_short_before
        && (long_before != long_after || short_before != short_after);
    if (!snapshots_refreshed) { return Change::Unexpected };
    if (!candidate_negative && allocated_after > allocated_before && allocated_after - allocated_before == candidate_collateral_magnitude) {
        return Change::FundingCredit(candidate_collateral_magnitude)
    };
    if (candidate_negative && allocated_after < allocated_before && allocated_before - allocated_after == candidate_collateral_magnitude) {
        return Change::FundingCost(candidate_collateral_magnitude)
    };
    Change::Unexpected
}

fun is_unexpected_change(change: &Change): bool {
    match (change) { Change::Unexpected => true, _ => false }
}

// === Private Functions ===

fun pyth_price(price_info_object: &PriceInfoObject, aftermath_feed: &price_feed::PriceFeed, venue_price: u256): (u64, u64, u64) {
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

fun assert_pyth_price_info(price_info_object: &PriceInfoObject, aftermath_feed: &price_feed::PriceFeed) {
    assert!(
        price_info::uid_to_inner(price_info_object) == price_feed::from(aftermath_feed),
        blast_leverage_aftermath::errors::pyth_price_info_mismatch!(),
    );
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
    let expo_negative = i64::get_is_negative(expo);
    let magnitude = if (expo_negative) {
        i64::get_magnitude_if_negative(expo)
    } else {
        i64::get_magnitude_if_positive(expo)
    };
    normalize_pyth_component_parts(component, expo_negative, magnitude, round_up)
}

fun normalize_pyth_component_parts(component: u64, expo_negative: bool, magnitude: u64, round_up: bool): u64 {
    assert!(magnitude <= 18, blast_leverage_aftermath::errors::pyth_normalization_overflow!());
    let raw = component as u256;
    let normalized = if (expo_negative) {
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
    fixed_to_u64_down(value, 9)
}

fun fixed_to_u64_down(value: u256, decimals: u64): u64 {
    let (normalized, representable) = fixed_to_u64_down_health(value, decimals);
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    normalized
}

fun fixed_to_u64_down_health(value: u256, decimals: u64): (u64, bool) {
    let normalized = value / pow10(18 - decimals);
    if (normalized > std::u64::max_value!() as u256) { (0, false) } else { (normalized as u64, true) }
}

fun fixed_to_u64_up_health(value: u256, decimals: u64): (u64, bool) {
    let scale = pow10(18 - decimals);
    let down = value / scale;
    if (down > std::u64::max_value!() as u256 || (value % scale != 0 && down == std::u64::max_value!() as u256)) {
        (0, false)
    } else if (value % scale == 0) { (down as u64, true) } else { ((down + 1) as u64, true) }
}

fun usd_fixed_to_collateral_fixed(usd: u256, collateral_price: u256, round_up: bool): u256 {
    assert!(collateral_price > 0, blast_leverage_aftermath::errors::normalization_overflow!());
    let whole = usd / collateral_price;
    let remainder = usd % collateral_price;
    assert!(whole <= std::u256::max_value!() / pow10(18), blast_leverage_aftermath::errors::normalization_overflow!());
    assert!(remainder == 0 || remainder <= std::u256::max_value!() / pow10(18), blast_leverage_aftermath::errors::normalization_overflow!());
    let whole_scaled = whole * pow10(18);
    let fraction = remainder * pow10(18) / collateral_price;
    assert!(whole_scaled <= std::u256::max_value!() - fraction, blast_leverage_aftermath::errors::normalization_overflow!());
    let down = whole_scaled + fraction;
    if (round_up && remainder * pow10(18) % collateral_price != 0) { down + 1 } else { down }
}

fun usd_fixed_to_collateral_u64_up_health(usd: u256, collateral_price: u256): (u64, bool) {
    let (collateral, representable) = usd_fixed_to_collateral_fixed_health(usd, collateral_price, true);
    if (!representable) { (0, false) } else { fixed_to_u64_up_health(collateral, 6) }
}

fun signed_equity_health(free: u64, allocated: u256, pnl_usd: u256, collateral_price: u256): (u64, bool) {
    if (ifixed::is_neg(allocated) || collateral_price == 0) { return (0, false) };
    let (allocated_tokens, allocated_ok) = fixed_to_u64_down_health(allocated, 6);
    let (pnl, collateral_ok) = usd_fixed_to_collateral_fixed_health(ifixed::abs(pnl_usd), collateral_price, ifixed::is_neg(pnl_usd));
    let (rounded, pnl_ok) = if (ifixed::is_neg(pnl_usd)) { fixed_to_u64_up_health(pnl, 6) } else { fixed_to_u64_down_health(pnl, 6) };
    if (!allocated_ok || !collateral_ok || !pnl_ok) { return (0, false) };
    let assets = (free as u128) + (allocated_tokens as u128);
    if (ifixed::is_neg(pnl_usd)) {
        if (assets < (rounded as u128)) { (0, false) } else { ((assets - (rounded as u128)) as u64, true) }
    } else {
        if (assets > (std::u64::max_value!() as u128) - (rounded as u128)) { (0, false) } else { ((assets + (rounded as u128)) as u64, true) }
    }
}

fun usd_fixed_to_collateral_fixed_health(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    if (collateral_price == 0) { return (0, false) };
    let scalar = pow10(18);
    let whole = usd / collateral_price;
    let remainder = usd % collateral_price;
    if (whole > std::u256::max_value!() / scalar || (remainder != 0 && remainder > std::u256::max_value!() / scalar)) { return (0, false) };
    let fractional_scaled = remainder * scalar;
    let whole_scaled = whole * scalar;
    let fraction = fractional_scaled / collateral_price;
    if (whole_scaled > std::u256::max_value!() - fraction) { return (0, false) };
    let down = whole_scaled + fraction;
    if (round_up && fractional_scaled % collateral_price != 0) {
        if (down == std::u256::max_value!()) { (0, false) } else { (down + 1, true) }
    } else { (down, true) }
}

fun margin_safe(margin: u256, requirement: u256): bool {
    margin_safe_from_parts(ifixed::is_neg(margin), margin, requirement)
}

fun margin_safe_from_parts(margin_negative: bool, margin: u256, requirement: u256): bool {
    !margin_negative && margin >= requirement
}

fun position_signs_coherent(base: u256, quote: u256, long_or_flat: bool): bool {
    let base_negative = ifixed::is_neg(base);
    let quote_negative = ifixed::is_neg(quote);
    let base_zero = ifixed::abs(base) == 0;
    let quote_zero = ifixed::abs(quote) == 0;
    position_signs_coherent_from_parts(base_negative, quote_negative, base_zero, quote_zero, long_or_flat)
}

fun position_signs_coherent_from_parts(base_negative: bool, quote_negative: bool, base_zero: bool, quote_zero: bool, long_or_flat: bool): bool {
    if (base_zero || quote_zero) {
        return base_zero && quote_zero
    };
    if (long_or_flat) {
        !base_negative && quote_negative
    } else {
        base_negative && !quote_negative
    }
}

fun assert_position_signs(base: u256, quote: u256, long_or_flat: bool): PositionSide {
    assert!(position_signs_coherent(base, quote, long_or_flat), blast_leverage_aftermath::errors::incoherent_position_signs!());
    if (long_or_flat) { policy::long() } else { policy::short() }
}

// === Test-Only Functions ===

#[test_only]
public fun classify_change_for_testing(before: &Checkpoint, after: &Checkpoint): Change {
    classify_change_(before, after, false, 0)
}

#[test_only]
public fun classify_change_with_candidate_for_testing(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_magnitude: u256,
    active_long: bool,
): Change {
    let _ = active_long;
    classify_change_(before, after, candidate_negative, candidate_magnitude)
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
public fun funding_amount_for_testing(change: Change): u256 {
    match (change) {
        Change::FundingCredit(amount) => amount,
        Change::FundingCost(amount) => amount,
        _ => 0,
    }
}

#[test_only]
public fun is_unexpected_for_testing(change: Change): bool {
    match (change) { Change::Unexpected => true, _ => false }
}

#[test_only]
public fun normalize_raw_fixed_for_testing(value: u256, decimals: u64, round_up: bool): u64 {
    let (normalized, representable) = if (round_up) {
        fixed_to_u64_up_health(value, decimals)
    } else {
        fixed_to_u64_down_health(value, decimals)
    };
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    normalized
}

#[test_only]
public fun normalize_pyth_for_testing(component: u64, expo_negative: bool, expo_magnitude: u64, round_up: bool): u64 {
    normalize_pyth_component_parts(component, expo_negative, expo_magnitude, round_up)
}

#[test_only]
public fun usd_fixed_to_collateral_for_testing(usd: u256, collateral_price: u256, round_up: bool): u256 {
    usd_fixed_to_collateral_fixed(usd, collateral_price, round_up)
}

#[test_only]
public fun margin_safe_for_testing(margin_negative: bool, margin: u256, requirement: u256): bool { margin_safe_from_parts(margin_negative, margin, requirement) }

#[test_only]
public fun position_signs_coherent_for_testing(base_negative: bool, quote_negative: bool, base_zero: bool, quote_zero: bool, long_or_flat: bool): bool {
    position_signs_coherent_from_parts(base_negative, quote_negative, base_zero, quote_zero, long_or_flat)
}

#[test_only]
public fun seconds_to_millis_for_testing(seconds: u64): u64 {
    checked_seconds_to_millis(seconds)
}
