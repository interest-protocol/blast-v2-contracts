// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Order placement for one operation: the sealed terms, the whole-lot sizing,
/// each market session, and the proof of every fill against the checkpoint.
module blast_boosts_aftermath::orders;

// === Public Types ===

// `unwind_base_decoded` takes the position already decoded from IFixed; the
// pinned `ifixed` port aborts under test, so the pure check is exercised
// from fixtures through it.

/// The sealed terms every order of one operation is placed and proved under.
/// Package-internal; Move has no private structs.
public struct OrderTerms has copy, drop {
    is_ask: bool,
    reduce_only: bool,
    /// The whole-lot base one order may carry, sized by the core at the sealed pair.
    max_order_base: u64,
    lot_size: u64,
    base_price: u64,
    collateral_price: u64,
}

/// What one whole-lot market order proved: the base atoms filled and the raw
/// quote the session moved, already checked against the cap, the lot and the
/// slippage bound.
public struct Fill has drop {
    filled: u64,
    filled_quote: u256,
}

// === Package Functions ===

// --- Seed ---

/// Sizes the seed from a fresh flat observation and opens it in capped orders.
public(package) fun seed_position<Product, Collateral>(
    issuance: &Issuance<Product>,
    account: &mut Account<Collateral>,
    admin_cap: &AuthorityCap<ACCOUNT, ADMIN>,
    binding: &Binding,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    seed_reserve: u64,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<Collateral> {
    binding.update_funding_when_due(&mut clearing_house, base_oracle, clock);

    let (flat_observation, _) = binding.capture(
        account, registry, &clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();
    let (target_base, max_order_base, seed) = issuance.seed_terms(flat_observation, seed_reserve);

    open_seed_position(
        issuance, account, admin_cap, clearing_house, base_oracle, collateral_oracle,
        order_sizes(target_base, max_order_base), seed.lot_size(), seed.base_price(), seed.collateral_price(),
        clock, ctx,
    )
}

// --- Active ---

/// The terms of an operation that increases the vault's side: direction from
/// policy, the live cap, and the plan's sealed prices.
public(package) fun increasing_terms<Product, Collateral>(vault: &Vault<Product, Collateral>, position: ActivePosition): OrderTerms {
    active_terms(vault, false, position)
}

/// The terms of a reduce-only operation against the vault's side, otherwise as `increasing_terms`.
public(package) fun reducing_terms<Product, Collateral>(vault: &Vault<Product, Collateral>, position: ActivePosition): OrderTerms {
    active_terms(vault, true, position)
}

/// Prices the step at fresh oracles: the close-only order terms, the whole-lot
/// base still open, and the checkpoint the step starts from, which must carry
/// no resting orders.
public(package) fun unwind_terms<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    capture: &CapturedSnapshot,
    now_ms: u64,
): (OrderTerms, u64, Checkpoint) {
    let before = capture.checkpoint();
    let (side, max_order_base, base_price, collateral_price) = vault.state().unwind_constraints(
        capture.base_price_observation(), capture.collateral_price_observation(), before.lot_size(), now_ms,
    );
    before.assert_no_orders();

    let terms = OrderTerms {
        is_ask: !opens_with_ask(side), reduce_only: true, max_order_base,
        lot_size: before.lot_size(), base_price, collateral_price,
    };
    let base = before.signed_base();

    (terms, unwind_base_decoded(base.abs(), !base.is_neg(), before.lot_size(), side), before)
}

/// Reads the market's taker fee as a basis-point bound. Rebalances run at the
/// reference gas price, so Aftermath's priority surcharge never applies.
public(package) fun live_venue_fee_bps<Collateral>(clearing_house: &ClearingHouse<Collateral>): u64 {
    venue_fee_bound(ifixed_math::nonnegative_rate(clearing_house.market_params().taker_fee()))
}

/// Places every order of one active mint or redemption, proving each fill
/// against the sealed oracle and the checkpoint before the next.
///
/// Returns the market once every fill is proven.
public(package) fun fill_orders<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    binding: &Binding,
    mut checkpoint: Checkpoint,
    terms: OrderTerms,
    mut remaining: u64,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<Collateral> {
    let mut index = 0;
    while (remaining > 0) {
        let requested = terms.next_order_size(remaining, index);
        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, &terms, requested, false, clock, ctx,
        );
        clearing_house = next_market;

        let after_checkpoint = binding.capture_checkpoint(
            account, registry, &clearing_house, base_oracle, collateral_oracle,
        );
        fill.assert_checkpoint(&terms, &checkpoint, &after_checkpoint);

        checkpoint = after_checkpoint;
        remaining = remaining - fill.filled;
        index = index + 1;
    };

    clearing_house
}

