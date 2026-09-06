// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Atomic Aftermath operations for adapter-owned leverage Vaults.
module blast_leverage_aftermath::operations;

use authority_cap::authority;
use blast_admin::acl::AdminWitness;
use blast_leverage_aftermath::{
    events,
    protocol::Protocol,
    snapshot,
    vault::{Self as vault, Vault},
    venue_account,
};
use blast_leverage_series_one::{
    observation::PositionObservation,
    policy::{Self, PositionSide},
    series_one_domain::{Self, SERIES_ONE_DOMAIN},
    state::{DonationPlan, MintPlan, RebalancePlan, RedemptionPlan},
};
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::{
    account::{Self as account, Account},
    clearing_house::{Self, ClearingHouse},
    market,
    registry::Registry,
};
use position::position;
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency};

// === Constants ===

/// Converts six-decimal collateral atoms to nine-decimal base atoms.
const COLLATERAL_TO_BASE_SCALE: u256 = 1_000;

/// Raw IFixed units represented by one nine-decimal base atom.
const BASE_ATOM_TO_IFIXED_SCALE: u256 = 1_000_000_000;

/// Converts six-decimal seed NAV atoms to nine-decimal share atoms.
const SEED_SHARE_SCALE: u64 = 1_000;

/// Maximum market-order calls permitted in one atomic initialization session.
const MAX_INITIALIZATION_ORDERS: u64 = 16;

/// Hard ceiling on venue market calls in one active atomic operation.
const MAX_ACTIVE_ORDERS: u64 = 16;

// === Public Types ===

/// Linear custody of priced shares until exact collateral and final margin are proved.
public struct RedemptionReceipt<phantom Product> {
    shares: Balance<Vault<Product>>,
    net: u64,
    admin: u64,
    fee: u64,
    buffer: u64,
    fee_bps: u64,
    admin_bps: u64,
    final_equity: u64,
    final_base: u64,
    base_price: u64,
    collateral_price: u64,
    unwound_checkpoint: venue_account::Checkpoint,
}

// === Public Functions ===

/// Permissionless, policy-sized maintenance with no caller reward or trade parameters.
public fun rebalance<Product, Collateral>(
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject, collateral_price_info: &PriceInfoObject,
    clock: &Clock, ctx: &mut TxContext,
) {
    protocol.assert_current();
    vault.assert_active();
    vault.assert_collateral_type<Product, Collateral>();
    sync_health(vault, protocol, account, registry, &mut clearing_house, base_oracle,
        collateral_oracle, base_price_info, collateral_price_info, clock);
    let binding = vault.venue_binding();
    let (before, mut checkpoint) = snapshot::capture(&binding, account, registry, &clearing_house,
        base_oracle, collateral_oracle, base_price_info, collateral_price_info, clock);
    venue_account::assert_accepted_checkpoint(vault.venue_checkpoint(), &checkpoint);
    let params = clearing_house.market_params();
    let ordinary = market::taker_fee(params);
    let priority = market::resolve_priority_taker_fee(market::priority_taker_fee(params));
    let fee = venue_fee_bound(
        if (ifixed::is_neg(ordinary)) { 0 } else { ifixed::abs(ordinary) },
        if (ifixed::is_neg(priority)) { 0 } else { ifixed::abs(priority) },
    );
    let mut plan = vault.prepare_rebalance(before, fee, clock.timestamp_ms());
    let (base_price, collateral_price, lot) = plan.rebalance_valuation();
    let (side, _) = vault.active_constraints();
    let mut index = 0;
    while (index < MAX_ACTIVE_ORDERS) {
        let (requested, increase, _) = vault.rebalance_order(&plan);
        if (requested == 0) { break };
        let is_ask = if (increase) { order_side(side) } else { !order_side(side) };
        vault.assert_order_notional_allowed(notional_for_base_up(requested, base_price, collateral_price));
        let (next_market, summary) = vault.execute_order(account, clearing_house, base_oracle,
            collateral_oracle, is_ask, requested, !increase, clock, ctx);
        clearing_house = next_market;
        let filled = active_fill(!is_ask, requested, lot, clearing_house::base_filled_bid(&summary),
            clearing_house::base_filled_ask(&summary), clearing_house::posted_orders(&summary),
            clearing_house::liquidated_size(&summary), clearing_house::liquidation_bad_debt(&summary));
        let (filled_base, filled_quote) = clearing_house::filled_base_and_quote(&summary, is_ask);
        vault.assert_rebalance_execution(&plan, base_price, execution_price(clearing_house::execution_price(&summary, is_ask), !is_ask));
        vault.assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));
        let (_, _, previous_base, previous_quote, _, _, _, _, _, _, _, _, _, _, _, _, _) = checkpoint.unpack();
        let expected_base = if (is_ask) { ifixed::sub(previous_base, filled_base) } else { ifixed::add(previous_base, filled_base) };
        let (after, after_checkpoint) = snapshot::capture(&binding, account, registry, &clearing_house,
            base_oracle, collateral_oracle, base_price_info, collateral_price_info, clock);
        if (increase) {
            let expected_quote = if (is_ask) { ifixed::add(previous_quote, filled_quote) } else { ifixed::sub(previous_quote, filled_quote) };
            venue_account::assert_trade_checkpoint(&checkpoint, &after_checkpoint, expected_base, expected_quote);
        } else {
            venue_account::assert_reduction_checkpoint(&checkpoint, &after_checkpoint, expected_base);
        };
        vault.accept_rebalance_fill(&mut plan, after, filled, clock.timestamp_ms());
        checkpoint = after_checkpoint;
        index = index + 1;
    };
    complete_rebalance<Product, Collateral>(vault, plan, checkpoint);
    clearing_house::share(clearing_house);
}

