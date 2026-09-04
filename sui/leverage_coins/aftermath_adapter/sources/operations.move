// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Atomic Aftermath operations for adapter-owned leverage Vaults.
module blast_leverage_aftermath::operations;

use authority_cap::authority;
use blast_leverage_aftermath::{
    events,
    protocol::Protocol,
    snapshot,
    vault::{Self as vault, Vault},
    venue_account,
};
use blast_leverage_series_one::policy::{Self, PositionSide};
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::{
    account,
    clearing_house::{Self, ClearingHouse},
    registry::Registry,
};
use position::position;
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::Coin, coin_registry::Currency};

// === Constants ===

/// Converts six-decimal collateral atoms to nine-decimal base atoms.
const COLLATERAL_TO_BASE_SCALE: u256 = 1_000;

/// Raw IFixed units represented by one nine-decimal base atom.
const BASE_ATOM_TO_IFIXED_SCALE: u256 = 1_000_000_000;

/// Converts six-decimal seed NAV atoms to nine-decimal share atoms.
const SEED_SHARE_SCALE: u64 = 1_000;

// === Public Functions ===

/// Atomically seeds and activates one issued Aftermath leverage Vault.
///
/// Direction and size come only from the immutable Series1 policy. The selected
/// risk module authenticates the edge but cannot choose an order parameter.
/// Every external value is either retained in the Vault, shared, or consumed.
public fun initialize<Product, RiskModule: drop, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    risk_module: RiskModule,
    currency: &Currency<Collateral>,
    registry: &mut Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    seed: Coin<Collateral>,
    seed_reserve: u64,
    position_imr: u256,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol.assert_current();
    let (position_side, max_order_notional) =
        vault.initialization_constraints(&risk_module);

    let seed_amount = seed.value();
    assert_initialization_inputs(
        currency.decimals(),
        seed_amount,
        seed_reserve,
        vault.share_supply(),
    );
    assert_position_imr(position_imr);

    let vault_id = vault.id();
    let registry_id = object::id(registry);
    let clearing_house_id = object::id(&clearing_house);
    let base_oracle_id = object::id(base_oracle);
    let collateral_oracle_id = object::id(collateral_oracle);
    let collateral_type = type_name::with_original_ids<Collateral>();

    let (mut account, share_policy, admin_cap) =
        account::create_account<Collateral>(registry, ctx);
    let account_object_id = object::id(&account);
    let account_number = account::account_id(&account);
    let binding = venue_account::new_binding(
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    );
    venue_account::assert_admin_cap_binding(
        authority::`for`(&admin_cap),
        account_object_id,
    );

    account::deposit_collateral(&mut account, &admin_cap, registry, seed);
    clearing_house::allocate_collateral(
        &mut clearing_house,
        &admin_cap,
        &mut account,
        seed_amount - seed_reserve,
    );
    clearing_house::create_market_position(
        &mut clearing_house,
        &admin_cap,
        &account,
    );
    clearing_house::set_position_initial_margin_ratio(
        &mut clearing_house,
        &admin_cap,
        &account,
        position_imr,
    );

    let (pre_observation, _, _) = snapshot::capture_initialization(
        &binding,
        &account,
        registry,
        &clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
    );
    let (
        target_notional,
        reference_base_price,
        collateral_price,
        lot_size,
    ) = vault.prepare_initialization(
        pre_observation,
        seed_reserve,
        clock.timestamp_ms(),
    );
    let is_long = position_side == policy::long();
    let aftermath_order_side = order_side(position_side);
    let mut orders = order_sizes(
        target_notional,
        max_order_notional,
        reference_base_price,
        collateral_price,
        lot_size,
    );
    let mut expected_base: u64 = 0;
    let mut order_index = 0;
    while (order_index < orders.length()) {
        let order_base = *orders.borrow(order_index);
        let order_notional = notional_for_base_up(
            order_base,
            reference_base_price,
            collateral_price,
        );
        vault.assert_order_notional_allowed(order_notional);
        expected_base = expected_base
            .checked_add(order_base)
            .destroy_or!(abort blast_leverage_aftermath::errors::normalization_overflow!());
        order_index = order_index + 1;
    };

    let mut session = clearing_house::start_session(
        clearing_house,
        &admin_cap,
        &mut account,
        base_oracle,
        collateral_oracle,
        option::none(),
        clock,
        ctx,
    );
    while (!orders.is_empty()) {
        clearing_house::place_market_order(
            &mut session,
            aftermath_order_side,
            orders.pop_back(),
            false,
        );
    };
    let (mut clearing_house, summary) = clearing_house::end_session(
        session,
        &admin_cap,
        &mut account,
        false,
        false,
    );
    assert_session_result(
        is_long,
        expected_base,
        clearing_house::base_filled_bid(&summary),
        clearing_house::base_filled_ask(&summary),
        clearing_house::posted_orders(&summary),
        clearing_house::liquidated_size(&summary),
        clearing_house::liquidation_bad_debt(&summary),
    );
    let execution_price = execution_price(
        clearing_house::execution_price(&summary, aftermath_order_side),
        is_long,
    );

    clearing_house::settle_position_funding(
        &mut clearing_house,
        base_oracle,
        account_number,
        clock,
    );
    let (final_observation, checkpoint, facts) = snapshot::capture_initialization(
        &binding,
        &account,
        registry,
        &clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
    );
    vault.assert_initialization_execution(reference_base_price, execution_price);
    let final_imr = position::initial_margin_ratio(
        clearing_house::position(&clearing_house, account_number),
    );
    assert!(
        !ifixed::is_neg(final_imr) && final_imr == position_imr,
        blast_leverage_aftermath::errors::initialization_imr_mismatch!(),
    );
    let (
        seed_venue_equity,
        absolute_base,
        absolute_notional,
        final_lot_size,
        final_side,
        _,
        _,
    ) = snapshot::unpack_facts(facts);
    let seed_shareholder_nav = vault.initialize_series(
        final_observation,
        seed_reserve,
        clock.timestamp_ms(),
    );
    let locked_shares = locked_shares(seed_shareholder_nav);
    vault.mint_locked_shares(locked_shares, ctx);

    let venue_account = venue_account::new(admin_cap, binding, checkpoint);
    account::consume_policy_and_share_account(account, share_policy);
    vault.install_venue_account(venue_account);
    clearing_house::share(clearing_house);
    events::vault_initialized<Product>(
        vault_id,
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        seed_amount,
        seed_venue_equity,
        seed_reserve,
        seed_shareholder_nav,
        locked_shares,
        absolute_base,
        absolute_notional,
        final_lot_size,
        final_side,
        position_imr,
        checkpoint,
    );
}

