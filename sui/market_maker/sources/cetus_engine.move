// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Cetus custody boundary: a burned base position earns fees while ordinary positions own capital.
module blast_market_maker::cetus_engine;

// === Public Types ===

/// Module-sealed child slot for the immutable base-liquidity burn proof.
public struct BaseProofKey() has copy, drop, store;

/// Permanently retained typed rewards; no extraction or fee-claim entitlement exists.
public struct QuarantinedRewardKey<phantom Reward>() has copy, drop, store;
public struct StrategyKey() has copy, drop, store;
public struct PositionKey(ID) has copy, drop, store;
public struct StrategyState has store { positions: vector<ID> }

/// Temporary transaction-local checked type reordering key.
public struct CastKey() has copy, drop, store;

// === Public Functions ===

/// Anyone may settle the burned base position's actual fees into the funded shared ledger.
public fun collect_base_fees<Meme, Quote, CoinA, CoinB>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    config: &GlobalConfig,
    manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    ctx: &mut TxContext,
) {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
    vault.assert_pool(object::id(pool));
    let proof = vault.escrowed_child_mut<Meme, Quote, _, CetusLPBurnProof>(BaseProofKey());
    let (a, b) = manager.collect_fee(config, pool, proof, ctx);
    let (meme, quote) = reorder(a.into_balance(), b.into_balance(), meme_is_a, ctx);

    vault.credit_lp_fees(version, policy, treasury, meme, quote);
}

/// Atomically opens and funds one of eight ordinary positions; returns only its inert ID.
public fun open_position<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerOperatorCap,
    version: &PackageVersion,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    tick_lower: u32,
    tick_upper: u32,
    max_meme: u64,
    max_quote: u64,
    min_liquidity: u128,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    let state = vault.adapter_state<Meme, Quote, _, StrategyState>(StrategyKey());
    assert_position_slot(state.positions.length());
    assert!(max_meme > 0 && max_quote > 0 && min_liquidity > 0, EInvalidAction);
    let action = risk::new_open_position(tick_lower, tick_upper, max_meme, max_quote, min_liquidity);
    vault.authorize_action(
        version,
        option::some(object::id(cap)),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );
    let position = pool::open_position(config, pool, tick_lower, tick_upper, ctx);
    let position_id = object::id(&position);
    assert!(position.pool_id() == object::id(pool) && position.liquidity() == 0, EPositionMismatch);

    vault.escrow_child(PositionKey(position_id), position);
    vault.adapter_state_mut<Meme, Quote, _, StrategyState>(StrategyKey())
        .positions
        .push_back(position_id);
    let (paid_meme, paid_quote) = vault.add_from_capital(
        config,
        pool,
        position_id,
        max_meme,
        max_quote,
        min_liquidity,
        meme_is_a,
        clock,
        ctx,
    );
    vault.finish_action(action, paid_meme, paid_quote, 0, 0, clock);
    sui::event::emit(BlastManagedPositionOpened {
        vault_id: object::id(vault),
        position_id,
        pool_id: object::id(pool),
        tick_lower,
        tick_upper,
        max_meme,
        max_quote,
        min_liquidity,
        paid_meme,
        paid_quote,
    });

    position_id
}

/// Actual ordinary-position fees are settled before its capital changes.
public fun collect_managed_fees<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    ctx: &mut TxContext,
) {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    let position = vault.managed_position(position_id, object::id(pool));
    let (a, b) = pool::collect_fee(config, pool, position, true);
    let (meme, quote) = reorder(a, b, meme_is_a, ctx);

    vault.credit_lp_fees(version, policy, treasury, meme, quote);
}

public fun add_liquidity<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerOperatorCap,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    max_meme: u64,
    max_quote: u64,
    min_liquidity: u128,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    assert!(max_meme > 0 && max_quote > 0 && min_liquidity > 0, EInvalidAction);
    let _ = vault.managed_position(position_id, object::id(pool));
    let action = risk::new_add_liquidity(position_id, max_meme, max_quote, min_liquidity);
    vault.authorize_action(
        version,
        option::some(object::id(cap)),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );
    vault.collect_managed_fees(version, policy, treasury, config, pool, position_id, ctx);
    let (paid_meme, paid_quote) = vault.add_from_capital(
        config,
        pool,
        position_id,
        max_meme,
        max_quote,
        min_liquidity,
        meme_is_a,
        clock,
        ctx,
    );

    vault.finish_action(action, paid_meme, paid_quote, 0, 0, clock);
}

