// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
#[allow(lint(abort_without_constant))]
/// Authenticated Aftermath/Pyth normalization and raw checkpoint comparison.
module blast_boosts_aftermath::snapshot;

// The `*_decoded` helpers take a value's sign and magnitude already decoded
// from IFixed. They exist because the pinned `ifixed` port aborts under test,
// so the pure arithmetic can be exercised from fixtures; production callers
// always go through the decoding wrapper above each one.

// === Public Types ===

/// One authenticated capture awaiting operation-specific finalization.
///
/// The value is linear so a caller must either consume a pre-settlement probe
/// or finalize a post-settlement health observation. Source authentication and
/// economic normalization therefore cannot be separated or replayed.
public struct CapturedSnapshot {
    venue_equity: u64,
    position_base: u64,
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

/// One normalized oracle leg of a capture.
///
/// `representable` is false only in a health capture whose values could not
/// be normalized; a strict capture aborts instead.
public struct OracleLeg has copy, drop {
    price: u64,
    confidence: u64,
    timestamp: u64,
    representable: bool,
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

// --- Capture ---

/// Authenticates raw terminal state without requiring a live price or positive equity.
public(package) fun capture_checkpoint<Collateral>(
    binding: &Binding, account: &Account<Collateral>, registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
): Checkpoint {
    binding.assert_object_graph(
        object::id(account), account.account_id(), object::id(registry),
        object::id(clearing_house), object::id(base_oracle), object::id(collateral_oracle),
        type_name::with_original_ids<Collateral>(),
    );

    read_checkpoint(account, clearing_house)
}

/// Captures one authenticated venue and Pyth valuation pair.
///
/// Source identity and source agreement are strict and abort. Values that do
/// not fit the adapter's units, and a venue that cannot serve a priced
/// operation, are carried as facts: `into_observation` refuses them for a
/// priced operation, health synchronization reports them. The two Pyth
/// objects are exact sources for the corresponding Aftermath feeds. The
/// interface packages are ABI ports, so this production path is mechanically
/// pinned but never executed by local unit tests.
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
): CapturedSnapshot {
    let checkpoint = capture_checkpoint(binding, account, registry, clearing_house, base_oracle, collateral_oracle);
    let params = clearing_house.market_params();
    let (base_feed, collateral_feed) = authenticated_feeds(
        params, base_oracle, collateral_oracle, base_price_info, collateral_price_info,
    );

    let base_fixed = params.base_oracle_price(base_oracle, clock);
    let collateral_fixed = params.collateral_oracle_price(collateral_oracle, clock);
    let mark_fixed = clearing_house.mark_price(base_oracle, clock);
    let base = oracle_leg(base_price_info, base_feed, base_fixed);
    let collateral = oracle_leg(collateral_price_info, collateral_feed, collateral_fixed);
    let (mark_price, mark_representable) = fixed_to_u64_down(mark_fixed, 9);

    let position = clearing_house.position(account.account_id());
    let (signed_base, signed_quote_notional) = position.base_and_quote_amounts();
    let (position_base, base_representable) = fixed_to_u64_up(signed_base.abs(), 9);
    let effective_imr = position.effective_initial_margin_ratio(params.margin_ratio_initial());
    let (margin, requirement) = position.compute_margin_and_requirement(
        collateral_fixed, mark_fixed, effective_imr, params.collateral_haircut(),
    );
    let (venue_equity, equity_representable) = signed_equity(
        account.collateral_balance(), position.collateral(), position.unrealized_pnl(base_fixed), collateral_fixed,
    );
    let economics_valid = position_signs_coherent(signed_base, signed_quote_notional, position.is_long_or_flat())
        && base.representable
        && collateral.representable
        && base_representable
        && mark_representable
        && equity_representable;

    CapturedSnapshot {
        venue_equity,
        position_base,
        lot_size: params.lot_size(),
        side: if (position.is_long_or_flat()) { policy::long() } else { policy::short() },
        pending_order_count: position.pending_order_count(),
        margin_safe: margin_safe(margin, requirement),
        venue_operational: clearing_house.market_pause_mode() == 0 && !clearing_house.is_frozen(),
        economics_valid,
        base_price: base.price,
        base_confidence: base.confidence,
        base_timestamp: base.timestamp,
        collateral_price: collateral.price,
        collateral_confidence: collateral.confidence,
        collateral_timestamp: collateral.timestamp,
        mark_price,
        checkpoint,
        collateral_fixed: if (collateral.representable) { collateral_fixed } else { 0 },
    }
}

// --- Captured Snapshot Reads ---

/// Turns a capture into the core's observation and the checkpoint it was read
/// with, refusing a venue no priced operation may build on: unrepresentable
/// economics, open orders, unsafe margin, or a paused or frozen market.
public(package) fun into_observation(self: CapturedSnapshot): (PositionObservation, Checkpoint) {
    let CapturedSnapshot {
        venue_equity, position_base, lot_size, side, pending_order_count, margin_safe, venue_operational,
        economics_valid, base_price, base_confidence, base_timestamp, collateral_price, collateral_confidence,
        collateral_timestamp, mark_price, checkpoint, collateral_fixed: _,
    } = self;
    assert!(economics_valid, blast_boosts_aftermath::errors::normalization_overflow!());
    assert!(
        pending_order_count == 0 && margin_safe && venue_operational,
        blast_boosts_aftermath::errors::venue_not_ready!(),
    );

    let observation = observation::new_position(
        venue_equity,
        position_base,
        lot_size,
        side,
        observation::new_price(base_price, base_confidence, base_timestamp),
        observation::new_price(collateral_price, collateral_confidence, collateral_timestamp),
        mark_price,
    );

    (observation, checkpoint)
}

/// Consumes a pre-settlement capture into the exact reconciliation inputs.
public(package) fun funding_probe(self: CapturedSnapshot): (Checkpoint, u256) {
    let CapturedSnapshot { checkpoint, collateral_fixed, .. } = self;

    (checkpoint, collateral_fixed)
}

/// Consumes the authenticated health capture after checkpoint classification.
public(package) fun into_checkpoint(self: CapturedSnapshot): Checkpoint {
    let CapturedSnapshot { checkpoint, .. } = self;
    checkpoint
}

/// Copies the post-settlement checkpoint before consuming the final capture.
public(package) fun checkpoint(self: &CapturedSnapshot): Checkpoint {
    self.checkpoint
}

/// Builds the base oracle observation from the authenticated capture.
public(package) fun base_price_observation(self: &CapturedSnapshot): PriceObservation {
    observation::new_price(self.base_price, self.base_confidence, self.base_timestamp)
}

/// Builds the collateral oracle observation from the authenticated capture.
public(package) fun collateral_price_observation(self: &CapturedSnapshot): PriceObservation {
    observation::new_price(self.collateral_price, self.collateral_confidence, self.collateral_timestamp)
}

/// Returns the raw IFixed collateral reading behind the capture.
public(package) fun collateral_fixed(self: &CapturedSnapshot): u256 { self.collateral_fixed }

// --- CheckpointChange Classification ---

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
    if (checkpoint_unchanged(before, after)) return CheckpointChange::Unchanged;

