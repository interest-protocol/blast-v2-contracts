// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Immutable Series1 policy values and pure policy gates.
///
/// This slice selects no production value, authenticates no valuation source,
/// and owns no Vault or venue state.
module blast_boosts_core::policy;

// === Public Types ===

/// Immutable venue position direction.
///
/// Contract code uses Long and Short. Bull and Bear remain display names only.
public enum PositionSide has copy, drop, store {
    Long,
    Short,
}

/// Immutable rebalance thresholds and execution constraints for one Vault.
///
/// Values use leverage basis points, where 10,000 means 1x. Construction
/// validates only relationships that are independent of simulation; this
/// module does not select production values.
public struct RebalancePolicy has copy, drop, store {
    rebalance_below_bps: u64,
    target_bps: u64,
    rebalance_above_bps: u64,
    max_leverage_bps: u64,
    max_slippage_bps: u64,
    emergency_max_slippage_bps: u64,
    min_leverage_improvement_bps: u64,
}

/// Locally validated bounds for the valuation gates of one Series.
///
/// Millisecond bounds use the on-chain clock scale. Relative bounds use the
/// package's 10,000 basis-point denominator. A future Series1 transition will
/// verify the bound oracle source directly; the adapter owns venue observations.
/// Freshness and confidence gate each share-pricing source; mark divergence gates venue
/// margin safety only and never supplies shareholder-NAV or accounting inputs.
/// Every bound is inclusive, freshness arithmetic branches to avoid underflow,
/// and relative comparisons cross-multiply through `u128`.
///
/// This value cannot prove that observations came from the bound source or one
/// operation-scoped valuation pair. Those remain Series and adapter obligations.
public struct PricePolicy has copy, drop, store {
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
}

/// The immutable rule-set one Vault is issued with.
///
/// Fee rates are the values the Vault starts with; the admin may move them
/// later inside the caps recorded here.
public struct VaultPolicy has copy, drop, store {
    side: PositionSide,
    rebalance_policy: RebalancePolicy,
    price_policy: PricePolicy,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    mint_fee_cap_bps: u64,
    redeem_fee_cap_bps: u64,
    admin_allocation_cap_bps: u64,
    min_exposure_lots: u64,
}

// === Public Functions ===

// --- Position Side ---

/// Returns the long position direction.
public fun long(): PositionSide {
    PositionSide::Long
}

/// Returns the short position direction.
public fun short(): PositionSide {
    PositionSide::Short
}

// --- Rebalance Policy ---

/// Creates one immutable rebalance policy from structurally valid values.
///
/// Thresholds must satisfy `rebalance_below < target < rebalance_above < max_leverage`,
/// and max leverage must not exceed the
/// structural `leverage_ceiling_bps` ceiling, which bounds every threshold below
/// it and so bounds the mint-contribution allowance. A zero rebalance-below
/// threshold is valid and means no caller may rebalance from below; leverage
/// can never be below zero, so the lower public trigger is then unreachable by
/// design. Max slippage must stay below 10,000 bps. Emergency max slippage
/// must be at least max slippage and below 10,000 bps. Minimum leverage improvement
/// must be positive.
public fun new_rebalance_policy(
    rebalance_below_bps: u64,
    target_bps: u64,
    rebalance_above_bps: u64,
    max_leverage_bps: u64,
    max_slippage_bps: u64,
    emergency_max_slippage_bps: u64,
    min_leverage_improvement_bps: u64,
): RebalancePolicy {
    assert!(
        rebalance_below_bps < target_bps
            && target_bps < rebalance_above_bps
            && rebalance_above_bps < max_leverage_bps
            && max_leverage_bps <= constants::leverage_ceiling_bps!(),
        blast_boosts_core::errors::invalid_rebalance_policy!(),
    );
    assert!(
        max_slippage_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_max_slippage_bps!(),
    );
    assert!(
        max_slippage_bps <= emergency_max_slippage_bps
            && emergency_max_slippage_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_emergency_max_slippage_bps!(),
    );
    assert!(
        min_leverage_improvement_bps > 0,
        blast_boosts_core::errors::invalid_min_leverage_improvement_bps!(),
    );

    RebalancePolicy {
        rebalance_below_bps,
        target_bps,
        rebalance_above_bps,
        max_leverage_bps,
        max_slippage_bps,
        emergency_max_slippage_bps,
        min_leverage_improvement_bps,
    }
}

// --- Price Policy ---

