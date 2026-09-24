// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// One deterministic lifecycle through a sealed mock adapter, replayed from its events.
///
/// Every required payload is decoded from its wire bytes and reduced into a fresh model that
/// starts from the eventless publication state. After every lifecycle step the model must equal
/// the authoritative getters and object reads, and at the end every destination's native coins.
/// Launchpad payloads must arrive only inside the `blast_events::Event<T>` envelope; migrator
/// payloads only directly. After migration the mock adapter collects with auto-LP and burns the
/// burn share's Meme, the creator settles a fee-split update and claims the creator balance, a
/// buyback admin burns Meme bought with the burn Quote, Blast's live share changes between
/// collections, and a holder-reward round is published and claimed.
module blast_fun_migrators::replay_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const PUBLISHER: address = @0xB0B;

const ADMIN: address = @0xAD;

const LAUNCHER: address = @0x1A;

const CREATOR: address = @0xC0FFEE;

const BUYER: address = @0xB0;

const KEEPER: address = @0xEE;

const PROTOCOL_RECIPIENT: address = @0xA1;

const TEAM: address = @0xA4;

const ADVISOR: address = @0xA5;

const ROUTE_A: address = @0xD1;

const ROUTE_B: address = @0xD2;

const ROUTE_C: address = @0xD3;

const ALICE: address = @0xA11CE;

const FIRST_PROTOCOL_DESTINATION: address = @0xF1;

const SECOND_PROTOCOL_DESTINATION: address = @0xF2;

const DECIMALS: u8 = 6;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const TARGET: u64 = 25_000_000;

const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 200;

const PUBLIC_START_MS: u64 = 1_234;

const POOL_TICK_SPACING: u32 = 60;

const POOL_FEE_RATE: u64 = 2_500;

const PROTECTION_WINDOW_MS: u64 = 60_000;

const CUMULATIVE_SENDER_BPS: u64 = 9_000;

const PER_TRANSACTION_BPS: u64 = 8_000;

const BASIS_POINTS: u64 = 10_000;

/// Whole tokens every generated Meme currency mints, at its decimals.
const MEME_SUPPLY_WHOLE_TOKENS: u64 = 1_000_000_000;

/// Blast's allocation is always the first recipient and rounds up: part 2 of the Meme parts
/// (curve, pool, recipients) and part 1 of the Quote parts (pool, recipients).
const PROTOCOL_MEME_PART: u64 = 2;

const PROTOCOL_QUOTE_PART: u64 = 1;

/// `launch::Lifecycle` tags in declaration order.
const LIVE: u8 = 0;

const MIGRATION_READY: u8 = 1;

const MIGRATED: u8 = 2;

/// Model lifecycle before any launch exists.
const UNCREATED: u8 = 255;

/// `creator_authority::CreatorRecipient::Address` tag.
const CREATOR_ADDRESS_TAG: u32 = 0;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct REPLAY_TESTS has drop {}

public struct QUOTE() has drop;

/// A second original Meme type whose own pair is set and then cleared.
public struct OtherMeme() has drop;

/// The mock adapter's sealed witness, which is also its vault venue marker.
public struct Venue() has drop;

public struct MockPool has key { id: UID }

/// Venue position owning the supplied principal and every auto-LP addition; the vault owns the
/// residuals.
public struct MockPosition<phantom Meme, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    liquidity: u128,
}

/// Lifecycle choreography plus the replay model its transactions are reduced into.
public struct ReplayFixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    runtime: RuntimeConfig,
    clock: Clock,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    replay: Replay,
}

/// Every fact reduced from decoded payloads, starting from the eventless publication state.
public struct Replay has drop {
    default_shares: Shares,
    coin_shares: vector<CoinShares>,
    protocol_destination: address,
    protocol_allocation: RecipientEntry,
    ticket_id: ID,
    meme: String,
    decimals: u8,
    atomic_supply: u64,
    metadata_cap_id: ID,
    creator: Option<address>,
    burnable: bool,
    sell_burn_bps: u64,
    total_supply: u64,
    launch_id: ID,
    migration_witness: String,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    launch_fee_split: SplitEntry,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    plan: PlanEntry,
    protection_window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
    public_start_ms: Option<u64>,
    lifecycle: u8,
    meme_reserve: u64,
    real_quote_reserve: u64,
    allocated_meme: u64,
    binding: Binding,
    generation: u64,
    fee_split: SplitEntry,
    venue: String,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    position_meme: u64,
    position_quote: u64,
    creator_balance: Pair,
    auto_lp: Pair,
    rewards: Pair,
    burn_quote: u64,
    next_round: u64,
    last_checkpoint: Option<u64>,
    rounds: vector<RoundEntry>,
    recipients_paid: u64,
    allocated_meme_paid: u64,
    allocated_quote_paid: u64,
    payouts: vector<Payout>,
}

public struct Shares has copy, drop {
    meme_bps: u64,
    quote_bps: u64,
}

/// One original Meme type's own pair, which replaces the defaults for its collections.
public struct CoinShares has copy, drop {
    meme: String,
    shares: Shares,
}

/// A Meme and Quote amount held by one vault balance.
public struct Pair has copy, drop {
    meme: u64,
    quote: u64,
}

/// A decoded allocation `Recipient`.
public struct RecipientEntry has copy, drop {
    destination: address,
    meme_bps: u64,
    quote_bps: u64,
}

/// A decoded `AllocationPlan`: the curve's and the pool's shares, then its recipients in payment
/// order.
public struct PlanEntry has copy, drop {
    curve_meme_bps: u64,
    lp_meme_bps: u64,
    lp_quote_bps: u64,
    recipients: vector<RecipientEntry>,
}

public struct RouteEntry has copy, drop {
    destination: address,
    bps: u64,
}

/// A decoded `FeeSplit`: its four shares, then its recipients in payment order.
public struct SplitEntry has copy, drop {
    creator_bps: u64,
    auto_lp_bps: u64,
    rewards_bps: u64,
    burn_bps: u64,
    recipients: vector<RouteEntry>,
}

/// One published holder-reward round: its remaining funds and the leaves it has paid.
public struct RoundEntry has copy, drop {
    round_id: ID,
    number: u64,
    root: vector<u8>,
    leaf_count: u64,
    remaining: Pair,
    claimed: vector<u64>,
}

/// The custody `VaultCreated` announced.
public struct Binding has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
}

/// Native coins one destination must hold once every payout event is reduced.
public struct Payout has copy, drop {
    destination: address,
    meme: u64,
    quote: u64,
}

// === Tests ===

#[test]
fun replayed_events_equal_every_getter_and_native_payout_across_the_lifecycle() {
    let mut fixture = start();

    fixture.configure_policy();
    fixture.assert_state();
    fixture.create_launch();
    fixture.assert_state();
    fixture.buy_to_graduation();
    fixture.assert_state();
    fixture.migrate();
    fixture.assert_state();
    fixture.claim_creator_caps();
    fixture.collect(10_001, 3_333);
    fixture.assert_state();
    fixture.settle_fee_split(777, 0);
    fixture.assert_state();
    fixture.buy_back_and_burn();
    fixture.assert_state();
    fixture.change_blast_share();
    fixture.redirect_protocol_share(SECOND_PROTOCOL_DESTINATION);
    fixture.collect(5, 12_345);
    fixture.assert_state();
    fixture.claim_creator_fees();
    fixture.assert_state();
    fixture.publish_round();
    fixture.assert_state();
    fixture.claim_reward();
    fixture.assert_state();
    fixture.assert_native_payouts();

    fixture.end();
}

