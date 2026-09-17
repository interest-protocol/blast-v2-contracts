// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
#[allow(lint(abort_without_constant))]
/// Authenticated Aftermath/Pyth normalization and raw checkpoint comparison.
module blast_leverage_aftermath::snapshot;

/// Converts nine-decimal base atoms to six-decimal collateral atoms.
const COLLATERAL_TO_BASE_SCALE: u256 = 1_000;

// === Public Types ===

/// The only recognized raw transition between authenticated checkpoints.
public enum Change has drop {
    Unchanged,
    FundingCredit(u256),
    FundingCost(u256),
    Unexpected,
}

/// Normalized primitives needed by the enclosing adapter operation.
///
/// This value is operation-scoped and is never stored. It lets the caller use
/// the same authenticated capture for sizing, postconditions, and events.
public struct SnapshotFacts has copy, drop {
    venue_equity: u64,
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
    side: PositionSide,
    base_price: u64,
    collateral_price: u64,
}

/// One authenticated capture awaiting operation-specific finalization.
///
/// The value is linear so a caller must either consume a pre-settlement probe
/// or finalize a post-settlement health observation. Source authentication and
/// economic normalization therefore cannot be separated or replayed.
public struct CapturedSnapshot {
    venue_equity: u64,
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
    side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    economics_valid: bool,
    base_price: u64,
    base_confidence: u64,
    base_timestamp: u64,
    collateral_price: u64,
    collateral_confidence: u64,
    collateral_timestamp: u64,
    mark_price: u64,
    checkpoint: Checkpoint,
    collateral_fixed: u256,
}

// === Package Functions ===

/// Authenticates raw terminal state without requiring a live price or positive equity.
public(package) fun capture_checkpoint<Collateral>(
    binding: &Binding, account: &Account<Collateral>, registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>, base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
): Checkpoint {
    binding.assert_exact(object::id(account), account::account_id(account), object::id(registry),
        object::id(clearing_house), object::id(base_oracle), object::id(collateral_oracle),
        type_name::with_original_ids<Collateral>());
    read_checkpoint(account, clearing_house)
}

/// Captures one authenticated venue and Pyth valuation pair.
///
/// The two Pyth objects are exact sources for the corresponding Aftermath
/// feeds. The interface packages are ABI ports, so this production path is
/// mechanically pinned but never executed by local unit tests.
public(package) fun capture<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
): (observation::PositionObservation, Checkpoint) {
    let captured = capture_(
        binding,
        account,
        registry,
        clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
        false,
    );
    let (observation, checkpoint, _) = into_observation(captured);
    (observation, checkpoint)
}

/// Captures strict seed facts for atomic Vault initialization.
public(package) fun capture_initialization<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
): (observation::PositionObservation, Checkpoint, SnapshotFacts) {
    let captured = capture_(
        binding,
        account,
        registry,
        clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
        false,
    );
    into_observation(captured)
}

/// Captures authenticated live facts for fail-closed health reporting.
///
/// Authentication and source agreement remain strict; only structural venue
/// values are retained instead of aborting; ordinary sync never changes lifecycle.
public(package) fun capture_health<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
): CapturedSnapshot {
    capture_(
        binding,
        account,
        registry,
        clearing_house,
        base_oracle,
        collateral_oracle,
        base_price_info,
        collateral_price_info,
        clock,
        true,
    )
}

