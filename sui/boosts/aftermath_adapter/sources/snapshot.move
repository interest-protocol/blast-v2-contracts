// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
#[allow(lint(abort_without_constant))]
/// Authenticated Aftermath capture: proves every source is the bound one,
/// reads the raw checkpoint, and normalizes prices and equity into the
/// adapter's units.
module blast_boosts_aftermath::snapshot;

// === Public Types ===

// The `*_decoded` helpers take a value's sign and magnitude already decoded
// from IFixed. They exist because the pinned `ifixed` port aborts under test,
// so the pure arithmetic can be exercised from fixtures; production callers
// always go through the decoding wrapper above each one.

/// One authenticated capture: the raw checkpoint, both oracle legs, the mark,
/// the position's economics, and whether the venue can serve a priced
/// operation. A priced caller consumes it through `into_observation`; a health
/// caller reads only its checkpoint.
public struct CapturedSnapshot has drop {
    venue_equity: u64,
    position_base: u64,
    lot_size: u64,
    side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    economics_valid: bool,
    base_price: u64,
    base_timestamp: u64,
    collateral_price: u64,
    collateral_timestamp: u64,
    mark_price: u64,
    checkpoint: Checkpoint,
    collateral_fixed: u256,
}

/// Cash the venue can release, the cash-only margin shortfall, and positive
/// oracle PnL that a maintenance trade can realize. All amounts are collateral atoms.
public struct CashLiquidity has copy, drop {
    releasable: u64,
    shortfall: u64,
    unrealized_profit: u64,
}

// === Package Functions ===

// --- Capture ---

/// Reads the venue's own withdrawal budget after funding has been settled.
/// The shortfall excludes positive PnL, applies the live haircut and effective
/// IMR, and credits free account cash. It is not a shareholder valuation.
public(package) fun capture_cash_liquidity<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): CashLiquidity {
    binding.assert_bound_graph(account, registry, clearing_house, base_oracle, collateral_oracle);
    let params = clearing_house.market_params();
    let position = clearing_house.position(account.account_id());
    let collateral_price = params.collateral_oracle_price(collateral_oracle, clock);
    let mark_price = clearing_house.mark_price(base_oracle, clock);
    let effective_imr = position.effective_initial_margin_ratio(params.margin_ratio_initial());
    let haircut = params.collateral_haircut();
    let (margin, requirement) = position.compute_margin_and_requirement(
        collateral_price, mark_price, effective_imr, haircut,
    );
    let mark_pnl = position.unrealized_pnl(mark_price);
    let cash_margin = if (mark_pnl.is_neg()) { margin } else { ifixed::sub(margin, mark_pnl) };
    let cash_deficit = ifixed::sub(requirement, cash_margin);

    cash_liquidity(
        account.collateral_balance(),
        position.compute_free_collateral(collateral_price, mark_price, effective_imr, haircut),
        cash_deficit,
        position.unrealized_pnl(params.base_oracle_price(base_oracle, clock)),
        collateral_price,
        haircut,
    )
}

/// Fails before deallocation without reducing the holder's agreed payout.
public(package) fun assert_releasable(self: &CashLiquidity, amount: u64) {
    assert!(amount <= self.releasable, blast_boosts_aftermath::errors::redemption_exceeds_releasable!());
}

public(package) fun shortfall(self: &CashLiquidity): u64 { self.shortfall }

public(package) fun unrealized_profit(self: &CashLiquidity): u64 { self.unrealized_profit }

/// Recovery must improve the cash shortfall and add more allocated cash than
/// holders paid in trading costs. Mark movements alone cannot prove progress.
public(package) fun assert_realization_progress(
    self: &CashLiquidity,
    after: &CashLiquidity,
    before_checkpoint: &Checkpoint,
    after_checkpoint: &Checkpoint,
    equity_cost: u64,
) {
    let cash_gain = ifixed::sub(after_checkpoint.allocated_collateral(), before_checkpoint.allocated_collateral());
    assert!(
        after.shortfall < self.shortfall && !cash_gain.is_neg()
            && cash_gain > (equity_cost as u256) * constants::collateral_atom_to_ifixed_scale!(),
        blast_boosts_aftermath::errors::profit_realization_no_progress!(),
    );
}

