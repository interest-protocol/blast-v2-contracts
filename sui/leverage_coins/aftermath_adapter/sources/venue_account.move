// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Exact Aftermath account custody and immutable venue binding.
module blast_leverage_aftermath::venue_account;

use authority_cap::authority::{Self, ADMIN, AuthorityCap};
use ifixed::ifixed;
use oracle_aggregator::price_feed_storage::PriceFeedStorage;
use perpetuals::{
    account::{Self, Account},
    authority::ACCOUNT,
    clearing_house::{Self, ClearingHouse, SessionSummary},
    registry::Registry,
};
use std::type_name::TypeName;
use sui::{clock::Clock, coin::Coin};

// === Public Types ===

/// Immutable external object graph for one Aftermath leverage account.
public struct Binding has copy, drop, store {
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
}

/// Raw Aftermath state captured at one authenticated mutation boundary.
public struct Checkpoint has copy, drop, store {
    free_collateral: u64,
    allocated_collateral: u256,
    signed_base: u256,
    signed_quote_notional: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
    pending_ask_base: u256,
    pending_bid_base: u256,
    pending_order_count: u64,
    market_pause_mode: u8,
    market_frozen: bool,
    position_initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
    market_maintenance_margin_ratio: u256,
}

/// Store-only custody for the sole admin authority of one bound Aftermath account.
public struct VenueAccount has store {
    admin_cap: Option<AuthorityCap<ACCOUNT, ADMIN>>,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
    checkpoint: Checkpoint,
}

// === Package Functions ===

/// Withdraws the exact payout, using free collateral before a bounded deallocation.
public(package) fun withdraw<Collateral>(
    self: &VenueAccount, account: &mut Account<Collateral>, registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>, base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage, amount: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    self.assert_market_account(account, clearing_house);
    assert!(object::id(registry) == self.registry_id, blast_leverage_aftermath::errors::registry_mismatch!());
    assert!(object::id(base_oracle) == self.base_oracle_id, blast_leverage_aftermath::errors::base_oracle_mismatch!());
    assert!(object::id(collateral_oracle) == self.collateral_oracle_id, blast_leverage_aftermath::errors::collateral_oracle_mismatch!());
    let free = account::collateral_balance(account);
    if (free < amount) {
        let required = amount - free;
        let deallocated = clearing_house::deallocate_collateral(
            clearing_house, self.admin_cap.borrow(), account, base_oracle, collateral_oracle, required, clock,
        );
        assert!(deallocated == required, blast_leverage_aftermath::errors::cash_checkpoint_mismatch!());
    };
    account::withdraw_collateral(account, self.admin_cap.borrow(), registry, amount, ctx)
}

/// Allocates deposited cash into the sole bound market without lending its authority.
public(package) fun allocate<Collateral>(
    self: &VenueAccount, account: &mut Account<Collateral>, clearing_house: &mut ClearingHouse<Collateral>, amount: u64,
) {
    self.assert_market_account(account, clearing_house);
    clearing_house::allocate_collateral(clearing_house, self.admin_cap.borrow(), account, amount);
}

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
    self.assert_market_account(account, &clearing_house);
    assert!(object::id(base_oracle) == self.base_oracle_id, blast_leverage_aftermath::errors::base_oracle_mismatch!());
    assert!(object::id(collateral_oracle) == self.collateral_oracle_id, blast_leverage_aftermath::errors::collateral_oracle_mismatch!());

    let mut session = clearing_house::start_session(
        clearing_house, self.admin_cap.borrow(), account, base_oracle, collateral_oracle,
        option::none(), clock, ctx,
    );
    clearing_house::place_market_order(&mut session, is_ask, base, reduce_only);
    clearing_house::end_session(session, self.admin_cap.borrow(), account, false, false)
}

