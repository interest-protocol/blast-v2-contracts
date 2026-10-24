// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Exact Aftermath account custody under its immutable venue binding: every
/// deposit, allocation, order and withdrawal the Vault makes goes through here.
module blast_boosts_aftermath::venue_account;

// === Public Types ===

/// Immutable account, registry and clearing-house identities for one Aftermath
/// leverage account. Oracle storages and feeds follow the authenticated
/// market's current settings; their identities are not frozen at activation.
public struct Binding has copy, drop, store {
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
}

/// The bound Aftermath account as the adapter knows it: its identity, the last
/// raw state it accepted, and the sole admin authority over it, paired once at
/// construction. Every venue mutation goes through this module's guarded
/// functions; the cap never leaves.
public struct VenueAccount has store {
    binding: Binding,
    checkpoint: Checkpoint,
    admin_cap: AuthorityCap<ACCOUNT, ADMIN>,
}

// === Package Functions ===

// --- Binding ---

/// Creates the value that authenticates the venue objects a Vault owns or
/// trades on. The oracle storages are not bound: the venue's admin may re-point
/// a market's oracle (`set_base_oracle_params`, `set_collateral_oracle_params`),
/// so each capture checks the storages it is given against the bound clearing
/// house's current market parameters instead.
public(package) fun new_binding(
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
): Binding {
    Binding { account_object_id, account_number, registry_id, clearing_house_id }
}

/// The venue objects a capture reads are the bound ones; rejects the first component that differs.
public(package) fun assert_object_graph(
    self: &Binding,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
) {
    assert!(self.account_object_id == account_object_id, blast_boosts_aftermath::errors::account_object_mismatch!());
    assert!(self.account_number == account_number, blast_boosts_aftermath::errors::account_number_mismatch!());
    assert!(self.registry_id == registry_id, blast_boosts_aftermath::errors::registry_mismatch!());
    assert!(self.clearing_house_id == clearing_house_id, blast_boosts_aftermath::errors::clearing_house_mismatch!());
}

/// Each price-feed storage is the one the bound market prices with now, base
/// first. The venue's own price functions repeat this check and read the feed
/// at the market's current source id; nothing about the oracles is bound at
/// activation, so a venue-side re-pointing of a market's oracle never strands
/// the account.
public(package) fun assert_market_oracles<Collateral>(
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
) {
    let params = clearing_house.market_params();
    assert_market_oracle_ids!(
        base_oracle.storage_id(), params.base_storage_id(),
        collateral_oracle.storage_id(), params.collateral_storage_id(),
    );
}

public(package) fun account_number(self: &Binding): u64 { self.account_number }

// --- Account ---

/// Seals the bound account's identity, the checkpoint activation accepted, and
/// the admin cap. The cap must name that account; both are immutable from here
/// on, so this is the only place the pairing is ever checked.
public(package) fun new(
    binding: Binding,
    checkpoint: Checkpoint,
    admin_cap: AuthorityCap<ACCOUNT, ADMIN>,
): VenueAccount {
    assert!(
        admin_cap.`for`() == binding.account_object_id,
        blast_boosts_aftermath::errors::admin_cap_account_mismatch!(),
    );

    VenueAccount { binding, checkpoint, admin_cap }
}

/// Copies the immutable binding.
public(package) fun binding(self: &VenueAccount): Binding { self.binding }

/// Borrows the latest authenticated raw checkpoint immutably.
public(package) fun checkpoint(self: &VenueAccount): &Checkpoint {
    &self.checkpoint
}

/// Replaces the raw checkpoint after one fully authenticated observation.
public(package) fun replace_checkpoint(
    self: &mut VenueAccount,
    checkpoint: Checkpoint,
) {
    self.checkpoint = checkpoint;
}

// --- Deposit ---

/// Deposits only into the bound account under its admin authority.
public(package) fun deposit<Collateral>(
    self: &VenueAccount,
    account: &mut Account<Collateral>,
    registry: &Registry,
    cash: Coin<Collateral>,
) {
    self.binding.assert_account(account);
    self.binding.assert_registry(registry);

    account.deposit_collateral(&self.admin_cap, registry, cash);
}

/// Allocates deposited cash into the sole bound market without lending its authority.
public(package) fun allocate<Collateral>(
    self: &VenueAccount,
    account: &mut Account<Collateral>,
    clearing_house: &mut ClearingHouse<Collateral>,
    amount: u64,
) {
    self.binding.assert_market_account(account, clearing_house);

    clearing_house.allocate_collateral(&self.admin_cap, account, amount);
}

// --- Trade ---