/// Authenticates raw terminal state without requiring a live price or positive equity.
public(package) fun capture_checkpoint<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
): Checkpoint {
    binding.assert_bound_graph(account, registry, clearing_house, base_oracle, collateral_oracle);

    account.read_checkpoint(clearing_house)
}

/// Reads only authenticated prices and the live lot for a risk-cap update.
/// Position valuation, mark price and opening-margin health cannot block it.
public(package) fun capture_order_capacity<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): (PriceObservation, PriceObservation, u64) {
    binding.assert_bound_graph(account, registry, clearing_house, base_oracle, collateral_oracle);
    let params = clearing_house.market_params();
    let base_feed = &base_oracle[params.base_source_id()];
    let collateral_feed = &collateral_oracle[params.collateral_source_id()];
    let (base_price, base_timestamp, base_valid) = base_feed.oracle_leg(params.base_oracle_price(base_oracle, clock));
    let (collateral_price, collateral_timestamp, collateral_valid) =
        collateral_feed.oracle_leg(params.collateral_oracle_price(collateral_oracle, clock));
    assert!(base_valid && collateral_valid, blast_boosts_aftermath::errors::normalization_overflow!());

    (
        observation::new_price(base_price, 0, base_timestamp),
        observation::new_price(collateral_price, 0, collateral_timestamp),
        params.lot_size(),
    )
}

/// Captures one authenticated venue valuation.
///
/// Source identity is strict and aborts. Values that do not fit the adapter's
/// units, and a venue that cannot serve a priced operation, are carried as
/// facts: `into_observation` refuses them for a priced operation, health
/// synchronization reports them. The interface packages are ABI ports, so this
/// production path is mechanically pinned but never executed by local unit
/// tests.
public(package) fun capture<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): CapturedSnapshot {
    let checkpoint = binding.capture_checkpoint(account, registry, clearing_house, base_oracle, collateral_oracle);
    let params = clearing_house.market_params();
    let base_feed = &base_oracle[params.base_source_id()];
    let collateral_feed = &collateral_oracle[params.collateral_source_id()];

    let base_fixed = params.base_oracle_price(base_oracle, clock);
    let collateral_fixed = params.collateral_oracle_price(collateral_oracle, clock);
    let mark_fixed = clearing_house.mark_price(base_oracle, clock);
    let (base_price, base_price_published_at_ms, base_representable) = base_feed.oracle_leg(base_fixed);
    let (collateral_price, collateral_price_published_at_ms, collateral_representable) =
        collateral_feed.oracle_leg(collateral_fixed);
    let (mark_price, mark_representable) = ifixed_math::fixed_to_u64_down(mark_fixed, constants::base_decimals!() as u64);

    let position = clearing_house.position(account.account_id());
    let (position_base, venue_equity, margin_safe, position_representable) = position.position_economics(
        params, account.collateral_balance(), base_fixed, collateral_fixed, mark_fixed,
    );

    CapturedSnapshot {
        venue_equity,
        position_base,
        lot_size: params.lot_size(),
        side: if (position.is_long_or_flat()) { policy::long() } else { policy::short() },
        pending_order_count: position.pending_order_count(),
        margin_safe,
        venue_operational: clearing_house.market_pause_mode() == 0 && !clearing_house.is_frozen(),
        economics_valid: position_representable && base_representable && collateral_representable && mark_representable,
        base_price,
        base_timestamp: base_price_published_at_ms,
        collateral_price,
        collateral_timestamp: collateral_price_published_at_ms,
        mark_price,
        checkpoint,
        collateral_fixed,
    }
}

// --- Captured Snapshot Reads ---

/// Turns a capture into the core's observation and the checkpoint it was read
/// with, refusing a venue no priced operation may build on: unrepresentable
/// economics, open orders, unsafe margin, or a paused or frozen market.
public(package) fun into_observation(self: CapturedSnapshot): (PositionObservation, Checkpoint) {
    self.into_validated_observation(true)
}