/// Creates immutable valuation policy from proposed structural bounds.
///
/// `max_price_age_ms` must be positive because the structural policy requires
/// a nonzero historical-age tolerance. This check alone does not prove that a
/// selected value supports the deployed source cadence; that remains a live
/// integration and simulation gate. `max_price_ahead_ms` may be zero; zero is
/// the strictest clock-skew policy and rejects the first millisecond after the
/// reference time. It must not exceed `max_price_age_ms`: clock skew is never
/// larger than a staleness budget, and the rule catches a transposed pair
/// that would otherwise reject every aged update and admit future-dated ones.
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
/// Guard order is the freshness budget, the freshness window shape, the
/// confidence bound, then the mark divergence bound.
public fun new_price_policy(
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
): PricePolicy {
    assert!(
        max_price_age_ms > 0,
        blast_boosts_core::errors::invalid_max_price_age!(),
    );
    assert!(
        max_price_ahead_ms <= max_price_age_ms,
        blast_boosts_core::errors::invalid_freshness_window!(),
    );
    assert!(
        max_confidence_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_max_confidence_bps!(),
    );
    assert!(
        max_mark_divergence_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_max_mark_divergence_bps!(),
    );

    PricePolicy {
        max_price_age_ms,
        max_price_ahead_ms,
        max_confidence_bps,
        max_mark_divergence_bps,
    }
}

// --- Vault Policy ---

/// Composes one complete immutable policy for one future Vault.
///
/// Both fee rates stay below 10,000 bps.
/// `min_exposure_lots` is positive and at most `max_min_exposure_lots`.
/// The NAV cap is not part of the policy: it is a live `State` value the
/// admin may move, supplied to `state::new` directly.
///
/// Guard order is the fee rates, then the lot multiple.
public fun new_vault_policy(
    side: PositionSide,
    rebalance_policy: RebalancePolicy,
    price_policy: PricePolicy,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    min_exposure_lots: u64,
): VaultPolicy {
    assert!(
        mint_fee_bps < constants::basis_points_denominator!()
            && redeem_fee_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_fee_bps!(),
    );
    assert!(
        min_exposure_lots > 0
            && min_exposure_lots <= constants::max_min_exposure_lots!(),
        blast_boosts_core::errors::invalid_min_exposure_lots!(),
    );

    VaultPolicy {
        side,
        rebalance_policy,
        price_policy,
        mint_fee_bps,
        redeem_fee_bps,
        mint_fee_cap_bps: mint_fee_bps,
        redeem_fee_cap_bps: redeem_fee_bps,
        admin_allocation_cap_bps: 0,
        min_exposure_lots,
    }
}

/// Configures immutable fee ceilings before this policy is consumed at issuance.
/// `admin_cap_bps` bounds the share of future collected fees the admin may
/// take; the Vault starts with an admin share of zero.
public fun with_fee_limits(
    mut self: VaultPolicy,
    mint_cap_bps: u64,
    redeem_cap_bps: u64,
    admin_cap_bps: u64,
): VaultPolicy {
    let bps = constants::basis_points_denominator!();
    assert!(
        self.mint_fee_bps <= mint_cap_bps && mint_cap_bps < bps
            && self.redeem_fee_bps <= redeem_cap_bps && redeem_cap_bps < bps
            && admin_cap_bps <= bps,
        blast_boosts_core::errors::fee_cap_exceeded!(),
    );
    self.mint_fee_cap_bps = mint_cap_bps;
    self.redeem_fee_cap_bps = redeem_cap_bps;
    self.admin_allocation_cap_bps = admin_cap_bps;
    self
}

// === Package Functions ===

// --- Rebalance Policy ---

public(package) fun rebalance_below_bps(self: &RebalancePolicy): u64 {
    self.rebalance_below_bps
}

public(package) fun target_bps(self: &RebalancePolicy): u64 {
    self.target_bps
}

public(package) fun rebalance_above_bps(self: &RebalancePolicy): u64 {
    self.rebalance_above_bps
}

public(package) fun max_leverage_bps(self: &RebalancePolicy): u64 {
    self.max_leverage_bps
}

public(package) fun max_slippage_bps(self: &RebalancePolicy): u64 {
    self.max_slippage_bps
}

public(package) fun emergency_max_slippage_bps(self: &RebalancePolicy): u64 {
    self.emergency_max_slippage_bps
}

public(package) fun min_leverage_improvement_bps(self: &RebalancePolicy): u64 {
    self.min_leverage_improvement_bps
}

/// Returns whether reported leverage lies inside the one inclusive public band.
public(package) fun is_healthy(self: &RebalancePolicy, leverage_bps: u64): bool {
    self.rebalance_below_bps <= leverage_bps
        && leverage_bps <= self.rebalance_above_bps
}