fun capture_<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
    health: bool,
): CapturedSnapshot {
    let checkpoint = capture_checkpoint(binding, account, registry, clearing_house, base_oracle, collateral_oracle);

    let params = clearing_house.market_params();
    let base_source_id = market::base_source_id(params);
    let collateral_source_id = market::collateral_source_id(params);
    assert!(
        price_feed_storage::storage_id(base_oracle) == market::base_storage_id(params),
        blast_leverage_aftermath::errors::oracle_storage_mismatch!(),
    );
    assert!(
        price_feed_storage::storage_id(collateral_oracle) == market::collateral_storage_id(params),
        blast_leverage_aftermath::errors::oracle_storage_mismatch!(),
    );

    let base_feed = &base_oracle[base_source_id];
    let collateral_feed = &collateral_oracle[collateral_source_id];
    assert!(
        price_feed::source_id(base_feed) == base_source_id
            && price_feed::source_id(collateral_feed) == collateral_source_id,
        blast_leverage_aftermath::errors::oracle_source_mismatch!(),
    );

    // Identity failures precede every named Aftermath price calculation.
    assert_pyth_price_info(base_price_info, base_feed);
    assert_pyth_price_info(collateral_price_info, collateral_feed);

    let base_fixed = market::base_oracle_price(params, base_oracle, clock);
    let collateral_fixed = market::collateral_oracle_price(params, collateral_oracle, clock);
    let mark_fixed = clearing_house.mark_price(base_oracle, clock);
    let (
        base_price,
        base_risk_price,
        base_confidence,
        base_timestamp,
        base_oracle_representable,
    ) = if (health) {
        pyth_price_health(base_price_info, base_feed, base_fixed)
    } else {
        let (price, risk_price, confidence, timestamp) = pyth_price(
            base_price_info,
            base_feed,
            base_fixed,
        );
        (price, risk_price, confidence, timestamp, true)
    };
    let (
        collateral_price,
        _collateral_risk_price,
        collateral_confidence,
        collateral_timestamp,
        collateral_oracle_representable,
    ) = if (health) {
        pyth_price_health(
            collateral_price_info,
            collateral_feed,
            collateral_fixed,
        )
    } else {
        let (price, risk_price, confidence, timestamp) = pyth_price(
            collateral_price_info,
            collateral_feed,
            collateral_fixed,
        );
        (price, risk_price, confidence, timestamp, true)
    };
    let (mark_price, mark_representable) = fixed_to_u64_down_health(mark_fixed, 9);
    if (!health) {
        assert!(mark_representable, blast_leverage_aftermath::errors::normalization_overflow!());
    };
    let position = clearing_house.position(account::account_id(account));
    let (signed_base, signed_quote_notional) = position::base_and_quote_amounts(position);
    let (position_base, base_representable) = fixed_to_u64_up_health(ifixed::abs(signed_base), 9);
    let (position_collateral, notional_representable) = base_notional_health(
        position_base,
        base_risk_price,
        collateral_price,
    );
    if (!health) {
        assert!(base_representable && notional_representable, blast_leverage_aftermath::errors::normalization_overflow!());
    };
    let side = if (health) {
        if (position.is_long_or_flat()) { policy::long() } else { policy::short() }
    } else {
        assert_position_signs(signed_base, signed_quote_notional, position.is_long_or_flat())
    };
    let allocated_collateral = position.collateral();
    let effective_imr = position::effective_initial_margin_ratio(position, market::margin_ratio_initial(params));
    let (margin, requirement) = position::compute_margin_and_requirement(position, collateral_fixed, mark_fixed, effective_imr, market::collateral_haircut(params));
    let pnl = position.unrealized_pnl(base_fixed);
    let (venue_equity, equity_representable) = signed_equity_health(
        account.collateral_balance(),
        allocated_collateral,
        pnl,
        collateral_fixed,
    );
    if (!health) {
        assert!(equity_representable, blast_leverage_aftermath::errors::normalization_overflow!());
    };
    let signs_coherent = position_signs_coherent(signed_base, signed_quote_notional, position.is_long_or_flat());
    let economics_valid = signs_coherent
        && base_oracle_representable
        && collateral_oracle_representable
        && base_representable
        && notional_representable
        && mark_representable
        && equity_representable;

    CapturedSnapshot {
        venue_equity,
        position_base,
        position_collateral,
        lot_size: market::lot_size(params),
        side,
        pending_order_count: position.pending_order_count(),
        margin_safe: margin_safe(margin, requirement),
        venue_operational: clearing_house.market_pause_mode() == 0
            && !clearing_house.is_frozen(),
        economics_valid,
        base_price,
        base_confidence,
        base_timestamp,
        collateral_price,
        collateral_confidence,
        collateral_timestamp,
        mark_price,
        checkpoint,
        collateral_fixed: if (collateral_oracle_representable) {
            collateral_fixed
        } else {
            0
        },
    }
}

/// Consumes a pre-settlement capture into the exact reconciliation inputs.
public(package) fun into_funding_probe(
    self: CapturedSnapshot,
): (Checkpoint, u256) {
    let CapturedSnapshot {
        checkpoint,
        collateral_fixed,
        ..
    } = self;

    (checkpoint, collateral_fixed)
}

/// Copies the post-settlement checkpoint before consuming the final capture.
public(package) fun checkpoint(self: &CapturedSnapshot): Checkpoint {
    self.checkpoint
}

/// Consumes the authenticated health capture after checkpoint classification.
public(package) fun finish_health(self: CapturedSnapshot): Checkpoint {
    let CapturedSnapshot { checkpoint, .. } = self;
    checkpoint
}

/// Builds the base oracle observation from the authenticated capture.
public(package) fun base_price_observation(self: &CapturedSnapshot): observation::PriceObservation {
    observation::new_price(self.base_price, self.base_confidence, self.base_timestamp)
}

/// Builds the collateral oracle observation from the authenticated capture.
public(package) fun collateral_price_observation(self: &CapturedSnapshot): observation::PriceObservation {
    observation::new_price(self.collateral_price, self.collateral_confidence, self.collateral_timestamp)
}

/// Returns the raw IFixed collateral reading behind the capture.
public(package) fun collateral_fixed(self: &CapturedSnapshot): u256 { self.collateral_fixed }

/// A terminal market close may realize losses, but cannot misattribute an unrelated funding mutation.
public(package) fun assert_clean_funding(change: Change) {
    assert!(match (change) { Change::Unexpected => false, _ => true },
        blast_leverage_aftermath::errors::unresolved_checkpoint!());
}

fun into_observation(
    self: CapturedSnapshot,
): (observation::PositionObservation, Checkpoint, SnapshotFacts) {
    let CapturedSnapshot {
        venue_equity,
        position_base,
        position_collateral,
        lot_size,
        side,
        pending_order_count,
        margin_safe,
        venue_operational,
        economics_valid,
        base_price,
        base_confidence,
        base_timestamp,
        collateral_price,
        collateral_confidence,
        collateral_timestamp,
        mark_price,
        checkpoint,
        collateral_fixed: _,
    } = self;
    let base_index = observation::new_price(base_price, base_confidence, base_timestamp);
    let collateral_index = observation::new_price(
        collateral_price,
        collateral_confidence,
        collateral_timestamp,
    );
    let observation = observation::new_position(
        venue_equity,
        position_base,
        position_collateral,
        lot_size,
        side,
        pending_order_count,
        economics_valid && margin_safe,
        venue_operational,
        true,
        base_index,
        collateral_index,
        mark_price,
    );

    (
        observation,
        checkpoint,
        SnapshotFacts {
            venue_equity,
            position_base,
            position_collateral,
            lot_size,
            side,
            base_price,
            collateral_price,
        },
    )
}

