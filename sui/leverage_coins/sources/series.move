// `blast_leverage_coins::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// Validated policy and closed lifecycle rules for one future leverage Series.
///
/// This pre-custody slice owns the Series domain rules whose local validation
/// is already settled. It does not define the shared `Series` object, select
/// production values, or authenticate valuation sources. The operation-scoped
/// valuation carrier, margin buffer, adapter execution tolerances, supply and
/// seed bounds, and shutdown policy remain later design gates.
module blast_leverage_coins::series;

use blast_leverage_coins::constants;

// === Public Types ===

/// Immutable venue position direction.
///
/// Contract code uses Long and Short. Bull and Bear remain display names only.
public enum PositionSide has copy, drop, store {
    Long,
    Short,
}

/// Strictly ordered operating band and terminal risk limit for one Series.
///
/// Values use leverage basis points, where 10,000 means 1x. Construction
/// validates only relationships that are independent of simulation; this
/// module does not select a production target, band, or hard cap.
public struct LeverageBounds has copy, drop, store {
    lower_bps: u64,
    target_bps: u64,
    upper_bps: u64,
    hard_cap_bps: u64,
}

/// Locally validated immutable values stored by the future Series.
public struct SeriesPolicy has copy, drop, store {
    side: PositionSide,
    leverage_bounds: LeverageBounds,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    max_mint_contribution_divergence_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
}

/// Locally validated bounds for the valuation gates of one Series.
///
/// Millisecond bounds use the on-chain clock scale. Relative bounds use the
/// package's 10,000 basis-point denominator. The future adapter normalizes the
/// price inputs and owns source identity and authentication. Freshness and
/// confidence gate each share-pricing source; mark divergence gates venue
/// margin safety only and never supplies shareholder-NAV or accounting inputs.
/// Every bound is inclusive, freshness arithmetic branches to avoid underflow,
/// and relative comparisons cross-multiply through `u128`.
///
/// This value cannot prove that observations came from the bound source or one
/// operation-scoped valuation pair. Those remain Series and adapter obligations.
public struct ValuationPolicy has copy, drop, store {
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
}

/// Consensus lifecycle for one leverage Series.
///
/// The value is intentionally non-copyable. This slice permits only monotone
/// degradation based on the current lifecycle. The future shared Series owns
/// the authority, health proofs, stored mutation, and event emission required
/// to invoke these transitions.
public enum Lifecycle has drop, store {
    /// Normal mint, redemption, and risk management are available.
    Active,
    /// New risk is disabled while reduction and venue-permitted exits remain.
    ReduceOnly,
    /// Ordinary redemption is stopped while the venue position closes or settles.
    ShutdownPending,
    /// The position is gone and only pro-rata settled-cash redemption remains.
    ShutdownSettled,
}

// === Package Functions ===

// --- Series Policy ---

/// Returns the long position direction.
public(package) fun long(): PositionSide {
    PositionSide::Long
}

/// Returns the short position direction.
public(package) fun short(): PositionSide {
    PositionSide::Short
}