/// Executes one bounded, price-limited order under retained authority and
/// returns its venue facts.
public(package) fun execute_order<Collateral>(
    self: &VenueAccount,
    account: &mut Account<Collateral>,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    is_ask: bool,
    base: u64,
    limit_price: u64,
    reduce_only: bool,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, SessionSummary) {
    self.binding.assert_market_account(account, &clearing_house);
    clearing_house.assert_market_oracles(base_oracle, collateral_oracle);

    self.admin_cap.execute_order_with_cap(
        account, clearing_house, base_oracle, collateral_oracle, is_ask, base, limit_price, reduce_only,
        clock, ctx,
    )
}

/// One immediate-or-cancel limit order in its own session under an explicit
/// cap: the seed position opens through this before the cap is sealed, and
/// every later order through `execute_order` above.
///
/// `limit_price` is the venue's 9-decimal price, a multiple of the market's
/// tick: a bid pays at most, an ask receives at least, that price. The venue
/// fills what rests at or inside it and cancels the remainder, so no order the
/// adapter places ever rests on the book and no fill crosses the limit.
public(package) fun execute_order_with_cap<Collateral>(
    admin_cap: &AuthorityCap<ACCOUNT, ADMIN>,
    account: &mut Account<Collateral>,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    is_ask: bool,
    base: u64,
    limit_price: u64,
    reduce_only: bool,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, SessionSummary) {
    let mut session = clearing_house.start_session(
        admin_cap, account, base_oracle, collateral_oracle, option::none(), clock, ctx,
    );
    // Immediate-or-cancel never posts, so the venue returns no resting order id.
    let _ = session.place_limit_order(
        is_ask, base, limit_price, constants::immediate_or_cancel_order_type!(), option::none(), reduce_only,
        option::none(),
    );

    session.end_session(admin_cap, account, false, false)
}

// --- Withdraw ---

/// Withdraws the exact payout, using free collateral before a bounded deallocation.
public(package) fun withdraw<Collateral>(
    self: &VenueAccount,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    self.binding.assert_market_account(account, clearing_house);
    self.binding.assert_registry(registry);
    clearing_house.assert_market_oracles(base_oracle, collateral_oracle);

    let free = account.collateral_balance();
    if (free < amount) {
        let required = amount - free;
        let deallocated = clearing_house.deallocate_collateral(
            &self.admin_cap, account, base_oracle, collateral_oracle, required, clock,
        );
        assert!(deallocated == required, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());
    };

    account.withdraw_collateral(&self.admin_cap, registry, amount, ctx)
}

// --- Funding ---

/// Refreshes the venue's lazily updated cumulative funding rates when they are
/// due, immediately before a settlement the vault accepts.
///
/// Aftermath advances cumulative funding only when someone trades or calls
/// its permissionless `update_funding`; an idle market would otherwise leave
/// accrued funding out of the settlement and both captured checkpoints.
/// The guard reads the bound market's `funding_last_upd_ms` and
/// the frequency, the first element of `funding_params`, and makes no venue
/// call when the update is not due. The bound market and base oracle are
/// checked against the binding first, so the venue mutation never touches an
/// unbound object. `update_funding` reads the base price-feed
/// storage: the deployed bytecode routes it through
/// `market::try_update_funding`, which prices the premium against the base
/// index through `base_oracle_price_and_twap_price` and aborts on any other
/// storage. The classifier already treats stored-to-pre market-rate
/// advancement as the expected precursor of a local settlement, so the
/// aggregate net-funding rule and the funding event are unchanged.
public(package) fun update_funding_when_due<Collateral>(
    self: &Binding,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    let params = clearing_house.market_params();
    self.assert_funding_update_inputs(object::id(clearing_house), base_oracle.storage_id(), params.base_storage_id());

    let (funding_update_interval_duration_ms, _) = params.funding_params();
    let funding_last_updated_at_ms = clearing_house.market_state().funding_last_upd_ms();

    if (is_time_to_update_funding(clock.timestamp_ms(), funding_last_updated_at_ms, funding_update_interval_duration_ms)) {
        clearing_house.update_funding(base_oracle, clock);
    };
}

// === Private Functions ===

/// Inlined so the base guard still runs before either collateral storage read.
/// Tests supply decoded ids because the external getter ports abort locally.
macro fun assert_market_oracle_ids(
    $base_storage_id: u32,
    $market_base_storage_id: u32,
    $collateral_storage_id: u32,
    $market_collateral_storage_id: u32,
) {
    assert!($base_storage_id == $market_base_storage_id, blast_boosts_aftermath::errors::base_oracle_mismatch!());
    assert!($collateral_storage_id == $market_collateral_storage_id, blast_boosts_aftermath::errors::collateral_oracle_mismatch!());
}