// === Test Helpers ===

/// Runs one transaction as `$sender`, then reduces every payload it emitted into the model.
macro fun replay_next_tx(
    $fixture: &mut ReplayFixture,
    $sender: address,
    $fn: |&mut ReplayFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
    fixture.reduce_transaction($sender);
}

macro fun replay_ctx($fixture: &mut ReplayFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): ReplayFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    let roles = blast_fun_domain::creator_admin_role_for_testing()
        | blast_fun_domain::buyback_admin_role();
    authority.grant_admin(&root, roles, ADMIN, scenario.ctx());
    destroy(root);
    launch_config::init_for_testing(scenario.ctx());
    lp_fee_policy::init_for_testing(scenario.ctx());
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(PUBLIC_START_MS);

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    ReplayFixture {
        scenario,
        version,
        migrators_version,
        runtime,
        clock,
        authority,
        admin_cap,
        replay: new_replay(PUBLISHER),
    }
}

fun replay_end(self: ReplayFixture) {
    let ReplayFixture {
        scenario,
        version,
        migrators_version,
        runtime,
        clock,
        authority,
        admin_cap,
        replay: _,
    } = self;

    destroy(version);
    destroy(migrators_version);
    destroy(runtime);
    clock.destroy_for_testing();
    destroy(authority);
    destroy(admin_cap);
    scenario.end();
}

// Lifecycle Steps

/// Launch intake policy, a default pair, this Meme's own pair, another coin's pair set and cleared,
/// and the first protocol destination.
fun configure_policy(self: &mut ReplayFixture) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut config = f.scenario.take_shared<LaunchConfig>();
        let mut policy = f.take_policy();

        config.set_quote<QUOTE>(&f.version, &admin, VIRTUAL_QUOTE);
        config.set_migration_witness_allowed<Venue>(&f.version, &admin, true);
        config.set_trade_fees(&f.version, &admin, bps::new(QUOTE_FEE_BPS), bps::new(MEME_FEE_BPS));
        config.set_protocol_allocation(
            &f.version,
            &admin,
            PROTOCOL_RECIPIENT,
            bps::new(500),
            bps::new(1_000),
        );
        let version = &f.migrators_version;
        policy.set_default_shares(version, &admin, bps::new(1_000), bps::new(2_000));
        policy.set_coin_shares<OtherMeme>(version, &admin, bps::new(9), bps::new(9));
        policy.set_coin_shares<REPLAY_TESTS>(version, &admin, bps::new(1_500), bps::new(2_500));
        policy.clear_coin_shares<OtherMeme>(version, &admin);
        policy.set_protocol_destination(version, &admin, FIRST_PROTOCOL_DESTINATION);

        test_scenario::return_shared(config);
        test_scenario::return_shared(policy);
    });
}

/// Mints the ticket, then starts, configures with protection, pre-buys, and shares the launch.
fun create_launch(self: &mut ReplayFixture) {
    let ticket;
    self.next_tx!(LAUNCHER, |f| {
        ticket = launch_ticket::new(
            test_utils::create_one_time_witness<REPLAY_TESTS>(),
            DECIMALS,
            b"RPLY".to_string(),
            b"Replay".to_string(),
            b"".to_string(),
            b"".to_string(),
            creator_authority::new_address(CREATOR),
            true,
            0,
            f.ctx!(),
        );
    });
    self.next_tx!(LAUNCHER, |f| {
        let config = f.scenario.take_shared<LaunchConfig>();
        let mut currency = f.take_currency();
        let mut initializer = launch::new<_, QUOTE, _>(
            ticket,
            &f.version,
            &config,
            Venue(),
            POOL_TICK_SPACING,
            POOL_FEE_RATE,
        );
        initializer.set_graduation_target(TARGET);
        initializer.set_allocation_plan(plan());
        initializer.set_lp_fee_split(first_split());
        initializer.set_protection(
            PROTECTION_WINDOW_MS,
            bps::new(CUMULATIVE_SENDER_BPS),
            bps::new(PER_TRANSACTION_BPS),
        );
        let mut launch = initializer.finalize(&mut currency, &config, f.ctx!());
        let (meme, refund) = launch.buy(
            &f.version,
            &f.runtime,
            coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!()),
            1,
            &f.clock,
            f.ctx!(),
        );
        transfer::public_transfer(meme, LAUNCHER);
        transfer::public_transfer(refund, LAUNCHER);
        launch.share(&f.clock);

        test_scenario::return_to_address(COIN_REGISTRY, currency);
        test_scenario::return_shared(config);
    });
}

/// One protected public purchase past the target: the excess is refunded and trading closes.
fun buy_to_graduation(self: &mut ReplayFixture) {
    self.next_tx!(BUYER, |f| {
        let mut launch = f.take_launch();
        let (meme, refund) = launch.buy(
            &f.version,
            &f.runtime,
            coin::mint_for_testing<QUOTE>(30_000_000, f.ctx!()),
            1,
            &f.clock,
            f.ctx!(),
        );
        transfer::public_transfer(meme, BUYER);
        transfer::public_transfer(refund, BUYER);

        test_scenario::return_shared(launch);
    });
}

/// Migrates through the sealed mock adapter in one transaction.
fun migrate(self: &mut ReplayFixture) {
    self.next_tx!(KEEPER, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();

        mock_adapter(&mut launch, &f.version, &mut currency, f.ctx!());

        test_scenario::return_shared(launch);
        test_scenario::return_to_address(COIN_REGISTRY, currency);
    });
}

/// The creator recipient claims both creator capabilities; the curve-fee cap updates the fee split
/// and claims the creator balance.
fun claim_creator_caps(self: &mut ReplayFixture) {
    self.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
            &f.version,
            &f.runtime,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        transfer::public_transfer(curve_fee_cap, CREATOR);
        transfer::public_transfer(metadata_cap, CREATOR);

        test_scenario::return_shared(launch);
    });
}

/// Adapter collection of the vault position with auto-LP; minted balances stand in for venue fees.
fun collect(self: &mut ReplayFixture, meme: u64, quote: u64) {
    self.next_tx!(KEEPER, |f| {
        let mut vault = f.take_vault();
        let policy = f.take_policy();
        let mut currency = f.take_currency();

        vault.split_fees(
            &policy,
            &mut currency,
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            f.ctx!(),
        );
        compound(&mut vault);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(policy);
        test_scenario::return_to_address(COIN_REGISTRY, currency);
    });
}

/// Settles the outstanding collection under generation zero, then commits the next split.
fun settle_fee_split(self: &mut ReplayFixture, meme: u64, quote: u64) {
    self.next_tx!(CREATOR, |f| {
        let curve_fee_cap = f.scenario.take_from_sender<CurveFeeCap<REPLAY_TESTS>>();
        let launch = f.take_launch();
        let mut vault = f.take_vault();
        let policy = f.take_policy();
        let mut currency = f.take_currency();

        vault.split_fees(
            &policy,
            &mut currency,
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            f.ctx!(),
        );
        compound(&mut vault);
        vault.update_fee_split(&launch, &curve_fee_cap, next_split());

        f.scenario.return_to_sender(curve_fee_cap);
        test_scenario::return_shared(launch);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(policy);
        test_scenario::return_to_address(COIN_REGISTRY, currency);
    });
}

