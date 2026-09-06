#[test_only]
module blast_fun_dex::pool_tests;

use blast_fun_dex::pool::{Self, Factory, Pool, Position};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{balance, clock::{Self, Clock}, coin::{Self, Coin}, event};

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;
public struct PoolFixture {
    factory: Factory,
    pool: Pool<MEME, QUOTE>,
    position: Position<MEME, QUOTE>,
    clock: Clock,
    ctx: TxContext,
}

// === Tests ===

#[test]
fun swaps_separate_fees_from_reserves_and_new_lp_cannot_claim_history() {
    let mut f = start();
    let input = coin::mint_for_testing<QUOTE>(101_000, f.ctx!());
    let (output, refund) = f.buy(input, 50_000, 200);
    assert_eq!(output.value(), 50_000);
    assert_eq!(refund.value(), 0);
    assert_balances(&f.pool, 50_000, 200_000, 1_000);
    destroy(output);
    destroy(refund);

    let mut late = f.new_position();
    let meme = coin::mint_for_testing<MEME>(50_000, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(200_000, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut late, meme, quote, 100_000);
    assert_eq!(meme.value(), 0);
    assert_eq!(quote.value(), 0);
    destroy(meme);
    destroy(quote);
    let late_fee = f.claim_fees(&mut late);
    assert_eq!(late_fee.value(), 0);
    destroy(late_fee);
    let original_fee = f.claim_initial_fees();
    assert_eq!(original_fee.value(), 989);
    destroy(original_fee);
    assert_balances(&f.pool, 100_000, 400_000, 11);
    destroy(late);
    f.end();
}

#[test]
fun deposits_return_excess_and_withdrawals_exclude_fee_pot() {
    let mut f = start();
    let mut position = f.new_position();
    let meme = coin::mint_for_testing<MEME>(10_000, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(30_000, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut position, meme, quote, 10_000);
    assert_eq!(meme.value(), 0);
    assert_eq!(quote.value(), 20_000);
    destroy(meme);
    destroy(quote);
    let (meme, quote) = f.remove_liquidity(&mut position, 10_000, 10_000, 10_000);
    assert_eq!(meme.value(), 10_000);
    assert_eq!(quote.value(), 10_000);
    destroy(meme);
    destroy(quote);
    position.destroy_empty();
    assert_balances(&f.pool, 100_000, 100_000, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EFeeLimit, location = pool)]
fun signed_fee_limit_rejects_a_more_expensive_trade() {
    let mut f = start();
    let input = coin::mint_for_testing<QUOTE>(101_000, f.ctx!());
    let (output, refund) = f.buy(input, 1, 0);
    destroy(output);
    destroy(refund);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EWrongPool, location = pool)]
fun foreign_position_cannot_claim_pool_fees() {
    let mut f = start();
    let mut foreign = pool::foreign_position_for_testing<MEME, QUOTE>(f.ctx!());
    let fees = f.claim_fees(&mut foreign);
    destroy(fees);
    destroy(foreign);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EDuplicatePool, location = pool)]
fun original_meme_type_has_only_one_canonical_pool() {
    let mut f = start();
    let (duplicate, position) = f.duplicate_pool();
    destroy(duplicate);
    destroy(position);
    f.end();
}

