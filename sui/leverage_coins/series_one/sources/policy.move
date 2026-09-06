// `blast_leverage_series_one::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// Immutable Series1 policy values and pure policy gates.
///
/// This slice selects no production value, authenticates no valuation source,
/// and owns no Vault or venue state.
module blast_leverage_series_one::policy;

use blast_leverage_series_one::constants;

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
    public_lower_bps: u64,
    target_bps: u64,
    public_upper_bps: u64,
    hard_cap_bps: u64,
    strict_tolerance_bps: u64,
    emergency_tolerance_bps: u64,
    minimum_improvement_bps: u64,
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
public struct ValuationPolicy has copy, drop, store {
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
}

/// One immutable policy selected for one Vault during issuance.
public struct TierPolicy has copy, drop, store {
    side: PositionSide,
    rebalance_policy: RebalancePolicy,
    valuation_policy: ValuationPolicy,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    mint_fee_cap_bps: u64,
    redeem_fee_cap_bps: u64,
    admin_allocation_cap_bps: u64,
    initial_admin_allocation_bps: u64,
    max_mint_contribution_divergence_bps: u64,
    max_redemption_gross_divergence_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
}

// === Functions ===

// --- Rebalance Policy ---

/// Returns the long position direction.
public fun long(): PositionSide {
    PositionSide::Long
}

/// Returns the short position direction.
public fun short(): PositionSide {
    PositionSide::Short
}

/// Creates one immutable rebalance policy from structurally valid values.
///
/// Thresholds must satisfy `public lower < target < public upper < hard cap`,
/// and the hard cap must not exceed the
/// structural `max_leverage_bps` ceiling, which bounds every threshold below
/// it and so bounds the mint-contribution allowance. A zero public lower
/// threshold is valid and means no caller may rebalance from below; leverage
/// can never be below zero, so the lower public trigger is then unreachable by
/// design. Strict tolerance must stay below 10,000 bps. Emergency tolerance
/// must be at least strict tolerance and below 10,000 bps. Minimum improvement
/// must be positive.
public fun new_rebalance_policy(
    public_lower_bps: u64,
    target_bps: u64,
    public_upper_bps: u64,
    hard_cap_bps: u64,
    strict_tolerance_bps: u64,
    emergency_tolerance_bps: u64,
    minimum_improvement_bps: u64,
): RebalancePolicy {
    assert!(
        public_lower_bps < target_bps
            && target_bps < public_upper_bps
            && public_upper_bps < hard_cap_bps
            && hard_cap_bps <= constants::max_leverage_bps!(),
        blast_leverage_series_one::errors::invalid_rebalance_policy!(),
    );
    assert!(
        strict_tolerance_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_strict_tolerance_bps!(),
    );
    assert!(
        strict_tolerance_bps <= emergency_tolerance_bps
            && emergency_tolerance_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_emergency_tolerance_bps!(),
    );
    assert!(
        minimum_improvement_bps > 0,
        blast_leverage_series_one::errors::invalid_minimum_improvement_bps!(),
    );

    RebalancePolicy {
        public_lower_bps,
        target_bps,
        public_upper_bps,
        hard_cap_bps,
        strict_tolerance_bps,
        emergency_tolerance_bps,
        minimum_improvement_bps,
    }
}

public(package) fun public_lower_bps(self: &RebalancePolicy): u64 {
    self.public_lower_bps
}

public(package) fun target_bps(self: &RebalancePolicy): u64 {
    self.target_bps
}

public(package) fun public_upper_bps(self: &RebalancePolicy): u64 {
    self.public_upper_bps
}

public(package) fun hard_cap_bps(self: &RebalancePolicy): u64 {
    self.hard_cap_bps
}

public(package) fun strict_tolerance_bps(self: &RebalancePolicy): u64 {
    self.strict_tolerance_bps
}

public(package) fun emergency_tolerance_bps(self: &RebalancePolicy): u64 {
    self.emergency_tolerance_bps
}

public(package) fun minimum_improvement_bps(self: &RebalancePolicy): u64 {
    self.minimum_improvement_bps
}

/// Returns whether reported leverage lies inside the one inclusive public band.
public(package) fun is_healthy(self: &RebalancePolicy, leverage_bps: u64): bool {
    self.public_lower_bps <= leverage_bps
        && leverage_bps <= self.public_upper_bps
}

/// Returns whether any caller may rebalance toward the fixed target.
///
/// Both public threshold equalities are inside; every caller uses this band.
public(package) fun is_public_allowed(
    self: &RebalancePolicy,
    leverage_bps: u64,
): bool {
    leverage_bps < self.public_lower_bps
        || leverage_bps > self.public_upper_bps
}

/// Returns whether leverage is strictly above the hard wider-tolerance threshold.
public(package) fun is_hard_emergency(
    self: &RebalancePolicy,
    leverage_bps: u64,
): bool {
    leverage_bps > self.hard_cap_bps
}