/// A buyback admin swaps the burn Quote through the mock venue, which takes two thirds of it into
/// the position and pays three Meme per Quote taken out of the position, at exactly the minimum.
fun buy_back_and_burn(self: &mut ReplayFixture) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut vault = f.take_vault();
        let mut currency = f.take_currency();

        let mut quote = vault.take_buyback_quote(&admin);
        let quote_in = quote.value();
        let spent = quote_in * 2 / 3;
        let position = vault.position_mut<_, _, _, MockPosition<REPLAY_TESTS, QUOTE>>(&Venue());
        position.quote.join(quote.split(spent));
        let meme = position.meme.split(spent * 3);
        vault.burn_buyback(&mut currency, meme, quote, quote_in, spent * 3, f.ctx!());

        test_scenario::return_shared(vault);
        test_scenario::return_to_address(COIN_REGISTRY, currency);
    });
}

/// Clears this Meme's own pair and moves the defaults, so the next collection pays the new
/// defaults.
fun change_blast_share(self: &mut ReplayFixture) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut policy = f.take_policy();

        policy.clear_coin_shares<REPLAY_TESTS>(&f.migrators_version, &admin);
        policy.set_default_shares(&f.migrators_version, &admin, bps::new(3_000), bps::new(500));

        test_scenario::return_shared(policy);
    });
}

/// The live curve-fee cap claims the creator balance to the creator.
fun claim_creator_fees(self: &mut ReplayFixture) {
    self.next_tx!(CREATOR, |f| {
        let curve_fee_cap = f.scenario.take_from_sender<CurveFeeCap<REPLAY_TESTS>>();
        let launch = f.take_launch();
        let mut vault = f.take_vault();

        let (meme, quote) = vault.claim_creator_fees(
            &f.migrators_version,
            &launch,
            &curve_fee_cap,
            f.ctx!(),
        );
        transfer::public_transfer(meme, CREATOR);
        transfer::public_transfer(quote, CREATOR);

        f.scenario.return_to_sender(curve_fee_cap);
        test_scenario::return_shared(launch);
        test_scenario::return_shared(vault);
    });
}

/// Publishes round zero: one leaf paying Alice half of each rewards balance.
fun publish_round(self: &mut ReplayFixture) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut vault = f.take_vault();
        let (meme, quote) = vault.rewards_balances();
        let root = merkle::leaf(object::id(&vault), 0, 0, ALICE, meme / 2, quote / 2);

        blast_holder_rewards::publish_round(
            &mut vault,
            &f.migrators_version,
            &admin,
            0,
            100,
            200,
            root,
            vector::tabulate!(32, |i| i as u8),
            1,
            meme / 2,
            quote / 2,
            f.ctx!(),
        );

        test_scenario::return_shared(vault);
    });
}

/// A keeper relays Alice's claim of the only leaf of the only round.
fun claim_reward(self: &mut ReplayFixture) {
    self.next_tx!(KEEPER, |f| {
        let entry = f.replay.rounds[0];
        let mut round = f.take_round(entry.round_id);

        round.claim(
            &f.migrators_version,
            0,
            ALICE,
            entry.remaining.meme,
            entry.remaining.quote,
            vector[],
            f.ctx!(),
        );

        test_scenario::return_shared(round);
    });
}

/// Redirects the live protocol share between two collections.
fun redirect_protocol_share(self: &mut ReplayFixture, destination: address) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut policy = f.take_policy();

        policy.set_protocol_destination(&f.migrators_version, &admin, destination);

        test_scenario::return_shared(policy);
    });
}

/// Migrate, keep one residual unit per asset in the vault, attach the position, share.
fun mock_adapter(
    launch: &mut Launch<REPLAY_TESTS, QUOTE>,
    version: &PackageVersion,
    currency: &mut Currency<REPLAY_TESTS>,
    ctx: &mut TxContext,
) {
    let (mut meme, mut quote) = launch.migrate(version, currency, Venue(), ctx);
    let residual_meme = meme.split(1);
    let residual_quote = quote.split(1);
    let pool = MockPool { id: object::new(ctx) };
    let pool_id = object::id(&pool);
    let position = MockPosition { id: object::new(ctx), pool_id, meme, quote, liquidity: 1 };
    vault::create(launch, &Venue(), pool_id, position, 1, residual_meme, residual_quote, ctx);
    transfer::share_object(pool);
}

/// The mock venue adds an equal amount of both waiting auto-LP assets to the position and the
/// vault keeps the rest.
fun compound(vault: &mut LpVault<REPLAY_TESTS, QUOTE>) {
    let (mut meme, mut quote) = vault.take_auto_lp();
    let added = meme.value().min(quote.value());
    let position = vault.position_mut<_, _, _, MockPosition<REPLAY_TESTS, QUOTE>>(&Venue());
    position.meme.join(meme.split(added));
    position.quote.join(quote.split(added));

    vault.keep_auto_lp(added, added, meme, quote);
}

/// The creator's plan leaves Blast out; the advisor takes Quote only, so its payment carries no
/// Meme.
fun plan(): AllocationPlan {
    allocation::plan(
        bps::new(7_000),
        bps::new(2_000),
        bps::new(8_000),
        vector[
            allocation::recipient(TEAM, bps::new(500), bps::new(700)),
            allocation::recipient(ADVISOR, bps::new(0), bps::new(300)),
        ],
    )
}

/// Every part is used; recipients are paid in the order given.
fun first_split(): FeeSplit {
    allocation::fee_split(
        bps::new(1_000),
        bps::new(2_000),
        bps::new(2_000),
        bps::new(1_000),
        vector[
            allocation::route(ROUTE_B, bps::new(2_500)),
            allocation::route(TEAM, bps::new(1_500)),
        ],
    )
}

/// Half back into the position and the rest to two new recipients.
fun next_split(): FeeSplit {
    allocation::fee_split(
        bps::new(0),
        bps::new(5_000),
        bps::new(0),
        bps::new(0),
        vector[
            allocation::route(ROUTE_C, bps::new(2_500)),
            allocation::route(ROUTE_A, bps::new(2_500)),
        ],
    )
}

fun take_policy(self: &ReplayFixture): LpFeePolicy {
    self.scenario.take_shared()
}

fun take_launch(self: &ReplayFixture): Launch<REPLAY_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.replay.launch_id)
}

fun take_vault(self: &ReplayFixture): LpVault<REPLAY_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.replay.binding.vault_id)
}

fun take_round(self: &ReplayFixture, round_id: ID): Round<REPLAY_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(round_id)
}

fun take_currency(self: &ReplayFixture): Currency<REPLAY_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