/// Recovery admits observations without opening-margin headroom. Callers must
/// restrict their use to recovery or prove the planned trade is reducing.
/// Pricing and operational checks remain unchanged.
public(package) fun into_recovery_observation(self: CapturedSnapshot): (PositionObservation, Checkpoint) {
    self.into_validated_observation(false)
}

/// A keeper hint with the same margin distinction as execution. It creates no
/// linear plan: the core only filters increases when opening margin is absent.
/// Returns the captured checkpoint so callers can reject unexplained drift.
public(package) fun into_rebalance_readiness<Product>(
    self: CapturedSnapshot,
    state: &State<Product>,
    now_at_ms: u64,
): (bool, Checkpoint) {
    let margin_safe = self.margin_safe;
    let (observation, checkpoint) = self.into_recovery_observation();

    (state.needs_rebalance(observation, margin_safe, now_at_ms), checkpoint)
}

/// Only the core's authenticated direction can exempt a rebalance from the
/// opening-margin requirement. All other active-operation checks still run.
public(package) fun into_rebalance_plan<Product>(
    self: CapturedSnapshot,
    state: &State<Product>,
    venue_fee_bps: u64,
    now_at_ms: u64,
): (RebalancePlan<Product>, Checkpoint) {
    let margin_safe = self.margin_safe;
    let (observation, checkpoint) = self.into_recovery_observation();
    let plan = state.prepare_rebalance(observation, venue_fee_bps, now_at_ms);
    assert!(!plan.is_increasing() || margin_safe, blast_boosts_aftermath::errors::venue_not_ready!());

    (plan, checkpoint)
}

/// A reducing fill need not restore opening margin in one step. Increasing
/// fills remain strict, using the direction sealed in the original plan.
public(package) fun into_rebalance_observation<Product>(
    self: CapturedSnapshot,
    plan: &RebalancePlan<Product>,
): (PositionObservation, Checkpoint) {
    self.into_validated_observation(plan.is_increasing())
}

/// The authenticated raw checkpoint the capture was read with.
public(package) fun checkpoint(self: &CapturedSnapshot): Checkpoint {
    self.checkpoint
}

/// Builds the base oracle observation from the authenticated capture.
public(package) fun base_price_observation(self: &CapturedSnapshot): PriceObservation {
    observation::new_price(self.base_price, 0, self.base_timestamp)
}

/// Builds the collateral oracle observation from the authenticated capture.
public(package) fun collateral_price_observation(self: &CapturedSnapshot): PriceObservation {
    observation::new_price(self.collateral_price, 0, self.collateral_timestamp)
}

/// Returns the raw IFixed collateral price the venue read for this capture.
public(package) fun collateral_fixed(self: &CapturedSnapshot): u256 { self.collateral_fixed }

/// Proves the venue objects are the bound ones, then that each price-feed
/// storage is the one the bound market prices with now, so the price a
/// capture values with is always the one the venue trades at.
public(package) fun assert_bound_graph<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
) {
    binding.assert_object_graph(
        object::id(account), account.account_id(), object::id(registry), object::id(clearing_house),
    );
    clearing_house.assert_market_oracles(base_oracle, collateral_oracle);
}

// === Private Functions ===