/// Returns whether any caller may rebalance toward the fixed target.
///
/// Both public threshold equalities are inside; every caller uses this band.
public(package) fun is_public_allowed(
    self: &RebalancePolicy,
    leverage_bps: u64,
): bool {
    leverage_bps < self.rebalance_below_bps
        || leverage_bps > self.rebalance_above_bps
}

/// Returns whether leverage is strictly above the hard wider-tolerance threshold.
public(package) fun is_hard_emergency(
    self: &RebalancePolicy,
    leverage_bps: u64,
): bool {
    leverage_bps > self.max_leverage_bps
}

/// Returns whether a rebalance moved leverage toward target by the minimum.
///
/// Improvement is measured as the decrease in absolute distance from
/// `target_bps`, so `|before - target| >= |after - target| +
/// min_leverage_improvement_bps` in `u128`. This is the only anti-grief control on
/// the permissionless trigger: a rebalance that stays outside the public band
/// leaves the trigger live, and without this rule a keeper could re-trigger
/// and bleed NAV through venue costs on every pass. Reaching the exact target
/// from further than the minimum always passes.
public(package) fun is_improvement_sufficient(
    self: &RebalancePolicy,
    leverage_before_bps: u64,
    leverage_after_bps: u64,
): bool {
    let distance_before = leverage_before_bps.diff(self.target_bps) as u128;
    let distance_after = leverage_after_bps.diff(self.target_bps) as u128;

    distance_before >= distance_after + (self.min_leverage_improvement_bps as u128)
}

/// Rejects a rebalance whose leverage improvement is below the policy minimum.
public(package) fun assert_improvement_sufficient(
    self: &RebalancePolicy,
    leverage_before_bps: u64,
    leverage_after_bps: u64,
) {
    assert!(
        self.is_improvement_sufficient(leverage_before_bps, leverage_after_bps),
        blast_boosts_core::errors::insufficient_leverage_improvement!(),
    );
}

/// Returns whether an executed value stays within max slippage of its reference.
///
/// Both values share one unit and scale; the gate is
/// `|executed - reference| * 10_000 <= max_slippage_bps * reference`,
/// cross-multiplied through `u128`. A zero reference returns false. Risk
/// increase and every ordinary rebalance use this bound.
public(package) fun is_execution_within_max_slippage(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
): bool {
    is_within_relative_tolerance(self.max_slippage_bps, reference, executed)
}

/// Rejects an execution outside max slippage; a zero reference aborts first.
public(package) fun assert_execution_within_max_slippage(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
) {
    assert!(
        reference > 0,
        blast_boosts_core::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_execution_within_max_slippage(reference, executed),
        blast_boosts_core::errors::execution_outside_max_slippage!(),
    );
}

/// Returns whether an executed value stays within emergency max slippage.
///
/// Same gate as the strict form with the wider emergency bound. Reduce-only
/// execution strictly above max leverage may use it. This finite wider bound
/// does not guarantee executable liquidity or successful deleveraging.
public(package) fun is_execution_within_emergency_max_slippage(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
): bool {
    is_within_relative_tolerance(
        self.emergency_max_slippage_bps,
        reference,
        executed,
    )
}

/// Rejects an execution outside emergency max slippage; a zero reference aborts first.
public(package) fun assert_execution_within_emergency_max_slippage(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
) {
    assert!(
        reference > 0,
        blast_boosts_core::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_execution_within_emergency_max_slippage(reference, executed),
        blast_boosts_core::errors::execution_outside_max_slippage!(),
    );
}

/// Rejects a NAV cap that is zero or so large that
/// `nav_cap * max_leverage_bps / 10_000` overflows `u64`; without that ceiling
/// a Vault at the cap could not compute a target notional and rebalance.
public(package) fun assert_valid_nav_cap(self: &RebalancePolicy, nav_cap: u64) {
    assert!(
        nav_cap > 0
            && (nav_cap as u128) * (self.max_leverage_bps as u128)
                <= (std::u64::max_value!() as u128)
                    * (constants::basis_points_denominator!() as u128),
        blast_boosts_core::errors::invalid_nav_cap!(),
    );
}

// --- Price Policy ---

/// Returns the oldest admitted source update age in milliseconds.
public(package) fun max_price_age_ms(self: &PricePolicy): u64 {
    self.max_price_age_ms
}

/// Returns the admitted forward clock skew in milliseconds.
public(package) fun max_price_ahead_ms(self: &PricePolicy): u64 {
    self.max_price_ahead_ms
}