/// Creates one immutable policy from values whose local bounds are settled.
///
/// The leverage values must satisfy
/// `0 < lower < target < upper < hard cap`. Both fee rates are basis points
/// and must stay below 10,000. The mint-contribution divergence bound is also
/// below 10,000 basis points and is distinct from the venue mark-divergence
/// policy. The minimum operation size is a positive number of live venue lots.
/// `nav_cap` is a positive number of atomic collateral units. This constructor
/// does not compare policy values with live venue state or select production
/// values.
///
/// Guard order is leverage bounds, fee rates, mint-contribution divergence,
/// minimum exposure lots, then NAV cap.
public(package) fun new_policy(
    side: PositionSide,
    lower_bps: u64,
    target_bps: u64,
    upper_bps: u64,
    hard_cap_bps: u64,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    max_mint_contribution_divergence_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
): SeriesPolicy {
    assert!(
        lower_bps > 0
            && lower_bps < target_bps
            && target_bps < upper_bps
            && upper_bps < hard_cap_bps,
        blast_leverage_coins::errors::invalid_leverage_bounds!(),
    );
    assert!(
        mint_fee_bps < constants::basis_points_denominator!()
            && redeem_fee_bps < constants::basis_points_denominator!(),
        blast_leverage_coins::errors::invalid_fee_bps!(),
    );
    assert!(
        max_mint_contribution_divergence_bps
            < constants::basis_points_denominator!(),
        blast_leverage_coins::errors::invalid_max_mint_contribution_divergence_bps!(),
    );
    assert!(
        min_exposure_lots > 0,
        blast_leverage_coins::errors::invalid_min_exposure_lots!(),
    );
    assert!(
        nav_cap > 0,
        blast_leverage_coins::errors::invalid_series_nav_cap!(),
    );

    let leverage_bounds = LeverageBounds {
        lower_bps,
        target_bps,
        upper_bps,
        hard_cap_bps,
    };

    SeriesPolicy {
        side,
        leverage_bounds,
        mint_fee_bps,
        redeem_fee_bps,
        max_mint_contribution_divergence_bps,
        min_exposure_lots,
        nav_cap,
    }
}

/// Returns the immutable position direction.
public(package) fun side(self: &SeriesPolicy): PositionSide {
    self.side
}

/// Returns the validated accounting-leverage bounds.
public(package) fun leverage_bounds(self: &SeriesPolicy): LeverageBounds {
    self.leverage_bounds
}

/// Returns the leverage below which an active Series may increase risk.
public(package) fun lower_bps(self: &LeverageBounds): u64 {
    self.lower_bps
}

/// Returns the leverage toward which a rebalance sizes exposure.
public(package) fun target_bps(self: &LeverageBounds): u64 {
    self.target_bps
}

/// Returns the leverage above which a Series must reduce risk.
public(package) fun upper_bps(self: &LeverageBounds): u64 {
    self.upper_bps
}

/// Returns the leverage that a risk-increasing operation may never reach.
public(package) fun hard_cap_bps(self: &LeverageBounds): u64 {
    self.hard_cap_bps
}

/// Returns the mint fee rate in basis points.
public(package) fun mint_fee_bps(self: &SeriesPolicy): u64 {
    self.mint_fee_bps
}

/// Returns the redemption fee rate in basis points.
public(package) fun redeem_fee_bps(self: &SeriesPolicy): u64 {
    self.redeem_fee_bps
}

/// Returns the minimum proportional exposure change in live venue lots.
public(package) fun min_exposure_lots(self: &SeriesPolicy): u64 {
    self.min_exposure_lots
}

/// Returns the hard Series NAV cap in atomic collateral units.
public(package) fun nav_cap(self: &SeriesPolicy): u64 {
    self.nav_cap
}

/// Rejects an impossible or overly favorable mint contribution.
///
/// `deposit` and `contribution` are atomic collateral units. `contribution` is
/// the actual post-operation shareholder-NAV contribution returned by the
/// canonical reserve-aware mint accounting path. A contribution at or below
/// the deposit always passes. Any excess is bounded by:
///
/// ```text
/// contribution <= deposit
///     + floor(
///         deposit
///             * max_mint_contribution_divergence_bps
///             * target_leverage_bps
///             / 100_000_000,
///     )
/// ```
///
/// The comparison cross-multiplies through `u256`, so it neither narrows the
/// allowed contribution nor overflows when every input is `u64::MAX` within
/// its validated policy range. Flooring the allowance protects existing
/// holders. The bound is inclusive.
///
/// This is a Series accounting postcondition, not a share-pricing input or an
/// execution-price oracle. It deliberately does not reuse the venue
/// mark-divergence policy. The future mint transition must apply it to the one
/// canonical contribution before minting shares.
public(package) fun assert_mint_contribution_within_bound(
    self: &SeriesPolicy,
    deposit: u64,
    contribution: u64,
) {
    assert!(
        is_mint_contribution_within_bound(self, deposit, contribution),
        blast_leverage_coins::errors::mint_contribution_exceeds_bound!(),
    );
}

// --- Valuation Policy ---

