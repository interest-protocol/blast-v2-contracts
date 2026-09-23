// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// One deterministic lifecycle through a sealed mock adapter, replayed from its events.
///
/// Every required payload is decoded from its wire bytes and reduced into a fresh model that
/// starts from the eventless publication state. After every lifecycle step the model must equal
/// the authoritative getters and object reads, and at the end every destination's native coins.
/// Launchpad payloads must arrive only inside the `blast_events::Event<T>` envelope; migrator
/// payloads only directly.
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

const PROTOCOL_CHANNEL: address = @0xA1;

const LIQUIDITY_CHANNEL: address = @0xA2;

const TEAM: address = @0xA4;

const ROUTE_A: address = @0xD1;

const ROUTE_B: address = @0xD2;

const ROUTE_C: address = @0xD3;

const FIRST_PROTOCOL_DESTINATION: address = @0xF1;

const SECOND_PROTOCOL_DESTINATION: address = @0xF2;

const DECIMALS: u8 = 6;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const TARGET: u64 = 25_000_000;

const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 200;

const PUBLIC_START_MS: u64 = 1_234;

/// `launch::Lifecycle` tags in declaration order; `Migrating` never outlives its transaction.
const LIVE: u8 = 0;

const MIGRATION_READY: u8 = 1;

const MIGRATED: u8 = 3;

/// Model lifecycle before any launch exists.
const UNCREATED: u8 = 255;

/// `allocation::ChannelRole` tags in declaration order.
const LIQUIDITY_ROLE: u32 = 0;

const PROTOCOL_ROLE: u32 = 1;

const EXTERNAL_ROLE: u32 = 2;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct REPLAY_TESTS has drop {}

public struct QUOTE() has drop;

/// A second original Meme type whose partner pair is pinned and then cleared.
public struct OtherMeme() has drop;

/// The mock adapter's sealed witness, which is also its vault venue marker.
public struct Venue() has drop;

public struct MockPool has key { id: UID }

/// Venue position owning exactly the supplied principal; the vault owns the residuals.
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
    runtime: RuntimeConfig,
    clock: Clock,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    replay: Replay,
}

/// Every fact reduced from decoded payloads, starting from the eventless publication state.
public struct Replay has drop {
    default_shares: Shares,
    partners: vector<Partner>,
    protocol_destination: address,
    protocol_channel: ChannelEntry,
    protocol_shares: Shares,
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
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    channels: vector<ChannelEntry>,
    meme_weights: vector<WeightEntry>,
    quote_weights: vector<WeightEntry>,
    meme_amounts: vector<u64>,
    public_start_ms: Option<u64>,
    pre_share_buy_completed: bool,
    lifecycle: u8,
    meme_reserve: u64,
    real_quote_reserve: u64,
    router_id: ID,
    config_cap_id: ID,
    config_cap_released: bool,
    active: bool,
    partner: bool,
    blast_shares: Shares,
    binding: Binding,
    generation: u64,
    meme_routes: vector<RouteEntry>,
    quote_routes: vector<RouteEntry>,
    venue: String,
    residual_meme: u64,
    residual_quote: u64,
    allocated_meme_paid: u64,
    allocated_quote_paid: u64,
    payouts: vector<Payout>,
}

public struct Shares has copy, drop {
    meme_bps: u64,
    quote_bps: u64,
}

public struct Partner has copy, drop {
    meme: String,
    shares: Shares,
}

public struct ChannelEntry has copy, drop {
    channel_id: u64,
    role: u32,
    destination: address,
}

public struct WeightEntry has copy, drop {
    channel_id: u64,
    bps: u64,
}

public struct RouteEntry has copy, drop {
    destination: address,
    bps: u64,
}

public struct Binding has copy, drop {
    settlement_witness: String,
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
    fixture.claim_router_config_cap();
    fixture.collect(10_001, 3_333);
    fixture.assert_state();
    fixture.settle_routes(777, 0);
    fixture.assert_state();
    fixture.redirect_protocol_share(SECOND_PROTOCOL_DESTINATION);
    fixture.collect(5, 12_345);
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
    fixture.reduce_transaction();
}

macro fun replay_ctx($fixture: &mut ReplayFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): ReplayFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role(), ADMIN, scenario.ctx());
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
        runtime,
        clock,
        authority,
        admin_cap,
        replay: new_replay(PUBLISHER),
    }
}

fun replay_end(self: ReplayFixture) {
    let ReplayFixture { scenario, version, runtime, clock, authority, admin_cap, replay: _ } = self;

    destroy(version);
    destroy(runtime);
    clock.destroy_for_testing();
    destroy(authority);
    destroy(admin_cap);
    scenario.end();
}

// Lifecycle Steps