/// Returns whether a rebalance moved leverage toward target by the minimum.
///
/// Improvement is measured as the decrease in absolute distance from
/// `target_bps`, so `|before - target| >= |after - target| +
/// minimum_improvement_bps` in `u128`. This is the only anti-grief control on
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

    distance_before >= distance_after + (self.minimum_improvement_bps as u128)
}

/// Rejects a rebalance whose leverage improvement is below the policy minimum.
public(package) fun assert_improvement_sufficient(
    self: &RebalancePolicy,
    leverage_before_bps: u64,
    leverage_after_bps: u64,
) {
    assert!(
        self.is_improvement_sufficient(leverage_before_bps, leverage_after_bps),
        blast_leverage_series_one::errors::insufficient_leverage_improvement!(),
    );
}

/// Returns whether an executed value stays within strict tolerance of its reference.
///
/// Both values share one unit and scale; the gate is
/// `|executed - reference| * 10_000 <= strict_tolerance_bps * reference`,
/// cross-multiplied through `u128`. A zero reference returns false. Risk
/// increase and every ordinary rebalance use this bound.
public(package) fun is_execution_within_strict_tolerance(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
): bool {
    is_within_relative_tolerance(self.strict_tolerance_bps, reference, executed)
}

/// Returns whether an executed value stays within emergency tolerance.
///
/// Same gate as the strict form with the wider emergency bound. Reduce-only
/// execution strictly above the hard cap may use it. This finite wider bound
/// does not guarantee executable liquidity or successful deleveraging.
public(package) fun is_execution_within_emergency_tolerance(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
): bool {
    is_within_relative_tolerance(
        self.emergency_tolerance_bps,
        reference,
        executed,
    )
}

/// Rejects an execution outside strict tolerance; a zero reference aborts first.
public(package) fun assert_execution_within_strict_tolerance(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
) {
    assert!(
        reference > 0,
        blast_leverage_series_one::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_execution_within_strict_tolerance(reference, executed),
        blast_leverage_series_one::errors::execution_outside_tolerance!(),
    );
}

/// Rejects an execution outside emergency tolerance; a zero reference aborts first.
public(package) fun assert_execution_within_emergency_tolerance(
    self: &RebalancePolicy,
    reference: u64,
    executed: u64,
) {
    assert!(
        reference > 0,
        blast_leverage_series_one::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_execution_within_emergency_tolerance(reference, executed),
        blast_leverage_series_one::errors::execution_outside_tolerance!(),
    );
}

// --- Tier Policy ---

/// Composes one complete immutable policy for one future Vault.
///
/// Both divergence bounds and both fee rates stay below 10,000 bps.
/// `min_exposure_lots` is positive and at most `max_min_exposure_lots`.
/// `nav_cap` is positive and small enough that
/// `nav_cap * hard_cap_bps / 10_000` fits in `u64`, so a target notional can be
/// computed for every leverage the policy admits; without that ceiling a Vault
/// at the cap could not be rebalanced. Because the policy is immutable, both
/// ceilings also fence a transposed lot multiple and NAV cap, which would
/// otherwise brick every mint of the deployed Vault.
///
/// Guard order is the fee rates, the mint divergence bound, the redemption
/// divergence bound, the lot multiple, then the NAV cap.
public fun new_tier_policy(
    side: PositionSide,
    rebalance_policy: RebalancePolicy,
    valuation_policy: ValuationPolicy,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    max_mint_contribution_divergence_bps: u64,
    max_redemption_gross_divergence_bps: u64,
    min_exposure_lots: u64,
    nav_cap: u64,
): TierPolicy {
    assert!(
        mint_fee_bps < constants::basis_points_denominator!()
            && redeem_fee_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_fee_bps!(),
    );
    assert!(
        max_mint_contribution_divergence_bps
            < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_max_mint_contribution_divergence_bps!(),
    );
    assert!(
        max_redemption_gross_divergence_bps
            < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_max_redemption_gross_divergence_bps!(),
    );
    assert!(
        min_exposure_lots > 0
            && min_exposure_lots <= constants::max_min_exposure_lots!(),
        blast_leverage_series_one::errors::invalid_min_exposure_lots!(),
    );
    assert!(
        nav_cap > 0
            && (nav_cap as u128) * (rebalance_policy.hard_cap_bps as u128)
                <= (std::u64::max_value!() as u128)
                    * (constants::basis_points_denominator!() as u128),
        blast_leverage_series_one::errors::invalid_series_nav_cap!(),
    );

    TierPolicy {
        side,
        rebalance_policy,
        valuation_policy,
        mint_fee_bps,
        redeem_fee_bps,
        mint_fee_cap_bps: mint_fee_bps,
        redeem_fee_cap_bps: redeem_fee_bps,
        admin_allocation_cap_bps: 0,
        initial_admin_allocation_bps: 0,
        max_mint_contribution_divergence_bps,
        max_redemption_gross_divergence_bps,
        min_exposure_lots,
        nav_cap,
    }
}

