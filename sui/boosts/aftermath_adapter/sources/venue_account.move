// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Exact Aftermath account custody, its immutable venue binding, and the raw
/// checkpoints the adapter proves every venue mutation against: how one is
/// read, what may change between two, and what each operation must leave.
module blast_boosts_aftermath::venue_account;

// The `*_decoded` helpers take collateral already decoded from IFixed into a
// sign and magnitude; the pinned `ifixed` port aborts under test, so the pure
// proof is exercised from fixtures through them.

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

/// The bound Aftermath account as the adapter knows it: its identity, the last
/// raw state it accepted, and the sole admin authority over it, paired once at
/// construction. Every venue mutation goes through this module's guarded
/// functions; the cap never leaves.
public struct VenueAccount has store {
    binding: Binding,
    checkpoint: Checkpoint,
    admin_cap: AuthorityCap<ACCOUNT, ADMIN>,
}

// This unstorable, same-call value carries the Coin that `vault::seal_terminal_cash` pays out.
// Pinned ESL99003 otherwise suggests Balance, which would require a new Coin/TxContext there.
#[allow(lint(coin_field))]
/// Actual recovered coin bound to its exact final venue checkpoint.
/// Package-only construction proves finality; Vault custody must consume it.
public struct TerminalWithdrawal<phantom Collateral> {
    recovered: Coin<Collateral>,
    checkpoint: Checkpoint,
}