/// Launch intake policy, a default pair, one pinned partner pair, a cleared one, and the first
/// protocol destination.
fun configure_policy(self: &mut ReplayFixture) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut config = f.scenario.take_shared<LaunchConfig>();
        let mut policy = f.take_policy();

        config.allow_quote<QUOTE>(&f.version, &admin, VIRTUAL_QUOTE);
        config.allow_migration_witness<Venue>(&f.version, &admin);
        config.set_trade_fees(&f.version, &admin, bps::new(QUOTE_FEE_BPS), bps::new(MEME_FEE_BPS));
        config.set_protocol_allocation(
            &f.version,
            &admin,
            1,
            PROTOCOL_CHANNEL,
            bps::new(500),
            bps::new(1_000),
        );
        policy.set_default_shares(&f.version, &admin, bps::new(1_000), bps::new(2_000));
        policy.set_partner_shares<OtherMeme>(&f.version, &admin, bps::new(9), bps::new(9));
        policy.set_partner_shares<REPLAY_TESTS>(&f.version, &admin, bps::new(1_500), bps::new(2_500));
        policy.clear_partner_shares<OtherMeme>(&f.version, &admin);
        policy.set_protocol_destination(&f.version, &admin, FIRST_PROTOCOL_DESTINATION);

        test_scenario::return_shared(config);
        test_scenario::return_shared(policy);
    });
}

/// Mints and binds the ticket, then opens, routes, pre-buys, and shares the launch.
fun create_launch(self: &mut ReplayFixture) {
    let ticket;
    self.next_tx!(LAUNCHER, |f| {
        let config = f.scenario.take_shared<LaunchConfig>();
        let mut minted = launch_ticket::new(
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
        minted.bind_migration_witness<_, QUOTE, _>(&config, Venue());
        ticket = minted;
        test_scenario::return_shared(config);
    });
    self.next_tx!(LAUNCHER, |f| {
        let config = f.scenario.take_shared<LaunchConfig>();
        let mut currency = f.take_currency();
        let mut launch = launch::new<_, QUOTE>(
            ticket,
            &mut currency,
            &f.version,
            &config,
            TARGET,
            plan(),
            0,
            bps::new(0),
            bps::new(0),
            f.ctx!(),
        );
        let (router, config_cap) = launch.new_fee_router(&f.version, first_routes(), f.ctx!());
        let (meme, refund) = launch.pre_share_buy(
            &f.version,
            &f.runtime,
            coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!()),
            1,
            f.ctx!(),
        );
        transfer::public_transfer(meme, LAUNCHER);
        transfer::public_transfer(refund, LAUNCHER);
        launch.share(&f.version, config_cap, router, &f.clock);

        test_scenario::return_to_address(COIN_REGISTRY, currency);
        test_scenario::return_shared(config);
    });
}

/// One public purchase past the target: the excess is refunded and trading closes.
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
        let mut router = f.take_router();
        let mut currency = f.take_currency();
        let policy = f.take_policy();

        mock_adapter(&mut launch, &mut router, &f.version, &policy, &mut currency, f.ctx!());

        test_scenario::return_shared(launch);
        test_scenario::return_shared(router);
        test_scenario::return_to_address(COIN_REGISTRY, currency);
        test_scenario::return_shared(policy);
    });
}

/// The creator recipient's claim releases the wrapped router configuration capability.
fun claim_router_config_cap(self: &mut ReplayFixture) {
    self.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let (curve_fee_cap, metadata_cap, config_cap) = launch.claim_setup_caps(
            &f.version,
            &f.runtime,
            option::none(),
            &f.clock,
            f.ctx!(),
        );
        transfer::public_transfer(curve_fee_cap, CREATOR);
        transfer::public_transfer(metadata_cap, CREATOR);
        transfer::public_transfer(config_cap, CREATOR);

        test_scenario::return_shared(launch);
    });
}