/// Creates immutable valuation policy from proposed structural bounds.
///
/// `max_price_age_ms` must be positive because the structural policy requires
/// a nonzero historical-age tolerance. This check alone does not prove that a
/// selected value supports the deployed source cadence; that remains a live
/// integration and simulation gate. `max_price_ahead_ms` may be zero; zero is
/// the strictest clock-skew policy and rejects the first millisecond after the
/// reference time.
///
/// Both relative bounds may be zero, which demands an exact price and an exact
/// mark, and both must stay below the 10,000 basis-point denominator. At or
/// above the denominator a confidence interval may span the complete price and
/// a divergence bound admits a zero mark, so the gate would stop constraining
/// the observation at all.
///
/// No upper millisecond bound is structural. The deployed source cadence,
/// keeper latency, venue margin parameters, and simulation select every value
/// here; this package compiles none of them and validates no value against
/// live venue state.
///
/// Guard order is the freshness budget, the confidence bound, then the mark
/// divergence bound.
public(package) fun new_valuation(
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
): ValuationPolicy {
    assert!(
        max_price_age_ms > 0,
        blast_leverage_coins::errors::invalid_max_price_age!(),
    );
    assert!(
        max_confidence_bps < constants::basis_points_denominator!(),
        blast_leverage_coins::errors::invalid_max_confidence_bps!(),
    );
    assert!(
        max_mark_divergence_bps < constants::basis_points_denominator!(),
        blast_leverage_coins::errors::invalid_max_mark_divergence_bps!(),
    );

    ValuationPolicy {
        max_price_age_ms,
        max_price_ahead_ms,
        max_confidence_bps,
        max_mark_divergence_bps,
    }
}

/// Returns the oldest admitted source update age in milliseconds.
public(package) fun max_price_age_ms(self: &ValuationPolicy): u64 {
    self.max_price_age_ms
}

/// Returns the admitted forward clock skew in milliseconds.
public(package) fun max_price_ahead_ms(self: &ValuationPolicy): u64 {
    self.max_price_ahead_ms
}

/// Returns the admitted confidence interval as basis points of the price.
public(package) fun max_confidence_bps(self: &ValuationPolicy): u64 {
    self.max_confidence_bps
}

/// Returns the admitted mark divergence as basis points of the index.
public(package) fun max_mark_divergence_bps(self: &ValuationPolicy): u64 {
    self.max_mark_divergence_bps
}

/// Returns whether a source update lies inside the two-sided freshness window.
///
/// The admitted window is the closed interval
/// `[reference_time_ms - max_price_age_ms, reference_time_ms + max_price_ahead_ms]`.
/// Unlike `assert_price_fresh`, this predicate never aborts: the later
/// objective health transition must observe a stale or future-stamped source
/// and degrade the Series lifecycle instead of rolling its own transaction
/// back.
public(package) fun is_price_fresh(
    self: &ValuationPolicy,
    published_at_ms: u64,
    reference_time_ms: u64,
): bool {
    if (published_at_ms > reference_time_ms) {
        published_at_ms - reference_time_ms <= self.max_price_ahead_ms
    } else {
        reference_time_ms - published_at_ms <= self.max_price_age_ms
    }
}

/// Rejects a source update outside the two-sided freshness window.
///
/// `published_at_ms` is the source's own update time and `reference_time_ms` is
/// the operation's single on-chain time reading, both in milliseconds. An
/// update older than the staleness budget aborts as stale, and one stamped
/// further ahead than the skew budget aborts as future-dated. The two failures
/// stay distinct because an outage and a skewed or misreporting source need
/// different operational responses.
///
/// Admitting a fresh update is necessary, not sufficient. This module cannot
/// prove which source produced the update, that the same pair priced both
/// sides of the operation, or that a caller did not choose among historical
/// updates.
public(package) fun assert_price_fresh(
    self: &ValuationPolicy,
    published_at_ms: u64,
    reference_time_ms: u64,
) {
    let freshness_abort_code = if (published_at_ms > reference_time_ms) {
        blast_leverage_coins::errors::future_valuation!()
    } else {
        blast_leverage_coins::errors::stale_valuation!()
    };

    assert!(
        self.is_price_fresh(published_at_ms, reference_time_ms),
        freshness_abort_code,
    );
}