/// Configures immutable fee ceilings before this policy is consumed at issuance.
/// The initial allocation belongs to future collected fees, never prior assets.
public fun with_fee_limits(
    mut self: TierPolicy,
    mint_cap_bps: u64,
    redeem_cap_bps: u64,
    admin_cap_bps: u64,
    initial_admin_bps: u64,
): TierPolicy {
    assert!(
        self.mint_fee_bps <= mint_cap_bps && mint_cap_bps < 10_000
            && self.redeem_fee_bps <= redeem_cap_bps && redeem_cap_bps < 10_000
            && initial_admin_bps <= admin_cap_bps && admin_cap_bps <= 10_000,
        blast_leverage_series_one::errors::fee_cap_exceeded!(),
    );
    self.mint_fee_cap_bps = mint_cap_bps;
    self.redeem_fee_cap_bps = redeem_cap_bps;
    self.admin_allocation_cap_bps = admin_cap_bps;
    self.initial_admin_allocation_bps = initial_admin_bps;
    self
}

public(package) fun initial_admin_allocation_bps(self: &TierPolicy): u64 {
    self.initial_admin_allocation_bps
}

public(package) fun assert_fee_limits(
    self: &TierPolicy,
    mint_bps: u64,
    redeem_bps: u64,
    admin_bps: u64,
) {
    assert!(
        mint_bps <= self.mint_fee_cap_bps
            && redeem_bps <= self.redeem_fee_cap_bps
            && admin_bps <= self.admin_allocation_cap_bps,
        blast_leverage_series_one::errors::fee_cap_exceeded!(),
    );
}

/// Returns the immutable position direction.
public(package) fun side(self: &TierPolicy): PositionSide {
    self.side
}

public(package) fun rebalance_policy(self: &TierPolicy): RebalancePolicy {
    self.rebalance_policy
}

public(package) fun valuation_policy(self: &TierPolicy): ValuationPolicy {
    self.valuation_policy
}

/// Returns the mint fee rate in basis points.
public(package) fun mint_fee_bps(self: &TierPolicy): u64 {
    self.mint_fee_bps
}

/// Returns the redemption fee rate in basis points.
public(package) fun redeem_fee_bps(self: &TierPolicy): u64 {
    self.redeem_fee_bps
}

/// Returns the minimum proportional exposure change in live venue lots.
public(package) fun min_exposure_lots(self: &TierPolicy): u64 {
    self.min_exposure_lots
}

/// Returns the hard Series NAV cap in atomic collateral units.
public(package) fun nav_cap(self: &TierPolicy): u64 {
    self.nav_cap
}

/// Returns whether shareholder NAV is at or below the immutable Series cap.
///
/// The cap is inclusive and is tied to executable book depth, not headline
/// open interest. The mint transition must apply it to post-mint shareholder
/// NAV from the canonical accounting checkpoint.
public(package) fun is_within_nav_cap(self: &TierPolicy, nav: u64): bool {
    nav <= self.nav_cap
}