/// Adapter collection of the exact vault position; minted balances stand in for venue fees.
fun collect(self: &mut ReplayFixture, meme: u64, quote: u64) {
    self.next_tx!(KEEPER, |f| {
        let vault = f.take_vault();
        let mut router = f.take_router();
        let policy = f.take_policy();

        router.collect(
            &f.version,
            &policy,
            Venue(),
            object::id(&vault),
            vault.pool_id(),
            vault.mock_position_id(),
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            f.ctx!(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(router);
        test_scenario::return_shared(policy);
    });
}

/// Settles the outstanding collection under generation zero, then commits the next routes.
fun settle_routes(self: &mut ReplayFixture, meme: u64, quote: u64) {
    self.next_tx!(CREATOR, |f| {
        let config_cap = f.scenario.take_from_sender<RouterConfigCap<REPLAY_TESTS, QUOTE>>();
        let vault = f.take_vault();
        let mut router = f.take_router();
        let policy = f.take_policy();

        router.settle_and_update_routes(
            &f.version,
            &policy,
            &config_cap,
            Venue(),
            object::id(&vault),
            vault.pool_id(),
            vault.mock_position_id(),
            balance::create_for_testing(meme),
            balance::create_for_testing(quote),
            next_routes(),
            f.ctx!(),
        );

        f.scenario.return_to_sender(config_cap);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(router);
        test_scenario::return_shared(policy);
    });
}

/// Redirects the live protocol share between two collections.
fun redirect_protocol_share(self: &mut ReplayFixture, destination: address) {
    self.next_tx!(ADMIN, |f| {
        let admin = f.authority.sign_in(&f.admin_cap);
        let mut policy = f.take_policy();

        policy.set_protocol_destination(&f.version, &admin, destination);

        test_scenario::return_shared(policy);
    });
}

/// Begin, keep one residual unit per asset in the vault, attach the position, complete, share.
/// Between begin and completion no lifecycle read reports a resting state.
fun mock_adapter(
    launch: &mut Launch<REPLAY_TESTS, QUOTE>,
    router: &mut FeeRouter<REPLAY_TESTS, QUOTE>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<REPLAY_TESTS>,
    ctx: &mut TxContext,
) {
    let (mut meme, mut quote, migration) = launch.begin_migration(version, Venue());
    assert!(!launch.is_live() && !launch.is_migration_ready() && !launch.is_migrated());
    let residual_meme = meme.split(1);
    let residual_quote = quote.split(1);
    let pool = MockPool { id: object::new(ctx) };
    let pool_id = object::id(&pool);
    let position = MockPosition { id: object::new(ctx), pool_id, meme, quote, liquidity: 1 };
    let mut pending_vault = vault::prepare(residual_meme, residual_quote, ctx);
    pending_vault.attach(&Venue(), pool_id, position);
    let position = pending_vault.position<
        REPLAY_TESTS,
        QUOTE,
        Venue,
        MockPosition<REPLAY_TESTS, QUOTE>,
    >(&Venue());
    let (residual_meme, residual_quote) = pending_vault.pending_residuals();
    launch.complete_migration(
        version,
        router,
        policy,
        currency,
        migration,
        Venue(),
        &pending_vault,
        position.pool_id,
        position,
        position.meme.value(),
        position.quote.value(),
        residual_meme,
        residual_quote,
        position.liquidity,
        ctx,
    );
    pending_vault.share<REPLAY_TESTS, QUOTE, Venue>(&Venue());
    transfer::share_object(pool);
}

/// Deliberately non-canonical input: channel IDs descend.
fun plan(): AllocationPlan {
    allocation::new(
        vector[
            allocation::channel(4, allocation::external_role(), TEAM),
            allocation::channel(2, allocation::liquidity_role(), LIQUIDITY_CHANNEL),
            allocation::channel(1, allocation::protocol_role(), PROTOCOL_CHANNEL),
        ],
        vector[
            allocation::weight(4, bps::new(500)),
            allocation::weight(2, bps::new(2_000)),
            allocation::weight(1, bps::new(500)),
            allocation::weight(0, bps::new(7_000)),
        ],
        vector[
            allocation::weight(4, bps::new(1_000)),
            allocation::weight(2, bps::new(8_000)),
            allocation::weight(1, bps::new(1_000)),
        ],
    )
}

/// Destinations are given out of canonical address order.
fun first_routes(): Routes {
    allocation::routes(
        vector[allocation::route(ROUTE_B, bps::new(6_000)), allocation::route(TEAM, bps::new(4_000))],
        vector[allocation::route(ROUTE_A, bps::new(7_000)), allocation::route(TEAM, bps::new(3_000))],
    )
}

fun next_routes(): Routes {
    allocation::routes(
        vector[allocation::route(ROUTE_C, bps::new(10_000))],
        vector[allocation::route(ROUTE_C, bps::new(5_000)), allocation::route(ROUTE_B, bps::new(5_000))],
    )
}

fun take_policy(self: &ReplayFixture): LpFeePolicy {
    self.scenario.take_shared()
}

fun take_launch(self: &ReplayFixture): Launch<REPLAY_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.replay.launch_id)
}

fun take_router(self: &ReplayFixture): FeeRouter<REPLAY_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.replay.router_id)
}

fun take_vault(self: &ReplayFixture): LpVault<REPLAY_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.replay.binding.vault_id)
}

