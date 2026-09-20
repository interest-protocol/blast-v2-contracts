// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Exact Aftermath account custody under its immutable venue binding: every
/// deposit, allocation, order and withdrawal the Vault makes goes through here.
module blast_boosts_aftermath::venue_account;

// === Public Types ===

/// Immutable external object graph for one Aftermath leverage account.
public struct Binding has copy, drop, store {
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
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

/// Creates a value used to authenticate one complete external object graph.
public(package) fun new_binding(
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
): Binding {
    Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
    }
}

/// The external object graph a capture reads is the bound one; rejects the first component that differs.
public(package) fun assert_object_graph(
    self: &Binding,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
) {
    assert!(self.account_object_id == account_object_id, blast_boosts_aftermath::errors::account_object_mismatch!());
    assert!(self.account_number == account_number, blast_boosts_aftermath::errors::account_number_mismatch!());
    assert!(self.registry_id == registry_id, blast_boosts_aftermath::errors::registry_mismatch!());
    assert!(self.clearing_house_id == clearing_house_id, blast_boosts_aftermath::errors::clearing_house_mismatch!());
    assert!(self.base_oracle_id == base_oracle_id, blast_boosts_aftermath::errors::base_oracle_mismatch!());
    assert!(
        self.collateral_oracle_id == collateral_oracle_id,
        blast_boosts_aftermath::errors::collateral_oracle_mismatch!(),
    );
}

/// Rejects a market or base oracle that is not the bound one before the venue
/// funding update mutates it; the later capture re-authenticates everything.
fun assert_funding_update_inputs(
    self: &Binding,
    clearing_house_id: ID,
    base_oracle_id: ID,
) {
    assert!(
        self.clearing_house_id == clearing_house_id,
        blast_boosts_aftermath::errors::clearing_house_mismatch!(),
    );
    assert!(
        self.base_oracle_id == base_oracle_id,
        blast_boosts_aftermath::errors::base_oracle_mismatch!(),
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
        authority::`for`(&admin_cap) == binding.account_object_id,
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

/// Executes one bounded market order under retained authority and returns its venue facts.
public(package) fun execute_order<Collateral>(
    self: &VenueAccount,
    account: &mut Account<Collateral>,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    is_ask: bool,
    base: u64,
    reduce_only: bool,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, SessionSummary) {
    self.binding.assert_market_account(account, &clearing_house);
    self.binding.assert_oracles(base_oracle, collateral_oracle);

    execute_order_with_cap(
        &self.admin_cap, account, clearing_house, base_oracle, collateral_oracle, is_ask, base, reduce_only, clock, ctx,
    )
}

/// One market order in its own session under an explicit cap: the seed
/// position opens through this before the cap is sealed, and every later
/// order through `execute_order` above.
public(package) fun execute_order_with_cap<Collateral>(
    admin_cap: &AuthorityCap<ACCOUNT, ADMIN>,
    account: &mut Account<Collateral>,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    is_ask: bool,
    base: u64,
    reduce_only: bool,
    clock: &Clock,
    ctx: &TxContext,
): (ClearingHouse<Collateral>, SessionSummary) {
    let mut session = clearing_house.start_session(
        admin_cap, account, base_oracle, collateral_oracle, option::none(), clock, ctx,
    );
    session.place_market_order(is_ask, base, reduce_only);

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
    self.binding.assert_oracles(base_oracle, collateral_oracle);

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
    self.assert_funding_update_inputs(object::id(clearing_house), object::id(base_oracle));

    let (funding_frequency_ms, _) = clearing_house.market_params().funding_params();
    let last_funding_update_ms = clearing_house.market_state().funding_last_upd_ms();

    if (is_time_to_update_funding(clock.timestamp_ms(), last_funding_update_ms, funding_frequency_ms)) {
        clearing_house.update_funding(base_oracle, clock);
    };
}

// === Private Functions ===

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

fun assert_oracles(self: &Binding, base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage) {
    assert!(object::id(base_oracle) == self.base_oracle_id, blast_boosts_aftermath::errors::base_oracle_mismatch!());
    assert!(
        object::id(collateral_oracle) == self.collateral_oracle_id,
        blast_boosts_aftermath::errors::collateral_oracle_mismatch!(),
    );
}

/// Returns whether the venue's cumulative funding is due for an update at `now_ms`.
///
/// Mirrors the pinned `market::is_time_to_update` bytecode exactly:
/// `now_ms >= next_funding_update_time_ms(last_funding_update_ms, funding_frequency_ms)`.
/// The venue's own `try_update_fundings` repeats this check, so the guard only
/// decides whether the adapter spends a venue call; it never changes what the
/// venue would settle. A zero frequency is never due: the venue formula would
/// divide by it, and a market without a funding cadence has nothing to
/// refresh.
fun is_time_to_update_funding(now_ms: u64, last_funding_update_ms: u64, funding_frequency_ms: u64): bool {
    funding_frequency_ms > 0
        && now_ms >= next_funding_update_time_ms(last_funding_update_ms, funding_frequency_ms)
}

/// Returns the venue's next funding update instant: the start of the period
/// after the one containing `last_funding_update_ms`, exactly as the pinned
/// `market::next_funding_update_time` computes it.
fun next_funding_update_time_ms(last_funding_update_ms: u64, funding_frequency_ms: u64): u64 {
    last_funding_update_ms - last_funding_update_ms % funding_frequency_ms + funding_frequency_ms
}

// === Test-Only Functions ===

#[test_only]
public fun assert_funding_update_inputs_for_testing(self: &Binding, clearing_house_id: ID, base_oracle_id: ID) {
    self.assert_funding_update_inputs(clearing_house_id, base_oracle_id);
}

#[test_only]
public fun is_time_to_update_funding_for_testing(
    now_ms: u64,
    last_funding_update_ms: u64,
    funding_frequency_ms: u64,
): bool {
    is_time_to_update_funding(now_ms, last_funding_update_ms, funding_frequency_ms)
}

#[test_only]
public fun next_funding_update_time_ms_for_testing(last_funding_update_ms: u64, funding_frequency_ms: u64): u64 {
    next_funding_update_time_ms(last_funding_update_ms, funding_frequency_ms)
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN, AuthorityCap};

use blast_boosts_aftermath::checkpoint::Checkpoint;

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{
    account::Account,
    authority::ACCOUNT,
    clearing_house::{ClearingHouse, SessionSummary},
    market,
    registry::Registry,
};

use sui::{clock::Clock, coin::Coin};