/// Converts the venue's signed results conservatively: budget and profit down,
/// cash needed up. A zero cash shortfall disables paid profit realization.
fun cash_liquidity(
    free: u64,
    releasable_fixed: u256,
    cash_deficit_usd: u256,
    oracle_pnl_usd: u256,
    collateral_price: u256,
    haircut: u256,
): CashLiquidity {
    assert!(
        collateral_price > 0 && !collateral_price.is_neg() && haircut < constants::ifixed_one!()
            && !releasable_fixed.is_neg(),
        blast_boosts_aftermath::errors::normalization_overflow!(),
    );
    let (available, available_ok) = ifixed_math::fixed_to_u64_down(releasable_fixed, constants::collateral_decimals!() as u64);
    let positive_deficit = if (cash_deficit_usd.is_neg()) { 0 } else { cash_deficit_usd };
    let (deficit_collateral, deficit_ok) = ifixed_math::usd_fixed_to_collateral_fixed(positive_deficit, collateral_price, true);
    let (deficit_before_haircut, haircut_ok) = ifixed_math::usd_fixed_to_collateral_fixed(
        deficit_collateral, constants::ifixed_one!() - haircut, true,
    );
    let (required, required_ok) = ifixed_math::fixed_to_u64_up(deficit_before_haircut, constants::collateral_decimals!() as u64);
    let positive_profit = if (oracle_pnl_usd.is_neg()) { 0 } else { oracle_pnl_usd };
    let (profit_fixed, profit_ok) = ifixed_math::usd_fixed_to_collateral_fixed(positive_profit, collateral_price, false);
    let (unrealized_profit, profit_atoms_ok) = ifixed_math::fixed_to_u64_down(profit_fixed, constants::collateral_decimals!() as u64);
    assert!(
        available_ok && deficit_ok && haircut_ok && required_ok && profit_ok && profit_atoms_ok
            && available <= std::u64::max_value!() - free,
        blast_boosts_aftermath::errors::normalization_overflow!(),
    );

    CashLiquidity {
        releasable: free + available,
        shortfall: required - required.min(free),
        unrealized_profit,
    }
}

fun into_validated_observation(self: CapturedSnapshot, require_opening_margin: bool): (PositionObservation, Checkpoint) {
    let CapturedSnapshot {
        venue_equity, position_base, lot_size, side, pending_order_count, margin_safe, venue_operational,
        economics_valid, base_price, base_timestamp: base_price_published_at_ms,
        collateral_price, collateral_timestamp: collateral_price_published_at_ms, mark_price,
        checkpoint, collateral_fixed: _,
    } = self;
    assert!(economics_valid, blast_boosts_aftermath::errors::normalization_overflow!());
    assert!(
        pending_order_count == 0 && (!require_opening_margin || margin_safe) && venue_operational,
        blast_boosts_aftermath::errors::venue_not_ready!(),
    );

    let observation = observation::new_position(
        venue_equity,
        position_base,
        lot_size,
        side,
        observation::new_price(base_price, 0, base_price_published_at_ms),
        observation::new_price(collateral_price, 0, collateral_price_published_at_ms),
        mark_price,
    );

    (observation, checkpoint)
}

// --- Capture ---

/// Values one position at the captured prices: whole-lot base, venue equity in
/// collateral atoms, whether margin covers the requirement, and whether every
/// figure fit and the position's signs agree with its side.
fun position_economics(
    position: &Position,
    params: &MarketParams,
    free_collateral: u64,
    base_fixed: u256,
    collateral_fixed: u256,
    mark_fixed: u256,
): (u64, u64, bool, bool) {
    let (signed_base, signed_quote_notional) = position.base_and_quote_amounts();
    let (position_base, base_representable) = ifixed_math::fixed_to_u64_up(signed_base.abs(), constants::base_decimals!() as u64);
    let effective_imr = position.effective_initial_margin_ratio(params.margin_ratio_initial());
    let (margin, requirement) = position.compute_margin_and_requirement(
        collateral_fixed, mark_fixed, effective_imr, params.collateral_haircut(),
    );
    let (venue_equity, equity_representable) = signed_equity(
        free_collateral, position.collateral(), position.unrealized_pnl(base_fixed), collateral_fixed,
    );
    let representable = base_representable
        && equity_representable
        && position_signs_coherent(signed_base, signed_quote_notional, position.is_long_or_flat());

    (position_base, venue_equity, margin_safe(margin, requirement), representable)
}