/// What moved between the checkpoint last accepted and the one just captured:
/// nothing, one funding settlement carrying its raw signed collateral delta, or
/// anything else, which no operation may build on.
public enum CheckpointChange has drop {
    Unchanged,
    FundingCredit(u256),
    FundingCost(u256),
    Unexpected,
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
public(package) fun assert_funding_update_inputs(
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

// --- Checkpoint ---

/// Reads every raw venue field the checkpoint authenticates, in one pass and without normalization.
public(package) fun read_checkpoint<Collateral>(account: &Account<Collateral>, clearing_house: &ClearingHouse<Collateral>): Checkpoint {
    let params = clearing_house.market_params();
    let position = clearing_house.position(account.account_id());
    let (base, quote) = position.base_and_quote_amounts();
    let (snapshot_long, snapshot_short) = position.funding_rate_snapshots();
    let (market_long, market_short) = clearing_house.market_state().cum_funding_rates();
    let (ask, bid) = position.pending_base_amounts_by_side();

    new_checkpoint(
        account.collateral_balance(), position.collateral(), base, quote,
        snapshot_long, snapshot_short, market_long, market_short, params.lot_size(), ask, bid,
        position.pending_order_count(), clearing_house.market_pause_mode(), clearing_house.is_frozen(),
        position.initial_margin_ratio(), params.margin_ratio_initial(), params.margin_ratio_maintenance(),
    )
}

/// The venue still shows the checkpoint last accepted; a priced operation may not build on drift.
public(package) fun assert_unchanged(self: &Checkpoint, observed: &Checkpoint) {
    assert!(self == observed, blast_boosts_aftermath::errors::unresolved_checkpoint!());
}

public(package) fun signed_base(self: &Checkpoint): u256 { self.signed_base }

public(package) fun signed_quote_notional(self: &Checkpoint): u256 { self.signed_quote_notional }

public(package) fun lot_size(self: &Checkpoint): u64 { self.lot_size }

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

/// A cash-only deposit may change exactly free collateral and no other raw field.
public(package) fun assert_deposit_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    let mut expected = *before;
    expected.free_collateral = expected.free_collateral.checked_add(amount)
        .destroy_or!(abort blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());
    assert!(&expected == after, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());
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

/// A deposited-and-allocated input changes exactly allocated six-decimal collateral.
public(package) fun assert_allocated_deposit_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    assert_signed_cash_change(
        before.allocated_collateral.is_neg(), before.allocated_collateral.abs(),
        after.allocated_collateral.is_neg(), after.allocated_collateral.abs(), amount, true,
    );
    assert_cash_checkpoint(before, after, before.free_collateral);
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

    let mut session = clearing_house.start_session(
        &self.admin_cap, account, base_oracle, collateral_oracle, option::none(), clock, ctx,
    );
    session.place_market_order(is_ask, base, reduce_only);

    session.end_session(&self.admin_cap, account, false, false)
}

/// An isolated session may change only its proved position and allocated trading cost.
/// Expected signed position values must derive from authenticated venue fill facts.
public(package) fun assert_trade_checkpoint(
    before: &Checkpoint,
    after: &Checkpoint,
    expected_base: u256,
    expected_quote: u256,
) {
    let mut expected = *before;
    expected.signed_base = expected_base;
    expected.signed_quote_notional = expected_quote;
    expected.allocated_collateral = after.allocated_collateral;

    assert!(&expected == after, blast_boosts_aftermath::errors::active_checkpoint_mismatch!());
}

/// Isolates a reduce-only session's actual realized-PnL/entry-quote effects.
/// The venue does not expose those deltas separately. Exact filled base, strict
/// post-position validity and actual kept-NAV pricing complete the adapter proof.
public(package) fun assert_reduction_checkpoint(before: &Checkpoint, after: &Checkpoint, expected_base: u256) {
    assert_trade_checkpoint(before, after, expected_base, after.signed_quote_notional);
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

/// Payout spends free cash first, then exactly deallocates the remaining amount.
public(package) fun assert_withdrawal_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    let from_free = before.free_collateral.min(amount);

    assert_signed_cash_change(
        before.allocated_collateral.is_neg(), before.allocated_collateral.abs(),
        after.allocated_collateral.is_neg(), after.allocated_collateral.abs(),
        amount - from_free, false,
    );
    assert_cash_checkpoint(before, after, before.free_collateral - from_free);
}

// --- Funding ---

/// Returns true when only the market's cumulative funding rates advanced.
///
/// This is the ordinary pre-settlement shape: the position still carries the
/// stored funding snapshots while the market rates may have moved forward.
public(package) fun checkpoint_ready_for_settlement(stored: &Checkpoint, before: &Checkpoint): bool {
    stored.non_funding_fields_equal(before)
        && stored.allocated_collateral() == before.allocated_collateral()
        && stored.funding_snapshot_long() == before.funding_snapshot_long()
        && stored.funding_snapshot_short() == before.funding_snapshot_short()
}

/// Recognizes funding that another caller settled before this synchronization.
///
/// Aftermath settlement is permissionless. The adapter therefore accepts the
/// one exact stored-to-pre shape that settlement can produce: funding
/// snapshots refresh to the current market rates and allocated collateral
/// changes, while every unrelated account, position, order, and risk field is
/// byte-for-byte unchanged.
public(package) fun classify_preexisting_funding(stored: &Checkpoint, before: &Checkpoint): CheckpointChange {
    classify_preexisting_from_delta(stored, before, allocated_delta(stored, before))
}

/// Classifies only an isolated funding-snapshot and allocated-collateral change.
public(package) fun classify_change(
    before: &Checkpoint,
    after: &Checkpoint,
    funding_candidate: u256,
    collateral_price: u256,
): CheckpointChange {
    if (before == after) return CheckpointChange::Unchanged;

    let (candidate_collateral_magnitude, representable) = ifixed_math::usd_fixed_to_collateral_fixed(
        funding_candidate.abs(), collateral_price, funding_candidate.is_neg(),
    );
    if (!representable) return CheckpointChange::Unexpected;

    classify_from_delta(
        before, after, funding_candidate.is_neg(), candidate_collateral_magnitude,
        allocated_delta(before, after),
    )
}

/// Nets authenticated settlement edges before rounding or buffer allocation.
/// No gross ordering inside one Blast checkpoint is an entitlement boundary.
public(package) fun net_funding(preexisting: CheckpointChange, settled: CheckpointChange): CheckpointChange {
    if (preexisting.is_unexpected() || settled.is_unexpected()) return CheckpointChange::Unexpected;

    let (preexisting_is_cost, preexisting_amount) = (preexisting.is_cost(), preexisting.raw_amount());
    let (settled_is_cost, settled_amount) = (settled.is_cost(), settled.raw_amount());
    let (is_cost, amount) = if (preexisting_is_cost == settled_is_cost) {
        (
            preexisting_is_cost,
            preexisting_amount.checked_add(settled_amount).destroy_or!(return CheckpointChange::Unexpected),
        )
    } else if (preexisting_amount >= settled_amount) {
        (preexisting_is_cost, preexisting_amount - settled_amount)
    } else {
        (settled_is_cost, settled_amount - preexisting_amount)
    };

    funding_change(is_cost, amount)
}

/// Creates the clean no-op classification for adapter orchestration.
public(package) fun unchanged_change(): CheckpointChange {
    CheckpointChange::Unchanged
}

/// A terminal market close may realize losses, but cannot misattribute an unrelated funding mutation.
public(package) fun assert_expected(self: CheckpointChange) {
    assert!(!self.is_unexpected(), blast_boosts_aftermath::errors::unresolved_checkpoint!());
}

// --- Funding Change Reads ---

/// Returns whether the change is a representable funding credit or cost.
public(package) fun has_funding(self: &CheckpointChange): bool {
    match (self) {
        CheckpointChange::FundingCredit(raw) => { let (_, ok) = ifixed_math::fixed_to_u64_down(*raw, constants::collateral_decimals!() as u64); ok },
        CheckpointChange::FundingCost(raw) => { let (_, ok) = ifixed_math::fixed_to_u64_up(*raw, constants::collateral_decimals!() as u64); ok },
        _ => false,
    }
}

/// Returns whether the change is a funding cost.
public(package) fun is_cost(self: &CheckpointChange): bool {
    match (self) { CheckpointChange::FundingCost(_) => true, _ => false }
}

/// Returns the raw IFixed funding magnitude; zero when there is no funding.
public(package) fun raw_amount(self: &CheckpointChange): u256 {
    match (self) {
        CheckpointChange::FundingCredit(raw) => *raw,
        CheckpointChange::FundingCost(raw) => *raw,
        _ => 0,
    }
}

/// Returns the six-decimal funding amount, credits down and costs up; zero when unrepresentable.
public(package) fun amount(self: &CheckpointChange): u64 {
    match (self) {
        CheckpointChange::FundingCredit(raw) => { let (amount, _) = ifixed_math::fixed_to_u64_down(*raw, constants::collateral_decimals!() as u64); amount },
        CheckpointChange::FundingCost(raw) => { let (amount, _) = ifixed_math::fixed_to_u64_up(*raw, constants::collateral_decimals!() as u64); amount },
        _ => 0,
    }
}

/// Returns whether the checkpoint is clean: unchanged, or a representable funding change.
public(package) fun is_clean(self: &CheckpointChange): bool {
    match (self) {
        CheckpointChange::Unchanged => true,
        CheckpointChange::Unexpected => false,
        _ => self.has_funding(),
    }
}

// --- Shutdown ---

/// Neither an ordinary close nor a direct settlement may adopt standing orders.
public(package) fun assert_no_orders(self: &Checkpoint) {
    assert!(
        self.pending_ask_base == 0 && self.pending_bid_base == 0 && self.pending_order_count == 0,
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );
}

/// A venue-enabled frozen settlement can realize cash, but must finish exactly flat and order-free.
public(package) fun assert_direct_settlement_checkpoint(before: &Checkpoint, after: &Checkpoint) {
    before.assert_no_orders();
    after.assert_no_orders();
    assert!(
        before.market_frozen && before.signed_base != 0
            && after.signed_base == 0 && after.signed_quote_notional == 0
            && after.funding_snapshot_long == after.market_funding_long
            && after.funding_snapshot_short == after.market_funding_short,
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );

    // The settlement may move only the position, the cash it released, and the funding snapshots.
    let mut expected = *before;
    expected.signed_base = 0;
    expected.signed_quote_notional = 0;
    expected.free_collateral = after.free_collateral;
    expected.allocated_collateral = after.allocated_collateral;
    expected.funding_snapshot_long = after.funding_snapshot_long;
    expected.funding_snapshot_short = after.funding_snapshot_short;

    assert!(&expected == after, blast_boosts_aftermath::errors::terminal_venue_unsettled!());
}

/// Returns every recoverable atomic USDC unit only after exact venue finality.
/// Named IFixed decoding excludes liabilities before whole-atom floor conversion.
public(package) fun recoverable_terminal_cash(self: &Checkpoint): u64 {
    let (negative, magnitude) = self.allocated_collateral_sign_and_magnitude();
    recoverable_cash_decoded(self, negative, magnitude)
}

/// Complete recovery changes only the two collateral locations, by the actual returned coin.
public(package) fun terminal_withdrawal<Collateral>(
    before: &Checkpoint,
    after: Checkpoint,
    recovered: Coin<Collateral>,
): TerminalWithdrawal<Collateral> {
    assert_terminal_withdrawal_checkpoint(before, &after, recovered.value());
    TerminalWithdrawal { recovered, checkpoint: after }
}

public(package) fun recovered_amount<Collateral>(self: &TerminalWithdrawal<Collateral>): u64 {
    self.recovered.value()
}

/// Consumes the verified withdrawal, including the raw sub-atomic remainder for replay.
public(package) fun into_recovered_cash<Collateral>(
    self: TerminalWithdrawal<Collateral>,
): (Coin<Collateral>, Checkpoint, u256) {
    let TerminalWithdrawal { recovered, checkpoint } = self;
    (recovered, checkpoint, checkpoint.allocated_collateral)
}

// === Private Functions ===

// --- Binding ---

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

// --- Checkpoint ---

/// Assembles one raw checkpoint from fields the caller read in one pass.
fun new_checkpoint(
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

/// Returns whether every field outside funding accounting is equal.
///
/// Funding fields are allocated collateral, both position funding snapshots,
/// and both market cumulative funding rates; settlement may move only those.
fun non_funding_fields_equal(self: &Checkpoint, other: &Checkpoint): bool {
    self.free_collateral == other.free_collateral
        && self.signed_base == other.signed_base
        && self.signed_quote_notional == other.signed_quote_notional
        && self.lot_size == other.lot_size
        && self.pending_ask_base == other.pending_ask_base
        && self.pending_bid_base == other.pending_bid_base
        && self.pending_order_count == other.pending_order_count
        && self.market_pause_mode == other.market_pause_mode
        && self.market_frozen == other.market_frozen
        && self.position_initial_margin_ratio == other.position_initial_margin_ratio
        && self.market_initial_margin_ratio == other.market_initial_margin_ratio
        && self.market_maintenance_margin_ratio == other.market_maintenance_margin_ratio
}

fun allocated_collateral(self: &Checkpoint): u256 { self.allocated_collateral }

fun funding_snapshot_long(self: &Checkpoint): u256 { self.funding_snapshot_long }

fun funding_snapshot_short(self: &Checkpoint): u256 { self.funding_snapshot_short }

fun market_funding_long(self: &Checkpoint): u256 { self.market_funding_long }

fun market_funding_short(self: &Checkpoint): u256 { self.market_funding_short }

// --- Cash ---

/// Exact signed change in decoded IFixed magnitudes, with no raw-carrier ordering.
fun assert_signed_cash_change(
    before_negative: bool,
    before: u256,
    after_negative: bool,
    after: u256,
    amount: u64,
    increase: bool,
) {
    let required = (amount as u256) * constants::collateral_atom_to_ifixed_scale!();
    let (actual, credit) = if (before_negative == after_negative) {
        (before.diff(after), if (before_negative) { before > after } else { after > before })
    } else {
        let crossed = before.checked_add(after)
            .destroy_or!(abort blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());
        (crossed, !after_negative)
    };

    assert!(
        actual == required && (actual == 0 || credit == increase),
        blast_boosts_aftermath::errors::cash_checkpoint_mismatch!(),
    );
}

/// Checks every unrelated field after the caller proves the signed collateral delta.
fun assert_cash_checkpoint(before: &Checkpoint, after: &Checkpoint, free_collateral: u64) {
    let mut expected = *before;
    expected.free_collateral = free_collateral;
    expected.allocated_collateral = after.allocated_collateral;

    assert!(&expected == after, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());
}

// --- Funding ---

fun classify_preexisting_from_delta(
    stored: &Checkpoint,
    before: &Checkpoint,
    allocated_change: CheckpointChange,
): CheckpointChange {
    // The position snapshots prove the completed external settlement. They may
    // trail the market again if another funding epoch advanced before Blast
    // synchronized, so equality with the current market rates is not required.
    let snapshots_refreshed = stored.funding_snapshot_long() != before.funding_snapshot_long()
        || stored.funding_snapshot_short() != before.funding_snapshot_short();
    if (!stored.non_funding_fields_equal(before) || !snapshots_refreshed) return CheckpointChange::Unexpected;

    allocated_change
}

fun classify_from_delta(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
    allocated_change: CheckpointChange,
): CheckpointChange {
    if (before == after) return CheckpointChange::Unchanged;
    if (!before.market_rates_unchanged(after) || !before.snapshots_refreshed_to_market(after)) {
        return CheckpointChange::Unexpected
    };
    if (candidate_collateral_magnitude == 0 && before.allocated_collateral() == after.allocated_collateral()) {
        return CheckpointChange::Unchanged
    };

    if (allocated_change.matches_candidate(candidate_negative, candidate_collateral_magnitude)) {
        allocated_change
    } else {
        CheckpointChange::Unexpected
    }
}

/// Every field but the position's own funding snapshots is byte-for-byte the same.
fun market_rates_unchanged(self: &Checkpoint, after: &Checkpoint): bool {
    self.non_funding_fields_equal(after)
        && self.market_funding_long() == after.market_funding_long()
        && self.market_funding_short() == after.market_funding_short()
}

/// The position's snapshots moved and now sit exactly at the market rates `self` showed.
fun snapshots_refreshed_to_market(self: &Checkpoint, after: &Checkpoint): bool {
    after.funding_snapshot_long() == self.market_funding_long()
        && after.funding_snapshot_short() == self.market_funding_short()
        && (self.funding_snapshot_long() != after.funding_snapshot_long()
            || self.funding_snapshot_short() != after.funding_snapshot_short())
}

/// The allocated-collateral move is the one the venue's own funding formula predicted.
fun matches_candidate(self: &CheckpointChange, candidate_negative: bool, candidate_magnitude: u256): bool {
    match (self) {
        CheckpointChange::FundingCredit(amount) => !candidate_negative && *amount == candidate_magnitude,
        CheckpointChange::FundingCost(amount) => candidate_negative && *amount == candidate_magnitude,
        CheckpointChange::Unchanged => candidate_magnitude == 0,
        CheckpointChange::Unexpected => false,
    }
}

/// Named IFixed operations decode signed collateral; raw checkpoint bits are never ordered.
fun allocated_delta(before: &Checkpoint, after: &Checkpoint): CheckpointChange {
    let (before_raw, after_raw) = (before.allocated_collateral(), after.allocated_collateral());

    signed_delta(before_raw.is_neg(), before_raw.abs(), after_raw.is_neg(), after_raw.abs())
}

/// Computes after-minus-before in sign/magnitude facts, including a zero crossing.
fun signed_delta(
    before_negative: bool,
    before_magnitude: u256,
    after_negative: bool,
    after_magnitude: u256,
): CheckpointChange {
    if (before_negative != after_negative) {
        return sign_crossing_delta(before_magnitude, after_negative, after_magnitude)
    };

    // Same sign: the balance grew when a positive got larger or a negative got smaller.
    let grew = if (before_negative) { before_magnitude > after_magnitude } else { after_magnitude > before_magnitude };

    funding_change(!grew, before_magnitude.diff(after_magnitude))
}

/// The balance crossed zero: it moved by both magnitudes, a cost when it landed negative.
fun sign_crossing_delta(before_magnitude: u256, after_negative: bool, after_magnitude: u256): CheckpointChange {
    if (before_magnitude > std::u256::max_value!() - after_magnitude) return CheckpointChange::Unexpected;

    funding_change(after_negative, before_magnitude + after_magnitude)
}

/// No move is no change; otherwise a cost or a credit of `amount`.
fun funding_change(is_cost: bool, amount: u256): CheckpointChange {
    if (amount == 0) {
        CheckpointChange::Unchanged
    } else if (is_cost) {
        CheckpointChange::FundingCost(amount)
    } else {
        CheckpointChange::FundingCredit(amount)
    }
}

fun is_unexpected(self: &CheckpointChange): bool {
    match (self) { CheckpointChange::Unexpected => true, _ => false }
}

// --- Shutdown ---

fun assert_terminal_withdrawal_checkpoint(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    let (negative, magnitude) = before.allocated_collateral_sign_and_magnitude();
    assert_terminal_withdrawal_checkpoint_decoded(before, after, amount, negative, magnitude);
}

/// Binds native cash to finality before the Vault can seal terminal custody.

fun allocated_collateral_sign_and_magnitude(self: &Checkpoint): (bool, u256) {
    if (self.allocated_collateral == 0) {
        (false, 0)
    } else {
        (self.allocated_collateral.is_neg(), self.allocated_collateral.abs())
    }
}

fun recoverable_cash_decoded(self: &Checkpoint, is_negative: bool, magnitude: u256): u64 {
    assert!(
        self.signed_base == 0 && self.signed_quote_notional == 0
            && self.pending_ask_base == 0 && self.pending_bid_base == 0
            && self.pending_order_count == 0
            && self.funding_snapshot_long == self.market_funding_long
            && self.funding_snapshot_short == self.market_funding_short,
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );

    let (atoms, representable) =
        ifixed_math::fixed_to_u64_down(magnitude, constants::collateral_decimals!() as u64);
    assert!(
        !is_negative && representable && atoms <= std::u64::max_value!() - self.free_collateral,
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );

    self.free_collateral + atoms
}

fun assert_terminal_withdrawal_checkpoint_decoded(
    before: &Checkpoint,
    after: &Checkpoint,
    amount: u64,
    is_negative: bool,
    magnitude: u256,
) {
    assert!(
        recoverable_cash_decoded(before, is_negative, magnitude) == amount,
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );

    let mut expected = *before;
    expected.free_collateral = 0;
    // Magnitude is nonnegative and validated above; the exact raw remainder is < one atom.
    expected.allocated_collateral = magnitude % constants::collateral_atom_to_ifixed_scale!();

    assert!(&expected == after, blast_boosts_aftermath::errors::terminal_venue_unsettled!());
}

// === Test-Only Functions ===

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

#[test_only]
/// Unpacks every checkpoint field, in declaration order, for test assertions.
public fun unpack_for_testing(self: Checkpoint): (
    u64, u256, u256, u256, u256, u256, u256, u256, u64, u256, u256, u64, u8, bool, u256, u256, u256,
) {
    let Checkpoint {
        free_collateral, allocated_collateral, signed_base, signed_quote_notional,
        funding_snapshot_long, funding_snapshot_short, market_funding_long, market_funding_short,
        lot_size, pending_ask_base, pending_bid_base, pending_order_count, market_pause_mode,
        market_frozen, position_initial_margin_ratio, market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    } = self;
    (
        free_collateral, allocated_collateral, signed_base, signed_quote_notional,
        funding_snapshot_long, funding_snapshot_short, market_funding_long, market_funding_short,
        lot_size, pending_ask_base, pending_bid_base, pending_order_count, market_pause_mode,
        market_frozen, position_initial_margin_ratio, market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    )
}

#[test_only]
public fun assert_signed_cash_change_for_testing(
    before_negative: bool,
    before: u256,
    after_negative: bool,
    after: u256,
    amount: u64,
    increase: bool,
) {
    assert_signed_cash_change(before_negative, before, after_negative, after, amount, increase);
}

/// Exercises the pure cash proof with explicitly nonnegative decoded fixture collateral.
#[test_only]
public fun assert_nonnegative_cash_checkpoint_for_testing(
    before: &Checkpoint,
    after: &Checkpoint,
    amount: u64,
    deposit: bool,
) {
    let from_free = if (deposit) { 0 } else { before.free_collateral.min(amount) };
    assert_signed_cash_change(
        false, before.allocated_collateral, false, after.allocated_collateral, amount - from_free, deposit,
    );
    assert_cash_checkpoint(before, after, before.free_collateral - from_free);
}

/// Decoded dependency-port values; the production wrapper always uses named IFixed decoding.
#[test_only]
public(package) fun recoverable_cash_for_testing(self: &Checkpoint, is_negative: bool, magnitude: u256): u64 {
    recoverable_cash_decoded(self, is_negative, magnitude)
}

#[test_only]
public fun assert_terminal_withdrawal_checkpoint_decoded_for_testing(
    before: &Checkpoint,
    after: &Checkpoint,
    amount: u64,
    is_negative: bool,
    magnitude: u256,
) {
    assert_terminal_withdrawal_checkpoint_decoded(before, after, amount, is_negative, magnitude);
}

/// Substitutes only named IFixed decoding; cash and checkpoint guards remain production code.
#[test_only]
public(package) fun terminal_withdrawal_for_testing<Collateral>(
    before: &Checkpoint,
    after: Checkpoint,
    recovered: Coin<Collateral>,
    is_negative: bool,
    magnitude: u256,
): TerminalWithdrawal<Collateral> {
    assert_terminal_withdrawal_checkpoint_decoded(before, &after, recovered.value(), is_negative, magnitude);
    TerminalWithdrawal { recovered, checkpoint: after }
}

#[test_only]
public fun assert_terminal_withdrawal_checkpoint_for_testing(before: &Checkpoint, after: &Checkpoint, amount: u64) {
    assert_terminal_withdrawal_checkpoint(before, after, amount)
}

#[test_only]
/// Creates the dirty-checkpoint classification for adapter test fixtures.
public fun unexpected_change(): CheckpointChange {
    CheckpointChange::Unexpected
}

#[test_only]
/// Returns `(has_funding, is_cost, raw_amount, amount, is_clean)` for test assertions.
public fun funding_change_fields(
    change: &CheckpointChange,
): (bool, bool, u256, u64, bool) {
    match (change) {
        CheckpointChange::Unchanged => (false, false, 0, 0, true),
        CheckpointChange::Unexpected => (false, false, 0, 0, false),
        CheckpointChange::FundingCredit(raw_amount) => {
            let (amount, representable) = ifixed_math::fixed_to_u64_down(*raw_amount, constants::collateral_decimals!() as u64);
            (representable, false, *raw_amount, amount, representable)
        },
        CheckpointChange::FundingCost(raw_amount) => {
            let (amount, representable) = ifixed_math::fixed_to_u64_up(*raw_amount, constants::collateral_decimals!() as u64);
            (representable, true, *raw_amount, amount, representable)
        },
    }
}

#[test_only]
public fun classify_change_for_testing(before: &Checkpoint, after: &Checkpoint): CheckpointChange {
    classify_change_with_candidate_for_testing(before, after, false, 0)
}

#[test_only]
public fun classify_change_with_candidate_for_testing(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_magnitude: u256,
): CheckpointChange {
    let delta = signed_delta(false, before.allocated_collateral(), false, after.allocated_collateral());
    classify_from_delta(before, after, candidate_negative, candidate_magnitude, delta)
}

#[test_only]
public fun classify_preexisting_funding_for_testing(
    stored: &Checkpoint,
    before: &Checkpoint,
): CheckpointChange {
    let delta = signed_delta(false, stored.allocated_collateral(), false, before.allocated_collateral());
    classify_preexisting_from_delta(stored, before, delta)
}

#[test_only]
public fun classify_signed_funding_for_testing(
    stored: &Checkpoint,
    before: &Checkpoint,
    stored_negative: bool,
    stored_magnitude: u256,
    before_negative: bool,
    before_magnitude: u256,
): CheckpointChange {
    classify_preexisting_from_delta(
        stored, before, signed_delta(stored_negative, stored_magnitude, before_negative, before_magnitude),
    )
}

#[test_only]
public fun is_unchanged_for_testing(change: CheckpointChange): bool {
    match (change) { CheckpointChange::Unchanged => true, _ => false }
}

#[test_only]
public fun is_credit_for_testing(change: CheckpointChange): bool {
    match (change) { CheckpointChange::FundingCredit(_) => true, _ => false }
}

#[test_only]
public fun is_cost_for_testing(change: CheckpointChange): bool {
    match (change) { CheckpointChange::FundingCost(_) => true, _ => false }
}

#[test_only]
public fun funding_amount_for_testing(change: CheckpointChange): u256 {
    match (change) {
        CheckpointChange::FundingCredit(amount) => amount,
        CheckpointChange::FundingCost(amount) => amount,
        _ => 0,
    }
}

#[test_only]
public fun is_unexpected_for_testing(change: CheckpointChange): bool {
    match (change) { CheckpointChange::Unexpected => true, _ => false }
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN, AuthorityCap};

use blast_boosts_aftermath::{constants, ifixed_math};

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign and magnitude read as methods.
use fun ifixed::abs as u256.abs;
use fun ifixed::is_neg as u256.is_neg;

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{
    account::Account,
    authority::ACCOUNT,
    clearing_house::{ClearingHouse, SessionSummary},
    registry::Registry,
};

use sui::{clock::Clock, coin::Coin};