// === Private Functions ===

fun order_sizes(
    target_notional: u64,
    max_order_notional: u64,
    base_price: u64,
    collateral_price: u64,
    lot_size: u64,
): vector<u64> {
    assert!(
        target_notional > 0 && max_order_notional > 0,
        blast_leverage_aftermath::errors::invalid_initialization_order_size!(),
    );
    let target_base = base_for_notional_down(
        target_notional,
        base_price,
        collateral_price,
        lot_size,
    );
    let max_order_base = base_for_notional_down(
        max_order_notional,
        base_price,
        collateral_price,
        lot_size,
    );
    assert!(
        target_base > 0 && max_order_base > 0,
        blast_leverage_aftermath::errors::invalid_initialization_order_size!(),
    );

    let mut remaining = target_base;
    let mut orders = vector[];
    while (remaining > 0) {
        let order_base = if (remaining < max_order_base) {
            remaining
        } else {
            max_order_base
        };
        let order_notional = notional_for_base_up(
            order_base,
            base_price,
            collateral_price,
        );
        assert!(
            order_notional <= max_order_notional,
            blast_leverage_aftermath::errors::normalization_overflow!(),
        );

        orders.push_back(order_base);
        remaining = remaining - order_base;
    };

    orders
}

/// Aftermath encodes ask as true and bid as false in its deployed bytecode.
fun order_side(position_side: PositionSide): bool {
    position_side == policy::short()
}