/// One oracle leg as the adapter's 9-decimal price, the feed's millisecond
/// timestamp, and whether the price fit. The venue's named price is the bound
/// feed's raw 18-decimal price (`market::*_oracle_price` bytecode); the
/// equality is asserted so the leg is never valued from a feed the venue is
/// not reading. Aftermath feeds carry no confidence interval.
fun oracle_leg(feed: &PriceFeed, venue_price: u256): (u64, u64, bool) {
    let (feed_price, price_published_at_ms) = feed.price_and_timestamp_ms();
    oracle_leg_decoded(feed_price, price_published_at_ms, venue_price)
}

fun oracle_leg_decoded(feed_price: u128, price_published_at_ms: u64, venue_price: u256): (u64, u64, bool) {
    assert!(
        (feed_price as u256) == venue_price,
        blast_boosts_aftermath::errors::oracle_observation_mismatch!(),
    );
    let (price, representable) = ifixed_math::fixed_to_u64_down(venue_price, constants::base_decimals!() as u64);

    (price, price_published_at_ms, representable)
}

// --- Position Arithmetic ---

fun signed_equity(
    free_collateral: u64,
    allocated_collateral: u256,
    pnl_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    signed_equity_decoded(
        free_collateral,
        allocated_collateral.is_neg(),
        allocated_collateral.abs(),
        pnl_usd.is_neg(),
        pnl_usd.abs(),
        collateral_price,
    )
}

fun signed_equity_decoded(
    free_collateral: u64,
    allocated_negative: bool,
    allocated_magnitude: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    if (collateral_price == 0) return (0, false);

    let (allocated_asset, allocated_liability, allocated_ok) = signed_collateral_atoms(allocated_negative, allocated_magnitude);
    let (pnl, collateral_ok) = ifixed_math::usd_fixed_to_collateral_fixed(pnl_magnitude_usd, collateral_price, pnl_negative);
    let (pnl_asset, pnl_liability, pnl_ok) = signed_collateral_atoms(pnl_negative, pnl);
    if (!allocated_ok || !collateral_ok || !pnl_ok) return (0, false);

    let assets = (free_collateral as u128) + (allocated_asset as u128) + (pnl_asset as u128);
    let liabilities = (allocated_liability as u128) + (pnl_liability as u128);
    if (assets < liabilities) return (0, false);

    let net = assets - liabilities;
    if (net > std::u64::max_value!() as u128) { (0, false) } else { (net as u64, true) }
}

/// One signed IFixed collateral amount as `(asset_atoms, liability_atoms, representable)`.
/// A liability rounds up and an asset rounds down, so equity never reads high.
fun signed_collateral_atoms(negative: bool, magnitude: u256): (u64, u64, bool) {
    let decimals = constants::collateral_decimals!() as u64;
    let (atoms, representable) = if (negative) {
        ifixed_math::fixed_to_u64_up(magnitude, decimals)
    } else {
        ifixed_math::fixed_to_u64_down(magnitude, decimals)
    };

    if (negative) { (0, atoms, representable) } else { (atoms, 0, representable) }
}

fun margin_safe(margin: u256, requirement: u256): bool {
    margin_safe_decoded(margin.is_neg(), margin, requirement)
}

fun margin_safe_decoded(margin_negative: bool, margin: u256, requirement: u256): bool {
    !margin_negative && margin >= requirement
}

fun position_signs_coherent(base: u256, quote: u256, is_long_or_flat: bool): bool {
    position_signs_coherent_decoded(
        base.is_neg(), quote.is_neg(), base.abs() == 0, quote.abs() == 0, is_long_or_flat,
    )
}

/// The venue keeps the quote notional under the base's sign, and a flat
/// position carries no notional.
fun position_signs_coherent_decoded(
    base_negative: bool,
    quote_negative: bool,
    base_zero: bool,
    quote_zero: bool,
    is_long_or_flat: bool,
): bool {
    if (base_zero || quote_zero) return base_zero && quote_zero;

    if (is_long_or_flat) { !base_negative && !quote_negative } else { base_negative && quote_negative }
}

// === Test-Only Functions ===

#[test_only]
public fun cash_liquidity_for_testing(
    free: u64, releasable_fixed: u256, cash_deficit_usd: u256,
    oracle_pnl_usd: u256, collateral_price: u256, haircut: u256,
): CashLiquidity {
    cash_liquidity(free, releasable_fixed, cash_deficit_usd, oracle_pnl_usd, collateral_price, haircut)
}