/// Ordinary partial/full removal requires both authorities and consumes a discretionary action.
public fun remove_liquidity<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerOperatorCap,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    liquidity: u128,
    min_meme: u64,
    min_quote: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    let position = vault.managed_position(position_id, object::id(pool));
    assert!(liquidity > 0 && liquidity <= position.liquidity(), EInvalidAction);
    let action = risk::new_remove_liquidity(position_id, liquidity, min_meme, min_quote);
    vault.authorize_action(
        version,
        option::some(object::id(cap)),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );

    vault.remove_and_keep(
        version,
        policy,
        treasury,
        config,
        pool,
        position_id,
        liquidity,
        min_meme,
        min_quote,
        meme_is_a,
        clock,
        ctx,
    );
    vault.finish_action(action, 0, 0, 0, 0, clock);
}

/// Signed full unwind is permissionless while paused or after turnover/actions are exhausted.
public fun unwind<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    min_meme: u64,
    min_quote: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    let liquidity = vault.managed_position(position_id, object::id(pool)).liquidity();
    assert!(liquidity > 0, EZeroLiquidity);
    let action = risk::new_unwind(position_id, liquidity, min_meme, min_quote);
    vault.authorize_action(
        version,
        option::none(),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );

    vault.remove_and_keep(
        version,
        policy,
        treasury,
        config,
        pool,
        position_id,
        liquidity,
        min_meme,
        min_quote,
        meme_is_a,
        clock,
        ctx,
    );
    vault.finish_action(action, 0, 0, 0, 0, clock);
}

/// Unknown reward assets are retained in typed quarantine, never distributed as Meme/Quote fees.
/// Anyone may settle them to unblock a zero-position close; no asset extraction seam exists.
public fun quarantine_managed_reward<Meme, Quote, A, B, Reward>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    reward_vault: &mut RewarderGlobalVault,
    position_id: ID,
    clock: &Clock,
) {
    version.assert_current();
    let _ = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    let position = vault.managed_position(position_id, object::id(pool));
    let reward = pool::collect_reward<A, B, Reward>(
        config,
        pool,
        position,
        reward_vault,
        true,
        clock,
    );
    let amount = reward.value();
    if (vault.has_adapter_state(QuarantinedRewardKey<Reward>())) {
        vault.adapter_state_mut<Meme, Quote, _, Balance<Reward>>(QuarantinedRewardKey<Reward>()).join(reward);
    } else {
        vault.add_adapter_state(QuarantinedRewardKey<Reward>(), reward);
    };

    sui::event::emit(BlastManagedRewardQuarantined<Reward> {
        vault_id: object::id(vault),
        position_id,
        amount,
    });
}

/// A fully empty, fee-settled and reward-settled position may be closed without trading authority.
/// Unsupported reward tokens stay at the venue and prevent closure instead of being discarded.
public fun close_empty_position<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    clock: &Clock,
) {
    version.assert_current();
    let _ = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    assert!(
        vault.managed_position(position_id, object::id(pool)).liquidity() == 0,
        EPositionNotEmpty,
    );
    let (fee_a, fee_b) = pool.get_position_fee(position_id);
    assert!(fee_a == 0 && fee_b == 0, EPositionNotEmpty);
    let rewards = pool::calculate_and_update_rewards(config, pool, position_id, clock);
    assert!(rewards.length() <= MAX_REWARDS, EUnsupportedRewards);
    assert!(rewards.all!(|amount| amount == 0), EUnsupportedRewards);
    let position = vault.take_escrowed_child<Meme, Quote, _, Position>(PositionKey(position_id));
    pool::close_position(config, pool, position);
    let state = vault.adapter_state_mut<Meme, Quote, _, StrategyState>(StrategyKey());
    let (found, index) = state.positions.index_of(&position_id);
    assert!(found, EPositionMismatch);
    let _ = state.positions.swap_remove(index);

    sui::event::emit(BlastManagedPositionClosed { vault_id: object::id(vault), position_id });
}