/// Returns whether a positive share-pricing price has an admitted confidence.
///
/// A zero price returns false instead of aborting so the future objective
/// health transition can observe the failure and persist lifecycle degradation.
/// `assert_confidence_within_bound` remains the priced-operation guard that
/// reports a zero price separately from an excessive confidence interval.
public(package) fun is_confidence_within_bound(
    self: &ValuationPolicy,
    confidence: u64,
    price: u64,
): bool {
    price > 0
        && (confidence as u128) * (constants::basis_points_denominator!() as u128)
            <= (self.max_confidence_bps as u128) * (price as u128)
}

/// Rejects a share-pricing price whose confidence interval is too wide.
///
/// `confidence` is the absolute interval reported with `price`, in the same
/// units and scale as `price`. The gate is
/// `confidence * 10_000 <= max_confidence_bps * price`, so it holds exactly
/// when `confidence` is at most `floor(max_confidence_bps * price / 10_000)`.
/// Cross-multiplying keeps the comparison exact and removes the division that
/// a zero price would otherwise have to survive.
///
/// A zero price is rejected before the bound is read: a relative interval is
/// undefined against it, and a zero share-pricing price is itself a source
/// failure that must fail closed. A confidence at or above the price is always
/// rejected because the constructor keeps `max_confidence_bps` below 10,000.
///
/// Guard order is the positive price, then the confidence bound.
public(package) fun assert_confidence_within_bound(
    self: &ValuationPolicy,
    confidence: u64,
    price: u64,
) {
    assert!(
        price > 0,
        blast_leverage_coins::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_confidence_within_bound(confidence, price),
        blast_leverage_coins::errors::confidence_exceeds_bound!(),
    );
}

/// Returns whether a venue mark is inside the admitted base-index band.
///
/// A zero index returns false instead of aborting so the future objective
/// health transition can persist lifecycle degradation. The mark may be zero
/// at the type level, but every valid policy rejects it against a positive
/// index because the divergence bound stays below 10,000 basis points.
public(package) fun is_mark_within_index_divergence(
    self: &ValuationPolicy,
    mark: u64,
    index: u64,
): bool {
    index > 0
        && (mark.diff(index) as u128)
            * (constants::basis_points_denominator!() as u128)
            <= (self.max_mark_divergence_bps as u128) * (index as u128)
}

/// Rejects a venue mark that diverges too far from the base index.
///
/// The gate is `|mark - index| * 10_000 <= max_mark_divergence_bps * index`,
/// so it holds exactly when the absolute difference is at most
/// `floor(max_mark_divergence_bps * index / 10_000)`. The bound is symmetric:
/// a mark above and a mark below the index are limited by the same fraction of
/// the index.
///
/// This is a venue margin-safety gate. Its result never prices shares, never
/// enters shareholder NAV, and never sizes exposure; ADR 0064 I25 keeps the
/// index-and-collateral pair as the only share-pricing valuation. A zero index
/// is rejected before the bound is read, and a zero mark against a positive
/// index is always rejected because the constructor keeps
/// `max_mark_divergence_bps` below 10,000.
///
/// Guard order is the positive index, then the divergence bound.
public(package) fun assert_mark_within_index_divergence(
    self: &ValuationPolicy,
    mark: u64,
    index: u64,
) {
    assert!(
        index > 0,
        blast_leverage_coins::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_mark_within_index_divergence(mark, index),
        blast_leverage_coins::errors::mark_index_divergence_exceeds_bound!(),
    );
}

// --- Lifecycle ---

/// Returns the lifecycle of a newly constructed Series.
public(package) fun new_lifecycle(): Lifecycle {
    Lifecycle::Active
}

/// Returns whether normal minting and risk increase are permitted.
public(package) fun is_active(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::Active => true,
        _ => false,
    }
}