/// Replaces only external reads for recovery tests; production conversion and
/// core valuation still run. Uses the standard unit-price fixture.
#[test_only]
public fun captured_position_for_testing(
    checkpoint: Checkpoint,
    equity: u64,
    base: u64,
    side: PositionSide,
    margin_safe: bool,
    venue_operational: bool,
): CapturedSnapshot {
    let mut capture = captured_health_for_testing(checkpoint, equity, margin_safe, 0, venue_operational, true);
    capture.position_base = base;
    capture.side = side;
    capture
}

/// Builds a normalized authenticated post-capture fixture around a real raw
/// checkpoint. Tests vary only equity and the venue-readiness facts; all other
/// objective facts are the standard healthy 2x long fixture used by connected
/// Vault tests.
#[test_only]
public fun captured_health_for_testing(
    checkpoint: Checkpoint,
    venue_equity: u64,
    margin_safe: bool,
    pending_order_count: u64,
    venue_operational: bool,
    economics_valid: bool,
): CapturedSnapshot {
    CapturedSnapshot {
        venue_equity,
        position_base: 1_800,
        lot_size: 1,
        side: policy::long(),
        pending_order_count,
        margin_safe,
        venue_operational,
        economics_valid,
        base_price: 1_000_000_000,
        base_timestamp: 1_000,
        collateral_price: 1_000_000_000,
        collateral_timestamp: 1_000,
        mark_price: 1_000_000_000,
        checkpoint,
        collateral_fixed: 1_000_000_000_000_000_000,
    }
}

#[test_only]
public fun normalize_price_for_testing(value: u256): (u64, bool) {
    ifixed_math::fixed_to_u64_down(value, constants::base_decimals!() as u64)
}

#[test_only]
public fun oracle_leg_for_testing(feed_price: u128, price_published_at_ms: u64, venue_price: u256): (u64, u64, bool) {
    oracle_leg_decoded(feed_price, price_published_at_ms, venue_price)
}

#[test_only]
public fun signed_equity_for_testing(
    free_collateral: u64,
    allocated_negative: bool,
    allocated_magnitude: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    signed_equity_decoded(
        free_collateral, allocated_negative, allocated_magnitude, pnl_negative, pnl_magnitude_usd, collateral_price,
    )
}

#[test_only]
public fun margin_safe_for_testing(margin_negative: bool, margin: u256, requirement: u256): bool {
    margin_safe_decoded(margin_negative, margin, requirement)
}

#[test_only]
public fun position_signs_coherent_for_testing(
    base_negative: bool,
    quote_negative: bool,
    base_zero: bool,
    quote_zero: bool,
    is_long_or_flat: bool,
): bool {
    position_signs_coherent_decoded(base_negative, quote_negative, base_zero, quote_zero, is_long_or_flat)
}

// === Imports ===

use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint}, constants, ifixed_math, venue_account::{Self, Binding}};

use blast_boosts_core::{
    observation::{Self, PositionObservation, PriceObservation},
    policy::{Self, PositionSide},
    state::{State, RebalancePlan},
};

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign and magnitude read as methods.
use fun ifixed::abs as u256.abs;

use fun ifixed::is_neg as u256.is_neg;

use oracle_aggregator::{price_feed::PriceFeed, price_feed_storage::PriceFeedStorage};

use perpetuals::{
    account::Account,
    clearing_house::ClearingHouse,
    market::MarketParams,
    registry::Registry,
};

use position::position::Position;

use sui::clock::Clock;

use fun assert_bound_graph as Binding.assert_bound_graph;

use fun capture_checkpoint as Binding.capture_checkpoint;

use fun oracle_leg as PriceFeed.oracle_leg;

use fun position_economics as Position.position_economics;

use fun checkpoint::read_checkpoint as Account.read_checkpoint;

use fun venue_account::assert_market_oracles as ClearingHouse.assert_market_oracles;