/// Places the core's next rebalance order until it sizes zero or the per-call
/// budget is spent, proving each fill against the checkpoint and handing it
/// to the plan; the emergency bound applies while the plan says so.
///
/// Returns the market and the checkpoint the last fill left.
public(package) fun rebalance_orders<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    binding: &Binding,
    terms: &OrderTerms,
    plan: &mut RebalancePlan<Product>,
    mut checkpoint: Checkpoint,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, Checkpoint) {
    let mut index = 0;
    while (index < constants::max_active_orders!()) {
        let order = vault.state().next_rebalance_order(plan);
        if (order.order_base() == 0) break;

        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, terms, order.order_base(),
            order.is_emergency(), clock, ctx,
        );
        clearing_house = next_market;

        let (after, after_checkpoint) = binding.capture(
            account, registry, &clearing_house, base_oracle, collateral_oracle, clock,
        ).into_observation();
        fill.assert_checkpoint(terms, &checkpoint, &after_checkpoint);
        vault.state().accept_rebalance_fill(plan, order, after, fill.filled, clock.timestamp_ms());

        checkpoint = after_checkpoint;
        index = index + 1;
    };

    (clearing_house, checkpoint)
}

/// Places close-only orders under the emergency bound until the base is flat or
/// the per-call order budget is spent; every fill is proven against the
/// checkpoint before the next, which also keeps the book order-free.
///
/// Returns the market, the checkpoint the last fill left, the orders placed,
/// and the quote they filled in total.
public(package) fun close_orders<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    binding: &Binding,
    terms: &OrderTerms,
    mut checkpoint: Checkpoint,
    mut remaining: u64,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, Checkpoint, u64, u256) {
    let mut orders = 0;
    let mut filled_quote: u256 = 0;

    while (orders < constants::max_active_orders!() && remaining > 0) {
        let requested = terms.next_order_size(remaining, orders);
        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, terms, requested, true, clock, ctx,
        );
        clearing_house = next_market;

        let after = binding.capture_checkpoint(
            account, registry, &clearing_house, base_oracle, collateral_oracle,
        );
        fill.assert_checkpoint(terms, &checkpoint, &after);

        checkpoint = after;
        remaining = remaining - fill.filled;
        filled_quote = filled_quote.checked_add(fill.filled_quote)
            .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
        orders = orders + 1;
    };

    (clearing_house, checkpoint, orders, filled_quote)
}

// === Private Functions ===

// --- Seed ---

/// Opens the seed position one policy-sized market order at a time.
///
/// Every session must fill its whole order at the sealed oracle price within
/// the ordinary slippage bound, post nothing, and touch no liquidation; each
/// actual fill is capped separately so admitted slippage cannot carry one
/// order past the live cap.
fun open_seed_position<Product, Collateral>(
    issuance: &Issuance<Product>,
    account: &mut Account<Collateral>,
    admin_cap: &AuthorityCap<ACCOUNT, ADMIN>,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    mut orders: vector<u64>,
    lot_size: u64,
    reference_base_price: u64,
    collateral_price: u64,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<Collateral> {
    let is_long = issuance.seed_side() == policy::long();
    let aftermath_order_side = opens_with_ask(issuance.seed_side());

    while (!orders.is_empty()) {
        let order_base = orders.pop_back();
        let (next_clearing_house, summary) = venue_account::execute_order_with_cap(
            admin_cap, account, clearing_house, base_oracle, collateral_oracle,
            aftermath_order_side, order_base, false, clock, ctx,
        );
        clearing_house = next_clearing_house;

        assert_seed_fill(
            is_long, order_base, lot_size,
            summary.base_filled_bid(), summary.base_filled_ask(),
            summary.posted_orders(), summary.liquidated_size(),
            summary.liquidation_bad_debt(),
        );
        let executed = execution_price(summary.execution_price(aftermath_order_side), is_long);
        issuance.assert_seed_execution(reference_base_price, executed);
        let (_, filled_quote) = summary.filled_base_and_quote(aftermath_order_side);
        issuance.assert_seed_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));

        events::order_filled<Product>(
            object::id(account), aftermath_order_side, false, false, order_base, order_base, filled_quote,
            reference_base_price, executed,
        );
    };

    clearing_house
}