/// Burns native shares only after their proportional close and exact collateral payout.
/// Entry-quote and realized PnL use authenticated post-session state, never an invented formula.
public fun redeem<Product, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    shares: Coin<Vault<Product>>,
    minimum_collateral: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    vault.assert_active();
    vault.assert_collateral_type<Product, Collateral>();
    assert!(shares.value() > 0, blast_leverage_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.assert_user_fee_limit(false, maximum_fee_bps);

    sync_health(
        vault, protocol, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, mut checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_accepted_checkpoint(vault.venue_checkpoint(), &checkpoint);
    let plan = vault.prepare_redemption(before, &shares, minimum_collateral, maximum_fee_bps, clock.timestamp_ms());
    let (base_price, collateral_price, lot) = plan.redemption_valuation();
    let (side, cap) = vault.active_constraints();
    let is_ask = !order_side(side);
    let mut remaining = plan.redemption_order_base();

    let mut index = 0;
    while (remaining > 0) {
        let requested = active_order_size(remaining, cap, base_price, collateral_price, lot, index);
        vault.assert_order_notional_allowed(notional_for_base_up(requested, base_price, collateral_price));
        let (next_market, summary) = vault.execute_order(
            account, clearing_house, base_oracle, collateral_oracle, is_ask, requested, true, clock, ctx,
        );
        clearing_house = next_market;
        let filled = active_fill(
            !is_ask, requested, lot, clearing_house::base_filled_bid(&summary),
            clearing_house::base_filled_ask(&summary), clearing_house::posted_orders(&summary),
            clearing_house::liquidated_size(&summary), clearing_house::liquidation_bad_debt(&summary),
        );
        let (filled_base, filled_quote) = clearing_house::filled_base_and_quote(&summary, is_ask);
        vault.assert_active_execution(base_price, execution_price(clearing_house::execution_price(&summary, is_ask), !is_ask));
        vault.assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));
        let (_, _, previous_base, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = checkpoint.unpack();
        let expected_base = if (is_ask) { ifixed::sub(previous_base, filled_base) } else { ifixed::add(previous_base, filled_base) };
        let (intermediate, after_checkpoint) = snapshot::capture(
            &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock,
        );
        venue_account::assert_reduction_checkpoint(&checkpoint, &after_checkpoint, expected_base);
        vault.assert_active_observation(intermediate, base_price, collateral_price, clock.timestamp_ms());
        checkpoint = after_checkpoint;
        remaining = remaining - filled;
        index = index + 1;
    };

    let (unwound, unwound_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_deposit_checkpoint(&checkpoint, &unwound_checkpoint, 0);
    let receipt = price_redemption(vault, plan, shares, unwound, unwound_checkpoint, clock.timestamp_ms());
    let cash = vault.withdraw_collateral(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        receipt.redemption_cash_required(), clock, ctx,
    );
    let (after, final_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_withdrawal_checkpoint(&receipt.unwound_checkpoint, &final_checkpoint, receipt.redemption_cash_required());
    let cash = complete_redemption(vault, receipt, cash, after, final_checkpoint, clock.timestamp_ms(), ctx);
    clearing_house::share(clearing_house);
    cash
}

/// Exchanges exact bound collateral for native leverage shares in one atomic operation.
/// Policy fixes direction and whole-lot size; partial sessions must complete the aggregate.
public fun mint<Product, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    mut cash: Coin<Collateral>,
    minimum_shares: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Vault<Product>> {
    protocol.assert_current();
    vault.assert_active();
    vault.assert_collateral_type<Product, Collateral>();
    let deposit = cash.value();
    assert!(deposit > 0, blast_leverage_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.assert_user_fee_limit(true, maximum_fee_bps);

    sync_health(
        vault, protocol, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, before_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_accepted_checkpoint(vault.venue_checkpoint(), &before_checkpoint);
    let plan = vault.prepare_mint(before, deposit, minimum_shares, maximum_fee_bps, clock.timestamp_ms());
    let (base_price, collateral_price, lot) = plan.mint_valuation();
    let (side, cap) = vault.active_constraints();
    let is_ask = order_side(side);
    let mut remaining = plan.order_base();

    let admin_cash = cash.split(plan.admin_fee(), ctx);
    vault.retain_admin_cash(admin_cash);
    let venue_deposit = cash.value();
    vault.deposit_collateral(account, registry, cash);
    vault.allocate_collateral(account, &mut clearing_house, venue_deposit);
    let (allocated, mut checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_allocated_deposit_checkpoint(&before_checkpoint, &checkpoint, venue_deposit);
    vault.assert_active_observation(allocated, base_price, collateral_price, clock.timestamp_ms());

    let mut index = 0;
    while (remaining > 0) {
        let requested = active_order_size(remaining, cap, base_price, collateral_price, lot, index);
        vault.assert_order_notional_allowed(notional_for_base_up(requested, base_price, collateral_price));
        let (next_market, summary) = vault.execute_order(
            account, clearing_house, base_oracle, collateral_oracle, is_ask, requested, false, clock, ctx,
        );
        clearing_house = next_market;
        let filled = active_fill(
            !is_ask, requested, lot, clearing_house::base_filled_bid(&summary),
            clearing_house::base_filled_ask(&summary), clearing_house::posted_orders(&summary),
            clearing_house::liquidated_size(&summary), clearing_house::liquidation_bad_debt(&summary),
        );
        let (filled_base, filled_quote) = clearing_house::filled_base_and_quote(&summary, is_ask);
        vault.assert_active_execution(base_price, execution_price(clearing_house::execution_price(&summary, is_ask), !is_ask));
        vault.assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));
        let (_, _, previous_base, previous_quote, _, _, _, _, _, _, _, _, _, _, _, _, _) = checkpoint.unpack();
        let expected_base = if (is_ask) { ifixed::sub(previous_base, filled_base) } else { ifixed::add(previous_base, filled_base) };
        let expected_quote = if (is_ask) { ifixed::add(previous_quote, filled_quote) } else { ifixed::sub(previous_quote, filled_quote) };
        let (intermediate, after_checkpoint) = snapshot::capture(
            &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock,
        );
        venue_account::assert_trade_checkpoint(&checkpoint, &after_checkpoint, expected_base, expected_quote);
        vault.assert_active_observation(intermediate, base_price, collateral_price, clock.timestamp_ms());
        checkpoint = after_checkpoint;
        remaining = remaining - filled;
        index = index + 1;
    };

    let (after, final_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_deposit_checkpoint(&checkpoint, &final_checkpoint, 0);
    let shares = complete_mint<Product, Collateral>(vault, plan, after, final_checkpoint, clock.timestamp_ms(), ctx);
    clearing_house::share(clearing_house);
    shares
}

/// Releases active buffer to holder NAV without a venue trade or withdrawal.
public fun release_buffer<Product, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<SERIES_ONE_DOMAIN>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    amount: u64,
    clock: &Clock,
) {
    protocol.assert_current();
    vault.assert_active();
    admin_witness.assert_role(series_one_domain::risk_admin_role());
    vault.assert_collateral_type<Product, Collateral>();
    assert!(amount > 0, blast_leverage_aftermath::errors::zero_amount!());
    sync_health(
        vault, protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let (observation, checkpoint) = snapshot::capture(
        &vault.venue_binding(), account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    complete_buffer_release(vault, admin_witness, observation, checkpoint, amount, clock.timestamp_ms());
}

/// Deposits configured collateral into the active funding buffer without shares or fees.
public fun donate<Product, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    cash: Coin<Collateral>,
    clock: &Clock,
) {
    protocol.assert_current();
    vault.assert_active();
    vault.assert_collateral_type<Product, Collateral>();
    let amount = cash.value();
    assert!(amount > 0, blast_leverage_aftermath::errors::zero_amount!());
    sync_health(
        vault, protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, before_checkpoint) = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    venue_account::assert_accepted_checkpoint(vault.venue_checkpoint(), &before_checkpoint);
    let plan = vault.prepare_donation(before, amount, clock.timestamp_ms());
    vault.deposit_collateral(account, registry, cash);
    let (after, checkpoint) = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    complete_donation(vault, plan, after, checkpoint, amount, clock.timestamp_ms());
}

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
    seed_funder: address,
    position_imr: u256,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol.assert_current();
    let (position_side, max_order_notional) =
        vault.initialization_constraints(&risk_module);

    let seed_amount = seed.value();
    vault::assert_seed_funder(seed_funder);
    assert_initialization_inputs(
        currency.decimals(),
        seed_amount,
        seed_reserve,
        vault.share_supply(),
    );
    assert_position_imr(position_imr);

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
        seed_amount,
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
    let mut order_index = 0;
    while (order_index < orders.length()) {
        let order_base = *orders.borrow(order_index);
        let order_notional = notional_for_base_up(
            order_base,
            reference_base_price,
            collateral_price,
        );
        vault.assert_order_notional_allowed(order_notional);
        order_index = order_index + 1;
    };

    while (!orders.is_empty()) {
        let order_base = orders.pop_back();
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
        clearing_house::place_market_order(
            &mut session,
            aftermath_order_side,
            order_base,
            false,
        );
        let (next_clearing_house, summary) = clearing_house::end_session(
            session,
            &admin_cap,
            &mut account,
            false,
            false,
        );
        clearing_house = next_clearing_house;
        assert_session_result(
            is_long,
            order_base,
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
        vault.assert_initialization_execution(
            reference_base_price,
            execution_price,
        );
        let (_, filled_quote) = clearing_house::filled_base_and_quote(
            &summary,
            aftermath_order_side,
        );
        vault.assert_order_notional_allowed(actual_fill_notional(
            filled_quote,
            collateral_price,
        ));
    };

    clearing_house::settle_position_funding(
        &mut clearing_house,
        collateral_oracle,
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
    // BLAST_ACTIVATION_BOUNDARY_A1
    let locked_shares = locked_shares(seed_shareholder_nav);
    vault.mint_locked_shares(locked_shares, seed_funder, ctx);
    // BLAST_ACTIVATION_BOUNDARY_A2

    let venue_account = venue_account::new(admin_cap, binding, checkpoint);
    // BLAST_ACTIVATION_BOUNDARY_A3
    account::consume_policy_and_share_account(account, share_policy);
    // BLAST_ACTIVATION_BOUNDARY_A4
    vault.install_venue_account(venue_account);
    // BLAST_ACTIVATION_BOUNDARY_A5
    clearing_house::share(clearing_house);
    // BLAST_ACTIVATION_BOUNDARY_A6
    emit_vault_initialized<Product>(
        vault,
        seed_amount,
        seed_venue_equity,
        absolute_base,
        absolute_notional,
        final_lot_size,
        final_side,
        position_imr,
    );
    // BLAST_ACTIVATION_BOUNDARY_A7
}

/// Reconciles one bound Aftermath checkpoint and persists objective health.
///
/// Any caller may submit the immutable bound objects and exact Pyth updates.
/// Source or identity authentication failures abort. Authenticated economic
/// faults preserve lifecycle; unresolved external changes preserve the accepted
/// economic checkpoint and emit only a novel diagnostic observation.
public fun sync_health<Product, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
) {
    protocol.assert_current();
    vault.assert_venue_custody_binding();

    let binding = vault.venue_binding();
    let stored_checkpoint = *vault.venue_checkpoint();
    let pre_capture = snapshot::capture_health(
        &binding,
        account,
        registry,
        clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
    );
    let (pre_checkpoint, collateral_price) =
        snapshot::into_funding_probe(pre_capture);
    let position = clearing_house.position(account::account_id(account));
    let (funding_rate_long, funding_rate_short) =
        market::cum_funding_rates(clearing_house.market_state());
    let funding_candidate = position::calculate_position_funding_internal(
        position,
        funding_rate_long,
        funding_rate_short,
    );

    clearing_house::settle_position_funding(
        clearing_house,
        collateral_oracle,
        account::account_id(account),
        clock,
    );

    let post_capture = snapshot::capture_health(
        &binding,
        account,
        registry,
        clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
    );
    let post_checkpoint = post_capture.checkpoint();
    let (preexisting_change, local_change) = classify_sync_changes(
        &stored_checkpoint,
        &pre_checkpoint,
        &post_checkpoint,
        funding_candidate,
        collateral_price,
    );
    apply_post_capture(
        vault,
        post_capture,
        preexisting_change,
        local_change,
    );
}

// === Package Functions ===

/// Advances the sole economic checkpoint only after sealed maintenance has succeeded.
public(package) fun complete_rebalance<Product, Collateral>(
    vault: &mut Vault<Product>, plan: RebalancePlan<Product>, checkpoint: venue_account::Checkpoint,
) {
    let (before_equity, after_equity, before_base, after_base, increase) = vault.complete_rebalance(plan);
    vault.replace_venue_checkpoint(checkpoint);
    events::rebalanced<Product>(object::id(vault), before_equity, after_equity, before_base, after_base,
        increase, vault.maintenance_reserve(), vault.admin_cash_balance<Product, Collateral>(), vault.share_supply(), checkpoint);
}

/// Holds the actual input coin across payout instead of accepting a numerical burn promise.
public(package) fun price_redemption<Product>(
    vault: &mut Vault<Product>, plan: RedemptionPlan<Product>, shares: Coin<Vault<Product>>,
    unwound: PositionObservation, unwound_checkpoint: venue_account::Checkpoint, now: u64,
): RedemptionReceipt<Product> {
    let (amount, final_base, base_price, collateral_price, fee_bps, admin_bps) = plan.redemption_terms();
    assert!(shares.value() == amount, blast_leverage_aftermath::errors::redemption_share_mismatch!());
    let (net, admin, final_equity, fee, buffer) = vault.price_redemption(plan, unwound, now);
    let shares = shares.into_balance();
    RedemptionReceipt {
        shares, net, admin, fee, buffer, fee_bps, admin_bps, final_equity, final_base,
        base_price, collateral_price, unwound_checkpoint,
    }
}

/// Returns only the exact total collateral that must leave the venue before completion.
public(package) fun redemption_cash_required<Product>(self: &RedemptionReceipt<Product>): u64 {
    self.net + self.admin
}

/// Completes custody after the public operation proves the signed withdrawal checkpoint.
/// Validates final cash and margin, retains earned admin cash, then burns the held shares.
public(package) fun complete_redemption<Product, Collateral>(
    vault: &mut Vault<Product>, receipt: RedemptionReceipt<Product>, mut cash: Coin<Collateral>,
    after: PositionObservation, checkpoint: venue_account::Checkpoint, now: u64, ctx: &mut TxContext,
): Coin<Collateral> {
    let RedemptionReceipt {
        shares, net, admin, fee, buffer, fee_bps, admin_bps, final_equity, final_base,
        base_price, collateral_price, unwound_checkpoint: _,
    } = receipt;
    vault.assert_collateral_type<Product, Collateral>();
    assert!(cash.value() == net + admin, blast_leverage_aftermath::errors::cash_checkpoint_mismatch!());
    vault.assert_redemption_cash_out(after, final_equity, final_base, base_price, collateral_price, now);

    let admin_cash = cash.split(admin, ctx);
    vault.retain_admin_cash(admin_cash);
    let burned = vault.burn_redeemed_shares(shares.into_coin(ctx));
    vault.replace_venue_checkpoint(checkpoint);
    events::redeemed<Product>(
        vault.id(), burned, net, fee, admin, buffer, fee_bps, admin_bps,
        vault.maintenance_reserve(), vault.admin_cash_balance<Product, Collateral>(), vault.share_supply(), checkpoint,
    );
    cash
}

/// Commits native mint effects only after the orchestration proved its venue checkpoint.
public(package) fun complete_mint<Product, Collateral>(
    vault: &mut Vault<Product>, plan: MintPlan<Product>, after: PositionObservation,
    checkpoint: venue_account::Checkpoint, now: u64, ctx: &mut TxContext,
): Coin<Vault<Product>> {
    let deposit = plan.mint_deposit();
    let (shares, contribution, fee, admin, buffer, rate, admin_rate) = vault.complete_mint(plan, after, now, ctx);
    vault.replace_venue_checkpoint(checkpoint);
    events::minted<Product>(
        vault.id(), deposit, shares.value(), contribution, fee, admin, buffer, rate, admin_rate,
        vault.maintenance_reserve(), vault.admin_cash_balance<Product, Collateral>(),
        vault.share_supply(), checkpoint,
    );
    shares
}

/// Completes a pure buffer relabeling only at the accepted economic checkpoint.
public(package) fun complete_buffer_release<Product>(
    vault: &mut Vault<Product>,
    admin_witness: &AdminWitness<SERIES_ONE_DOMAIN>,
    observation: PositionObservation,
    checkpoint: venue_account::Checkpoint,
    amount: u64,
    reference_time_ms: u64,
) {
    admin_witness.assert_role(series_one_domain::risk_admin_role());
    venue_account::assert_accepted_checkpoint(vault.venue_checkpoint(), &checkpoint);
    vault.release_buffer(admin_witness, observation, amount, reference_time_ms);
    events::buffer_released<Product>(vault.id(), amount, vault.maintenance_reserve());
}

/// Shared production completion phase, after the real venue deposit has returned.
public(package) fun complete_donation<Product>(
    vault: &mut Vault<Product>,
    plan: DonationPlan<Product>,
    after: PositionObservation,
    checkpoint: venue_account::Checkpoint,
    amount: u64,
    reference_time_ms: u64,
) {
    venue_account::assert_deposit_checkpoint(vault.venue_checkpoint(), &checkpoint, amount);
    vault.complete_donation(plan, after, reference_time_ms);
    vault.replace_venue_checkpoint(checkpoint);
    events::donated<Product>(vault.id(), amount, vault.maintenance_reserve(), checkpoint);
}

/// Applies the complete Blast-owned post-capture synchronization phase.
public(package) fun apply_post_capture<Product>(
    vault: &mut Vault<Product>,
    post_capture: snapshot::CapturedSnapshot,
    preexisting_change: snapshot::Change,
    local_change: snapshot::Change,
) {
    let stored_checkpoint = *vault.venue_checkpoint();
    let net = snapshot::net_funding(preexisting_change, local_change);
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        snapshot::funding_change_fields(&net);
    let (absorbed, uncovered, reserve_after) = if (has_funding) {
        vault.settle_funding(is_cost, amount)
    } else {
        (0, 0, vault.maintenance_reserve())
    };
    let checkpoint = snapshot::finish_health(post_capture);

    let diagnostic_changed = vault.note_checkpoint_health(&checkpoint, checkpoint_clean);
    if (checkpoint_clean) {
        vault.replace_venue_checkpoint(checkpoint);
    };

    let vault_id = vault.id();
    // A zero-net interval still advances authenticated source identity and
    // needs a reducer-visible completed fact; identical retries remain quiet.
    if (checkpoint_clean && !snapshot::checkpoint_unchanged(&stored_checkpoint, &checkpoint)) {
        events::funding_settled<Product>(
            vault_id,
            is_cost,
            raw_amount,
            amount,
            absorbed,
            uncovered,
            reserve_after,
            stored_checkpoint,
            checkpoint,
        );
    };
    if (diagnostic_changed) {
        events::health_synchronized<Product>(
            vault_id,
            if (checkpoint_clean) {
                events::checkpoint_reconciled_reason()
            } else {
                events::unexpected_checkpoint_reason()
            },
            checkpoint,
        );
    };
}

/// Emits activation facts read back from the resulting real Vault state.
public(package) fun emit_vault_initialized<Product>(
    vault: &Vault<Product>,
    seed_amount: u64,
    seed_venue_equity: u64,
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
) {
    let (
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    ) = vault.venue_binding().unpack_binding();
    let checkpoint = *vault.venue_checkpoint();
    let (locked_shares, seed_funder) = vault.seed_facts();
    let seed_reserve = vault.maintenance_reserve();

    events::vault_initialized<Product>(
        vault.id(),
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
        locked_shares / SEED_SHARE_SCALE,
        locked_shares,
        seed_funder,
        absolute_base,
        absolute_notional,
        lot_size,
        position_side,
        position_imr,
        checkpoint,
    );
}

// === Private Functions ===

/// Aftermath's priority rate is an additional surcharge, not an alternative fee.
/// Negative rebates are ignored conservatively; callers provide no fee input.
fun venue_fee_bound(ordinary: u256, priority: u256): u64 {
    let one = 1_000_000_000_000_000_000u256;
    assert!(ordinary <= one && priority <= one && ordinary <= one - priority,
        blast_leverage_aftermath::errors::venue_fee_unusable!());
    ((ordinary + priority).div_ceil(100_000_000_000_000)) as u64
}

fun classify_sync_changes(
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
    funding_candidate: u256,
    collateral_price: u256,
): (snapshot::Change, snapshot::Change) {
    let preexisting_change = if (
        snapshot::checkpoint_ready_for_settlement(stored, before)
    ) {
        snapshot::unchanged_change()
    } else {
        snapshot::classify_preexisting_funding(stored, before)
    };
    let local_change = snapshot::classify_change(
        before,
        after,
        funding_candidate,
        collateral_price,
    );
    (preexisting_change, local_change)
}

/// Bounds each next whole-lot request without re-rounding the sealed aggregate.
fun active_order_size(
    remaining: u64, cap: u64, base_price: u64, collateral_price: u64, lot: u64, index: u64,
): u64 {
    assert!(index < MAX_ACTIVE_ORDERS, blast_leverage_aftermath::errors::active_order_count_exceeded!());
    let maximum = base_for_notional_down(cap, base_price, collateral_price, lot);
    assert!(maximum > 0 && remaining > 0 && remaining % lot == 0, blast_leverage_aftermath::errors::active_fill_mismatch!());
    remaining.min(maximum)
}

fun assert_deadline(now: u64, deadline: u64) {
    assert!(now <= deadline, blast_leverage_aftermath::errors::deadline_expired!());
}

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
    let order_count = initialization_order_count(target_base, max_order_base);

    let mut remaining = target_base;
    let mut orders = vector[];
    while (orders.length() < order_count) {
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
    assert!(
        remaining == 0,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );

    orders
}

fun initialization_order_count(
    target_base: u64,
    max_order_base: u64,
): u64 {
    assert!(
        max_order_base > 0,
        blast_leverage_aftermath::errors::invalid_initialization_order_size!(),
    );
    let quotient = target_base / max_order_base;
    let remainder = target_base % max_order_base;
    let count = quotient
        .checked_add(if (remainder == 0) { 0 } else { 1 })
        .destroy_or!(
            abort blast_leverage_aftermath::errors::initialization_order_count_exceeded!()
        );
    assert!(
        count <= MAX_INITIALIZATION_ORDERS,
        blast_leverage_aftermath::errors::initialization_order_count_exceeded!(),
    );

    count
}

/// Maps the Series side to the Aftermath port's bid/ask boolean convention.
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

/// Converts one session's actual filled quote into atomic collateral notional.
///
/// The fill is checked separately for every order so allowed execution
/// slippage cannot make an individual order exceed the live Series1 cap.
fun actual_fill_notional(
    filled_quote: u256,
    collateral_price: u64,
): u64 {
    assert!(
        collateral_price > 0,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    let denominator = (collateral_price as u256)
        .checked_mul(COLLATERAL_TO_BASE_SCALE)
        .destroy_or!(abort blast_leverage_aftermath::errors::normalization_overflow!());
    let notional = filled_quote.div_ceil(denominator);
    assert!(
        notional <= std::u64::max_value!() as u256,
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    notional as u64
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
    assert!(posted_orders == 0, blast_leverage_aftermath::errors::active_orders_posted!());
    assert!(liquidated_size == 0 && bad_debt == 0, blast_leverage_aftermath::errors::active_liquidation!());
    let (filled, opposite) = if (is_bid) { (filled_bid, filled_ask) } else { (filled_ask, filled_bid) };
    assert!(
        opposite == 0 && filled > 0 && filled <= (requested_base as u256) * BASE_ATOM_TO_IFIXED_SCALE
            && lot_size > 0 && filled % ((lot_size as u256) * BASE_ATOM_TO_IFIXED_SCALE) == 0,
        blast_leverage_aftermath::errors::active_fill_mismatch!(),
    );
    (filled / BASE_ATOM_TO_IFIXED_SCALE) as u64
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
public fun venue_fee_bound_for_testing(ordinary: u256, priority: u256): u64 { venue_fee_bound(ordinary, priority) }

#[test_only]
public fun active_order_size_for_testing(
    remaining: u64, cap: u64, base_price: u64, collateral_price: u64, lot: u64, index: u64,
): u64 {
    active_order_size(remaining, cap, base_price, collateral_price, lot, index)
}

#[test_only]
public fun assert_deadline_for_testing(now: u64, deadline: u64) { assert_deadline(now, deadline); }

#[test_only]
public fun active_fill_for_testing(
    is_bid: bool, requested_base: u64, lot_size: u64, filled_bid: u256, filled_ask: u256,
    posted_orders: u64, liquidated_size: u64, bad_debt: u256,
): u64 {
    active_fill(is_bid, requested_base, lot_size, filled_bid, filled_ask, posted_orders, liquidated_size, bad_debt)
}

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
public fun max_initialization_orders_for_testing(): u64 {
    MAX_INITIALIZATION_ORDERS
}

#[test_only]
public fun order_count_for_testing(
    target_base: u64,
    max_order_base: u64,
): u64 {
    initialization_order_count(target_base, max_order_base)
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
public fun actual_fill_notional_for_testing(
    filled_quote: u256,
    collateral_price: u64,
): u64 {
    actual_fill_notional(filled_quote, collateral_price)
}

#[test_only]
public fun assert_position_imr_for_testing(negative: bool) {
    assert_position_imr_sign(negative);
}

#[test_only]
public fun classify_sync_change_for_testing(
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
): snapshot::Change {
    let (preexisting_change, local_change) =
        classify_sync_changes_for_testing(
            stored,
            before,
            after,
            candidate_negative,
            candidate_collateral_magnitude,
        );
    snapshot::net_funding(preexisting_change, local_change)
}

#[test_only]
public fun classify_sync_changes_for_testing(
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
): (snapshot::Change, snapshot::Change) {
    let preexisting_change = if (
        snapshot::checkpoint_ready_for_settlement(stored, before)
    ) {
        snapshot::unchanged_change()
    } else {
        snapshot::classify_preexisting_funding_for_testing(stored, before)
    };
    let local_change = snapshot::classify_change_with_candidate_for_testing(
        before,
        after,
        candidate_negative,
        candidate_collateral_magnitude,
    );
    (preexisting_change, local_change)
}

#[test_only]
public fun apply_post_capture_for_testing<Product>(
    vault: &mut Vault<Product>,
    post_capture: snapshot::CapturedSnapshot,
    change: snapshot::Change,
) {
    apply_post_capture(
        vault,
        post_capture,
        snapshot::unchanged_change(),
        change,
    );
}

#[test_only]
public fun apply_post_captures_for_testing<Product>(
    vault: &mut Vault<Product>,
    post_capture: snapshot::CapturedSnapshot,
    preexisting_change: snapshot::Change,
    local_change: snapshot::Change,
) {
    apply_post_capture(
        vault,
        post_capture,
        preexisting_change,
        local_change,
    );
}