/// Exact-input flash-swap/repay; every unspent input atom and output rejoins retained capital.
public fun swap<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerOperatorCap,
    version: &PackageVersion,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    meme_input: u64,
    quote_input: u64,
    min_meme: u64,
    min_quote: u64,
    sqrt_price_limit: u128,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, A, B>();
    vault.assert_pool(object::id(pool));
    assert!((meme_input > 0) != (quote_input > 0), EInvalidAction);
    assert!(
        if (meme_input > 0) min_quote > 0 && min_meme == 0 else min_meme > 0 && min_quote == 0,
        EInvalidAction,
    );
    let action = risk::new_pool_swap(meme_input, quote_input, min_meme, min_quote, sqrt_price_limit);
    vault.authorize_action(
        version,
        option::some(object::id(cap)),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );
    let meme = vault.take_capital_meme(meme_input);
    let quote = vault.take_capital_quote(quote_input);
    let (mut a, mut b): (Balance<A>, Balance<B>) = reorder(meme, quote, meme_is_a, ctx);
    let a2b = (meme_input > 0) == meme_is_a;
    let supplied = if (a2b) a.value() else b.value();
    let (out_a, out_b, receipt) = pool::flash_swap(
        config,
        pool,
        a2b,
        true,
        supplied,
        sqrt_price_limit,
        clock,
    );
    let paid = receipt.swap_pay_amount();
    assert!(paid > 0 && paid <= supplied, EExcessiveVenuePayment);
    let output = if (a2b) out_b.value() else out_a.value();
    assert!(output >= if (meme_input > 0) min_quote else min_meme, ESlippage);
    let repay_a = if (a2b) a.split(paid) else balance::zero();
    let repay_b = if (a2b) balance::zero() else b.split(paid);
    pool::repay_flash_swap(config, pool, repay_a, repay_b, receipt);
    a.join(out_a);
    b.join(out_b);
    let (meme, quote) = reorder(a, b, meme_is_a, ctx);
    vault.join_capital(meme, quote);
    let (paid_meme, paid_quote) = if (meme_input > 0) (paid, 0) else (0, paid);

    vault.finish_action(action, paid_meme, paid_quote, 0, paid_quote, clock);
}

// === Package Functions ===

/// Retention applies to the exact net handoff. Both remaining seed assets must be positive.
/// All venue operations and core migration roll back together if creation or burning fails.
public(package) fun create_burn_and_activate<Meme, Quote, CoinA, CoinB>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    retain_bps: u64,
    tick_spacing: u32,
    config: &GlobalConfig,
    pools: &mut Pools,
    creation_cap: &PoolCreationCap,
    manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
    let meme_handoff = meme.value();
    let quote_handoff = quote.value();
    let (meme, quote) = vault.retain_capital_and_return_seed(meme, quote, retain_bps);
    let retained_meme = meme_handoff - meme.value();
    let retained_quote = quote_handoff - quote.value();
    let meme_seed = meme.value();
    let quote_seed = quote.value();
    let price = venue_math::sqrt_price_x64_down(meme_seed, quote_seed, meme_is_a);
    let (lower, upper) = pool_creator::full_range_tick_range(tick_spacing);
    let fix_a = seed_uses_coin_a(lower, upper, price, meme_seed, quote_seed, meme_is_a);
    let (a, b) = reorder(meme.into_coin(ctx), quote.into_coin(ctx), meme_is_a, ctx);
    let (position, residual_a, residual_b) = pool_creator::create_pool_v3_with_creation_cap<
        CoinA,
        CoinB,
    >(
        config,
        pools,
        creation_cap,
        tick_spacing,
        price,
        b"".to_string(),
        lower,
        upper,
        a,
        b,
        fix_a,
        clock,
        ctx,
    );
    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    assert!(liquidity > 0, EEmptyBaseSeed);
    let proof = manager.burn_lp_v2(position, ctx);
    let (residual_meme, residual_quote): (Balance<Meme>, Balance<Quote>) = reorder(
        residual_a.into_balance(),
        residual_b.into_balance(),
        meme_is_a,
        ctx,
    );
    vault.escrow_child(BaseProofKey(), proof);
    let (residual_meme_amount, residual_quote_amount) = vault.retain_seed_residuals(
        residual_meme,
        residual_quote,
    );
    vault.add_adapter_state(StrategyKey(), StrategyState { positions: vector[] });
    vault.activate_pool(pool_id);
    sui::event::emit(BlastBaseLiquidityBurned<Meme, Quote> {
        vault_id: object::id(vault),
        pool_id,
        liquidity,
        retain_bps,
        retained_meme,
        retained_quote,
        meme_seed,
        quote_seed,
        residual_meme: residual_meme_amount,
        residual_quote: residual_quote_amount,
    });
}