/// A seed session must fill its whole order: the shared fill checks, then exactness.
fun assert_seed_fill(
    is_bid: bool,
    order_base: u64,
    lot_size: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
) {
    let filled = active_fill(is_bid, order_base, lot_size, filled_bid, filled_ask, posted_orders, liquidated_size, bad_debt);
    assert!(filled == order_base, blast_boosts_aftermath::errors::initialization_fill_mismatch!());
}

fun initialization_order_count(target_base: u64, max_order_base: u64): u64 {
    assert!(max_order_base > 0, blast_boosts_aftermath::errors::invalid_initialization_order_size!());

    let count = target_base.div_ceil(max_order_base);
    assert!(
        count <= constants::max_initialization_orders!(),
        blast_boosts_aftermath::errors::initialization_order_count_exceeded!(),
    );

    count
}

/// Splits the seed target into whole-lot orders, each at most the per-order cap.
fun order_sizes(target_base: u64, max_order_base: u64): vector<u64> {
    assert!(
        target_base > 0 && max_order_base > 0,
        blast_boosts_aftermath::errors::invalid_initialization_order_size!(),
    );

    let order_count = initialization_order_count(target_base, max_order_base);

    let mut remaining = target_base;
    let mut orders = vector[];
    while (orders.length() < order_count) {
        let order_base = remaining.min(max_order_base);
        orders.push_back(order_base);
        remaining = remaining - order_base;
    };

    orders
}

// --- Terms ---

/// Direction from policy, the live cap, and the plan's sealed prices; a
/// reduction faces the side that increases.
fun active_terms<Product, Collateral>(vault: &Vault<Product, Collateral>, reduce_only: bool, position: ActivePosition): OrderTerms {
    let side = vault.state().side();
    let is_ask = if (reduce_only) { !opens_with_ask(side) } else { opens_with_ask(side) };

    OrderTerms {
        is_ask, reduce_only, max_order_base: vault.state().max_order_base(&position),
        lot_size: position.lot_size(), base_price: position.base_price(), collateral_price: position.collateral_price(),
    }
}

/// Rounds the taker fee up to whole basis points. Negative rebates are ignored
/// conservatively; callers provide no fee input.
fun venue_fee_bound(taker_fee: u256): u64 {
    assert!(taker_fee <= constants::ifixed_one!(), blast_boosts_aftermath::errors::venue_fee_unusable!());

    taker_fee.div_ceil(constants::ifixed_per_basis_point!()) as u64
}

/// Whether opening this side is an ask on the Aftermath port: shorts sell to open, longs buy.
fun opens_with_ask(position_side: PositionSide): bool {
    position_side == policy::short()
}

/// Bounds each next whole-lot request without re-rounding the sealed aggregate.
fun active_order_size(remaining: u64, max_order_base: u64, lot_size: u64, index: u64): u64 {
    assert!(index < constants::max_active_orders!(), blast_boosts_aftermath::errors::active_order_count_exceeded!());
    assert!(
        max_order_base > 0 && remaining > 0 && lot_size > 0 && remaining % lot_size == 0,
        blast_boosts_aftermath::errors::fill_mismatch!(),
    );

    remaining.min(max_order_base)
}

/// The next whole-lot request: what remains, capped per order.
fun next_order_size(self: &OrderTerms, remaining: u64, index: u64): u64 {
    active_order_size(remaining, self.max_order_base, self.lot_size, index)
}

/// Exact base-atom and lot validation of the position to close.
fun unwind_base_decoded(magnitude: u256, is_long: bool, lot_size: u64, side: PositionSide): u64 {
    assert!(
        lot_size > 0 && magnitude > 0
            && magnitude <= (std::u64::max_value!() as u256) * constants::base_atom_to_ifixed_scale!()
            && magnitude % ((lot_size as u256) * constants::base_atom_to_ifixed_scale!()) == 0
            && is_long == (side == policy::long()),
        blast_boosts_aftermath::errors::invalid_unwind_exposure!(),
    );

    (magnitude / constants::base_atom_to_ifixed_scale!()) as u64
}