/// Rejects a market that is not the bound one, then a base oracle storage the
/// market does not price with, before the venue funding update mutates either;
/// the later capture re-authenticates everything.
fun assert_funding_update_inputs(
    self: &Binding,
    clearing_house_id: ID,
    base_storage_id: u32,
    market_base_storage_id: u32,
) {
    assert!(
        self.clearing_house_id == clearing_house_id,
        blast_boosts_aftermath::errors::clearing_house_mismatch!(),
    );
    assert!(base_storage_id == market_base_storage_id, blast_boosts_aftermath::errors::base_oracle_mismatch!());
}

/// The account object, its venue number, and its collateral type are the bound ones.
fun assert_account<Collateral>(self: &Binding, account: &Account<Collateral>) {
    assert!(object::id(account) == self.account_object_id, blast_boosts_aftermath::errors::account_object_mismatch!());
    assert!(account.account_id() == self.account_number, blast_boosts_aftermath::errors::account_number_mismatch!());
}

/// The account and the market a session touches are the bound ones.
fun assert_market_account<Collateral>(
    self: &Binding,
    account: &Account<Collateral>,
    clearing_house: &ClearingHouse<Collateral>,
) {
    self.assert_account(account);
    assert!(
        object::id(clearing_house) == self.clearing_house_id,
        blast_boosts_aftermath::errors::clearing_house_mismatch!(),
    );
}

fun assert_registry(self: &Binding, registry: &Registry) {
    assert!(object::id(registry) == self.registry_id, blast_boosts_aftermath::errors::registry_mismatch!());
}

/// Returns whether the venue's cumulative funding is due for an update at `now_at_ms`.
///
/// Mirrors the pinned `market::is_time_to_update` bytecode exactly:
/// `now_at_ms >= next_funding_update_at_ms(funding_last_updated_at_ms, funding_update_interval_duration_ms)`.
/// The venue's own `try_update_fundings` repeats this check, so the guard only
/// decides whether the adapter spends a venue call; it never changes what the
/// venue would settle. A zero frequency is never due: the venue formula would
/// divide by it, and a market without a funding cadence has nothing to
/// refresh.
fun is_time_to_update_funding(
    now_at_ms: u64,
    funding_last_updated_at_ms: u64,
    funding_update_interval_duration_ms: u64,
): bool {
    funding_update_interval_duration_ms > 0
        && now_at_ms >= next_funding_update_at_ms(funding_last_updated_at_ms, funding_update_interval_duration_ms)
}

/// Returns the venue's next funding update instant: the start of the period
/// after the one containing `funding_last_updated_at_ms`, exactly as the pinned
/// `market::next_funding_update_time` computes it.
fun next_funding_update_at_ms(
    funding_last_updated_at_ms: u64,
    funding_update_interval_duration_ms: u64,
): u64 {
    funding_last_updated_at_ms - funding_last_updated_at_ms % funding_update_interval_duration_ms + funding_update_interval_duration_ms
}

// === Test-Only Functions ===

#[test_only]
public fun assert_market_oracle_ids_for_testing(
    base_storage_id: u32,
    market_base_storage_id: u32,
    collateral_storage_id: u32,
    market_collateral_storage_id: u32,
) {
    assert_market_oracle_ids!(base_storage_id, market_base_storage_id, collateral_storage_id, market_collateral_storage_id);
}

#[test_only]
// EC09005 flags the deliberately unreachable getter trap; the test pins the earlier abort.
#[allow(dead_code)]
public fun assert_base_oracle_before_collateral_read_for_testing() {
    assert_market_oracle_ids!(1, 2, abort 404, abort 404);
}

#[test_only]
public fun assert_funding_update_inputs_for_testing(
    self: &Binding,
    clearing_house_id: ID,
    base_storage_id: u32,
    market_base_storage_id: u32,
) {
    self.assert_funding_update_inputs(clearing_house_id, base_storage_id, market_base_storage_id);
}

#[test_only]
public fun is_time_to_update_funding_for_testing(
    now_at_ms: u64,
    funding_last_updated_at_ms: u64,
    funding_update_interval_duration_ms: u64,
): bool {
    is_time_to_update_funding(now_at_ms, funding_last_updated_at_ms, funding_update_interval_duration_ms)
}

#[test_only]
public fun next_funding_update_time_ms_for_testing(funding_last_updated_at_ms: u64, funding_update_interval_duration_ms: u64): u64 {
    next_funding_update_at_ms(funding_last_updated_at_ms, funding_update_interval_duration_ms)
}

// === Imports ===

use authority_cap::authority::{ADMIN, AuthorityCap};

use blast_boosts_aftermath::{checkpoint::Checkpoint, constants};

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{
    account::Account,
    authority::ACCOUNT,
    clearing_house::{ClearingHouse, SessionSummary},
    market,
    registry::Registry,
};

use sui::{clock::Clock, coin::Coin};

use fun assert_market_oracles as ClearingHouse.assert_market_oracles;

use fun execute_order_with_cap as AuthorityCap.execute_order_with_cap;