// === Private Functions ===

fun meme_is_coin_a<Meme, Quote, A, B>(): bool {
    assert!(factory::is_right_order<A, B>(), EInvalidCoinOrder);

    meme_is_first_asset<Meme, Quote, A, B>()
}

/// Proves exact type equality independently of venue ordering and its external linkage.
fun meme_is_first_asset<Meme, Quote, A, B>(): bool {
    assert!(
        type_name::with_defining_ids<Meme>() != type_name::with_defining_ids<Quote>(),
        EWrongPair,
    );
    let meme_is_a = type_name::with_defining_ids<Meme>() == type_name::with_defining_ids<A>();
    let correct = if (meme_is_a)
        type_name::with_defining_ids<Quote>() == type_name::with_defining_ids<B>()
    else
        type_name::with_defining_ids<Meme>() == type_name::with_defining_ids<B>() && type_name::with_defining_ids<Quote>() == type_name::with_defining_ids<A>();
    assert!(correct, EWrongPair);

    meme_is_a
}

/// A dynamic-field round trip checks the concrete runtime types before returning a balance.
fun reorder<T: store, U: store, V: store, W: store>(
    a: T,
    b: U,
    same_order: bool,
    ctx: &mut TxContext,
): (V, W) {
    let mut id = object::new(ctx);
    let (first, second) = if (same_order) {
        id.add_dynamic_field(CastKey(), a);
        let first = id.remove_dynamic_field<_, V>(CastKey());
        id.add_dynamic_field(CastKey(), b);
        (first, id.remove_dynamic_field<_, W>(CastKey()))
    } else {
        id.add_dynamic_field(CastKey(), b);
        let first = id.remove_dynamic_field<_, V>(CastKey());
        id.add_dynamic_field(CastKey(), a);
        (first, id.remove_dynamic_field<_, W>(CastKey()))
    };
    id.delete();

    (first, second)
}

/// Every actual unused seed asset remains creator-managed strategy capital.
/// Returns the received amounts for the completed base-liquidity settlement event.
fun retain_seed_residuals<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
): (u64, u64) {
    let meme_amount = meme.value();
    let quote_amount = quote.value();

    vault.join_capital(meme, quote);
    (meme_amount, quote_amount)
}

/// Shared retention arithmetic is exercised against real core handoff balances without venue stubs.
fun retain_capital_and_return_seed<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    mut meme: Balance<Meme>,
    mut quote: Balance<Quote>,
    retain_bps: u64,
): (Balance<Meme>, Balance<Quote>) {
    assert!(retain_bps < 10_000, EInvalidRetention);
    let retained_meme = market_maker_math::apply_down(meme.value(), retain_bps);
    let retained_quote = market_maker_math::apply_down(quote.value(), retain_bps);
    assert!(meme.value() > retained_meme && quote.value() > retained_quote, EEmptyBaseSeed);

    vault.join_capital(meme.split(retained_meme), quote.split(retained_quote));
    (meme, quote)
}

/// Shared admission guard; a full strategy can remove/close before opening another range.
fun assert_position_slot(count: u64) {
    assert!(count < MAX_POSITIONS, EPositionCapacity);
}

fun add_from_capital<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    max_meme: u64,
    max_quote: u64,
    min_liquidity: u128,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {
    let meme = vault.take_capital_meme(max_meme);
    let quote = vault.take_capital_quote(max_quote);
    let (mut a, mut b): (Balance<A>, Balance<B>) = reorder(meme, quote, meme_is_a, ctx);
    let position = vault.escrowed_child_mut<Meme, Quote, _, Position>(PositionKey(position_id));
    let before = position.liquidity();
    let (fix_a, amount) = fixed_liquidity_input(pool, position, a.value(), b.value());
    assert!(amount > 0, EZeroLiquidity);
    let receipt = pool::add_liquidity_fix_coin(config, pool, position, amount, fix_a, clock);
    let (paid_a, paid_b) = receipt.add_liquidity_pay_amount();
    assert!(paid_a <= a.value() && paid_b <= b.value(), EExcessiveVenuePayment);
    assert!(
        position.liquidity() >= before && position.liquidity() - before >= min_liquidity,
        ESlippage,
    );
    pool::repay_add_liquidity(config, pool, a.split(paid_a), b.split(paid_b), receipt);
    let (meme, quote) = reorder(a, b, meme_is_a, ctx);
    let (paid_meme, paid_quote) = if (meme_is_a) (paid_a, paid_b) else (paid_b, paid_a);
    vault.join_capital(meme, quote);

    (paid_meme, paid_quote)
}