fun base_for_notional_down(
    notional: u64,
    base_price: u64,
    collateral_price: u64,
    lot_size: u64,
): u64 {
    assert!(
        notional > 0 && base_price > 0 && collateral_price > 0 && lot_size > 0,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    let numerator = (notional as u256)
        .checked_mul(collateral_price as u256)
        .destroy_or!(abort blast_leverage_aftermath::errors::normalization_overflow!())
        .checked_mul(COLLATERAL_TO_BASE_SCALE)
        .destroy_or!(abort blast_leverage_aftermath::errors::normalization_overflow!());
    let base = numerator / (base_price as u256);
    assert!(
        base <= std::u64::max_value!() as u256,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );

    let base = base as u64;
    base / lot_size * lot_size
}

fun notional_for_base_up(
    base: u64,
    base_price: u64,
    collateral_price: u64,
): u64 {
    let numerator = (base as u256)
        .checked_mul(base_price as u256)
        .destroy_or!(abort blast_leverage_aftermath::errors::normalization_overflow!());
    let denominator = (collateral_price as u256)
        .checked_mul(COLLATERAL_TO_BASE_SCALE)
        .destroy_or!(abort blast_leverage_aftermath::errors::normalization_overflow!());
    let notional = numerator.div_ceil(denominator);
    assert!(
        notional <= std::u64::max_value!() as u256,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );

    notional as u64
}

fun assert_session_result(
    is_long: bool,
    expected_base: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
) {
    assert!(
        posted_orders == 0,
        blast_leverage_aftermath::errors::initialization_orders_posted!(),
    );
    assert!(
        liquidated_size == 0 && bad_debt == 0,
        blast_leverage_aftermath::errors::initialization_liquidation!(),
    );

    let expected_raw_base = (expected_base as u256) * BASE_ATOM_TO_IFIXED_SCALE;
    let fill_matches = if (is_long) {
        filled_bid == expected_raw_base && filled_ask == 0
    } else {
        filled_ask == expected_raw_base && filled_bid == 0
    };
    assert!(
        fill_matches,
        blast_leverage_aftermath::errors::initialization_fill_mismatch!(),
    );
}

fun assert_initialization_inputs(
    collateral_decimals: u8,
    seed_amount: u64,
    seed_reserve: u64,
    share_supply: u64,
) {
    assert!(
        collateral_decimals == 6,
        blast_leverage_aftermath::errors::invalid_collateral_decimals!(),
    );
    assert!(
        seed_amount > 0,
        blast_leverage_aftermath::errors::invalid_seed!(),
    );
    assert!(
        seed_reserve < seed_amount,
        blast_leverage_aftermath::errors::invalid_seed_reserve!(),
    );
    assert!(
        share_supply == 0,
        blast_leverage_aftermath::errors::share_supply_not_zero!(),
    );
}

fun locked_shares(seed_nav: u64): u64 {
    seed_nav
        .checked_mul(SEED_SHARE_SCALE)
        .destroy_or!(abort blast_leverage_aftermath::errors::locked_shares_overflow!())
}

fun execution_price(raw_price: u256, round_up: bool): u64 {
    normalize_execution_price(raw_price, round_up, ifixed::is_neg(raw_price))
}

fun normalize_execution_price(
    raw_price: u256,
    round_up: bool,
    negative: bool,
): u64 {
    assert!(
        !negative,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    let down = raw_price / BASE_ATOM_TO_IFIXED_SCALE;
    let normalized = if (round_up && raw_price % BASE_ATOM_TO_IFIXED_SCALE != 0) {
        down + 1
    } else {
        down
    };
    assert!(
        normalized <= std::u64::max_value!() as u256,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );

    normalized as u64
}

fun assert_position_imr(position_imr: u256) {
    assert_position_imr_sign(ifixed::is_neg(position_imr));
}

fun assert_position_imr_sign(negative: bool) {
    assert!(
        !negative,
        blast_leverage_aftermath::errors::initialization_imr_mismatch!(),
    );
}

// === Test-Only Functions ===

#[test_only]
public fun order_sizes_for_testing(
    target_notional: u64,
    max_order_notional: u64,
    base_price: u64,
    collateral_price: u64,
    lot_size: u64,
): vector<u64> {
    order_sizes(
        target_notional,
        max_order_notional,
        base_price,
        collateral_price,
        lot_size,
    )
}

#[test_only]
public fun assert_session_result_for_testing(
    is_long: bool,
    expected_base: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
) {
    assert_session_result(
        is_long,
        expected_base,
        filled_bid,
        filled_ask,
        posted_orders,
        liquidated_size,
        bad_debt,
    );
}

#[test_only]
public fun order_side_for_testing(position_side: PositionSide): bool {
    order_side(position_side)
}

#[test_only]
public fun assert_initialization_inputs_for_testing(
    already_initialized: bool,
    collateral_decimals: u8,
    seed_amount: u64,
    seed_reserve: u64,
    share_supply: u64,
) {
    if (already_initialized) {
        blast_leverage_aftermath::vault::assert_venue_account_installable_for_testing(true);
    };
    assert_initialization_inputs(
        collateral_decimals,
        seed_amount,
        seed_reserve,
        share_supply,
    );
}

#[test_only]
public fun locked_shares_for_testing(seed_nav: u64): u64 {
    locked_shares(seed_nav)
}

#[test_only]
public fun execution_price_for_testing(
    raw_price: u256,
    round_up: bool,
    negative: bool,
): u64 {
    normalize_execution_price(raw_price, round_up, negative)
}

#[test_only]
public fun assert_position_imr_for_testing(negative: bool) {
    assert_position_imr_sign(negative);
}