#[test]
fun events_replay_swaps_deposits_withdrawals_and_fee_claims() {
    let mut f = start();
    let pool_id = object::id(&f.pool);
    let initial_id = object::id(&f.position);
    let created = event::events_by_type<pool::PoolCreated<MEME, QUOTE>>();
    let mut expected = bcs::to_bytes(&pool_id);
    expected.append(bcs::to_bytes(&initial_id));
    expected.append(bcs::to_bytes(&100_000u64));
    expected.append(bcs::to_bytes(&100_000u64));
    expected.append(bcs::to_bytes(&100_000u128));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&200u64));
    expected.append(bcs::to_bytes(&0u64));
    assert_eq!(created.length(), 1);
    assert_eq!(bcs::to_bytes(&created[0]), expected);

    let input = coin::mint_for_testing<QUOTE>(101_000, f.ctx!());
    let (meme, refund) = f.buy(input, 50_000, 200);
    destroy(meme);
    destroy(refund);
    let mut late = f.new_position();
    let late_id = object::id(&late);
    let positions = event::events_by_type<pool::PositionCreated>();
    let mut expected = bcs::to_bytes(&pool_id);
    expected.append(bcs::to_bytes(&late_id));
    assert_eq!(positions.length(), 1);
    assert_eq!(bcs::to_bytes(&positions[0]), expected);
    let meme = coin::mint_for_testing<MEME>(5_000, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(20_000, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut late, meme, quote, 10_000);
    destroy(meme);
    destroy(quote);
    let input = coin::mint_for_testing<MEME>(55_000, f.ctx!());
    let output = f.sell(input, 107_800, 200);
    assert_eq!(output.value(), 107_800);
    destroy(output);
    let swaps = event::events_by_type<pool::Swapped>();
    assert_eq!(swaps.length(), 2);
    assert_eq!(
        bcs::to_bytes(&swaps[0]),
        swap_bytes(pool_id, true, 50_000, 100_000, 1_000, 50_000, 200_000, 1_000),
    );
    assert_eq!(
        bcs::to_bytes(&swaps[1]),
        swap_bytes(pool_id, false, 55_000, 110_000, 2_200, 110_000, 110_000, 3_200),
    );
    let (meme, quote) = f.remove_liquidity(&mut late, 10_000, 10_000, 10_000);
    assert_eq!(meme.value(), 10_000);
    assert_eq!(quote.value(), 10_000);
    destroy(meme);
    destroy(quote);
    let changes = event::events_by_type<pool::LiquidityChanged>();
    assert_eq!(changes.length(), 2);
    assert_eq!(
        bcs::to_bytes(&changes[0]),
        liquidity_bytes(pool_id, late_id, true, 5_000, 20_000, 110_000),
    );
    assert_eq!(
        bcs::to_bytes(&changes[1]),
        liquidity_bytes(pool_id, late_id, false, 10_000, 10_000, 100_000),
    );
    let fee = f.claim_fees(&mut late);
    assert_eq!(fee.value(), 199);
    destroy(fee);
    let fee = f.claim_initial_fees();
    assert_eq!(fee.value(), 2_969);
    destroy(fee);
    let claims = event::events_by_type<pool::FeesClaimed>();
    assert_eq!(claims.length(), 2);
    let mut expected = bcs::to_bytes(&pool_id);
    expected.append(bcs::to_bytes(&late_id));
    expected.append(bcs::to_bytes(&199u64));
    assert_eq!(bcs::to_bytes(&claims[0]), expected);
    let mut expected = bcs::to_bytes(&pool_id);
    expected.append(bcs::to_bytes(&initial_id));
    expected.append(bcs::to_bytes(&2_969u64));
    assert_eq!(bcs::to_bytes(&claims[1]), expected);
    late.destroy_empty();
    let closed = event::events_by_type<pool::PositionClosed>();
    let mut expected = bcs::to_bytes(&pool_id);
    expected.append(bcs::to_bytes(&late_id));
    assert_eq!(closed.length(), 1);
    assert_eq!(bcs::to_bytes(&closed[0]), expected);
    assert_balances(&f.pool, 100_000, 100_000, 32);
    f.end();
}

#[test]
fun transferred_position_carries_earned_fees_to_its_new_owner() {
    let mut scenario = sui::test_scenario::begin(@0xA);
    let mut factory = pool::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let (mut pool, position) = pool::create_from_balances<MEME, QUOTE>(
        &mut factory,
        balance::create_for_testing(100_000),
        balance::create_for_testing(100_000),
        0,
        &clock,
        scenario.ctx(),
    );
    let position_id = object::id(&position);
    let input = coin::mint_for_testing<QUOTE>(101_000, scenario.ctx());
    let (meme, refund) = pool.buy(&factory, input, 50_000, 200, 0, &clock, scenario.ctx());
    destroy(meme);
    destroy(refund);
    transfer::public_transfer(position, @0xB);
    scenario.next_tx(@0xB);
    let mut position = scenario.take_from_sender<Position<MEME, QUOTE>>();
    assert_eq!(object::id(&position), position_id);
    let fee = pool.claim_fees(&factory, &mut position, scenario.ctx());
    assert_eq!(fee.value(), 989);
    assert_balances(&pool, 50_000, 200_000, 11);
    destroy(fee);
    destroy(position);
    destroy(pool);
    destroy(factory);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = pool::EExpired, location = pool)]
fun expired_deposit_rejects_before_zero_share_amounts() {
    let mut f = start();
    f.clock.increment_for_testing(1);
    let mut position = f.new_position();
    let meme = coin::mint_for_testing<MEME>(0, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(0, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut position, meme, quote, 0);
    destroy(meme);
    destroy(quote);
    destroy(position);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EExpired, location = pool)]