fun managed_position<Meme, Quote>(
    vault: &BlastMarketMakerVault<Meme, Quote>,
    position_id: ID,
    pool_id: ID,
): &Position {
    let position = vault.escrowed_child<Meme, Quote, _, Position>(PositionKey(position_id));
    assert!(
        object::id(position) == position_id && position.pool_id() == pool_id,
        EPositionMismatch,
    );
    position
}

fun fixed_liquidity_input<A, B>(
    pool: &Pool<A, B>,
    position: &Position,
    amount_a: u64,
    amount_b: u64,
): (bool, u64) {
    let (lower, upper) = position.tick_range();
    let tick = pool.current_tick_index();
    let price = pool.current_sqrt_price();
    let (liquidity_a, _, needed_b) = clmm_math::get_liquidity_by_amount(
        lower,
        upper,
        tick,
        price,
        amount_a,
        true,
    );
    let (liquidity_b, needed_a, _) = clmm_math::get_liquidity_by_amount(
        lower,
        upper,
        tick,
        price,
        amount_b,
        false,
    );
    if (liquidity_a > 0 && needed_b <= amount_b) return (true, amount_a);
    if (liquidity_b > 0 && needed_a <= amount_a) return (false, amount_b);
    (true, 0)
}

fun remove_and_keep<Meme, Quote, A, B>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    position_id: ID,
    liquidity: u128,
    min_meme: u64,
    min_quote: u64,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    vault.collect_managed_fees(version, policy, treasury, config, pool, position_id, ctx);
    let position = vault.escrowed_child_mut<Meme, Quote, _, Position>(PositionKey(position_id));
    let before = position.liquidity();
    let (a, b) = pool::remove_liquidity(config, pool, position, liquidity, clock);
    assert!(position.liquidity() == before - liquidity, EPositionMismatch);
    let (meme, quote): (Balance<Meme>, Balance<Quote>) = reorder(a, b, meme_is_a, ctx);
    assert!(meme.value() >= min_meme && quote.value() >= min_quote, ESlippage);
    let meme_out = meme.value();
    let quote_out = quote.value();
    vault.join_capital(meme, quote);

    sui::event::emit(BlastManagedLiquidityRemoved<Meme, Quote> {
        vault_id: object::id(vault),
        position_id,
        liquidity,
        meme_out,
        quote_out,
    });
}

fun seed_uses_coin_a(lower: u32, upper: u32, price: u128, meme: u64, quote: u64, meme_is_a: bool): bool {
    let (a, b) = if (meme_is_a) (meme, quote) else (quote, meme);
    let prefer_a = (meme >= quote) == meme_is_a;
    let (_, needed_a, needed_b) = clmm_math::get_liquidity_by_amount(
        i32::from_u32(lower),
        i32::from_u32(upper),
        i32::zero(),
        price,
        if (prefer_a) a else b,
        prefer_a,
    );

    if (needed_a <= a && needed_b <= b) prefer_a else !prefer_a
}

// === Test-Only Functions ===

#[test_only]
public fun meme_is_first_asset_for_testing<Meme, Quote, A, B>(): bool {
    meme_is_first_asset<Meme, Quote, A, B>()
}

#[test_only]
public fun reorder_for_testing<T: store, U: store, V: store, W: store>(
    first: T,
    second: U,
    same_order: bool,
    ctx: &mut TxContext,
): (V, W) {
    reorder(first, second, same_order, ctx)
}

#[test_only]
public fun retain_seed_residuals_for_testing<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
): (u64, u64) {
    vault.retain_seed_residuals(meme, quote)
}

#[test_only]
public fun retain_capital_and_return_seed_for_testing<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    retain_bps: u64,
): (Balance<Meme>, Balance<Quote>) {
    vault.retain_capital_and_return_seed(meme, quote, retain_bps)
}