/// Rejects shareholder NAV above the immutable Series cap.
public(package) fun assert_within_nav_cap(self: &TierPolicy, nav: u64) {
    assert!(
        self.is_within_nav_cap(nav),
        blast_leverage_series_one::errors::series_nav_cap_exceeded!(),
    );
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
/// mark-divergence policy. The mint transition applies it to the one
/// canonical contribution before minting shares.
public(package) fun assert_mint_contribution_within_bound(
    self: &TierPolicy,
    deposit: u64,
    contribution: u64,
) {
    assert!(
        is_mint_contribution_within_bound(self, deposit, contribution),
        blast_leverage_series_one::errors::mint_contribution_exceeds_bound!(),
    );
}

/// Rejects an overly favorable redemption gross claim.
///
/// `proportional_claim` and `gross` are atomic collateral units returned
/// together by `accounting_math::redemption_accounting_quote`. The claim is
/// the redeemer's share of pre-unwind NAV; the gross measures against
/// post-unwind NAV and receives every unit by which the second reading exceeds
/// the first, however few shares were burned. A gross at or below the claim
/// always passes. Any excess is bounded by the same leveraged allowance the
/// mint side applies to its contribution:
///
/// ```text
/// gross <= proportional_claim
///     + floor(
///         proportional_claim
///             * max_redemption_gross_divergence_bps
///             * target_leverage_bps
///             / 100_000_000,
///     )
/// ```
///
/// A zero claim admits only a zero gross, which the quote already rejects, so
/// a dust redeemer can never be paid a gain that is not proportionally theirs.
/// The comparison cross-multiplies through `u256` and the bound is inclusive.
/// The redemption transition applies it before paying `net`.
public(package) fun assert_redemption_gross_within_bound(
    self: &TierPolicy,
    proportional_claim: u64,
    gross: u64,
) {
    assert!(
        is_redemption_gross_within_bound(self, proportional_claim, gross),
        blast_leverage_series_one::errors::redemption_gross_exceeds_bound!(),
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
public fun new_valuation(
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
): ValuationPolicy {
    assert!(
        max_price_age_ms > 0,
        blast_leverage_series_one::errors::invalid_max_price_age!(),
    );
    assert!(
        max_price_ahead_ms <= max_price_age_ms,
        blast_leverage_series_one::errors::invalid_freshness_window!(),
    );
    assert!(
        max_confidence_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_max_confidence_bps!(),
    );
    assert!(
        max_mark_divergence_bps < constants::basis_points_denominator!(),
        blast_leverage_series_one::errors::invalid_max_mark_divergence_bps!(),
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
/// Unlike `assert_price_fresh`, this predicate never aborts: health may report
/// a stale or future-stamped source without changing lifecycle.
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
        blast_leverage_series_one::errors::future_valuation!()
    } else {
        blast_leverage_series_one::errors::stale_valuation!()
    };

    assert!(
        self.is_price_fresh(published_at_ms, reference_time_ms),
        freshness_abort_code,
    );
}

/// Returns whether a positive share-pricing price has an admitted confidence.
///
/// A zero price returns false instead of aborting so the future objective
/// health check can report the failure without changing lifecycle.
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
        blast_leverage_series_one::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_confidence_within_bound(confidence, price),
        blast_leverage_series_one::errors::confidence_exceeds_bound!(),
    );
}

/// Returns whether a venue mark is inside the admitted base-index band.
///
/// A zero index returns false instead of aborting so the future objective
/// health check can report invalid data. The mark may be zero
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
        blast_leverage_series_one::errors::invalid_valuation_price!(),
    );
    assert!(
        self.is_mark_within_index_divergence(mark, index),
        blast_leverage_series_one::errors::mark_index_divergence_exceeds_bound!(),
    );
}

// === Private Functions ===

/// Returns whether a mint contribution satisfies its leveraged divergence cap.
fun is_mint_contribution_within_bound(
    self: &TierPolicy,
    deposit: u64,
    contribution: u64,
): bool {
    is_within_leveraged_allowance(
        deposit,
        contribution,
        self.max_mint_contribution_divergence_bps,
        self.rebalance_policy.target_bps,
    )
}

/// Returns whether a redemption gross satisfies its leveraged divergence cap.
fun is_redemption_gross_within_bound(
    self: &TierPolicy,
    proportional_claim: u64,
    gross: u64,
): bool {
    is_within_leveraged_allowance(
        proportional_claim,
        gross,
        self.max_redemption_gross_divergence_bps,
        self.rebalance_policy.target_bps,
    )
}

/// Returns whether `actual` exceeds `expected` by at most the leveraged allowance.
///
/// The allowance is `floor(expected * divergence_bps * target_bps /
/// 100_000_000)`; an actual at or below the expected value always passes. The
/// comparison cross-multiplies through `u256`, so it neither narrows the
/// allowance nor overflows at `u64::MAX` inputs within the validated ranges.
fun is_within_leveraged_allowance(
    expected: u64,
    actual: u64,
    divergence_bps: u64,
    target_bps: u64,
): bool {
    if (actual <= expected) {
        true
    } else {
        let denominator = constants::basis_points_denominator!() as u256;
        let excess = (actual - expected) as u256;

        excess * denominator * denominator
            <= (expected as u256) * (divergence_bps as u256) * (target_bps as u256)
    }
}

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
/// Returns the mint contribution's maximum favorable divergence in basis points.
public(package) fun max_mint_contribution_divergence_bps(
    self: &TierPolicy,
): u64 {
    self.max_mint_contribution_divergence_bps
}

#[test_only]
/// Exposes the mint-contribution predicate for exhaustive reference testing.
public(package) fun is_mint_contribution_within_bound_for_testing(
    self: &TierPolicy,
    deposit: u64,
    contribution: u64,
): bool {
    is_mint_contribution_within_bound(self, deposit, contribution)
}

#[test_only]
/// Returns the redemption gross claim's maximum favorable divergence in basis points.
public(package) fun max_redemption_gross_divergence_bps(
    self: &TierPolicy,
): u64 {
    self.max_redemption_gross_divergence_bps
}

#[test_only]
/// Exposes the redemption-gross predicate for exhaustive reference testing.
public(package) fun is_redemption_gross_within_bound_for_testing(
    self: &TierPolicy,
    proportional_claim: u64,
    gross: u64,
): bool {
    is_redemption_gross_within_bound(self, proportional_claim, gross)
}