fun take_currency(self: &ReplayFixture): Currency<REPLAY_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun mock_position_id(self: &LpVault<REPLAY_TESTS, QUOTE>): ID {
    object::id(self.position<_, _, Venue, MockPosition<REPLAY_TESTS, QUOTE>>(&Venue()))
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
fun reduce_transaction(self: &mut ReplayFixture) {
    let replay = &mut self.replay;
    let mut reduced = 0;

    wrapped<events::ProtocolAllocationConfigured>().do!(|bytes| {
        replay.protocol_allocation_configured(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::LpFeePolicyChanged>().do!(|bytes| {
        replay.lp_fee_policy_changed(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::LpFeeDestinationChanged>().do!(|bytes| {
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
    wrapped<events::FeeRouterCreated>().do!(|bytes| {
        replay.fee_router_created(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::PreShareBought>().do!(|bytes| {
        replay.pre_share_bought(bytes);
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
    direct<blast_events::VaultCreated>().do!(|bytes| {
        replay.vault_created(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::RouterActivated>().do!(|bytes| {
        replay.router_activated(bytes);
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
    wrapped<events::RouterConfigCapReleased>().do!(|bytes| {
        replay.router_config_cap_released(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::FeesCollected>().do!(|bytes| {
        replay.fees_collected(bytes);
        reduced = reduced + 1;
    });
    wrapped<events::RoutesChanged>().do!(|bytes| {
        replay.routes_changed(bytes);
        reduced = reduced + 1;
    });

    // Intake admissions, the protection ticket's policy record, and the creator capability claim
    // are outside this schema; nothing else may appear.
    let unreduced = wrapped<events::QuoteAllowed>().length()
        + wrapped<events::MigrationWitnessAllowed>().length()
        + wrapped<events::LaunchTradeFeesChanged>().length()
        + wrapped<events::ProtectionConfigured>().length()
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
        partners: vector[],
        protocol_destination: publisher,
        protocol_channel: ChannelEntry { channel_id: 0, role: PROTOCOL_ROLE, destination: @0x0 },
        protocol_shares: Shares { meme_bps: 0, quote_bps: 0 },
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
        virtual_quote: 0,
        graduation_target: 0,
        quote_fee_bps: 0,
        meme_fee_bps: 0,
        channels: vector[],
        meme_weights: vector[],
        quote_weights: vector[],
        meme_amounts: vector[],
        public_start_ms: option::none(),
        pre_share_buy_completed: false,
        lifecycle: UNCREATED,
        meme_reserve: 0,
        real_quote_reserve: 0,
        router_id: absent(),
        config_cap_id: absent(),
        config_cap_released: false,
        active: false,
        partner: false,
        blast_shares: Shares { meme_bps: 0, quote_bps: 0 },
        binding: Binding {
            settlement_witness: b"".to_ascii_string(),
            vault_id: absent(),
            pool_id: absent(),
            position_id: absent(),
        },
        generation: 0,
        meme_routes: vector[],
        quote_routes: vector[],
        venue: b"".to_ascii_string(),
        residual_meme: 0,
        residual_quote: 0,
        allocated_meme_paid: 0,
        allocated_quote_paid: 0,
        payouts: vector[],
    }
}

fun protocol_allocation_configured(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    let channel_id = r.peel_u64();
    let destination = r.peel_address();
    let meme_bps = r.peel_u64();
    let quote_bps = r.peel_u64();
    r.assert_consumed();

    self.protocol_channel = ChannelEntry { channel_id, role: PROTOCOL_ROLE, destination };
    self.protocol_shares = Shares { meme_bps, quote_bps };
}

fun lp_fee_policy_changed(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    let override_meme = r.peel_option!(|r| r.peel_type_name());
    let old = r.peel_shares();
    let new = r.peel_shares();
    r.assert_consumed();

    if (override_meme.is_none()) {
        assert_eq!(old, option::some(self.default_shares));
        self.default_shares = new.destroy_some();
    } else {
        let meme = override_meme.destroy_some();
        assert_eq!(old, self.partner_shares(meme));
        self.partners = self.partners.filter!(|partner| partner.meme != meme);
        new.do!(|shares| self.partners.push_back(Partner { meme, shares }));
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

fun launch_ticket_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.ticket_id = r.peel_id();
    self.meme = r.peel_type_name();
    self.decimals = r.peel_u8();
    self.atomic_supply = r.peel_u64();
    self.metadata_cap_id = r.peel_id();
    self.creator = r.peel_option_address();
    assert!(r.peel_option!(|r| r.peel_vec_u8()).is_none());
    self.burnable = r.peel_bool();
    self.sell_burn_bps = r.peel_u64();
    r.assert_consumed();

    self.total_supply = self.atomic_supply;
}

fun launch_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.launch_id = r.peel_id();
    assert_eq!(r.peel_id(), self.ticket_id);
    assert_eq!(r.peel_u8(), self.decimals);
    assert_eq!(r.peel_u64(), self.atomic_supply);
    assert_eq!(r.peel_type_name(), type_name::with_original_ids<QUOTE>().into_string());
    self.migration_witness = r.peel_type_name();
    self.virtual_quote = r.peel_u64();
    self.graduation_target = r.peel_u64();
    self.quote_fee_bps = r.peel_u64();
    self.meme_fee_bps = r.peel_u64();
    self.channels = r.peel_vec!(|r| {
        let channel_id = r.peel_u64();
        let role = r.peel_enum_tag();
        let destination = r.peel_address();
        ChannelEntry { channel_id, role, destination }
    });
    self.meme_weights = r.peel_weights();
    self.quote_weights = r.peel_weights();
    self.meme_amounts = r.peel_vec_u64();
    r.assert_consumed();

    // The immutable Blast policy is enforced at intake, and the plan partitions the supply.
    assert!(self.channels.contains(&self.protocol_channel));
    assert_eq!(self.meme_weights.bps_of(self.protocol_channel.channel_id), self.protocol_shares.meme_bps);
    assert_eq!(self.quote_weights.bps_of(self.protocol_channel.channel_id), self.protocol_shares.quote_bps);
    assert_eq!(self.meme_amounts.length(), self.meme_weights.length());
    assert_eq!(self.meme_amounts.fold!(0, |sum, amount| sum + amount), self.atomic_supply);
    self.lifecycle = LIVE;
    self.meme_reserve = self.meme_weights.amount_of(&self.meme_amounts, 0);
}

fun fee_router_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.router_id = r.peel_id();
    assert_eq!(r.peel_id(), self.launch_id);
    self.config_cap_id = r.peel_id();
    let (meme_routes, quote_routes) = r.peel_routes();
    r.assert_consumed();

    self.meme_routes = meme_routes;
    self.quote_routes = quote_routes;
}

fun pre_share_bought(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    self.reduce_purchase(&mut r);
    let _meme_out_net = r.peel_u64();
    let _quote_refund = r.peel_u64();
    r.assert_consumed();

    assert_eq!(self.lifecycle, LIVE);
    self.pre_share_buy_completed = true;
}

fun launch_shared(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    assert_eq!(r.peel_id(), self.router_id);
    self.public_start_ms = option::some(r.peel_u64());
    assert_eq!(r.peel_bool(), self.pre_share_buy_completed);
    r.assert_consumed();
}

fun bought(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    self.reduce_purchase(&mut r);
    r.assert_consumed();
}

/// Applies a purchase's gross amounts and fee deltas, checks the posted reserves against them,
/// and closes trading once the real Quote reserve reaches the graduation target.
fun reduce_purchase(self: &mut Replay, r: &mut BCS) {
    let quote_in = r.peel_u64();
    let meme_out_gross = r.peel_u64();
    let _protocol_meme_fee_delta = r.peel_u64();
    let _creator_meme_fee_delta = r.peel_u64();
    let protocol_quote_fee_delta = r.peel_u64();
    let creator_quote_fee_delta = r.peel_u64();
    let meme_reserve = r.peel_u64();
    let real_quote_reserve = r.peel_u64();

    assert_eq!(meme_reserve, self.meme_reserve - meme_out_gross);
    assert_eq!(
        real_quote_reserve,
        self.real_quote_reserve + quote_in - protocol_quote_fee_delta - creator_quote_fee_delta,
    );
    self.meme_reserve = meme_reserve;
    self.real_quote_reserve = real_quote_reserve;
    if (real_quote_reserve >= self.graduation_target) self.lifecycle = MIGRATION_READY;
}

fun vault_created(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    self.binding.vault_id = r.peel_id();
    self.binding.pool_id = r.peel_id();
    self.binding.position_id = r.peel_id();
    self.venue = r.peel_type_name();
    assert_eq!(r.peel_type_name(), self.meme);
    assert_eq!(r.peel_type_name(), type_name::with_original_ids<QUOTE>().into_string());
    r.assert_consumed();
}

/// Activation freezes the policy the replayed LP-fee policy selects for this Meme type and binds
/// the ticket-bound adapter to the custody `VaultCreated` announced.
fun router_activated(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.router_id);
    assert_eq!(r.peel_id(), self.launch_id);
    self.partner = r.peel_bool();
    let meme_bps = r.peel_u64();
    let quote_bps = r.peel_u64();
    self.blast_shares = Shares { meme_bps, quote_bps };
    self.binding.settlement_witness = r.peel_type_name();
    assert_eq!(r.peel_id(), self.binding.vault_id);
    assert_eq!(r.peel_id(), self.binding.pool_id);
    assert_eq!(r.peel_id(), self.binding.position_id);
    assert_eq!(r.peel_u64(), self.generation);
    let (meme_routes, quote_routes) = r.peel_routes();
    r.assert_consumed();

    let pinned = self.partner_shares(self.meme);
    assert_eq!(self.partner, pinned.is_some());
    assert_eq!(self.blast_shares, pinned.destroy_or!(self.default_shares));
    assert_eq!(self.binding.settlement_witness, self.migration_witness);
    assert_eq!(meme_routes, self.meme_routes);
    assert_eq!(quote_routes, self.quote_routes);
    self.active = true;
}

fun migration_allocation_paid(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    let channel_id = r.peel_u64();
    let destination = r.peel_address();
    let meme = r.peel_u64();
    let quote = r.peel_u64();
    r.assert_consumed();

    let channel = self.channels.find_channel(channel_id);
    assert!(channel.role != LIQUIDITY_ROLE);
    assert_eq!(channel.destination, destination);
    assert_eq!(meme, self.meme_weights.amount_of(&self.meme_amounts, channel_id));
    self.allocated_meme_paid = self.allocated_meme_paid + meme;
    self.allocated_quote_paid = self.allocated_quote_paid + quote;
    self.credit(destination, meme, quote);
}

/// The liquidity principal plus every paid allocation empties both pools, and disposal removes
/// the remaining curve reserve from supply.
fun migrated(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    let supplied_meme = r.peel_u64();
    let supplied_quote = r.peel_u64();
    self.residual_meme = r.peel_u64();
    self.residual_quote = r.peel_u64();
    assert!(r.peel_u128() > 0);
    let disposed_meme = r.peel_u64();
    assert_eq!(r.peel_bool(), self.burnable);
    self.total_supply = r.peel_u64();
    r.assert_consumed();

    let liquidity_id = self.channels.find_role(LIQUIDITY_ROLE).channel_id;
    assert_eq!(
        supplied_meme + self.residual_meme,
        self.meme_weights.amount_of(&self.meme_amounts, liquidity_id),
    );
    assert_eq!(
        supplied_meme + self.residual_meme + self.allocated_meme_paid,
        self.atomic_supply - self.meme_weights.amount_of(&self.meme_amounts, 0),
    );
    assert_eq!(
        supplied_quote + self.residual_quote + self.allocated_quote_paid,
        self.real_quote_reserve,
    );
    assert_eq!(disposed_meme, self.meme_reserve);
    assert_eq!(self.total_supply, self.atomic_supply - disposed_meme);
    self.lifecycle = MIGRATED;
    self.meme_reserve = 0;
    self.real_quote_reserve = 0;
}

fun router_config_cap_released(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.launch_id);
    assert_eq!(r.peel_id(), self.config_cap_id);
    r.assert_consumed();

    self.config_cap_released = true;
}

/// The frozen shares round the protocol amount up, the live destination receives it, and the
/// remainder is paid route by route in the canonical order of the stamped generation.
fun fees_collected(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.router_id);
    assert_eq!(r.peel_id(), self.launch_id);
    assert_eq!(r.peel_u64(), self.generation);
    let gross_meme = r.peel_u64();
    let gross_quote = r.peel_u64();
    let protocol_destination = r.peel_address();
    let protocol_meme = r.peel_u64();
    let protocol_quote = r.peel_u64();
    let meme_amounts = r.peel_vec_u64();
    let quote_amounts = r.peel_vec_u64();
    r.assert_consumed();

    assert!(self.active);
    assert_eq!(protocol_destination, self.protocol_destination);
    assert_eq!(protocol_meme, bps::new(self.blast_shares.meme_bps).apply_up(gross_meme));
    assert_eq!(protocol_quote, bps::new(self.blast_shares.quote_bps).apply_up(gross_quote));
    assert_eq!(meme_amounts.length(), self.meme_routes.length());
    assert_eq!(quote_amounts.length(), self.quote_routes.length());
    assert_eq!(protocol_meme + meme_amounts.fold!(0, |sum, amount| sum + amount), gross_meme);
    assert_eq!(protocol_quote + quote_amounts.fold!(0, |sum, amount| sum + amount), gross_quote);
    self.credit(protocol_destination, protocol_meme, protocol_quote);
    let meme_routes = self.meme_routes;
    let quote_routes = self.quote_routes;
    meme_routes.length().do!(|i| self.credit(meme_routes[i].destination, meme_amounts[i], 0));
    quote_routes.length().do!(|i| self.credit(quote_routes[i].destination, 0, quote_amounts[i]));
}

fun routes_changed(self: &mut Replay, bytes: vector<u8>) {
    let mut r = bcs::new(bytes);
    assert_eq!(r.peel_id(), self.router_id);
    assert_eq!(r.peel_u64(), self.generation);
    let new_generation = r.peel_u64();
    let (old_meme_routes, old_quote_routes) = r.peel_routes();
    let (new_meme_routes, new_quote_routes) = r.peel_routes();
    r.assert_consumed();

    assert_eq!(new_generation, self.generation + 1);
    assert_eq!(old_meme_routes, self.meme_routes);
    assert_eq!(old_quote_routes, self.quote_routes);
    self.generation = new_generation;
    self.meme_routes = new_meme_routes;
    self.quote_routes = new_quote_routes;
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

fun partner_shares(self: &Replay, meme: String): Option<Shares> {
    self.partners.find_index!(|partner| partner.meme == meme).map!(|i| self.partners[i].shares)
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

fun peel_weights(r: &mut BCS): vector<WeightEntry> {
    r.peel_vec!(|r| {
        let channel_id = r.peel_u64();
        let bps = r.peel_u64();
        WeightEntry { channel_id, bps }
    })
}

fun peel_routes(r: &mut BCS): (vector<RouteEntry>, vector<RouteEntry>) {
    let meme = r.peel_vec!(|r| r.peel_route());
    let quote = r.peel_vec!(|r| r.peel_route());

    (meme, quote)
}

fun peel_route(r: &mut BCS): RouteEntry {
    let destination = r.peel_address();
    let bps = r.peel_u64();

    RouteEntry { destination, bps }
}

fun assert_consumed(r: BCS) {
    assert!(r.into_remainder_bytes().is_empty());
}

fun bps_of(weights: &vector<WeightEntry>, channel_id: u64): u64 {
    weights.find_index!(|entry| entry.channel_id == channel_id).map!(|i| weights[i].bps).destroy_or!(0)
}

fun amount_of(weights: &vector<WeightEntry>, amounts: &vector<u64>, channel_id: u64): u64 {
    weights.find_index!(|entry| entry.channel_id == channel_id).map!(|i| amounts[i]).destroy_or!(0)
}

fun find_channel(channels: &vector<ChannelEntry>, channel_id: u64): ChannelEntry {
    channels[channels.find_index!(|channel| channel.channel_id == channel_id).destroy_some()]
}

fun find_role(channels: &vector<ChannelEntry>, role: u32): ChannelEntry {
    channels[channels.find_index!(|channel| channel.role == role).destroy_some()]
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
            let router = f.take_router();
            let currency = f.take_currency();
            f.replay.assert_launch(&launch, &currency);
            f.replay.assert_router(&router);
            test_scenario::return_shared(launch);
            test_scenario::return_shared(router);
            test_scenario::return_to_address(COIN_REGISTRY, currency);
        };

        if (f.replay.binding.vault_id != absent()) {
            let vault = f.take_vault();
            f.replay.assert_vault(&vault);
            test_scenario::return_shared(vault);
        };
    });
}

fun assert_policy(self: &Replay, policy: &LpFeePolicy) {
    let (default_meme_share, default_quote_share) = policy.default_shares();
    assert_eq!(default_meme_share.value(), self.default_shares.meme_bps);
    assert_eq!(default_quote_share.value(), self.default_shares.quote_bps);
    assert_eq!(policy.protocol_destination(), self.protocol_destination);

    let snapshot = policy.snapshot<REPLAY_TESTS>();
    let pinned = self.partner_shares(type_name::with_original_ids<REPLAY_TESTS>().into_string());
    assert_eq!(snapshot.is_partner(), pinned.is_some());
    assert_eq!(snapshot.meme_share().value(), pinned.destroy_or!(self.default_shares).meme_bps);
    assert_eq!(snapshot.quote_share().value(), pinned.destroy_or!(self.default_shares).quote_bps);
    let cleared = policy.snapshot<OtherMeme>();
    assert!(self.partner_shares(type_name::with_original_ids<OtherMeme>().into_string()).is_none());
    assert!(!cleared.is_partner());
}

fun assert_launch(self: &Replay, launch: &Launch<REPLAY_TESTS, QUOTE>, currency: &Currency<REPLAY_TESTS>) {
    assert_eq!(object::id(launch), self.launch_id);
    assert_eq!(launch.is_live(), self.lifecycle == LIVE);
    assert_eq!(launch.is_migration_ready(), self.lifecycle == MIGRATION_READY);
    assert_eq!(launch.is_migrated(), self.lifecycle == MIGRATED);
    assert_eq!(launch.graduation_target(), self.graduation_target);
    assert_eq!(launch.meme_reserve(), self.meme_reserve);
    assert_eq!(launch.real_quote_reserve(), self.real_quote_reserve);
    assert_eq!(launch.virtual_quote(), self.virtual_quote);
    assert_eq!(launch.public_start_ms(), self.public_start_ms);
    assert_eq!(launch.pre_share_buy_completed(), self.pre_share_buy_completed);
    assert_eq!(launch.atomic_supply(), self.atomic_supply);
    assert_eq!(launch.migration_witness().into_string(), self.migration_witness);
    assert_eq!(launch.fee_router_id(), option::some(self.router_id));

    let plan = launch.allocation_plan();
    assert_eq!(
        plan.channels().map_ref!(|channel| ChannelEntry {
            channel_id: channel.channel_id(),
            role: role_tag(channel.channel_role()),
            destination: channel.channel_destination(),
        }),
        self.channels,
    );
    assert_eq!(plan.meme_weights().map_ref!(|entry| weight_entry(entry)), self.meme_weights);
    assert_eq!(plan.quote_weights().map_ref!(|entry| weight_entry(entry)), self.quote_weights);

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

fun assert_router(self: &Replay, router: &FeeRouter<REPLAY_TESTS, QUOTE>) {
    assert_eq!(object::id(router), self.router_id);
    assert_eq!(router.launch_id(), self.launch_id);
    assert_eq!(router.is_active(), self.active);
    assert_eq!(router.generation(), self.generation);
    assert_eq!(router.routes().meme_routes().map_ref!(|route| route_entry(route)), self.meme_routes);
    assert_eq!(router.routes().quote_routes().map_ref!(|route| route_entry(route)), self.quote_routes);
    // Native custody of the one configuration capability follows its release.
    assert_eq!(
        test_scenario::most_recent_id_for_address<RouterConfigCap<REPLAY_TESTS, QUOTE>>(CREATOR),
        if (self.config_cap_released) option::some(self.config_cap_id) else option::none(),
    );

    if (!self.active) {
        assert!(router.policy().is_none() && router.settlement_binding().is_none());
        return
    };
    let policy = router.policy().destroy_some();
    assert_eq!(policy.is_partner(), self.partner);
    assert_eq!(policy.meme_share().value(), self.blast_shares.meme_bps);
    assert_eq!(policy.quote_share().value(), self.blast_shares.quote_bps);
    let (settlement_witness, vault_id, pool_id, position_id) = router
        .settlement_binding()
        .destroy_some()
        .settlement_binding_fields();
    assert_eq!(
        Binding { settlement_witness: settlement_witness.into_string(), vault_id, pool_id, position_id },
        self.binding,
    );
}

fun assert_vault(self: &Replay, vault: &LpVault<REPLAY_TESTS, QUOTE>) {
    assert_eq!(object::id(vault), self.binding.vault_id);
    assert_eq!(vault.pool_id(), self.binding.pool_id);
    assert_eq!(vault.position_id<_, _, Venue>(), option::some(self.binding.position_id));
    assert_eq!(self.venue, type_name::with_original_ids<Venue>().into_string());
    assert_eq!(vault.protocol_meme_residual(), self.residual_meme);
    assert_eq!(vault.protocol_quote_residual(), self.residual_quote);
}

/// Every payout event must equal the native coins its destination received.
fun assert_native_payouts(self: &mut ReplayFixture) {
    self.next_tx!(KEEPER, |f| {
        assert_eq!(f.replay.payouts.length(), 7);
        f.replay.payouts.do_ref!(|payout| {
            assert_eq!(f.coin_total<REPLAY_TESTS>(payout.destination), payout.meme);
            assert_eq!(f.coin_total<QUOTE>(payout.destination), payout.quote);
        });
    });
}

fun role_tag(role: ChannelRole): u32 {
    if (role == allocation::liquidity_role()) return LIQUIDITY_ROLE;
    if (role == allocation::protocol_role()) return PROTOCOL_ROLE;
    assert_eq!(role, allocation::external_role());
    EXTERNAL_ROLE
}

fun weight_entry(entry: &Weight): WeightEntry {
    WeightEntry { channel_id: entry.weight_channel_id(), bps: entry.weight_bps() }
}

fun route_entry(route: &Route): RouteEntry {
    RouteEntry { destination: route.destination(), bps: route.route_bps() }
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap};

use blast_fun::{
    allocation::{Self, AllocationPlan, ChannelRole, Route, Routes, Weight},
    blast_events::Event as BlastEvent,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps,
    creator_authority,
    events,
    fee_router::{FeeRouter, RouterConfigCap},
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_migrators::{blast_events, vault::{Self, LpVault}};

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

use fun mock_position_id as LpVault.mock_position_id;

use fun peel_id as BCS.peel_id;

use fun peel_type_name as BCS.peel_type_name;

use fun peel_shares as BCS.peel_shares;

use fun peel_weights as BCS.peel_weights;

use fun peel_routes as BCS.peel_routes;

use fun peel_route as BCS.peel_route;

use fun assert_consumed as BCS.assert_consumed;

use fun bps_of as vector.bps_of;

use fun amount_of as vector.amount_of;

use fun find_channel as vector.find_channel;

use fun find_role as vector.find_role;