/// Deposits only into the retained account under its private admin authority.
public(package) fun deposit<Collateral>(
    self: &VenueAccount,
    account: &mut Account<Collateral>,
    registry: &Registry,
    cash: Coin<Collateral>,
) {
    self.assert_custody_binding();
    assert!(object::id(account) == self.account_object_id, blast_leverage_aftermath::errors::account_object_mismatch!());
    assert!(account::account_id(account) == self.account_number, blast_leverage_aftermath::errors::account_number_mismatch!());
    assert!(object::id(registry) == self.registry_id, blast_leverage_aftermath::errors::registry_mismatch!());
    assert!(std::type_name::with_original_ids<Collateral>() == self.collateral_type, blast_leverage_aftermath::errors::collateral_type_mismatch!());
    account::deposit_collateral(account, self.admin_cap.borrow(), registry, cash);
}

/// Rejects unresolved venue drift before a priced operation uses the accepted checkpoint.
public(package) fun assert_accepted_checkpoint(accepted: &Checkpoint, observed: &Checkpoint) {
    assert!(accepted == observed, blast_leverage_aftermath::errors::unresolved_checkpoint!());
}

/// A cash-only deposit may change exactly free collateral and no other raw field.
public(package) fun assert_deposit_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    let mut expected = *before;
    expected.free_collateral = expected.free_collateral.checked_add(amount)
        .destroy_or!(abort blast_leverage_aftermath::errors::cash_checkpoint_mismatch!());
    assert!(&expected == after, blast_leverage_aftermath::errors::cash_checkpoint_mismatch!());
}

/// A deposited-and-allocated input changes exactly allocated six-decimal collateral.
public(package) fun assert_allocated_deposit_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    assert_signed_cash_change(
        ifixed::is_neg(before.allocated_collateral), ifixed::abs(before.allocated_collateral),
        ifixed::is_neg(after.allocated_collateral), ifixed::abs(after.allocated_collateral), amount, true,
    );
    assert_cash_checkpoint(before, after, before.free_collateral);
}

/// Payout spends free cash first, then exactly deallocates the remaining amount.
public(package) fun assert_withdrawal_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    let from_free = before.free_collateral.min(amount);
    let from_position = amount - from_free;
    assert_signed_cash_change(
        ifixed::is_neg(before.allocated_collateral), ifixed::abs(before.allocated_collateral),
        ifixed::is_neg(after.allocated_collateral), ifixed::abs(after.allocated_collateral), from_position, false,
    );
    assert_cash_checkpoint(before, after, before.free_collateral - from_free);
}

/// An isolated session may change only its proved position and allocated trading cost.
/// Expected signed position values must derive from authenticated venue fill facts.
public(package) fun assert_trade_checkpoint(
    before: &Checkpoint, after: &Checkpoint, expected_base: u256, expected_quote: u256,
) {
    let mut expected = *before;
    expected.signed_base = expected_base;
    expected.signed_quote_notional = expected_quote;
    expected.allocated_collateral = after.allocated_collateral;
    assert!(&expected == after, blast_leverage_aftermath::errors::active_checkpoint_mismatch!());
}

/// Isolates a reduce-only session's actual realized-PnL/entry-quote effects.
/// The venue does not expose those deltas separately. Exact filled base, strict
/// post-position validity and actual kept-NAV pricing complete the adapter proof.
public(package) fun assert_reduction_checkpoint(before: &Checkpoint, after: &Checkpoint, expected_base: u256) {
    assert_trade_checkpoint(before, after, expected_base, after.signed_quote_notional);
}

/// Creates a value used to authenticate one complete external object graph.
public(package) fun new_binding(
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
): Binding {
    Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    }
}

/// Creates one raw checkpoint after the caller authenticates every source.
public(package) fun new_checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    signed_base: u256,
    signed_quote_notional: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
    pending_ask_base: u256,
    pending_bid_base: u256,
    pending_order_count: u64,
    market_pause_mode: u8,
    market_frozen: bool,
    position_initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
    market_maintenance_margin_ratio: u256,
): Checkpoint {
    Checkpoint {
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    }
}