/// Returns whether new risk is disabled but ordinary exits remain possible.
public(package) fun is_reduce_only(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ReduceOnly => true,
        _ => false,
    }
}

/// Returns whether shutdown still requires venue close or settlement.
public(package) fun is_shutdown_pending(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ShutdownPending => true,
        _ => false,
    }
}

/// Returns whether shutdown cash is final and redeemable.
public(package) fun is_shutdown_settled(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ShutdownSettled => true,
        _ => false,
    }
}

/// Disables new risk from the active lifecycle.
public(package) fun enter_reduce_only(self: &mut Lifecycle) {
    assert!(
        self.is_active(),
        blast_leverage_coins::errors::invalid_lifecycle_transition!(),
    );

    *self = Lifecycle::ReduceOnly;
}

/// Starts terminal shutdown from either nonterminal operating lifecycle.
public(package) fun enter_shutdown_pending(self: &mut Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_coins::errors::invalid_lifecycle_transition!(),
    );

    *self = Lifecycle::ShutdownPending;
}

/// Permits a mint, risk increase, or ordinary active-only operation.
public(package) fun assert_active(self: &Lifecycle) {
    assert!(
        self.is_active(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits an ordinary redemption only before shutdown starts.
///
/// `ReduceOnly` admission is necessary but not sufficient: the later Series
/// and adapter must still prove that the venue can complete the exit safely.
public(package) fun assert_normal_redemption_allowed(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits ordinary risk reduction while the Series is still operating.
///
/// This guard intentionally remains separate from ordinary redemption even
/// while both admit the same states. Any future ReduceOnly redemption-policy
/// change must re-audit both guards against the lifecycle permission matrix.
public(package) fun assert_operating_risk_reduction_allowed(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits the close-or-settle operation only during pending shutdown.
public(package) fun assert_shutdown_close_allowed(self: &Lifecycle) {
    assert!(
        self.is_shutdown_pending(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits pro-rata cash redemption only after shutdown settlement is final.
public(package) fun assert_shutdown_redemption_allowed(self: &Lifecycle) {
    assert!(
        self.is_shutdown_settled(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

// ponytail: Resume and settlement finalization stay absent until the shared Series can prove their
// authority, cooldown, venue-health, funding, custody, and reserve-reclassification conditions.

// === Private Functions ===

/// Returns whether a mint contribution satisfies its leveraged divergence cap.
fun is_mint_contribution_within_bound(
    self: &SeriesPolicy,
    deposit: u64,
    contribution: u64,
): bool {
    if (contribution <= deposit) {
        true
    } else {
        let denominator = constants::basis_points_denominator!() as u256;
        let excess = (contribution - deposit) as u256;

        excess * denominator * denominator
            <= (deposit as u256)
                * (self.max_mint_contribution_divergence_bps as u256)
                * (self.leverage_bounds.target_bps as u256)
    }
}

// === Test-Only Functions ===

#[test_only]
/// Returns the mint contribution's maximum favorable divergence in basis points.
public(package) fun max_mint_contribution_divergence_bps(
    self: &SeriesPolicy,
): u64 {
    self.max_mint_contribution_divergence_bps
}

#[test_only]
/// Exposes the mint-contribution predicate for exhaustive reference testing.
public(package) fun is_mint_contribution_within_bound_for_testing(
    self: &SeriesPolicy,
    deposit: u64,
    contribution: u64,
): bool {
    is_mint_contribution_within_bound(self, deposit, contribution)
}

#[test_only]
/// Creates ReduceOnly state for exhaustive transition and operation tests.
public(package) fun reduce_only_for_testing(): Lifecycle {
    Lifecycle::ReduceOnly
}

#[test_only]
/// Creates ShutdownPending state for exhaustive transition and operation tests.
public(package) fun shutdown_pending_for_testing(): Lifecycle {
    Lifecycle::ShutdownPending
}

#[test_only]
/// Creates ShutdownSettled state for exhaustive transition and operation tests.
public(package) fun shutdown_settled_for_testing(): Lifecycle {
    Lifecycle::ShutdownSettled
}