    let (candidate_collateral_magnitude, representable) = usd_fixed_to_collateral_fixed(
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
public(package) fun net_funding(first: CheckpointChange, second: CheckpointChange): CheckpointChange {
    if (first.is_unexpected() || second.is_unexpected()) return CheckpointChange::Unexpected;

    let (first_cost, first_amount) = (first.is_cost(), first.raw_amount());
    let (second_cost, second_amount) = (second.is_cost(), second.raw_amount());
    let (is_cost, amount) = if (first_cost == second_cost) {
        (first_cost, first_amount.checked_add(second_amount).destroy_or!(return CheckpointChange::Unexpected))
    } else if (first_amount >= second_amount) {
        (first_cost, first_amount - second_amount)
    } else {
        (second_cost, second_amount - first_amount)
    };

    if (amount == 0) {
        CheckpointChange::Unchanged
    } else if (is_cost) {
        CheckpointChange::FundingCost(amount)
    } else {
        CheckpointChange::FundingCredit(amount)
    }
}

/// Creates the clean no-op classification for adapter orchestration.
public(package) fun unchanged_change(): CheckpointChange {
    CheckpointChange::Unchanged
}

/// A terminal market close may realize losses, but cannot misattribute an unrelated funding mutation.
public(package) fun assert_expected(self: CheckpointChange) {
    assert!(!self.is_unexpected(), blast_boosts_aftermath::errors::unresolved_checkpoint!());
}

// --- CheckpointChange Reads ---

/// Returns whether the change is a representable funding credit or cost.
public(package) fun has_funding(self: &CheckpointChange): bool {
    match (self) {
        CheckpointChange::FundingCredit(raw) => { let (_, ok) = fixed_to_u64_down(*raw, constants::collateral_decimals!() as u64); ok },
        CheckpointChange::FundingCost(raw) => { let (_, ok) = fixed_to_u64_up(*raw, constants::collateral_decimals!() as u64); ok },
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
        CheckpointChange::FundingCredit(raw) => { let (amount, _) = fixed_to_u64_down(*raw, constants::collateral_decimals!() as u64); amount },
        CheckpointChange::FundingCost(raw) => { let (amount, _) = fixed_to_u64_up(*raw, constants::collateral_decimals!() as u64); amount },
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

public(package) fun is_unexpected(self: &CheckpointChange): bool {
    match (self) { CheckpointChange::Unexpected => true, _ => false }
}

// === Private Functions ===

// --- Capture ---

/// Reads every raw venue field the checkpoint authenticates, in one pass and without normalization.
fun read_checkpoint<Collateral>(account: &Account<Collateral>, clearing_house: &ClearingHouse<Collateral>): Checkpoint {
    let params = clearing_house.market_params();
    let position = clearing_house.position(account.account_id());
    let (base, quote) = position.base_and_quote_amounts();
    let (snapshot_long, snapshot_short) = position.funding_rate_snapshots();
    let (market_long, market_short) = clearing_house.market_state().cum_funding_rates();
    let (ask, bid) = position.pending_base_amounts_by_side();

    venue_account::new_checkpoint(
        account.collateral_balance(), position.collateral(), base, quote,
        snapshot_long, snapshot_short, market_long, market_short, params.lot_size(), ask, bid,
        position.pending_order_count(), clearing_house.market_pause_mode(), clearing_house.is_frozen(),
        position.initial_margin_ratio(), params.margin_ratio_initial(), params.margin_ratio_maintenance(),
    )
}

/// Proves both oracle storages and both feeds are the ones the bound market
/// prices with, then returns the feeds. Identity failures abort before any
/// named Aftermath price calculation runs, in health captures too.
fun authenticated_feeds(
    params: &MarketParams,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
): (&PriceFeed, &PriceFeed) {
    assert!(
        base_oracle.storage_id() == params.base_storage_id()
            && collateral_oracle.storage_id() == params.collateral_storage_id(),
        blast_boosts_aftermath::errors::oracle_storage_mismatch!(),
    );

    let base_source_id = params.base_source_id();
    let collateral_source_id = params.collateral_source_id();
    let base_feed = &base_oracle[base_source_id];
    let collateral_feed = &collateral_oracle[collateral_source_id];
    assert!(
        base_feed.source_id() == base_source_id
            && collateral_feed.source_id() == collateral_source_id,
        blast_boosts_aftermath::errors::oracle_source_mismatch!(),
    );
    assert_pyth_price_info(base_price_info, base_feed);
    assert_pyth_price_info(collateral_price_info, collateral_feed);

    (base_feed, collateral_feed)
}

/// Normalizes one oracle leg, carrying whether every value fit.
fun oracle_leg(price_info: &PriceInfoObject, feed: &PriceFeed, fixed: u256): OracleLeg {
    let (price, confidence, timestamp, representable) = pyth_price(price_info, feed, fixed);

    OracleLeg { price, confidence, timestamp, representable }
}

// --- CheckpointChange Classification ---

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
    let market_rates_unchanged = before.non_funding_fields_equal(after)
        && before.market_funding_long() == after.market_funding_long()
        && before.market_funding_short() == after.market_funding_short();
    if (!market_rates_unchanged) return CheckpointChange::Unexpected;

    let snapshots_refreshed = after.funding_snapshot_long() == before.market_funding_long()
        && after.funding_snapshot_short() == before.market_funding_short()
        && (before.funding_snapshot_long() != after.funding_snapshot_long()
            || before.funding_snapshot_short() != after.funding_snapshot_short());
    if (!snapshots_refreshed) return CheckpointChange::Unexpected;
    if (candidate_collateral_magnitude == 0 && before.allocated_collateral() == after.allocated_collateral()) {
        return CheckpointChange::Unchanged
    };

    let matched = match (&allocated_change) {
        CheckpointChange::FundingCredit(amount) => !candidate_negative && *amount == candidate_collateral_magnitude,
        CheckpointChange::FundingCost(amount) => candidate_negative && *amount == candidate_collateral_magnitude,
        CheckpointChange::Unchanged => candidate_collateral_magnitude == 0,
        CheckpointChange::Unexpected => false,
    };

    if (matched) { allocated_change } else { CheckpointChange::Unexpected }
}

/// Named IFixed operations decode signed collateral; raw checkpoint bits are never ordered.
fun allocated_delta(before: &Checkpoint, after: &Checkpoint): CheckpointChange {
    let (before_raw, after_raw) = (before.allocated_collateral(), after.allocated_collateral());

    signed_delta(before_raw.is_neg(), before_raw.abs(), after_raw.is_neg(), after_raw.abs())
}

/// Computes after-minus-before in sign/magnitude facts, including a zero crossing.
fun signed_delta(before_negative: bool, before: u256, after_negative: bool, after: u256): CheckpointChange {
    if (before_negative == after_negative) {
        if (before == after) return CheckpointChange::Unchanged;
        let credit = if (before_negative) { before > after } else { after > before };
        let amount = before.diff(after);

        if (credit) { CheckpointChange::FundingCredit(amount) } else { CheckpointChange::FundingCost(amount) }
    } else {
        if (before > std::u256::max_value!() - after) return CheckpointChange::Unexpected;
        let amount = before + after;

        if (amount == 0) {
            CheckpointChange::Unchanged
        } else if (after_negative) {
            CheckpointChange::FundingCost(amount)
        } else {
            CheckpointChange::FundingCredit(amount)
        }
    }
}

// --- Pyth Normalization ---

/// Normalizes authenticated oracle values without aborting on representation.
/// A representable disagreement is still an authentication failure and aborts;
/// width, exponent, sign, or timestamp-domain failures come back as not
/// representable for the caller to refuse or report.
fun pyth_price(
    price_info_object: &PriceInfoObject,
    aftermath_feed: &PriceFeed,
    venue_price: u256,
): (u64, u64, u64, bool) {
    let price_info = price_info_object.get_price_info_from_price_info_object();
    let pyth_price = price_info.get_price_feed().get_price();
    let price_i64 = pyth_price.get_price();
    let price_nonnegative = !price_i64.get_is_negative();
    let magnitude = if (price_nonnegative) { price_i64.get_magnitude_if_positive() } else { 0 };
    let expo = pyth_price.get_expo();

    let (normalized_price, price_representable) = normalize_pyth_component(magnitude, &expo, false);
    let (normalized_confidence, confidence_representable) =
        normalize_pyth_component(pyth_price.get_conf(), &expo, true);
    let (aftermath_price, aftermath_timestamp) = aftermath_feed.price_and_timestamp_ms();
    let (normalized_feed_price, feed_representable) = normalize_feed_price(aftermath_price);
    let (normalized_venue_price, venue_representable) = fixed_to_u64_down(venue_price, 9);
    let (pyth_timestamp, timestamp_representable) = seconds_to_millis(pyth_price.get_timestamp());
    let representable = price_nonnegative
        && price_representable
        && confidence_representable
        && feed_representable
        && venue_representable
        && timestamp_representable;
    if (!representable) return (0, 0, 0, false);

    assert!(
        normalized_feed_price == normalized_price
            && normalized_venue_price == normalized_price
            && aftermath_timestamp == pyth_timestamp,
        blast_boosts_aftermath::errors::oracle_observation_mismatch!(),
    );

    (normalized_price, normalized_confidence, aftermath_timestamp, true)
}

fun assert_pyth_price_info(price_info_object: &PriceInfoObject, aftermath_feed: &PriceFeed) {
    assert!(
        price_info_object.uid_to_inner() == aftermath_feed.from(),
        blast_boosts_aftermath::errors::pyth_price_info_mismatch!(),
    );
}

/// Aftermath feeds at the bound source use the adapter's 9-decimal price unit.
fun normalize_feed_price(raw_price: u128): (u64, bool) {
    if (raw_price > std::u64::max_value!() as u128) {
        (0, false)
    } else {
        (raw_price as u64, true)
    }
}

/// Scales one Pyth component from its signed exponent to the 9-decimal unit.
fun normalize_pyth_component(component: u64, expo: &I64, round_up: bool): (u64, bool) {
    let expo_negative = expo.get_is_negative();
    let magnitude = if (expo_negative) {
        expo.get_magnitude_if_negative()
    } else {
        expo.get_magnitude_if_positive()
    };

    normalize_pyth_component_parts(component, expo_negative, magnitude, round_up)
}

/// A u64 component scaled by at most 10^27 stays far inside u256, so the only
/// way out of range is the final u64 narrowing.
fun normalize_pyth_component_parts(
    component: u64,
    expo_negative: bool,
    magnitude: u64,
    round_up: bool,
): (u64, bool) {
    if (magnitude > 18) return (0, false);

    let raw = component as u256;
    let normalized = if (expo_negative) {
        if (magnitude <= 9) {
            raw * pow10(9 - magnitude)
        } else {
            let scale = pow10(magnitude - 9);
            let down = raw / scale;
            if (round_up && raw % scale != 0) { down + 1 } else { down }
        }
    } else {
        raw * pow10(9 + magnitude)
    };

    if (normalized > std::u64::max_value!() as u256) { (0, false) } else { (normalized as u64, true) }
}

fun seconds_to_millis(seconds: u64): (u64, bool) {
    if (seconds > std::u64::max_value!() / 1_000) {
        (0, false)
    } else {
        (seconds * 1_000, true)
    }
}

fun pow10(exponent: u64): u256 {
    let mut result = 1;
    exponent.do!(|_| result = result * 10);

    result
}

fun fixed_to_u64_down(value: u256, decimals: u64): (u64, bool) {
    let normalized = value / pow10(18 - decimals);
    if (normalized > std::u64::max_value!() as u256) { (0, false) } else { (normalized as u64, true) }
}

fun fixed_to_u64_up(value: u256, decimals: u64): (u64, bool) {
    let scale = pow10(18 - decimals);
    let down = value / scale;
    let exact = value % scale == 0;
    let up = if (exact) { down } else { down + 1 };

    if (up > std::u64::max_value!() as u256) { (0, false) } else { (up as u64, true) }
}

// --- Position Arithmetic ---

/// Converts a USD IFixed amount into collateral IFixed at `collateral_price`.
fun usd_fixed_to_collateral_fixed(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    if (collateral_price == 0) return (0, false);

    let one = constants::ifixed_one!();
    let whole = usd / collateral_price;
    let remainder = usd % collateral_price;
    if (whole > std::u256::max_value!() / one || remainder > std::u256::max_value!() / one) return (0, false);
    let fractional_scaled = remainder * one;
    let whole_scaled = whole * one;
    let fraction = fractional_scaled / collateral_price;
    if (whole_scaled > std::u256::max_value!() - fraction) return (0, false);

    let down = whole_scaled + fraction;
    if (round_up && fractional_scaled % collateral_price != 0) {
        if (down == std::u256::max_value!()) { (0, false) } else { (down + 1, true) }
    } else {
        (down, true)
    }
}

fun signed_equity(free: u64, allocated: u256, pnl_usd: u256, collateral_price: u256): (u64, bool) {
    signed_equity_decoded(
        free,
        allocated.is_neg(),
        allocated.abs(),
        pnl_usd.is_neg(),
        pnl_usd.abs(),
        collateral_price,
    )
}

fun signed_equity_decoded(
    free: u64,
    allocated_negative: bool,
    allocated: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    if (collateral_price == 0) return (0, false);

    // A liability rounds up and an asset rounds down, so equity never reads high.
    let (allocated_tokens, allocated_ok) = if (allocated_negative) {
        fixed_to_u64_up(allocated, constants::collateral_decimals!() as u64)
    } else {
        fixed_to_u64_down(allocated, constants::collateral_decimals!() as u64)
    };
    let (pnl, collateral_ok) = usd_fixed_to_collateral_fixed(pnl_magnitude_usd, collateral_price, pnl_negative);
    let (rounded, pnl_ok) = if (pnl_negative) {
        fixed_to_u64_up(pnl, constants::collateral_decimals!() as u64)
    } else {
        fixed_to_u64_down(pnl, constants::collateral_decimals!() as u64)
    };
    if (!allocated_ok || !collateral_ok || !pnl_ok) return (0, false);

    let (allocated_asset, allocated_liability) =
        if (allocated_negative) { (0, allocated_tokens) } else { (allocated_tokens, 0) };
    let (pnl_asset, pnl_liability) = if (pnl_negative) { (0, rounded) } else { (rounded, 0) };
    let assets = (free as u128) + (allocated_asset as u128) + (pnl_asset as u128);
    let liabilities = (allocated_liability as u128) + (pnl_liability as u128);
    if (assets < liabilities) return (0, false);

    let net = assets - liabilities;
    if (net > std::u64::max_value!() as u128) { (0, false) } else { (net as u64, true) }
}

fun margin_safe(margin: u256, requirement: u256): bool {
    margin_safe_decoded(margin.is_neg(), margin, requirement)
}

fun margin_safe_decoded(margin_negative: bool, margin: u256, requirement: u256): bool {
    !margin_negative && margin >= requirement
}

fun position_signs_coherent(base: u256, quote: u256, long_or_flat: bool): bool {
    position_signs_coherent_decoded(
        base.is_neg(), quote.is_neg(), base.abs() == 0, quote.abs() == 0, long_or_flat,
    )
}

fun position_signs_coherent_decoded(
    base_negative: bool, quote_negative: bool, base_zero: bool, quote_zero: bool, long_or_flat: bool,
): bool {
    if (base_zero || quote_zero) return base_zero && quote_zero;

    if (long_or_flat) { !base_negative && quote_negative } else { base_negative && !quote_negative }
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
            let (amount, representable) = fixed_to_u64_down(*raw_amount, constants::collateral_decimals!() as u64);
            (representable, false, *raw_amount, amount, representable)
        },
        CheckpointChange::FundingCost(raw_amount) => {
            let (amount, representable) = fixed_to_u64_up(*raw_amount, constants::collateral_decimals!() as u64);
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
    stored: &Checkpoint, before: &Checkpoint, stored_negative: bool, stored_magnitude: u256,
    before_negative: bool, before_magnitude: u256,
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

#[test_only]
public fun normalize_raw_fixed_for_testing(value: u256, decimals: u64, round_up: bool): u64 {
    let (normalized, representable) = if (round_up) {
        fixed_to_u64_up(value, decimals)
    } else {
        fixed_to_u64_down(value, decimals)
    };
    assert!(representable, blast_boosts_aftermath::errors::normalization_overflow!());
    normalized
}

#[test_only]
public fun normalize_pyth_for_testing(
    component: u64,
    expo_negative: bool,
    expo_magnitude: u64,
    round_up: bool,
): (u64, bool) {
    normalize_pyth_component_parts(
        component,
        expo_negative,
        expo_magnitude,
        round_up,
    )
}

#[test_only]
public fun normalize_feed_for_testing(raw_price: u128): (u64, bool) {
    normalize_feed_price(raw_price)
}

#[test_only]
public fun normalize_mark_for_testing(value: u256): (u64, bool) {
    fixed_to_u64_down(value, 9)
}

#[test_only]
public fun seconds_to_millis_for_testing(seconds: u64): (u64, bool) {
    seconds_to_millis(seconds)
}

#[test_only]
public fun usd_fixed_to_collateral_for_testing(usd: u256, collateral_price: u256, round_up: bool): (u256, bool) {
    usd_fixed_to_collateral_fixed(usd, collateral_price, round_up)
}

#[test_only]
public fun signed_equity_for_testing(
    free: u64,
    allocated_negative: bool,
    allocated: u256,
    pnl_negative: bool,
    pnl_magnitude_usd: u256,
    collateral_price: u256,
): (u64, bool) {
    signed_equity_decoded(
        free,
        allocated_negative,
        allocated,
        pnl_negative,
        pnl_magnitude_usd,
        collateral_price,
    )
}

#[test_only]
public fun margin_safe_for_testing(margin_negative: bool, margin: u256, requirement: u256): bool {
    margin_safe_decoded(margin_negative, margin, requirement)
}

#[test_only]
public fun position_signs_coherent_for_testing(
    base_negative: bool, quote_negative: bool, base_zero: bool, quote_zero: bool, long_or_flat: bool,
): bool {
    position_signs_coherent_decoded(base_negative, quote_negative, base_zero, quote_zero, long_or_flat)
}

// === Imports ===

use blast_boosts_aftermath::{constants, venue_account::{Self as venue_account, Binding, Checkpoint}};

use blast_boosts_core::{
    observation::{Self, PositionObservation, PriceObservation},
    policy::{Self, PositionSide},
};

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign and magnitude read as methods.
use fun ifixed::abs as u256.abs;
use fun ifixed::is_neg as u256.is_neg;

use oracle_aggregator::{price_feed::PriceFeed, price_feed_storage::PriceFeedStorage};

use perpetuals::{
    account::Account,
    clearing_house::ClearingHouse,
    market::MarketParams,
    registry::Registry,
};

use pyth::{i64::I64, price_info::PriceInfoObject};

use sui::clock::Clock;

use std::type_name;