/// Rejects the first external component that differs from this binding.
public(package) fun assert_exact(
    self: &Binding,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
) {
    assert!(
        self.account_object_id == account_object_id,
        blast_leverage_aftermath::errors::account_object_mismatch!(),
    );
    assert!(
        self.account_number == account_number,
        blast_leverage_aftermath::errors::account_number_mismatch!(),
    );
    assert!(
        self.registry_id == registry_id,
        blast_leverage_aftermath::errors::registry_mismatch!(),
    );
    assert!(
        self.clearing_house_id == clearing_house_id,
        blast_leverage_aftermath::errors::clearing_house_mismatch!(),
    );
    assert!(
        self.base_oracle_id == base_oracle_id,
        blast_leverage_aftermath::errors::base_oracle_mismatch!(),
    );
    assert!(
        self.collateral_oracle_id == collateral_oracle_id,
        blast_leverage_aftermath::errors::collateral_oracle_mismatch!(),
    );
    assert!(
        self.collateral_type == collateral_type,
        blast_leverage_aftermath::errors::collateral_type_mismatch!(),
    );
}

/// Seals the exact account admin authority into its authenticated binding.
public(package) fun new(
    admin_cap: AuthorityCap<ACCOUNT, ADMIN>,
    binding: Binding,
    checkpoint: Checkpoint,
): VenueAccount {
    let Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    } = binding;
    assert_admin_cap_binding(authority::`for`(&admin_cap), account_object_id);
    let admin_cap = option::some(admin_cap);
    VenueAccount {
        admin_cap,
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        checkpoint,
    }
}

/// Rejects an admin cap that does not belong to the created account object.
public(package) fun assert_admin_cap_binding(
    cap_account_object_id: ID,
    account_object_id: ID,
) {
    assert!(
        cap_account_object_id == account_object_id,
        blast_leverage_aftermath::errors::admin_cap_account_mismatch!(),
    );
}

/// Copies the immutable binding without exposing venue custody.
public(package) fun binding(self: &VenueAccount): Binding {
    Binding {
        account_object_id: self.account_object_id,
        account_number: self.account_number,
        registry_id: self.registry_id,
        clearing_house_id: self.clearing_house_id,
        base_oracle_id: self.base_oracle_id,
        collateral_oracle_id: self.collateral_oracle_id,
        collateral_type: self.collateral_type,
    }
}

/// Unpacks a copied immutable binding for replay-complete adapter events.
public(package) fun unpack_binding(
    self: Binding,
): (ID, u64, ID, ID, ID, ID, TypeName) {
    let Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    } = self;

    (
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    )
}

/// Borrows the latest authenticated raw checkpoint immutably.
public(package) fun checkpoint(self: &VenueAccount): &Checkpoint {
    &self.checkpoint
}

/// Revalidates that retained admin authority still names the bound account.
public(package) fun assert_custody_binding(self: &VenueAccount) {
    assert!(
        self.admin_cap.is_some(),
        blast_leverage_aftermath::errors::admin_cap_account_mismatch!(),
    );
    assert_admin_cap_binding(
        authority::`for`(self.admin_cap.borrow()),
        self.account_object_id,
    );
}

/// Unpacks a copied checkpoint for normalization and change classification.
public(package) fun unpack(
    self: Checkpoint,
): (
    u64,
    u256,
    u256,
    u256,
    u256,
    u256,
    u256,
    u256,
    u64,
    u256,
    u256,
    u64,
    u8,
    bool,
    u256,
    u256,
    u256,
) {
    let Checkpoint {
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    } = self;

    (
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    )
}

/// Replaces the raw checkpoint after one fully authenticated observation.
public(package) fun replace_checkpoint(
    self: &mut VenueAccount,
    checkpoint: Checkpoint,
) {
    self.checkpoint = checkpoint;
}

// === Private Functions ===