/// Returns the admitted confidence interval as basis points of the price.
public(package) fun max_confidence_bps(self: &PricePolicy): u64 {
    self.max_confidence_bps
}

/// Returns the admitted mark divergence as basis points of the index.
public(package) fun max_mark_divergence_bps(self: &PricePolicy): u64 {
    self.max_mark_divergence_bps
}

/// Returns whether a source update lies inside the two-sided freshness window.
///
/// The admitted window is the closed interval
/// `[reference_time_ms - max_price_age_ms, reference_time_ms + max_price_ahead_ms]`.
/// Unlike `assert_price_fresh`, this predicate never aborts: health may report
/// a stale or future-stamped source without changing lifecycle.
public(package) fun is_price_fresh(
    self: &PricePolicy,
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
    self: &PricePolicy,
    published_at_ms: u64,
    reference_time_ms: u64,
) {
    let fresh = self.is_price_fresh(published_at_ms, reference_time_ms);
    if (published_at_ms > reference_time_ms) {
        assert!(fresh, blast_boosts_core::errors::future_valuation!());
    } else {
        assert!(fresh, blast_boosts_core::errors::stale_valuation!());
    };
}

/// Returns whether a positive share-pricing price has an admitted confidence.
///
/// A zero price returns false instead of aborting so the future objective
/// health check can report the failure without changing lifecycle.
/// `assert_confidence_within_bound` remains the priced-operation guard that
/// reports a zero price separately from an excessive confidence interval.
public(package) fun is_confidence_within_bound(
    self: &PricePolicy,
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
    self: &PricePolicy,
    confidence: u64,
    price: u64,
) {
    assert!(
        price > 0,
        blast_boosts_core::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_confidence_within_bound(confidence, price),
        blast_boosts_core::errors::confidence_exceeds_bound!(),
    );
}

/// Returns whether a venue mark is inside the admitted base-index band.
///
/// A zero index returns false instead of aborting so the future objective
/// health check can report invalid data. The mark may be zero
/// at the type level, but every valid policy rejects it against a positive
/// index because the divergence bound stays below 10,000 basis points.
public(package) fun is_mark_within_index_divergence(
    self: &PricePolicy,
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
    self: &PricePolicy,
    mark: u64,
    index: u64,
) {
    assert!(
        index > 0,
        blast_boosts_core::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_mark_within_index_divergence(mark, index),
        blast_boosts_core::errors::mark_index_divergence_exceeds_bound!(),
    );
}

// --- Vault Policy ---

/// Returns the immutable position direction.
public(package) fun side(self: &VaultPolicy): PositionSide {
    self.side
}

public(package) fun rebalance_policy(self: &VaultPolicy): RebalancePolicy {
    self.rebalance_policy
}

public(package) fun price_policy(self: &VaultPolicy): PricePolicy {
    self.price_policy
}

/// Returns the mint fee rate in basis points.
public(package) fun mint_fee_bps(self: &VaultPolicy): u64 {
    self.mint_fee_bps
}

/// Returns the redemption fee rate in basis points.
public(package) fun redeem_fee_bps(self: &VaultPolicy): u64 {
    self.redeem_fee_bps
}

/// Returns the minimum proportional exposure change in live venue lots.
public(package) fun min_exposure_lots(self: &VaultPolicy): u64 {
    self.min_exposure_lots
}

public(package) fun assert_fee_limits(
    self: &VaultPolicy,
    mint_bps: u64,
    redeem_bps: u64,
    admin_bps: u64,
) {
    assert!(
        mint_bps <= self.mint_fee_cap_bps
            && redeem_bps <= self.redeem_fee_cap_bps
            && admin_bps <= self.admin_allocation_cap_bps,
        blast_boosts_core::errors::fee_cap_exceeded!(),
    );
}

// === Private Functions ===

/// Returns whether `executed` is within `tolerance_bps` of a positive `reference`.
fun is_within_relative_tolerance(
    tolerance_bps: u64,
    reference: u64,
    executed: u64,
): bool {
    reference > 0
        && (executed.diff(reference) as u128)
            * (constants::basis_points_denominator!() as u128)
            <= (tolerance_bps as u128) * (reference as u128)
}

// === Test-Only Functions ===

#[test_only]
/// Exposes issuance fee rates to the test event reducer without widening production ABI.
public fun initial_fee_rates_for_testing(self: &VaultPolicy): (u64, u64) {
    (self.mint_fee_bps, self.redeem_fee_bps)
}

// === Imports ===

use blast_boosts_core::constants;