fun expired_withdrawal_precedes_empty_position() {
    let mut f = start();
    f.clock.increment_for_testing(1);
    let mut position = f.new_position();
    let (meme, quote) = f.remove_liquidity(&mut position, 1, 0, 0);
    destroy(meme);
    destroy(quote);
    destroy(position);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EInsufficientShares, location = pool)]
fun withdrawal_cannot_redeem_another_positions_shares() {
    let mut f = start();
    let mut position = f.new_position();
    let (meme, quote) = f.remove_liquidity(&mut position, 1, 0, 0);
    destroy(meme);
    destroy(quote);
    destroy(position);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EMinimumShares, location = pool)]
fun paired_deposit_rejects_more_than_supported_minimum_shares() {
    let mut f = start();
    let mut position = f.new_position();
    let meme = coin::mint_for_testing<MEME>(1, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(1, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut position, meme, quote, 2);
    destroy(meme);
    destroy(quote);
    destroy(position);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EPositionNotEmpty, location = pool)]
fun position_with_principal_cannot_be_destroyed() {
    let mut f = start();
    let mut position = f.new_position();
    let meme = coin::mint_for_testing<MEME>(1, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(1, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut position, meme, quote, 1);
    destroy(meme);
    destroy(quote);
    position.destroy_empty();
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EMinimumOutput, location = pool)]
fun withdrawal_checks_each_minimum_receipt() {
    let mut f = start();
    let mut position = f.new_position();
    let meme = coin::mint_for_testing<MEME>(1000, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(1000, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut position, meme, quote, 1000);
    destroy(meme);
    destroy(quote);
    let (meme, quote) = f.remove_liquidity(&mut position, 1000, 1001, 1000);
    destroy(meme);
    destroy(quote);
    destroy(position);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EZeroAmount, location = pool)]
fun withdrawal_rejects_a_zero_rounded_asset_receipt() {
    let mut f = start();
    let mut position = f.new_position();
    let meme = coin::mint_for_testing<MEME>(1, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(1, f.ctx!());
    let (meme, quote) = f.add_liquidity(&mut position, meme, quote, 1);
    destroy(meme);
    destroy(quote);
    let input = coin::mint_for_testing<QUOTE>(101_001, f.ctx!());
    let (meme, quote) = f.buy(input, 1, 500);
    destroy(meme);
    destroy(quote);
    let (meme, quote) = f.remove_liquidity(&mut position, 1, 0, 0);
    destroy(meme);
    destroy(quote);
    destroy(position);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::ESeedTooSmall, location = pool)]
fun seed_equal_to_permanently_locked_shares_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut factory = pool::new_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let (pool, position) = pool::create_from_balances<MEME, QUOTE>(
        &mut factory,
        balance::create_for_testing(1000),
        balance::create_for_testing(1000),
        0,
        &clock,
        &mut ctx,
    );
    destroy(pool);
    destroy(position);
    destroy(factory);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EIdenticalAssets, location = pool)]
fun pool_cannot_use_identical_asset_types() {
    let mut ctx = tx_context::dummy();
    let mut factory = pool::new_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let (pool, position) = pool::create_from_balances<MEME, MEME>(
        &mut factory,
        balance::create_for_testing(100_000),
        balance::create_for_testing(100_000),
        0,
        &clock,
        &mut ctx,
    );
    destroy(pool);
    destroy(position);
    destroy(factory);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EAccountingOverflow, location = pool)]
fun fee_growth_rejects_an_unrepresentable_accumulation() {
    let mut f = start();
    f.pool.set_fee_growth_for_testing(std::u128::max_value!());
    let input = coin::mint_for_testing<QUOTE>(101_000, f.ctx!());
    let (meme, refund) = f.buy(input, 1, 500);
    destroy(meme);
    destroy(refund);
    f.end();
}

// === Fixture Functions ===

fun start(): PoolFixture {
    let mut ctx = tx_context::dummy();
    let mut factory = pool::new_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let (pool, position) = pool::create_from_balances<MEME, QUOTE>(
        &mut factory,
        balance::create_for_testing(100_000),
        balance::create_for_testing(100_000),
        0,
        &clock,
        &mut ctx,
    );
    PoolFixture { factory, pool, position, clock, ctx }
}