// --- Fills ---

/// Places one whole-lot market order and verifies the venue's report of it.
///
/// The request is at most the core-sized per-order cap; the actual fill is
/// checked against the cap afterwards, so admitted slippage cannot carry one
/// order past it, and its price against the sealed oracle under the bound the
/// caller names: the ordinary one, or the emergency one for a reduction above
/// the hard cap and for shutdown. Every operation loop places its orders
/// through this step, and every accepted fill leaves one `OrderFilled` event.
fun place_order<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    terms: &OrderTerms,
    requested: u64,
    emergency: bool,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, Fill) {
    let OrderTerms { is_ask, reduce_only, lot_size, base_price, collateral_price, .. } = *terms;

    let (clearing_house, summary) = vault.venue().execute_order(
        account, clearing_house, base_oracle, collateral_oracle, is_ask, requested, reduce_only, clock, ctx,
    );

    let filled = active_fill(
        !is_ask, requested, lot_size,
        summary.base_filled_bid(), summary.base_filled_ask(),
        summary.posted_orders(), summary.liquidated_size(),
        summary.liquidation_bad_debt(),
    );
    let (_, filled_quote) = summary.filled_base_and_quote(is_ask);
    let executed = execution_price(summary.execution_price(is_ask), !is_ask);
    vault.state().assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));
    vault.state().assert_execution(emergency, base_price, executed);

    events::order_filled<Product>(
        object::id(account), is_ask, reduce_only, emergency, requested, filled, filled_quote, base_price, executed,
    );

    (clearing_house, Fill { filled, filled_quote })
}

/// Proves the checkpoint moved exactly as this fill did: an opening trade moves
/// base and quote, a reduction only base.
fun assert_checkpoint(self: &Fill, terms: &OrderTerms, before: &Checkpoint, after: &Checkpoint) {
    let filled_base = (self.filled as u256) * constants::base_atom_to_ifixed_scale!();
    let base = filled_after(terms.is_ask, before.signed_base(), filled_base);

    if (terms.reduce_only) {
        before.assert_reduction_checkpoint(after, base)
    } else {
        let quote = filled_after(terms.is_ask, before.signed_quote_notional(), self.filled_quote);
        before.assert_trade_checkpoint(after, base, quote)
    }
}

/// A signed position value after a fill. The venue keeps base and quote
/// notional under one sign (`position::add_base_to_position`), so a bid adds
/// the fill to both and an ask subtracts it from both.
fun filled_after(is_ask: bool, previous: u256, filled: u256): u256 {
    if (is_ask) { ifixed::sub(previous, filled) } else { ifixed::add(previous, filled) }
}

/// Accepts a positive whole-lot fill toward a bounded atomic aggregate.
fun active_fill(
    is_bid: bool,
    requested_base: u64,
    lot_size: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
): u64 {
    assert!(posted_orders == 0, blast_boosts_aftermath::errors::orders_posted!());
    assert!(liquidated_size == 0 && bad_debt == 0, blast_boosts_aftermath::errors::liquidation!());

    let (filled, opposite) = if (is_bid) { (filled_bid, filled_ask) } else { (filled_ask, filled_bid) };
    assert!(
        opposite == 0 && filled > 0 && filled <= (requested_base as u256) * constants::base_atom_to_ifixed_scale!()
            && lot_size > 0 && filled % ((lot_size as u256) * constants::base_atom_to_ifixed_scale!()) == 0,
        blast_boosts_aftermath::errors::fill_mismatch!(),
    );

    (filled / constants::base_atom_to_ifixed_scale!()) as u64
}