#[test_only]
public fun assert_position_slot_for_testing(count: u64) {
    assert_position_slot(count);
}

// === Events ===

public struct BlastBaseLiquidityBurned<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    pool_id: ID,
    liquidity: u128,
    retain_bps: u64,
    retained_meme: u64,
    retained_quote: u64,
    meme_seed: u64,
    quote_seed: u64,
    residual_meme: u64,
    residual_quote: u64,
}

public struct BlastManagedRewardQuarantined<phantom Reward> has copy, drop {
    vault_id: ID,
    position_id: ID,
    amount: u64,
}
public struct BlastManagedPositionOpened has copy, drop {
    vault_id: ID,
    position_id: ID,
    pool_id: ID,
    tick_lower: u32,
    tick_upper: u32,
    max_meme: u64,
    max_quote: u64,
    min_liquidity: u128,
    paid_meme: u64,
    paid_quote: u64,
}
public struct BlastManagedPositionClosed has copy, drop { vault_id: ID, position_id: ID }
public struct BlastManagedLiquidityRemoved<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    position_id: ID,
    liquidity: u128,
    meme_out: u64,
    quote_out: u64,
}

// === Constants ===

const MAX_POSITIONS: u64 = 8;
const MAX_REWARDS: u64 = 8;

// === Errors ===

#[error(code = 0)]
const EInvalidRetention: vector<u8> = b"Retention must leave a positive base-pool share.";
#[error(code = 1)]
const EEmptyBaseSeed: vector<u8> = b"Both base seed assets and base liquidity must be positive.";
#[error(code = 2)]
const EInvalidCoinOrder: vector<u8> =
    b"Cetus pool type arguments are not in the venue's canonical order.";
#[error(code = 3)]
const EWrongPair: vector<u8> =
    b"The pool types do not match the market maker's exact Meme and Quote.";

#[error(code = 4)]
const EPositionCapacity: vector<u8> = b"The market maker has eight active strategy positions.";
#[error(code = 5)]
const EPositionMismatch: vector<u8> =
    b"The owned position identity, pool or resulting liquidity does not match.";
#[error(code = 6)]
const EInvalidAction: vector<u8> =
    b"The action must have positive, consistent inputs and output minima.";
#[error(code = 7)]
const EZeroLiquidity: vector<u8> =
    b"The requested action cannot create or remove positive liquidity.";
#[error(code = 8)]
const EExcessiveVenuePayment: vector<u8> =
    b"The venue payment exceeds the signed maximum or is zero.";
#[error(code = 9)]
const ESlippage: vector<u8> = b"The venue result does not satisfy the signed minimum.";
#[error(code = 10)]
const EPositionNotEmpty: vector<u8> =
    b"Only a zero-liquidity, fee-settled position can close without authorization.";
#[error(code = 11)]
const EUnsupportedRewards: vector<u8> = b"Unhandled venue rewards prevent position closure.";

// === Imports ===

use blast_market_maker::{
    market_maker::{Self, BlastMarketMakerVault, BlastMarketMakerOperatorCap},
    market_maker_fee_policy::BlastMarketMakerFeePolicy,
    market_maker_math,
    package_version::BlastMarketMakerVersion as PackageVersion,
    protocol_treasury::BlastMarketMakerTreasury,
    risk,
    venue_math,
};
use cetus_clmm::{
    clmm_math,
    config::GlobalConfig,
    factory::{Self, PoolCreationCap, Pools},
    pool::{Self, Pool},
    pool_creator,
    position::Position,
    rewarder::RewarderGlobalVault,
};
use integer_mate::i32;
use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};
use std::type_name;
use sui::{balance::{Self, Balance}, clock::Clock, dynamic_field};

use fun add_from_capital as BlastMarketMakerVault.add_from_capital;
use fun collect_managed_fees as BlastMarketMakerVault.collect_managed_fees;
use fun managed_position as BlastMarketMakerVault.managed_position;
use fun remove_and_keep as BlastMarketMakerVault.remove_and_keep;
use fun retain_capital_and_return_seed as BlastMarketMakerVault.retain_capital_and_return_seed;
use fun retain_seed_residuals as BlastMarketMakerVault.retain_seed_residuals;
use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