// --- Snapshot Facts Reads ---

public(package) fun venue_equity(self: &SnapshotFacts): u64 { self.venue_equity }

public(package) fun position_base(self: &SnapshotFacts): u64 { self.position_base }

public(package) fun position_collateral(self: &SnapshotFacts): u64 { self.position_collateral }

public(package) fun lot_size(self: &SnapshotFacts): u64 { self.lot_size }

public(package) fun side(self: &SnapshotFacts): PositionSide { self.side }

public(package) fun base_price(self: &SnapshotFacts): u64 { self.base_price }

public(package) fun collateral_price(self: &SnapshotFacts): u64 { self.collateral_price }

#[test_only]
/// Unpacks every fact, in declaration order, for test assertions.
public fun unpack_facts_for_testing(self: SnapshotFacts): (u64, u64, u64, u64, PositionSide, u64, u64) {
    (self.venue_equity, self.position_base, self.position_collateral, self.lot_size, self.side,
        self.base_price, self.collateral_price)
}

/// Classifies only an isolated funding-snapshot and allocated-collateral change.
public(package) fun classify_change(
    before: &Checkpoint,
    after: &Checkpoint,
    funding_candidate: u256,
    collateral_price: u256,
): Change {
    if (checkpoint_unchanged(before, after)) {
        return Change::Unchanged
    };
    let (candidate_collateral_magnitude, representable) =
        usd_fixed_to_collateral_fixed_health(
            ifixed::abs(funding_candidate),
            collateral_price,
            ifixed::is_neg(funding_candidate),
        );
    if (!representable) {
        return Change::Unexpected
    };

    classify_change_(
        before,
        after,
        ifixed::is_neg(funding_candidate),
        candidate_collateral_magnitude,
        allocated_delta(before, after),
    )
}

/// Returns true only when every stored raw checkpoint field is unchanged.
public(package) fun checkpoint_unchanged(
    before: &Checkpoint,
    after: &Checkpoint,
): bool {
    before == after
}