/// Checks every unrelated field after the caller proves the signed collateral delta.
fun assert_cash_checkpoint(before: &Checkpoint, after: &Checkpoint, free: u64) {
    let mut expected = *before;
    expected.free_collateral = free;
    expected.allocated_collateral = after.allocated_collateral;
    assert!(&expected == after, blast_leverage_aftermath::errors::cash_checkpoint_mismatch!());
}

/// Exact signed change in decoded IFixed magnitudes, with no raw-carrier ordering.
fun assert_signed_cash_change(
    before_negative: bool, before: u256, after_negative: bool, after: u256,
    amount: u64, increase: bool,
) {
    let required = (amount as u256) * 1_000_000_000_000;
    let (actual, credit) = if (before_negative == after_negative) {
        (before.diff(after), if (before_negative) { before > after } else { after > before })
    } else {
        (before.checked_add(after).destroy_or!(abort blast_leverage_aftermath::errors::cash_checkpoint_mismatch!()), !after_negative)
    };
    assert!(actual == required && (actual == 0 || credit == increase), blast_leverage_aftermath::errors::cash_checkpoint_mismatch!());
}

/// Verifies every authority-bearing account/market component before a session.
fun assert_market_account<Collateral>(
    self: &VenueAccount, account: &Account<Collateral>, clearing_house: &ClearingHouse<Collateral>,
) {
    self.assert_custody_binding();
    assert!(object::id(account) == self.account_object_id, blast_leverage_aftermath::errors::account_object_mismatch!());
    assert!(account::account_id(account) == self.account_number, blast_leverage_aftermath::errors::account_number_mismatch!());
    assert!(object::id(clearing_house) == self.clearing_house_id, blast_leverage_aftermath::errors::clearing_house_mismatch!());
    assert!(std::type_name::with_original_ids<Collateral>() == self.collateral_type, blast_leverage_aftermath::errors::collateral_type_mismatch!());
}

// === Test-Only Functions ===

/// Builds real binding/checkpoint custody around the unavailable local cap.
///
/// The authoritative external AuthorityCap constructor is an aborting ABI
/// stub in local tests. Published code has no path that can create `none`.
#[test_only]
public fun new_for_testing(
    binding: Binding,
    checkpoint: Checkpoint,
): VenueAccount {
    let Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    } = binding;

    VenueAccount {
        admin_cap: option::none(),
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        checkpoint,
    }
}

#[test_only]
public fun assert_admin_cap_binding_for_testing(
    cap_account_object_id: ID,
    account_object_id: ID,
) {
    assert_admin_cap_binding(cap_account_object_id, account_object_id);
}

#[test_only]
public fun assert_signed_cash_change_for_testing(
    before_negative: bool, before: u256, after_negative: bool, after: u256,
    amount: u64, increase: bool,
) {
    assert_signed_cash_change(before_negative, before, after_negative, after, amount, increase);
}

/// Exercises the pure cash proof with explicitly nonnegative decoded fixture collateral.
#[test_only]
public fun assert_nonnegative_cash_checkpoint_for_testing(
    before: &Checkpoint, after: &Checkpoint, amount: u64, deposit: bool,
) {
    let from_free = if (deposit) { 0 } else { before.free_collateral.min(amount) };
    assert_signed_cash_change(false, before.allocated_collateral, false, after.allocated_collateral, amount - from_free, deposit);
    assert_cash_checkpoint(before, after, before.free_collateral - from_free);
}

#[test_only]
public fun checkpoint_for_testing(
    free_collateral: u64,
    allocated_collateral: u256,
    signed_base: u256,
    signed_quote_notional: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
    pending_ask_base: u256,
    pending_bid_base: u256,
    pending_order_count: u64,
    market_pause_mode: u8,
    market_frozen: bool,
    position_initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
    market_maintenance_margin_ratio: u256,
): Checkpoint {
    new_checkpoint(
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    )
}