/// Sums every native `Coin<T>` `owner` holds.
fun coin_total<T>(self: &ReplayFixture, owner: address): u64 {
    test_scenario::ids_for_address<Coin<T>>(owner).fold!(0, |sum, id| {
        let coin = self.scenario.take_from_address_by_id<Coin<T>>(owner, id);
        let value = coin.value();
        test_scenario::return_to_address(owner, coin);
        sum + value
    })
}

// Event Reduction

/// Decodes and reduces every required payload this transaction emitted, grouped by payload type
/// in the lifecycle's causal order, and proves no other payload was emitted. Native emission
/// order is asserted by the PTB harness.
fun reduce_transaction(self: &mut ReplayFixture, sender: address) {
    let replay = &mut self.replay;
    let mut reduced = 0;

    wrapped<events::ProtocolAllocationSet>().do!(|bytes| {
        replay.protocol_allocation_set(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::LpFeePolicyChanged>().do!(|bytes| {
        replay.lp_fee_policy_changed(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::LpFeeDestinationChanged>().do!(|bytes| {
        replay.lp_fee_destination_changed(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::LaunchTicketCreated>().do!(|bytes| {
        replay.launch_ticket_created(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::LaunchCreated>().do!(|bytes| {
        replay.launch_created(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::LaunchShared>().do!(|bytes| {
        replay.launch_shared(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::Bought>().do!(|bytes| {
        replay.bought(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::MigrationAllocationPaid>().do!(|bytes| {
        replay.migration_allocation_paid(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::Migrated>().do!(|bytes| {
        replay.migrated(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::VaultCreated>().do!(|bytes| {
        replay.vault_created(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::FeesCollected>().do!(|bytes| {
        replay.fees_collected(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::AutoLiquidityAdded>().do!(|bytes| {
        replay.auto_liquidity_added(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::FeeSplitChanged>().do!(|bytes| {
        replay.fee_split_changed(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::BuybackBurned>().do!(|bytes| {
        replay.buyback_burned(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::CreatorFeesClaimed>().do!(|bytes| {
        replay.creator_fees_claimed(bytes, sender);
        reduced = reduced + 1;
    });
    direct<blast_events::RoundPublished>().do!(|bytes| {
        replay.round_published(bytes);
        reduced = reduced + 1;
    });
    direct<blast_events::RewardPaid>().do!(|bytes| {
        replay.reward_paid(bytes);
        reduced = reduced + 1;
    });

    // Intake admissions and the creator capability claim are outside this schema; nothing else
    // may appear.
    let unreduced = wrapped<events::QuoteSet>().length()
        + wrapped<events::MigrationWitnessSet>().length()
        + wrapped<events::LaunchTradeFeesChanged>().length()
        + wrapped<events::CreatorCapsClaimed>().length();
    assert_eq!(event::num_events() as u64, reduced + unreduced);
}

/// Payload bytes of each `T` this transaction emitted inside the launchpad envelope, which
/// encodes exactly as its payload. The bare payload type must never be emitted.
fun wrapped<T: copy + drop>(): vector<vector<u8>> {
    assert!(event::events_by_type<T>().is_empty());
    event::events_by_type<BlastEvent<T>>().map!(|envelope| bcs::to_bytes(&envelope))
}

/// Payload bytes of each `T` this transaction emitted directly, never inside the envelope.
fun direct<T: copy + drop>(): vector<vector<u8>> {
    assert!(event::events_by_type<BlastEvent<T>>().is_empty());
    event::events_by_type<T>().map!(|payload| bcs::to_bytes(&payload))
}

fun new_replay(publisher: address): Replay {
    Replay {
        default_shares: Shares { meme_bps: 0, quote_bps: 0 },
        coin_shares: vector[],
        protocol_destination: publisher,
        protocol_allocation: RecipientEntry { destination: @0x0, meme_bps: 0, quote_bps: 0 },
        ticket_id: absent(),
        meme: b"".to_ascii_string(),
        decimals: 0,
        atomic_supply: 0,
        metadata_cap_id: absent(),
        creator: option::none(),
        burnable: false,
        sell_burn_bps: 0,
        total_supply: 0,
        launch_id: absent(),
        migration_witness: b"".to_ascii_string(),
        pool_tick_spacing: 0,
        pool_fee_rate: 0,
        launch_fee_split: empty_split(),
        virtual_quote: 0,
        graduation_target: 0,
        quote_fee_bps: 0,
        meme_fee_bps: 0,
        plan: PlanEntry { curve_meme_bps: 0, lp_meme_bps: 0, lp_quote_bps: 0, recipients: vector[] },
        protection_window_ms: 0,
        cumulative_sender_bps: 0,
        per_transaction_bps: 0,
        public_start_ms: option::none(),
        lifecycle: UNCREATED,
        meme_reserve: 0,
        real_quote_reserve: 0,
        allocated_meme: 0,
        binding: Binding {
            vault_id: absent(),
            pool_id: absent(),
            position_id: absent(),
        },
        generation: 0,
        fee_split: empty_split(),
        venue: b"".to_ascii_string(),
        residual_meme: 0,
        residual_quote: 0,
        liquidity: 0,
        position_meme: 0,
        position_quote: 0,
        creator_balance: Pair { meme: 0, quote: 0 },
        auto_lp: Pair { meme: 0, quote: 0 },
        rewards: Pair { meme: 0, quote: 0 },
        burn_quote: 0,
        next_round: 0,
        last_checkpoint: option::none(),
        rounds: vector[],
        recipients_paid: 0,
        allocated_meme_paid: 0,
        allocated_quote_paid: 0,
        payouts: vector[],
    }
}

fun protocol_allocation_set(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    let protocol_allocation = r.peel_recipient();
    r.assert_consumed();

    self.protocol_allocation = protocol_allocation;
}

fun lp_fee_policy_changed(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    let coin = r.peel_option!(|r| r.peel_type_name());
    let old = r.peel_shares();
    let new = r.peel_shares();
    r.assert_consumed();

    if (coin.is_none()) {
        assert_eq!(old, option::some(self.default_shares));
        self.default_shares = new.destroy_some();
    } else {
        let meme = coin.destroy_some();
        assert_eq!(old, self.own_shares(meme));
        self.coin_shares = self.coin_shares.filter!(|entry| entry.meme != meme);
        new.do!(|shares| self.coin_shares.push_back(CoinShares { meme, shares }));
    };
}

fun lp_fee_destination_changed(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    let old_destination = r.peel_address();
    let new_destination = r.peel_address();
    r.assert_consumed();

    assert_eq!(old_destination, self.protocol_destination);
    self.protocol_destination = new_destination;
}

/// The ticket fixes the canonical supply: one billion whole tokens at its decimals.
fun launch_ticket_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.ticket_id = r.peel_id();
    self.meme = r.peel_type_name();
    self.decimals = r.peel_u8();
    self.metadata_cap_id = r.peel_id();
    assert_eq!(r.peel_enum_tag(), CREATOR_ADDRESS_TAG);
    self.creator = option::some(r.peel_address());
    self.burnable = r.peel_bool();
    self.sell_burn_bps = r.peel_u64();
    r.assert_consumed();

    self.atomic_supply = MEME_SUPPLY_WHOLE_TOKENS * 10u64.pow(self.decimals);
    self.total_supply = self.atomic_supply;
}

/// Finalization puts Blast's allocation first in the creator's plan, each asset sums to 10,000,
/// and the curve starts with its apportioned Meme while the pool's and the recipients' wait.
fun launch_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.launch_id = r.peel_id();
    assert_eq!(r.peel_id(), self.ticket_id);
    assert_eq!(r.peel_type_name(), type_name::with_original_ids<QUOTE>().into_string());
    self.migration_witness = r.peel_type_name();
    self.pool_tick_spacing = r.peel_u32();
    self.pool_fee_rate = r.peel_u64();
    self.launch_fee_split = r.peel_fee_split();
    self.virtual_quote = r.peel_u64();
    self.graduation_target = r.peel_u64();
    self.quote_fee_bps = r.peel_u64();
    self.meme_fee_bps = r.peel_u64();
    self.plan = r.peel_plan();
    self.protection_window_ms = r.peel_u64();
    self.cumulative_sender_bps = r.peel_u64();
    self.per_transaction_bps = r.peel_u64();
    r.assert_consumed();

    let recipients = self.plan.recipients;
    assert_eq!(recipients[0], self.protocol_allocation);
    assert_eq!(self.plan.meme_bps().total(), BASIS_POINTS);
    assert_eq!(self.plan.quote_bps().total(), BASIS_POINTS);
    let curve_meme = self.plan.meme_amounts(self.atomic_supply)[0];
    self.lifecycle = LIVE;
    self.meme_reserve = curve_meme;
    self.allocated_meme = self.atomic_supply - curve_meme;
}

fun launch_shared(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    let public_start_ms = r.peel_u64();
    r.assert_consumed();

    assert!(self.public_start_ms.is_none());
    self.public_start_ms = option::some(public_start_ms);
}

/// Applies a purchase's gross amounts and fees, checks the posted reserves against them, and
/// closes trading once the real Quote reserve reaches the graduation target. Purchases before
/// `LaunchShared` are the creator's pre-share purchases.
fun bought(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    let quote_in = r.peel_u64();
    let meme_out_gross = r.peel_u64();
    let meme_out_net = r.peel_u64();
    let _quote_refund = r.peel_u64();
    let protocol_meme_fee = r.peel_u64();
    let creator_meme_fee = r.peel_u64();
    let protocol_quote_fee = r.peel_u64();
    let creator_quote_fee = r.peel_u64();
    let meme_reserve = r.peel_u64();
    let real_quote_reserve = r.peel_u64();
    r.assert_consumed();

    assert_eq!(self.lifecycle, LIVE);
    assert_eq!(meme_out_net, meme_out_gross - protocol_meme_fee - creator_meme_fee);
    assert_eq!(meme_reserve, self.meme_reserve - meme_out_gross);
    assert_eq!(
        real_quote_reserve,
        self.real_quote_reserve + quote_in - protocol_quote_fee - creator_quote_fee,
    );
    self.meme_reserve = meme_reserve;
    self.real_quote_reserve = real_quote_reserve;
    if (real_quote_reserve >= self.graduation_target) self.lifecycle = MIGRATION_READY;
}

/// Migration copies the creator's launch fee split into the custody `VaultCreated` announces, at
/// generation zero, and the residuals it keeps leave the rest of the hand-off in a position that
/// holds liquidity.
fun vault_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.binding.vault_id = r.peel_id();
    self.binding.pool_id = r.peel_id();
    self.binding.position_id = r.peel_id();
    self.venue = r.peel_type_name();
    assert_eq!(r.peel_type_name(), self.meme);
    assert_eq!(r.peel_type_name(), type_name::with_original_ids<QUOTE>().into_string());
    self.residual_meme = r.peel_u64();
    self.residual_quote = r.peel_u64();
    self.liquidity = r.peel_u128();
    let fee_split = r.peel_fee_split();
    r.assert_consumed();

    assert_eq!(self.lifecycle, MIGRATED);
    assert!(self.liquidity > 0);
    assert_eq!(self.venue, self.migration_witness);
    assert_eq!(fee_split, self.launch_fee_split);
    self.generation = 0;
    self.fee_split = fee_split;
    self.position_meme = self.position_meme - self.residual_meme;
    self.position_quote = self.position_quote - self.residual_quote;
}

/// Recipients are paid in plan order, each its apportioned Meme and its apportioned share of the
/// final Quote reserve, even when an amount is zero.
fun migration_allocation_paid(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    let destination = r.peel_address();
    let meme = r.peel_u64();
    let quote = r.peel_u64();
    r.assert_consumed();

    let i = self.recipients_paid;
    assert_eq!(self.lifecycle, MIGRATION_READY);
    assert_eq!(destination, self.plan.recipients[i].destination);
    assert_eq!(meme, self.plan.meme_amounts(self.atomic_supply)[PROTOCOL_MEME_PART + i]);
    assert_eq!(quote, self.plan.quote_amounts(self.real_quote_reserve)[PROTOCOL_QUOTE_PART + i]);
    self.recipients_paid = i + 1;
    self.allocated_meme_paid = self.allocated_meme_paid + meme;
    self.allocated_quote_paid = self.allocated_quote_paid + quote;
    self.credit(destination, meme, quote);
}

/// After every recipient is paid, the adapter receives the pool's shares, which empty the
/// allocated Meme and the Quote reserve, and disposal removes the curve's unsold Meme from supply.
fun migrated(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    let meme = r.peel_u64();
    let quote = r.peel_u64();
    let disposed_meme = r.peel_u64();
    assert_eq!(r.peel_bool(), self.burnable);
    self.total_supply = r.peel_u64();
    r.assert_consumed();

    assert_eq!(self.lifecycle, MIGRATION_READY);
    assert_eq!(self.recipients_paid, self.plan.recipients.length());
    assert_eq!(meme, self.plan.meme_amounts(self.atomic_supply)[1]);
    assert_eq!(quote, self.plan.quote_amounts(self.real_quote_reserve)[0]);
    assert_eq!(meme + self.allocated_meme_paid, self.allocated_meme);
    assert_eq!(quote + self.allocated_quote_paid, self.real_quote_reserve);
    assert_eq!(disposed_meme, self.meme_reserve);
    assert_eq!(self.total_supply, self.atomic_supply - disposed_meme);
    self.lifecycle = MIGRATED;
    // The whole hand-off until `VaultCreated` moves the residuals out.
    self.position_meme = meme;
    self.position_quote = quote;
    self.meme_reserve = 0;
    self.real_quote_reserve = 0;
    self.allocated_meme = 0;
}

/// Blast's live share for this Meme rounds up and pays the live destination; the rest splits
/// under the stamped generation into the creator, auto-LP, and rewards balances, the burned Meme
/// and the waiting burn Quote, and one payment per recipient in the split's order, conserving each
/// asset.
fun fees_collected(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.binding.vault_id);
    assert_eq!(r.peel_u64(), self.generation);
    let gross_meme = r.peel_u64();
    let gross_quote = r.peel_u64();
    let protocol_destination = r.peel_address();
    let protocol_meme = r.peel_u64();
    let protocol_quote = r.peel_u64();
    let creator = r.peel_pair();
    let auto_lp = r.peel_pair();
    let rewards = r.peel_pair();
    let burn = r.peel_pair();
    let recipient_meme = r.peel_vec_u64();
    let recipient_quote = r.peel_vec_u64();
    r.assert_consumed();

    let shares = self.live_shares();
    let recipients = self.fee_split.recipients;
    assert_eq!(self.lifecycle, MIGRATED);
    assert!(gross_meme > 0 || gross_quote > 0);
    assert_eq!(protocol_destination, self.protocol_destination);
    assert_eq!(protocol_meme, bps::new(shares.meme_bps).apply_up(gross_meme));
    assert_eq!(protocol_quote, bps::new(shares.quote_bps).apply_up(gross_quote));
    assert_eq!(recipient_meme.length(), recipients.length());
    assert_eq!(recipient_quote.length(), recipients.length());
    assert_eq!(
        protocol_meme + creator.meme + auto_lp.meme + rewards.meme + burn.meme
            + recipient_meme.total(),
        gross_meme,
    );
    assert_eq!(
        protocol_quote + creator.quote + auto_lp.quote + rewards.quote + burn.quote
            + recipient_quote.total(),
        gross_quote,
    );
    self.credit(protocol_destination, protocol_meme, protocol_quote);
    self.creator_balance = self.creator_balance.plus(creator);
    self.auto_lp = self.auto_lp.plus(auto_lp);
    self.rewards = self.rewards.plus(rewards);
    self.burn(burn.meme);
    self.burn_quote = self.burn_quote + burn.quote;
    recipients.length().do!(|i| {
        self.credit(recipients[i].destination, recipient_meme[i], recipient_quote[i]);
    });
}

/// The addition leaves the vault and joins the position; what the event reports pending is what
/// the vault still waits with.
fun auto_liquidity_added(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.binding.vault_id);
    let added = r.peel_pair();
    let pending = r.peel_pair();
    r.assert_consumed();

    assert!(added.meme > 0 || added.quote > 0);
    assert_eq!(pending.meme, self.auto_lp.meme - added.meme);
    assert_eq!(pending.quote, self.auto_lp.quote - added.quote);
    self.auto_lp = pending;
    self.position_meme = self.position_meme + added.meme;
    self.position_quote = self.position_quote + added.quote;
}

fun fee_split_changed(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.binding.vault_id);
    assert_eq!(r.peel_u64(), self.generation);
    let new_generation = r.peel_u64();
    let old_fee_split = r.peel_fee_split();
    let new_fee_split = r.peel_fee_split();
    r.assert_consumed();

    assert_eq!(new_generation, self.generation + 1);
    assert_eq!(old_fee_split, self.fee_split);
    assert!(new_fee_split != old_fee_split);
    self.generation = new_generation;
    self.fee_split = new_fee_split;
}

/// A buyback spends part of the waiting burn Quote through the mock venue, which is the position,
/// and burns the Meme it returns; the unspent Quote waits again.
fun buyback_burned(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.binding.vault_id);
    let quote_spent = r.peel_u64();
    let meme_burned = r.peel_u64();
    let quote_pending = r.peel_u64();
    r.assert_consumed();

    assert!(quote_spent > 0);
    assert_eq!(quote_pending, self.burn_quote - quote_spent);
    self.burn_quote = quote_pending;
    self.burn(meme_burned);
    self.position_meme = self.position_meme - meme_burned;
    self.position_quote = self.position_quote + quote_spent;
}

/// The whole creator balance leaves to the transaction sender, the live cap holder.
fun creator_fees_claimed(self: &mut Replay, bytes: vector<u8>, sender: address) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.binding.vault_id);
    let claimed = r.peel_pair();
    r.assert_consumed();

    assert_eq!(claimed, self.creator_balance);
    assert!(claimed.meme > 0 || claimed.quote > 0);
    self.creator_balance = Pair { meme: 0, quote: 0 };
    self.credit(sender, claimed.meme, claimed.quote);
}

/// A round takes the next number, starts where the last one ended, and moves its budget out of
/// the rewards balance, which the event reports as unallocated.
fun round_published(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.binding.vault_id);
    let round_id = r.peel_id();
    let number = r.peel_u64();
    let start_checkpoint = r.peel_u64();
    let end_checkpoint = r.peel_u64();
    let root = r.peel_vec_u8();
    assert_eq!(r.peel_vec_u8().length(), 32);
    let leaf_count = r.peel_u64();
    let budget = r.peel_pair();
    let unallocated = r.peel_pair();
    r.assert_consumed();

    assert_eq!(number, self.next_round);
    assert!(start_checkpoint < end_checkpoint);
    assert!(self.last_checkpoint.is_none_or!(|last| *last == start_checkpoint));
    assert_eq!(root.length(), 32);
    assert!(leaf_count > 0);
    assert!(budget.meme > 0 || budget.quote > 0);
    assert_eq!(unallocated.meme, self.rewards.meme - budget.meme);
    assert_eq!(unallocated.quote, self.rewards.quote - budget.quote);
    self.rewards = unallocated;
    self.next_round = number + 1;
    self.last_checkpoint = option::some(end_checkpoint);
    self.rounds.push_back(RoundEntry {
        round_id,
        number,
        root,
        leaf_count,
        remaining: budget,
        claimed: vector[],
    });
}

/// A leaf pays its beneficiary once, from its round's remaining funds.
fun reward_paid(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    let round_id = r.peel_id();
    let index = r.peel_u64();
    let beneficiary = r.peel_address();
    let paid = r.peel_pair();
    let remaining = r.peel_pair();
    r.assert_consumed();

    let i = self.rounds.find_index!(|round| round.round_id == round_id).destroy_some();
    let round = &mut self.rounds[i];
    assert!(index < round.leaf_count && !round.claimed.contains(&index));
    assert_eq!(remaining.meme, round.remaining.meme - paid.meme);
    assert_eq!(remaining.quote, round.remaining.quote - paid.quote);
    round.remaining = remaining;
    round.claimed.push_back(index);
    self.credit(beneficiary, paid.meme, paid.quote);
}

/// Burned Meme leaves a burn-only supply and reaches `@0x0` under a fixed one.
fun burn(self: &mut Replay, meme: u64) {
    if (self.burnable) self.total_supply = self.total_supply - meme
    else self.credit(@0x0, meme, 0);
}

fun credit(self: &mut Replay, destination: address, meme: u64, quote: u64) {
    let index = self.payouts.find_index!(|payout| payout.destination == destination);
    if (index.is_none()) {
        self.payouts.push_back(Payout { destination, meme, quote });
    } else {
        let payout = &mut self.payouts[index.destroy_some()];
        payout.meme = payout.meme + meme;
        payout.quote = payout.quote + quote;
    };
}

/// The pair a coin set for itself, if any.
fun own_shares(self: &Replay, meme: String): Option<Shares> {
    self.coin_shares.find_index!(|entry| entry.meme == meme).map!(|i| self.coin_shares[i].shares)
}

/// The pair this launch's collections pay Blast now: its own, else the defaults.
fun live_shares(self: &Replay): Shares {
    self.own_shares(self.meme).destroy_or!(self.default_shares)
}

fun total(amounts: vector<u64>): u64 {
    amounts.fold!(0, |sum, amount| sum + amount)
}

fun plus(self: Pair, other: Pair): Pair {
    Pair { meme: self.meme + other.meme, quote: self.quote + other.quote }
}

fun empty_split(): SplitEntry {
    SplitEntry { creator_bps: 0, auto_lp_bps: 0, rewards_bps: 0, burn_bps: 0, recipients: vector[] }
}

// Payload Decoding

fun peel_id(r: &mut BCS): ID {
    object::id_from_address(r.peel_address())
}

fun peel_type_name(r: &mut BCS): String {
    r.peel_vec_u8().to_ascii_string()
}

/// One optional Meme/Quote pair, present for both assets or for neither.
fun peel_shares(r: &mut BCS): Option<Shares> {
    let meme_bps = r.peel_option_u64();
    let quote_bps = r.peel_option_u64();

    assert_eq!(meme_bps.is_some(), quote_bps.is_some());
    meme_bps.map!(|meme_bps| Shares { meme_bps, quote_bps: quote_bps.destroy_some() })
}

fun peel_plan(r: &mut BCS): PlanEntry {
    let curve_meme_bps = r.peel_u64();
    let lp_meme_bps = r.peel_u64();
    let lp_quote_bps = r.peel_u64();
    let recipients = r.peel_vec!(|r| r.peel_recipient());

    PlanEntry { curve_meme_bps, lp_meme_bps, lp_quote_bps, recipients }
}

fun peel_recipient(r: &mut BCS): RecipientEntry {
    let destination = r.peel_address();
    let meme_bps = r.peel_u64();
    let quote_bps = r.peel_u64();

    RecipientEntry { destination, meme_bps, quote_bps }
}

fun peel_fee_split(r: &mut BCS): SplitEntry {
    let creator_bps = r.peel_u64();
    let auto_lp_bps = r.peel_u64();
    let rewards_bps = r.peel_u64();
    let burn_bps = r.peel_u64();
    let recipients = r.peel_vec!(|r| r.peel_route());

    SplitEntry { creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients }
}

/// One Meme amount followed by one Quote amount.
fun peel_pair(r: &mut BCS): Pair {
    let meme = r.peel_u64();
    let quote = r.peel_u64();

    Pair { meme, quote }
}

fun peel_route(r: &mut BCS): RouteEntry {
    let destination = r.peel_address();
    let bps = r.peel_u64();

    RouteEntry { destination, bps }
}

fun assert_consumed(r: BCS) {
    assert!(r.into_remainder_bytes().is_empty());
}

// Reference Apportionment

/// The Meme parts in apportionment order: the curve, the pool, then each recipient.
fun meme_bps(self: &PlanEntry): vector<u64> {
    let mut bps = vector[self.curve_meme_bps, self.lp_meme_bps];
    self.recipients.do_ref!(|recipient| bps.push_back(recipient.meme_bps));

    bps
}

/// The Quote parts in apportionment order: the pool, then each recipient.
fun quote_bps(self: &PlanEntry): vector<u64> {
    let mut bps = vector[self.lp_quote_bps];
    self.recipients.do_ref!(|recipient| bps.push_back(recipient.quote_bps));

    bps
}

fun meme_amounts(self: &PlanEntry, supply: u64): vector<u64> {
    apportion(self.meme_bps(), supply, PROTOCOL_MEME_PART)
}

fun quote_amounts(self: &PlanEntry, reserve: u64): vector<u64> {
    apportion(self.quote_bps(), reserve, PROTOCOL_QUOTE_PART)
}

/// Blast's part takes its ceiling and every other part its floor; each leftover unit then goes to
/// the part with the largest remaining remainder, the earliest on a tie.
fun apportion(bps: vector<u64>, total: u64, rounded_up: u64): vector<u64> {
    let exact = bps.map!(|share| (total as u128) * (share as u128));
    let denominator = BASIS_POINTS as u128;
    let mut amounts = vector::tabulate!(exact.length(), |i| {
        let floor = (exact[i] / denominator) as u64;
        if (i == rounded_up && exact[i] % denominator > 0) floor + 1 else floor
    });
    let mut remainders = vector::tabulate!(exact.length(), |i| {
        if (i == rounded_up) option::none() else option::some(exact[i] % denominator)
    });
    let leftover = total - amounts.total();
    leftover.do!(|_| {
        let mut largest = option::none<u64>();
        remainders.length().do!(|i| {
            if (remainders[i].is_some()
                && largest.is_none_or!(|j| *remainders[i].borrow() > *remainders[*j].borrow())
            ) {
                largest = option::some(i);
            };
        });
        let i = largest.destroy_some();
        *&mut amounts[i] = amounts[i] + 1;
        *&mut remainders[i] = option::none();
    });

    amounts
}

fun absent(): ID {
    object::id_from_address(@0x0)
}

// Authoritative Reads

/// Compares the model with every getter and object read in a fresh transaction.
fun assert_state(self: &mut ReplayFixture) {
    self.next_tx!(KEEPER, |f| {
        let policy = f.take_policy();
        f.replay.assert_policy(&policy);
        test_scenario::return_shared(policy);

        if (f.replay.lifecycle != UNCREATED) {
            let launch = f.take_launch();
            let currency = f.take_currency();
            f.replay.assert_launch(&launch, &currency);
            test_scenario::return_shared(launch);
            test_scenario::return_to_address(COIN_REGISTRY, currency);
        };

        if (f.replay.binding.vault_id != absent()) {
            let mut vault = f.take_vault();
            f.replay.assert_vault(&mut vault);
            test_scenario::return_shared(vault);
        };

        f.replay.rounds.do_ref!(|entry| {
            let round = f.take_round(entry.round_id);
            let (meme, quote) = round.round_balances_for_testing();
            assert_eq!(Pair { meme, quote }, entry.remaining);
            entry.leaf_count.do!(|index| {
                assert_eq!(round.is_claimed_for_testing(index), entry.claimed.contains(&index));
            });
            test_scenario::return_shared(round);
        });
    });
}

fun assert_policy(self: &Replay, policy: &LpFeePolicy) {
    let (default_meme_share, default_quote_share) = policy.default_shares_for_testing();
    assert_eq!(default_meme_share.value(), self.default_shares.meme_bps);
    assert_eq!(default_quote_share.value(), self.default_shares.quote_bps);
    assert_eq!(policy.protocol_destination(), self.protocol_destination);

    assert_eq!(policy.coin_count_for_testing(), self.coin_shares.length());
    let (meme_share, quote_share) = policy.shares<REPLAY_TESTS>();
    let own = self.own_shares(type_name::with_original_ids<REPLAY_TESTS>().into_string());
    let live = own.destroy_or!(self.default_shares);
    assert_eq!(Shares { meme_bps: meme_share.value(), quote_bps: quote_share.value() }, live);
    let (meme_share, quote_share) = policy.shares<OtherMeme>();
    assert!(self.own_shares(type_name::with_original_ids<OtherMeme>().into_string()).is_none());
    assert_eq!(meme_share.value(), self.default_shares.meme_bps);
    assert_eq!(quote_share.value(), self.default_shares.quote_bps);
}

fun assert_launch(self: &Replay, launch: &Launch<REPLAY_TESTS, QUOTE>, currency: &Currency<REPLAY_TESTS>) {
    let (meme_reserve, real_quote_reserve, pending_burn, allocated_meme) = launch.balances_for_testing();

    assert_eq!(object::id(launch), self.launch_id);
    assert_eq!(launch.is_live_for_testing(), self.lifecycle == LIVE);
    assert_eq!(launch.is_migration_ready_for_testing(), self.lifecycle == MIGRATION_READY);
    assert_eq!(launch.is_migrated_for_testing(), self.lifecycle == MIGRATED);
    assert_eq!(launch.graduation_target_for_testing(), self.graduation_target);
    assert_eq!(meme_reserve, self.meme_reserve);
    assert_eq!(real_quote_reserve, self.real_quote_reserve);
    assert_eq!(pending_burn, 0);
    assert_eq!(allocated_meme, self.allocated_meme);
    assert_eq!(launch.virtual_quote_for_testing(), self.virtual_quote);
    assert_eq!(
        launch.protection_end_ms_for_testing(),
        self.public_start_ms.map!(|start| start + self.protection_window_ms),
    );
    assert_eq!(launch.protection_window_ms_for_testing(), self.protection_window_ms);
    assert_eq!(
        launch.cumulative_atomic_limit_for_testing(),
        self.atomic_supply * self.cumulative_sender_bps / BASIS_POINTS,
    );
    assert_eq!(
        launch.per_transaction_atomic_limit_for_testing(),
        self.atomic_supply * self.per_transaction_bps / BASIS_POINTS,
    );
    assert_eq!(launch.atomic_supply_for_testing(), self.atomic_supply);
    assert_eq!(launch.migration_witness_for_testing().into_string(), self.migration_witness);
    let (pool_tick_spacing, pool_fee_rate) = launch.pool_tier();
    assert_eq!(pool_tick_spacing, self.pool_tick_spacing);
    assert_eq!(pool_fee_rate, self.pool_fee_rate);
    assert_eq!(split_entry(&launch.lp_fee_split()), self.launch_fee_split);

    assert_eq!(
        *launch.allocation_plan_for_testing(),
        allocation::plan(
            bps::new(self.plan.curve_meme_bps),
            bps::new(self.plan.lp_meme_bps),
            bps::new(self.plan.lp_quote_bps),
            self.plan.recipients.map_ref!(|entry| allocation::recipient(
                entry.destination,
                bps::new(entry.meme_bps),
                bps::new(entry.quote_bps),
            )),
        ),
    );

    // Native Coin Registry reads own decimals, supply, and the supply mode.
    assert_eq!(currency.decimals(), self.decimals);
    assert_eq!(currency.total_supply(), option::some(self.total_supply));
    assert_eq!(currency.is_supply_burn_only(), self.burnable);

    // Payload facts outside the getter inventory match the inputs or test-only reads.
    assert_eq!(self.meme, type_name::with_original_ids<REPLAY_TESTS>().into_string());
    assert_eq!(self.creator, option::some(CREATOR));
    assert_eq!(self.metadata_cap_id, launch.metadata_cap_id_for_testing());
    assert_eq!(self.sell_burn_bps, launch.sell_burn_bps_for_testing());
    let (quote_fee_bps, meme_fee_bps) = launch.policy_for_testing();
    assert_eq!(self.quote_fee_bps, quote_fee_bps);
    assert_eq!(self.meme_fee_bps, meme_fee_bps);
}

fun assert_vault(self: &Replay, vault: &mut LpVault<REPLAY_TESTS, QUOTE>) {
    assert_eq!(object::id(vault), self.binding.vault_id);
    assert_eq!(vault.pool_id(), self.binding.pool_id);
    assert_eq!(vault.position_id_for_testing<_, _, Venue>(), option::some(self.binding.position_id));
    assert_eq!(self.venue, type_name::with_original_ids<Venue>().into_string());
    assert_eq!(vault.protocol_meme_residual_for_testing(), self.residual_meme);
    assert_eq!(vault.protocol_quote_residual_for_testing(), self.residual_quote);
    assert_eq!(vault.generation_for_testing(), self.generation);
    assert_eq!(split_entry(&vault.fee_split_for_testing()), self.fee_split);
    assert_eq!(pair!(|| vault.creator_balances_for_testing()), self.creator_balance);
    assert_eq!(pair!(|| vault.auto_lp_balances_for_testing()), self.auto_lp);
    assert_eq!(pair!(|| vault.rewards_balances()), self.rewards);
    assert_eq!(vault.burn_quote_for_testing(), self.burn_quote);
    assert_eq!(vault.next_round(), self.next_round);
    assert_eq!(vault.last_checkpoint(), self.last_checkpoint);
    let position = vault.position_mut<_, _, _, MockPosition<REPLAY_TESTS, QUOTE>>(&Venue());
    assert_eq!(position.meme.value(), self.position_meme);
    assert_eq!(position.quote.value(), self.position_quote);
    assert_eq!(position.liquidity, self.liquidity);
}

/// Every payout event must equal the native coins its destination received.
fun assert_native_payouts(self: &mut ReplayFixture) {
    self.next_tx!(KEEPER, |f| {
        assert_eq!(f.replay.payouts.length(), 10);
        f.replay.payouts.do_ref!(|payout| {
            assert_eq!(f.coin_total<REPLAY_TESTS>(payout.destination), payout.meme);
            assert_eq!(f.coin_total<QUOTE>(payout.destination), payout.quote);
        });
    });
}

fun route_entry(route: &Route): RouteEntry {
    RouteEntry { destination: route.destination(), bps: route.route_bps_for_testing() }
}

fun split_entry(fee_split: &FeeSplit): SplitEntry {
    SplitEntry {
        creator_bps: fee_split.creator_bps_for_testing().value(),
        auto_lp_bps: fee_split.auto_lp_bps_for_testing().value(),
        rewards_bps: fee_split.rewards_bps_for_testing().value(),
        burn_bps: fee_split.burn_bps_for_testing().value(),
        recipients: fee_split.recipients().map_ref!(|route| route_entry(route)),
    }
}

/// The Meme and Quote amounts `$balances` reads.
macro fun pair($balances: || -> (u64, u64)): Pair {
    let (meme, quote) = $balances();

    Pair { meme, quote }
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap};

use blast_fun::{
    allocation::{Self, AllocationPlan, FeeSplit, Route},
    blast_events::Event as BlastEvent,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority::{Self, CurveFeeCap},
    events,
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_migrators::{
    blast_events,
    blast_holder_rewards::{Self, Round},
    lp_fee_policy::{Self, LpFeePolicy},
    merkle,
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::{ascii::String, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    bcs::{Self, BCS},
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun replay_ctx as ReplayFixture.ctx;

use fun replay_end as ReplayFixture.end;

use fun replay_next_tx as ReplayFixture.next_tx;

use fun peel_id as BCS.peel_id;

use fun peel_type_name as BCS.peel_type_name;

use fun peel_shares as BCS.peel_shares;

use fun peel_plan as BCS.peel_plan;

use fun peel_recipient as BCS.peel_recipient;

use fun peel_fee_split as BCS.peel_fee_split;

use fun peel_pair as BCS.peel_pair;

use fun peel_route as BCS.peel_route;

use fun assert_consumed as BCS.assert_consumed;

use fun total as vector.total;