/// Returns true when only the market's cumulative funding rates advanced.
///
/// This is the ordinary pre-settlement shape: the position still carries the
/// stored funding snapshots while the market rates may have moved forward.
public(package) fun checkpoint_ready_for_settlement(
    stored: &Checkpoint,
    before: &Checkpoint,
): bool {
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
public(package) fun classify_preexisting_funding(
    stored: &Checkpoint,
    before: &Checkpoint,
): Change {
    classify_preexisting_funding_(
        stored,
        before,
        allocated_delta(stored, before),
    )
}

fun classify_preexisting_funding_(
    stored: &Checkpoint,
    before: &Checkpoint,
    allocated_change: Change,
): Change {
    let unrelated_unchanged = stored.non_funding_fields_equal(before);
    // The position snapshots prove the completed external settlement. They may
    // trail the market again if another funding epoch advanced before Blast
    // synchronized, so equality with the current market rates is not required.
    let snapshots_refreshed = stored.funding_snapshot_long() != before.funding_snapshot_long()
        || stored.funding_snapshot_short() != before.funding_snapshot_short();
    if (!unrelated_unchanged || !snapshots_refreshed) {
        return Change::Unexpected
    };
    allocated_change
}

/// Creates the dirty-checkpoint classification for adapter orchestration.
public(package) fun unexpected_change(): Change {
    Change::Unexpected
}

/// Creates the clean no-op classification for adapter orchestration.
public(package) fun unchanged_change(): Change {
    Change::Unchanged
}

// --- Change Reads ---

/// Returns whether the change is a representable funding credit or cost.
public(package) fun has_funding(self: &Change): bool {
    match (self) {
        Change::FundingCredit(raw) => { let (_, ok) = fixed_to_u64_down_health(*raw, 6); ok },
        Change::FundingCost(raw) => { let (_, ok) = fixed_to_u64_up_health(*raw, 6); ok },
        _ => false,
    }
}

/// Returns whether the change is a funding cost.
public(package) fun is_cost(self: &Change): bool {
    match (self) { Change::FundingCost(_) => true, _ => false }
}

/// Returns the raw IFixed funding magnitude; zero when there is no funding.
public(package) fun raw_amount(self: &Change): u256 {
    match (self) {
        Change::FundingCredit(raw) => *raw,
        Change::FundingCost(raw) => *raw,
        _ => 0,
    }
}

/// Returns the six-decimal funding amount, credits down and costs up; zero when unrepresentable.
public(package) fun amount(self: &Change): u64 {
    match (self) {
        Change::FundingCredit(raw) => { let (v, _) = fixed_to_u64_down_health(*raw, 6); v },
        Change::FundingCost(raw) => { let (v, _) = fixed_to_u64_up_health(*raw, 6); v },
        _ => 0,
    }
}

/// Returns whether the checkpoint is clean: unchanged, or a representable funding change.
public(package) fun is_clean(self: &Change): bool {
    match (self) {
        Change::Unchanged => true,
        Change::Unexpected => false,
        _ => self.has_funding(),
    }
}

#[test_only]
/// Returns `(has_funding, is_cost, raw_amount, amount, is_clean)` for test assertions.
public fun funding_change_fields(
    change: &Change,
): (bool, bool, u256, u64, bool) {
    match (change) {
        Change::Unchanged => (false, false, 0, 0, true),
        Change::Unexpected => (false, false, 0, 0, false),
        Change::FundingCredit(raw_amount) => {
            let (amount, representable) = fixed_to_u64_down_health(*raw_amount, 6);
            (representable, false, *raw_amount, amount, representable)
        },
        Change::FundingCost(raw_amount) => {
            let (amount, representable) = fixed_to_u64_up_health(*raw_amount, 6);
            (representable, true, *raw_amount, amount, representable)
        },
    }
}

/// Nets authenticated settlement edges before rounding or buffer allocation.
/// No gross ordering inside one Blast checkpoint is an entitlement boundary.
public(package) fun net_funding(first: Change, second: Change): Change {
    let (first_cost, a) = match (first) {
        Change::Unexpected => return Change::Unexpected,
        Change::Unchanged => (false, 0),
        Change::FundingCredit(amount) => (false, amount),
        Change::FundingCost(amount) => (true, amount),
    };
    let (second_cost, b) = match (second) {
        Change::Unexpected => return Change::Unexpected,
        Change::Unchanged => (false, 0),
        Change::FundingCredit(amount) => (false, amount),
        Change::FundingCost(amount) => (true, amount),
    };
    let (is_cost, amount) = if (first_cost == second_cost) {
        (first_cost, a.checked_add(b).destroy_or!(return Change::Unexpected))
    } else if (a >= b) {
        (first_cost, a - b)
    } else {
        (second_cost, b - a)
    };
    if (amount == 0) { Change::Unchanged }
    else if (is_cost) { Change::FundingCost(amount) }
    else { Change::FundingCredit(amount) }
}

fun classify_change_(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
    allocated_change: Change,
): Change {
    if (before == after) { return Change::Unchanged };
    if (!before.non_funding_fields_equal(after)
        || before.market_funding_long() != after.market_funding_long()
        || before.market_funding_short() != after.market_funding_short()) {
        return Change::Unexpected
    };
    let snapshots_refreshed = after.funding_snapshot_long() == before.market_funding_long()
        && after.funding_snapshot_short() == before.market_funding_short()
        && (before.funding_snapshot_long() != after.funding_snapshot_long()
            || before.funding_snapshot_short() != after.funding_snapshot_short());
    if (!snapshots_refreshed) { return Change::Unexpected };
    if (candidate_collateral_magnitude == 0 && before.allocated_collateral() == after.allocated_collateral()) {
        return Change::Unchanged
    };
    let matched = match (&allocated_change) {
        Change::FundingCredit(amount) => !candidate_negative && *amount == candidate_collateral_magnitude,
        Change::FundingCost(amount) => candidate_negative && *amount == candidate_collateral_magnitude,
        Change::Unchanged => candidate_collateral_magnitude == 0,
        Change::Unexpected => false,
    };
    if (matched) { allocated_change } else { Change::Unexpected }
}

// === Private Functions ===

/// Reads the one canonical raw position/account field inventory after source authentication.
fun read_checkpoint<Collateral>(account: &Account<Collateral>, clearing_house: &ClearingHouse<Collateral>): Checkpoint {
    let params = clearing_house.market_params();
    let position = clearing_house.position(account::account_id(account));
    let (base, quote) = position::base_and_quote_amounts(position);
    let (snapshot_long, snapshot_short) = position.funding_rate_snapshots();
    let (market_long, market_short) = market::cum_funding_rates(clearing_house.market_state());
    let (ask, bid) = position.pending_base_amounts_by_side();
    venue_account::new_checkpoint(account.collateral_balance(), position.collateral(), base, quote,
        snapshot_long, snapshot_short, market_long, market_short, market::lot_size(params), ask, bid,
        position.pending_order_count(), clearing_house.market_pause_mode(), clearing_house.is_frozen(),
        position.initial_margin_ratio(), market::margin_ratio_initial(params), market::margin_ratio_maintenance(params))
}

/// Named IFixed operations decode signed collateral; raw checkpoint bits are never ordered.
fun allocated_delta(before: &Checkpoint, after: &Checkpoint): Change {
    let b = before.allocated_collateral();
    let a = after.allocated_collateral();
    signed_delta(ifixed::is_neg(b), ifixed::abs(b), ifixed::is_neg(a), ifixed::abs(a))
}

/// Computes after-minus-before in sign/magnitude facts, including a zero crossing.
fun signed_delta(before_negative: bool, before: u256, after_negative: bool, after: u256): Change {
    if (before_negative == after_negative) {
        if (before == after) { return Change::Unchanged };
        let credit = if (before_negative) { before > after } else { after > before };
        let amount = before.diff(after);
        if (credit) { Change::FundingCredit(amount) } else { Change::FundingCost(amount) }
    } else {
        if (before > std::u256::max_value!() - after) { return Change::Unexpected };
        let amount = before + after;
        if (amount == 0) { Change::Unchanged }
        else if (after_negative) { Change::FundingCost(amount) }
        else { Change::FundingCredit(amount) }
    }
}

fun pyth_price(
    price_info_object: &PriceInfoObject,
    aftermath_feed: &price_feed::PriceFeed,
    venue_price: u256,
): (u64, u64, u64, u64) {
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let pyth_price = pyth_price_feed::get_price(price_info::get_price_feed(&price_info));
    let price_i64 = price::get_price(&pyth_price);
    assert!(
        !i64::get_is_negative(&price_i64),
        blast_leverage_aftermath::errors::invalid_pyth_price!(),
    );
    let expo = price::get_expo(&pyth_price);
    let normalized_price = normalize_pyth_component(i64::get_magnitude_if_positive(&price_i64), &expo, false);
    let normalized_risk_price = normalize_pyth_component(i64::get_magnitude_if_positive(&price_i64), &expo, true);
    let normalized_confidence = normalize_pyth_component(price::get_conf(&pyth_price), &expo, true);
    let (aftermath_price, aftermath_timestamp) = price_feed::price_and_timestamp_ms(aftermath_feed);
    assert!(
        normalize_feed_price(aftermath_price) == normalized_price
            && fixed_to_u64_down_9(venue_price) == normalized_price
            && aftermath_timestamp == checked_seconds_to_millis(price::get_timestamp(&pyth_price)),
        blast_leverage_aftermath::errors::oracle_observation_mismatch!(),
    );

    (
        normalized_price,
        normalized_risk_price,
        normalized_confidence,
        aftermath_timestamp,
    )
}

/// Normalizes authenticated oracle values without aborting on representation.
/// A representable disagreement is still an authentication failure and aborts;
/// only width, exponent, sign, or timestamp-domain failures become invalid
/// economic facts for permissionless health reporting.
fun pyth_price_health(
    price_info_object: &PriceInfoObject,
    aftermath_feed: &price_feed::PriceFeed,
    venue_price: u256,
): (u64, u64, u64, u64, bool) {
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let pyth_price = pyth_price_feed::get_price(price_info::get_price_feed(&price_info));
    let price_i64 = price::get_price(&pyth_price);
    let price_nonnegative = !i64::get_is_negative(&price_i64);
    let price_magnitude = if (price_nonnegative) {
        i64::get_magnitude_if_positive(&price_i64)
    } else {
        0
    };
    let expo = price::get_expo(&pyth_price);
    let (normalized_price, price_representable) = normalize_pyth_component_health(
        price_magnitude,
        &expo,
        false,
    );
    let (normalized_risk_price, risk_price_representable) =
        normalize_pyth_component_health(price_magnitude, &expo, true);
    let (normalized_confidence, confidence_representable) =
        normalize_pyth_component_health(price::get_conf(&pyth_price), &expo, true);
    let (aftermath_price, aftermath_timestamp) =
        price_feed::price_and_timestamp_ms(aftermath_feed);
    let (normalized_feed_price, feed_representable) =
        normalize_feed_price_health(aftermath_price);
    let (normalized_venue_price, venue_representable) =
        fixed_to_u64_down_health(venue_price, 9);
    let (pyth_timestamp, timestamp_representable) =
        checked_seconds_to_millis_health(price::get_timestamp(&pyth_price));
    let representable = price_nonnegative
        && price_representable
        && risk_price_representable
        && confidence_representable
        && feed_representable
        && venue_representable
        && timestamp_representable;
    if (!representable) {
        return (0, 0, 0, 0, false)
    };
    assert!(
        normalized_feed_price == normalized_price
            && normalized_venue_price == normalized_price
            && aftermath_timestamp == pyth_timestamp,
        blast_leverage_aftermath::errors::oracle_observation_mismatch!(),
    );

    (
        normalized_price,
        normalized_risk_price,
        normalized_confidence,
        aftermath_timestamp,
        true,
    )
}

fun assert_pyth_price_info(price_info_object: &PriceInfoObject, aftermath_feed: &price_feed::PriceFeed) {
    assert!(
        price_info::uid_to_inner(price_info_object) == price_feed::from(aftermath_feed),
        blast_leverage_aftermath::errors::pyth_price_info_mismatch!(),
    );
}

/// Aftermath feeds at the bound source use the adapter's 9-decimal price unit.
fun normalize_feed_price(raw_price: u128): u64 {
    let (normalized, representable) = normalize_feed_price_health(raw_price);
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    normalized
}

fun normalize_feed_price_health(raw_price: u128): (u64, bool) {
    if (raw_price > std::u64::max_value!() as u128) {
        (0, false)
    } else {
        (raw_price as u64, true)
    }
}

fun normalize_pyth_component(component: u64, expo: &i64::I64, round_up: bool): u64 {
    let expo_negative = i64::get_is_negative(expo);
    let magnitude = if (expo_negative) {
        i64::get_magnitude_if_negative(expo)
    } else {
        i64::get_magnitude_if_positive(expo)
    };
    normalize_pyth_component_parts(component, expo_negative, magnitude, round_up)
}

fun normalize_pyth_component_parts(component: u64, expo_negative: bool, magnitude: u64, round_up: bool): u64 {
    let (normalized, representable) = normalize_pyth_component_parts_health(
        component,
        expo_negative,
        magnitude,
        round_up,
    );
    assert!(representable, blast_leverage_aftermath::errors::pyth_normalization_overflow!());
    normalized
}

fun normalize_pyth_component_health(
    component: u64,
    expo: &i64::I64,
    round_up: bool,
): (u64, bool) {
    let expo_negative = i64::get_is_negative(expo);
    let magnitude = if (expo_negative) {
        i64::get_magnitude_if_negative(expo)
    } else {
        i64::get_magnitude_if_positive(expo)
    };
    normalize_pyth_component_parts_health(
        component,
        expo_negative,
        magnitude,
        round_up,
    )
}

fun normalize_pyth_component_parts_health(
    component: u64,
    expo_negative: bool,
    magnitude: u64,
    round_up: bool,
): (u64, bool) {
    if (magnitude > 18) { return (0, false) };
    let raw = component as u256;
    let normalized = if (expo_negative) {
        if (magnitude <= 9) {
            checked_mul(raw, pow10(9 - magnitude))
        } else {
            let scale = pow10(magnitude - 9);
            let down = raw / scale;
            if (round_up && raw % scale != 0) { down + 1 } else { down }
        }
    } else {
        checked_mul(raw, pow10(9 + magnitude))
    };
    if (normalized > std::u64::max_value!() as u256) {
        (0, false)
    } else {
        (normalized as u64, true)
    }
}

fun checked_seconds_to_millis(seconds: u64): u64 {
    let (milliseconds, representable) = checked_seconds_to_millis_health(seconds);
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    milliseconds
}

fun checked_seconds_to_millis_health(seconds: u64): (u64, bool) {
    if (seconds > std::u64::max_value!() / 1_000) {
        (0, false)
    } else {
        (seconds * 1_000, true)
    }
}

fun checked_mul(value: u256, factor: u256): u256 {
    assert!(
        value == 0 || value <= (std::u256::max_value!() / factor),
        blast_leverage_aftermath::errors::normalization_overflow!(),
    );
    value * factor
}

fun pow10(exponent: u64): u256 {
    let mut result = 1;
    let mut remaining = exponent;
    while (remaining > 0) {
        result = result * 10;
        remaining = remaining - 1;
    };
    result
}

fun fixed_to_u64_down_9(value: u256): u64 {
    fixed_to_u64_down(value, 9)
}

fun fixed_to_u64_down(value: u256, decimals: u64): u64 {
    let (normalized, representable) = fixed_to_u64_down_health(value, decimals);
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    normalized
}

fun fixed_to_u64_down_health(value: u256, decimals: u64): (u64, bool) {
    let normalized = value / pow10(18 - decimals);
    if (normalized > std::u64::max_value!() as u256) { (0, false) } else { (normalized as u64, true) }
}

fun fixed_to_u64_up_health(value: u256, decimals: u64): (u64, bool) {
    let scale = pow10(18 - decimals);
    let down = value / scale;
    if (down > std::u64::max_value!() as u256 || (value % scale != 0 && down == std::u64::max_value!() as u256)) {
        (0, false)
    } else if (value % scale == 0) { (down as u64, true) } else { ((down + 1) as u64, true) }
}

// The strict variant remains a test-pinned aborting contract for risk-increasing
// paths; Task 7 production reconciliation uses the non-aborting health variant.
#[allow(unused_function)]
fun usd_fixed_to_collateral_fixed(usd: u256, collateral_price: u256, round_up: bool): u256 {
    assert!(collateral_price > 0, blast_leverage_aftermath::errors::normalization_overflow!());
    let whole = usd / collateral_price;
    let remainder = usd % collateral_price;
    assert!(whole <= std::u256::max_value!() / pow10(18), blast_leverage_aftermath::errors::normalization_overflow!());
    assert!(remainder == 0 || remainder <= std::u256::max_value!() / pow10(18), blast_leverage_aftermath::errors::normalization_overflow!());
    let whole_scaled = whole * pow10(18);
    let fraction = remainder * pow10(18) / collateral_price;
    assert!(whole_scaled <= std::u256::max_value!() - fraction, blast_leverage_aftermath::errors::normalization_overflow!());
    let down = whole_scaled + fraction;
    if (round_up && remainder * pow10(18) % collateral_price != 0) {
        assert!(down < std::u256::max_value!(), blast_leverage_aftermath::errors::normalization_overflow!());
        down + 1
    } else { down }
}

/// Values current position risk as absolute base × Pyth index ÷ collateral.
///
/// The quote amount remains in the raw checkpoint for transition guards and
/// direction coherence, but it is historical cost basis and therefore cannot
/// be the live leverage numerator.
fun base_notional_health(
    position_base: u64,
    base_price: u64,
    collateral_price: u64,
): (u64, bool) {
    if (collateral_price == 0) { return (0, false) };
    let numerator = (position_base as u256) * (base_price as u256);
    let denominator = (collateral_price as u256) * COLLATERAL_TO_BASE_SCALE;
    let notional = numerator.div_ceil(denominator);
    if (notional > std::u64::max_value!() as u256) {
        (0, false)
    } else {
        (notional as u64, true)
    }
}

fun signed_equity_health(free: u64, allocated: u256, pnl_usd: u256, collateral_price: u256): (u64, bool) {
    signed_equity_health_from_parts(
        free,
        ifixed::is_neg(allocated),
        ifixed::abs(allocated),
        ifixed::is_neg(pnl_usd),
        ifixed::abs(pnl_usd),
        collateral_price,
    )
}

fun signed_equity_health_from_parts(
    free: u64,
    allocated_negative: bool,
    allocated: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    if (collateral_price == 0) { return (0, false) };
    let (allocated_tokens, allocated_ok) = if (allocated_negative) {
        fixed_to_u64_up_health(allocated, 6)
    } else {
        fixed_to_u64_down_health(allocated, 6)
    };
    let (pnl, collateral_ok) = usd_fixed_to_collateral_fixed_health(
        pnl_magnitude_usd,
        collateral_price,
        pnl_negative,
    );
    let (rounded, pnl_ok) = if (pnl_negative) {
        fixed_to_u64_up_health(pnl, 6)
    } else {
        fixed_to_u64_down_health(pnl, 6)
    };
    if (!allocated_ok || !collateral_ok || !pnl_ok) { return (0, false) };
    let assets = (free as u128)
        + (if (allocated_negative) { 0 } else { allocated_tokens } as u128)
        + (if (pnl_negative) { 0 } else { rounded } as u128);
    let liabilities = (if (allocated_negative) { allocated_tokens } else { 0 } as u128)
        + (if (pnl_negative) { rounded } else { 0 } as u128);
    if (assets < liabilities) { return (0, false) };
    let net = assets - liabilities;
    if (net > std::u64::max_value!() as u128) { (0, false) } else { (net as u64, true) }
}

fun usd_fixed_to_collateral_fixed_health(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    if (collateral_price == 0) { return (0, false) };
    let scalar = pow10(18);
    let whole = usd / collateral_price;
    let remainder = usd % collateral_price;
    if (whole > std::u256::max_value!() / scalar || (remainder != 0 && remainder > std::u256::max_value!() / scalar)) { return (0, false) };
    let fractional_scaled = remainder * scalar;
    let whole_scaled = whole * scalar;
    let fraction = fractional_scaled / collateral_price;
    if (whole_scaled > std::u256::max_value!() - fraction) { return (0, false) };
    let down = whole_scaled + fraction;
    if (round_up && fractional_scaled % collateral_price != 0) {
        if (down == std::u256::max_value!()) { (0, false) } else { (down + 1, true) }
    } else { (down, true) }
}

fun margin_safe(margin: u256, requirement: u256): bool {
    margin_safe_from_parts(ifixed::is_neg(margin), margin, requirement)
}

fun margin_safe_from_parts(margin_negative: bool, margin: u256, requirement: u256): bool {
    !margin_negative && margin >= requirement
}

fun position_signs_coherent(base: u256, quote: u256, long_or_flat: bool): bool {
    let base_negative = ifixed::is_neg(base);
    let quote_negative = ifixed::is_neg(quote);
    let base_zero = ifixed::abs(base) == 0;
    let quote_zero = ifixed::abs(quote) == 0;
    position_signs_coherent_from_parts(base_negative, quote_negative, base_zero, quote_zero, long_or_flat)
}

fun position_signs_coherent_from_parts(base_negative: bool, quote_negative: bool, base_zero: bool, quote_zero: bool, long_or_flat: bool): bool {
    if (base_zero || quote_zero) {
        return base_zero && quote_zero
    };
    if (long_or_flat) {
        !base_negative && quote_negative
    } else {
        base_negative && !quote_negative
    }
}

fun assert_position_signs(base: u256, quote: u256, long_or_flat: bool): PositionSide {
    assert!(position_signs_coherent(base, quote, long_or_flat), blast_leverage_aftermath::errors::incoherent_position_signs!());
    if (long_or_flat) { policy::long() } else { policy::short() }
}

// === Test-Only Functions ===

/// Builds a normalized authenticated post-capture fixture around a real raw
/// checkpoint. Tests vary only equity and margin; all other objective facts
/// are the standard healthy 2x long fixture used by connected Vault tests.
#[test_only]
public fun captured_health_for_testing(
    checkpoint: Checkpoint,
    venue_equity: u64,
    margin_safe: bool,
): CapturedSnapshot {
    CapturedSnapshot {
        venue_equity,
        position_base: 1_800,
        position_collateral: 1_800,
        lot_size: 1,
        side: policy::long(),
        pending_order_count: 0,
        margin_safe,
        venue_operational: true,
        economics_valid: true,
        base_price: 1_000_000_000,
        base_confidence: 0,
        base_timestamp: 1_000,
        collateral_price: 1_000_000_000,
        collateral_confidence: 0,
        collateral_timestamp: 1_000,
        mark_price: 1_000_000_000,
        checkpoint,
        collateral_fixed: 1_000_000_000_000_000_000,
    }
}

#[test_only]
public fun classify_change_for_testing(before: &Checkpoint, after: &Checkpoint): Change {
    classify_change_with_candidate_for_testing(before, after, false, 0)
}

#[test_only]
public fun classify_change_with_candidate_for_testing(
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_magnitude: u256,
): Change {
    let delta = signed_delta(false, before.allocated_collateral(), false, after.allocated_collateral());
    classify_change_(before, after, candidate_negative, candidate_magnitude, delta)
}

#[test_only]
public fun classify_preexisting_funding_for_testing(
    stored: &Checkpoint,
    before: &Checkpoint,
): Change {
    let delta = signed_delta(false, stored.allocated_collateral(), false, before.allocated_collateral());
    classify_preexisting_funding_(stored, before, delta)
}

#[test_only]
public fun classify_signed_funding_for_testing(
    stored: &Checkpoint, before: &Checkpoint, stored_negative: bool, stored_magnitude: u256,
    before_negative: bool, before_magnitude: u256,
): Change {
    classify_preexisting_funding_(stored, before, signed_delta(stored_negative, stored_magnitude, before_negative, before_magnitude))
}

#[test_only]
public fun is_unchanged_for_testing(change: Change): bool {
    match (change) { Change::Unchanged => true, _ => false }
}

#[test_only]
public fun is_credit_for_testing(change: Change): bool {
    match (change) { Change::FundingCredit(_) => true, _ => false }
}

#[test_only]
public fun is_cost_for_testing(change: Change): bool {
    match (change) { Change::FundingCost(_) => true, _ => false }
}

#[test_only]
public fun funding_amount_for_testing(change: Change): u256 {
    match (change) {
        Change::FundingCredit(amount) => amount,
        Change::FundingCost(amount) => amount,
        _ => 0,
    }
}

#[test_only]
public fun is_unexpected_for_testing(change: Change): bool {
    match (change) { Change::Unexpected => true, _ => false }
}

#[test_only]
public fun normalize_raw_fixed_for_testing(value: u256, decimals: u64, round_up: bool): u64 {
    let (normalized, representable) = if (round_up) {
        fixed_to_u64_up_health(value, decimals)
    } else {
        fixed_to_u64_down_health(value, decimals)
    };
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    normalized
}

#[test_only]
public fun normalize_pyth_for_testing(component: u64, expo_negative: bool, expo_magnitude: u64, round_up: bool): u64 {
    normalize_pyth_component_parts(component, expo_negative, expo_magnitude, round_up)
}

#[test_only]
public fun normalize_pyth_health_for_testing(
    component: u64,
    expo_negative: bool,
    expo_magnitude: u64,
    round_up: bool,
): (u64, bool) {
    normalize_pyth_component_parts_health(
        component,
        expo_negative,
        expo_magnitude,
        round_up,
    )
}

#[test_only]
public fun normalize_feed_health_for_testing(raw_price: u128): (u64, bool) {
    normalize_feed_price_health(raw_price)
}

#[test_only]
public fun usd_fixed_to_collateral_for_testing(usd: u256, collateral_price: u256, round_up: bool): u256 {
    usd_fixed_to_collateral_fixed(usd, collateral_price, round_up)
}

#[test_only]
public fun usd_fixed_to_collateral_health_for_testing(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    usd_fixed_to_collateral_fixed_health(usd, collateral_price, round_up)
}

#[test_only]
public fun base_notional_health_for_testing(
    position_base: u64,
    base_price: u64,
    collateral_price: u64,
): (u64, bool) {
    base_notional_health(position_base, base_price, collateral_price)
}

#[test_only]
public fun base_notional_from_pyth_for_testing(
    position_base: u64,
    price_component: u64,
    expo_negative: bool,
    expo_magnitude: u64,
    collateral_price: u64,
): (u64, bool) {
    let (base_risk_price, price_representable) =
        normalize_pyth_component_parts_health(
            price_component,
            expo_negative,
            expo_magnitude,
            true,
        );
    if (!price_representable) {
        (0, false)
    } else {
        base_notional_health(
            position_base,
            base_risk_price,
            collateral_price,
        )
    }
}

#[test_only]
public fun margin_safe_for_testing(margin_negative: bool, margin: u256, requirement: u256): bool { margin_safe_from_parts(margin_negative, margin, requirement) }

#[test_only]
public fun position_signs_coherent_for_testing(base_negative: bool, quote_negative: bool, base_zero: bool, quote_zero: bool, long_or_flat: bool): bool {
    position_signs_coherent_from_parts(base_negative, quote_negative, base_zero, quote_zero, long_or_flat)
}

#[test_only]
public fun seconds_to_millis_for_testing(seconds: u64): u64 {
    checked_seconds_to_millis(seconds)
}

#[test_only]
public fun seconds_to_millis_health_for_testing(seconds: u64): (u64, bool) {
    checked_seconds_to_millis_health(seconds)
}

#[test_only]
public fun facts_for_testing(
    venue_equity: u64,
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
    side: PositionSide,
    base_price: u64,
    collateral_price: u64,
): SnapshotFacts {
    SnapshotFacts {
        venue_equity,
        position_base,
        position_collateral,
        lot_size,
        side,
        base_price,
        collateral_price,
    }
}

#[test_only]
public fun normalize_mark_health_for_testing(value: u256): (u64, bool) {
    fixed_to_u64_down_health(value, 9)
}

#[test_only]
public fun normalize_mark_strict_for_testing(value: u256): u64 {
    fixed_to_u64_down(value, 9)
}

#[test_only]
public fun signed_equity_health_for_testing(
    free: u64,
    allocated_negative: bool,
    allocated: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    signed_equity_health_from_parts(
        free,
        allocated_negative,
        allocated,
        pnl_negative,
        pnl_magnitude_usd,
        collateral_price,
    )
}

#[test_only]
public fun signed_equity_strict_for_testing(
    free: u64,
    allocated_negative: bool,
    allocated: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): u64 {
    let (equity, representable) = signed_equity_health_from_parts(
        free,
        allocated_negative,
        allocated,
        pnl_negative,
        pnl_magnitude_usd,
        collateral_price,
    );
    assert!(representable, blast_leverage_aftermath::errors::normalization_overflow!());
    equity
}

// === Imports ===

use blast_leverage_aftermath::venue_account::{Self as venue_account, Binding, Checkpoint};

use blast_leverage_core::{observation, policy::{Self, PositionSide}};

use ifixed::ifixed;

use oracle_aggregator::{price_feed, price_feed_storage::{Self, PriceFeedStorage}};

use perpetuals::{
    account::{Self, Account},
    clearing_house::{Self, ClearingHouse},
    market,
    registry::Registry,
};

use position::position;

use pyth::{i64, price, price_feed as pyth_price_feed, price_info::{Self, PriceInfoObject}};

use sui::clock::Clock;

use std::type_name;