/// Converts one session's actual filled quote into atomic collateral notional.
///
/// The fill is checked separately for every order so allowed execution
/// slippage cannot make an individual order exceed the live core cap.
fun actual_fill_notional(filled_quote: u256, collateral_price: u64): u64 {
    assert!(collateral_price > 0, blast_boosts_aftermath::errors::normalization_overflow!());

    let denominator = (collateral_price as u256)
        .checked_mul(constants::collateral_to_base_scale!())
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let notional = filled_quote.div_ceil(denominator);
    assert!(notional <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    notional as u64
}

fun execution_price(raw_price: u256, round_up: bool): u64 {
    normalize_execution_price(raw_price, round_up, raw_price.is_neg())
}

fun normalize_execution_price(raw_price: u256, round_up: bool, is_negative: bool): u64 {
    assert!(!is_negative, blast_boosts_aftermath::errors::normalization_overflow!());

    let (price, representable) = if (round_up) {
        ifixed_math::fixed_to_u64_up(raw_price, constants::base_decimals!() as u64)
    } else {
        ifixed_math::fixed_to_u64_down(raw_price, constants::base_decimals!() as u64)
    };
    assert!(representable, blast_boosts_aftermath::errors::normalization_overflow!());

    price
}

// === Test-Only Functions ===

#[test_only]
public fun assert_seed_fill_for_testing(
    is_bid: bool,
    order_base: u64,
    lot_size: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
) {
    assert_seed_fill(is_bid, order_base, lot_size, filled_bid, filled_ask, posted_orders, liquidated_size, bad_debt);
}

#[test_only]
public fun max_initialization_orders_for_testing(): u64 {
    constants::max_initialization_orders!()
}

#[test_only]
public fun order_count_for_testing(
    target_base: u64,
    max_order_base: u64,
): u64 {
    initialization_order_count(target_base, max_order_base)
}

#[test_only]
public fun venue_fee_bound_for_testing(taker_fee: u256): u64 {
    venue_fee_bound(taker_fee)
}

#[test_only]
public fun opens_with_ask_for_testing(position_side: PositionSide): bool {
    opens_with_ask(position_side)
}

#[test_only]
public fun order_sizes_for_testing(target_base: u64, max_order_base: u64): vector<u64> {
    order_sizes(target_base, max_order_base)
}

#[test_only]
public fun active_order_size_for_testing(remaining: u64, max_order_base: u64, lot_size: u64, index: u64): u64 {
    active_order_size(remaining, max_order_base, lot_size, index)
}

#[test_only]
public fun active_fill_for_testing(
    is_bid: bool,
    requested_base: u64,
    lot_size: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
): u64 {
    active_fill(is_bid, requested_base, lot_size, filled_bid, filled_ask, posted_orders, liquidated_size, bad_debt)
}

#[test_only]
public fun actual_fill_notional_for_testing(
    filled_quote: u256,
    collateral_price: u64,
): u64 {
    actual_fill_notional(filled_quote, collateral_price)
}

#[test_only]
public fun execution_price_for_testing(
    raw_price: u256,
    round_up: bool,
    is_negative: bool,
): u64 {
    normalize_execution_price(raw_price, round_up, is_negative)
}

#[test_only]
public fun unwind_base_for_testing(magnitude: u256, is_long: bool, lot_size: u64, side: PositionSide): u64 {
    unwind_base_decoded(magnitude, is_long, lot_size, side)
}

#[test_only]
/// `(is_ask, reduce_only, max_order_base, lot_size, base_price, collateral_price)`.
public fun order_terms_fields(self: &OrderTerms): (bool, bool, u64, u64, u64, u64) {
    (self.is_ask, self.reduce_only, self.max_order_base, self.lot_size, self.base_price, self.collateral_price)
}

// === Imports ===

use authority_cap::authority::{ADMIN, AuthorityCap};

use blast_boosts_aftermath::{
    checkpoint::Checkpoint,
    constants,
    events,
    ifixed_math,
    snapshot::{Self, CapturedSnapshot},
    vault::Vault,
    venue_account::{Self, Binding},
};

// A capture starts from the binding it authenticates; `snapshot` sits above
// `venue_account`, so the aliases stay local.
use fun snapshot::capture as Binding.capture;

use fun snapshot::capture_checkpoint as Binding.capture_checkpoint;

use blast_boosts_core::{
    policy::{Self, PositionSide},
    state::{ActivePosition, Issuance, RebalancePlan},
};

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign and magnitude read as methods.
use fun ifixed::abs as u256.abs;

use fun ifixed::is_neg as u256.is_neg;

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{account::Account, authority::ACCOUNT, clearing_house::ClearingHouse, registry::Registry};

use sui::clock::Clock;