fun end(f: PoolFixture) { destroy(f); }

fun assert_balances(pool: &Pool<MEME, QUOTE>, meme: u64, quote: u64, fees: u64) {
    let (actual_meme, actual_quote, actual_fees) = pool.balances_for_testing();
    assert_eq!(actual_meme, meme);
    assert_eq!(actual_quote, quote);
    assert_eq!(actual_fees, fees);
}

fun swap_bytes(
    pool_id: ID,
    buy: bool,
    meme: u64,
    quote: u64,
    fee: u64,
    meme_reserve: u64,
    quote_reserve: u64,
    fee_balance: u64,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&pool_id);
    bytes.append(bcs::to_bytes(&buy));
    bytes.append(bcs::to_bytes(&meme));
    bytes.append(bcs::to_bytes(&quote));
    bytes.append(bcs::to_bytes(&fee));
    bytes.append(bcs::to_bytes(&0u64));
    bytes.append(bcs::to_bytes(&meme_reserve));
    bytes.append(bcs::to_bytes(&quote_reserve));
    bytes.append(bcs::to_bytes(&fee_balance));
    bytes.append(bcs::to_bytes(&(100_000u128 << 32)));
    bytes.append(bcs::to_bytes(&0u64));
    bytes
}

fun liquidity_bytes(
    pool_id: ID,
    position_id: ID,
    added: bool,
    meme: u64,
    quote: u64,
    total: u128,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&pool_id);
    bytes.append(bcs::to_bytes(&position_id));
    bytes.append(bcs::to_bytes(&added));
    bytes.append(bcs::to_bytes(&10_000u128));
    bytes.append(bcs::to_bytes(&meme));
    bytes.append(bcs::to_bytes(&quote));
    bytes.append(bcs::to_bytes(&total));
    bytes
}

macro fun ctx($f: &mut PoolFixture): &mut TxContext { let f = $f; &mut f.ctx }

fun buy(
    f: &mut PoolFixture,
    input: Coin<QUOTE>,
    minimum: u64,
    fee: u64,
): (Coin<MEME>, Coin<QUOTE>) {
    let PoolFixture { factory, pool, clock, ctx, .. } = f;
    pool.buy(factory, input, minimum, fee, 0, clock, ctx)
}

fun sell(f: &mut PoolFixture, input: Coin<MEME>, minimum: u64, fee: u64): Coin<QUOTE> {
    let PoolFixture { factory, pool, clock, ctx, .. } = f;
    pool.sell(factory, input, minimum, fee, 0, clock, ctx)
}

fun new_position(f: &mut PoolFixture): Position<MEME, QUOTE> {
    let PoolFixture { pool, ctx, .. } = f;
    pool.new_position(ctx)
}

fun add_liquidity(
    f: &mut PoolFixture,
    position: &mut Position<MEME, QUOTE>,
    meme: Coin<MEME>,
    quote: Coin<QUOTE>,
    minimum: u128,
): (Coin<MEME>, Coin<QUOTE>) {
    let PoolFixture { factory, pool, clock, ctx, .. } = f;
    pool.add_liquidity(factory, position, meme, quote, minimum, 0, clock, ctx)
}

fun remove_liquidity(
    f: &mut PoolFixture,
    position: &mut Position<MEME, QUOTE>,
    shares: u128,
    meme: u64,
    quote: u64,
): (Coin<MEME>, Coin<QUOTE>) {
    let PoolFixture { factory, pool, clock, ctx, .. } = f;
    pool.remove_liquidity(factory, position, shares, meme, quote, 0, clock, ctx)
}

fun claim_fees(f: &mut PoolFixture, position: &mut Position<MEME, QUOTE>): Coin<QUOTE> {
    let PoolFixture { factory, pool, ctx, .. } = f;
    pool.claim_fees(factory, position, ctx)
}

fun claim_initial_fees(f: &mut PoolFixture): Coin<QUOTE> {
    let PoolFixture { factory, pool, position, ctx, .. } = f;
    pool.claim_fees(factory, position, ctx)
}

fun duplicate_pool(f: &mut PoolFixture): (Pool<MEME, QUOTE>, Position<MEME, QUOTE>) {
    let PoolFixture { factory, clock, ctx, .. } = f;
    pool::create_from_balances(
        factory,
        balance::create_for_testing(100_000),
        balance::create_for_testing(100_000),
        0,
        clock,
        ctx,
    )
}
