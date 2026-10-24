// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Immutable core policy values and pure policy gates.
///
/// This slice selects no production value, authenticates no price source,
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
    target_leverage_bps: u64,
    rebalance_above_bps: u64,
    max_leverage_bps: u64,
    max_slippage_bps: u64,
    emergency_max_slippage_bps: u64,
    min_leverage_improvement_bps: u64,
}

/// The execution bound one venue order is priced and proved under, in basis
/// points of the reference price: the limit the adapter places the order at
/// sits inside it, and the fill must land inside it.
///
/// Only this module constructs one, from the policy's own bounds, so no
/// caller of a permissionless operation can choose the price it accepts.
public struct ExecutionBound has copy, drop {
    slippage_bps: u64,
}

/// Locally validated bounds for the price gates of one Vault.
///
/// Millisecond bounds use the on-chain clock scale. Relative bounds use the
/// package's 10,000 basis-point denominator. A future core transition will
/// verify the bound oracle source directly; the adapter owns venue observations.
/// Freshness and confidence gate each share-pricing source; mark divergence gates venue
/// margin safety only and never supplies shareholder-NAV or accounting inputs.
/// Every bound is inclusive, freshness arithmetic branches to avoid underflow,
/// and relative comparisons cross-multiply through `u128`.
///
/// This value cannot prove that observations came from the bound source or one
/// operation-scoped price pair. Those remain core and adapter obligations.
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
    /// Fee rates the Vault starts with; `State` holds the live, adjustable rates.
    initial_mint_fee_bps: u64,
    initial_redeem_fee_bps: u64,
    mint_fee_cap_bps: u64,
    redeem_fee_cap_bps: u64,
    admin_share_cap_bps: u64,
    min_order_lots: u64,
    /// Ceiling on the maintenance reserve as basis points of position notional.
    max_reserve_bps: u64,
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
    target_leverage_bps: u64,
    rebalance_above_bps: u64,
    max_leverage_bps: u64,
    max_slippage_bps: u64,
    emergency_max_slippage_bps: u64,
    min_leverage_improvement_bps: u64,
): RebalancePolicy {
    assert!(
        rebalance_below_bps < target_leverage_bps
            && target_leverage_bps < rebalance_above_bps
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
        target_leverage_bps,
        rebalance_above_bps,
        max_leverage_bps,
        max_slippage_bps,
        emergency_max_slippage_bps,
        min_leverage_improvement_bps,
    }
}

// --- Price Policy ---

/// Creates immutable price policy from proposed structural bounds.
///
/// `max_price_age_duration_ms` must be positive because the structural policy requires
/// a nonzero historical-age slippage. This check alone does not prove that a
/// selected value supports the deployed source cadence; that remains a live
/// integration and simulation gate. `max_price_ahead_duration_ms` may be zero; zero is
/// the strictest clock-skew policy and rejects the first millisecond after the
/// reference time. It must not exceed `max_price_age_duration_ms`: clock skew is never
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
public fun new_price_policy(
    max_price_age_duration_ms: u64,
    max_price_ahead_duration_ms: u64,
    max_confidence_bps: u64,
    max_mark_divergence_bps: u64,
): PricePolicy {
    assert!(
        max_price_age_duration_ms > 0,
        blast_boosts_core::errors::invalid_max_price_age!(),
    );
    assert!(
        max_price_ahead_duration_ms <= max_price_age_duration_ms,
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
        max_price_age_ms: max_price_age_duration_ms,
        max_price_ahead_ms: max_price_ahead_duration_ms,
        max_confidence_bps,
        max_mark_divergence_bps,
    }
}

// --- Vault Policy ---

/// Composes one complete immutable policy for one future Vault.
///
/// The initial fee rates seed the live `State` rates; each stays at or below
/// its cap, and both caps stay below 10,000 bps. `admin_share_cap_bps` bounds
/// the share of future collected fees the admin may take and may equal
/// 10,000; the Vault starts with an admin share of zero.
/// `min_order_lots` is at least two and at most `max_min_order_lots`.
/// Two only excludes the vacuous one-lot rounding bound; each product still
/// needs a simulated minimum for its band, seed and intended growth.
/// `max_reserve_bps` is positive and at most 10,000: the maintenance reserve
/// may hold at most that share of position notional, and every reserve
/// credit is clamped to it so the excess stays with holders as NAV.
/// The NAV cap is not part of the policy: it is a live `State` value the
/// admin may move, supplied to `state::issue` directly.
public fun new_vault_policy(
    side: PositionSide,
    rebalance_policy: RebalancePolicy,
    price_policy: PricePolicy,
    initial_mint_fee_bps: u64,
    initial_redeem_fee_bps: u64,
    mint_fee_cap_bps: u64,
    redeem_fee_cap_bps: u64,
    admin_share_cap_bps: u64,
    min_order_lots: u64,
    max_reserve_bps: u64,
): VaultPolicy {
    let bps = constants::basis_points_denominator!();
    assert!(
        initial_mint_fee_bps < bps && initial_redeem_fee_bps < bps,
        blast_boosts_core::errors::invalid_fee_bps!(),
    );
    assert!(
        initial_mint_fee_bps <= mint_fee_cap_bps && mint_fee_cap_bps < bps
            && initial_redeem_fee_bps <= redeem_fee_cap_bps && redeem_fee_cap_bps < bps
            && admin_share_cap_bps <= bps,
        blast_boosts_core::errors::fee_cap_exceeded!(),
    );
    assert!(
        min_order_lots >= 2
            && min_order_lots <= constants::max_min_order_lots!(),
        blast_boosts_core::errors::invalid_min_order_lots!(),
    );
    assert!(
        max_reserve_bps > 0 && max_reserve_bps <= constants::basis_points_denominator!(),
        blast_boosts_core::errors::invalid_max_reserve_bps!(),
    );

    VaultPolicy {
        side,
        rebalance_policy,
        price_policy,
        initial_mint_fee_bps,
        initial_redeem_fee_bps,
        mint_fee_cap_bps,
        redeem_fee_cap_bps,
        admin_share_cap_bps,
        min_order_lots,
        max_reserve_bps,
    }
}

// --- Execution Bound ---

/// The bound in basis points of the reference price.
public fun slippage_bps(self: &ExecutionBound): u64 {
    self.slippage_bps
}

/// The price limit an order under this bound is placed with: the reference
/// moved by the bound against the order, up for a bid and down for an ask,
/// then rounded to a multiple of `tick_size` back toward the reference.
///
/// The limit always stays inside the bound, so a venue that honors it cannot
/// fill outside the bound, and the fill proof against the same reference
/// cannot then fail on price. A tick wider than the bound leaves no such
/// price and aborts; a zero reference or tick aborts first.
public fun limit_price(self: &ExecutionBound, reference_price: u64, is_ask: bool, tick_size: u64): u64 {
    assert!(reference_price > 0, blast_boosts_core::errors::invalid_price!());
    assert!(tick_size > 0, blast_boosts_core::errors::invalid_tick_size!());

    let denominator = constants::basis_points_denominator!() as u128;
    let (reference, slippage, tick) = (reference_price as u128, self.slippage_bps as u128, tick_size as u128);
    let limit = if (is_ask) {
        (reference * (denominator - slippage)).div_ceil(denominator).div_ceil(tick) * tick
    } else {
        reference * (denominator + slippage) / denominator / tick * tick
    };
    assert!(limit <= std::u64::max_value!() as u128, blast_boosts_core::errors::arithmetic_overflow!());
    assert!(
        is_within_relative_tolerance(self.slippage_bps, reference_price, limit as u64),
        blast_boosts_core::errors::execution_outside_max_slippage!(),
    );

    limit as u64
}

/// Rejects a price outside this bound of the reference; a zero reference
/// price aborts first. Inclusive:
/// `|executed_price - reference_price| * 10_000 <= slippage_bps * reference_price`.
public fun assert_execution(self: &ExecutionBound, reference_price: u64, executed_price: u64) {
    assert!(reference_price > 0, blast_boosts_core::errors::invalid_price!());
    assert!(
        is_within_relative_tolerance(self.slippage_bps, reference_price, executed_price),
        blast_boosts_core::errors::execution_outside_max_slippage!(),
    );
}

// === Package Functions ===

/// Configuration budget at the hard cap, assuming fully realized and allocated
/// equity and no reserve credit. Charge full-notional emergency execution costs,
/// discount the remaining cash by the live haircut, and allow adverse mark PnL
/// and the highest admitted mark requirement simultaneously. This conditional
/// opening cushion does not gate later recovery or guarantee future margin.
public(package) fun assert_initial_margin_headroom(
    self: &VaultPolicy,
    initial_margin_bps: u64,
    collateral_haircut_bps: u64,
    venue_fee_bps: u64,
) {
    let b = constants::basis_points_denominator!() as u128;
    assert!(
        initial_margin_bps > 0 && initial_margin_bps <= b as u64
            && collateral_haircut_bps < b as u64 && venue_fee_bps <= b as u64,
        blast_boosts_core::errors::initial_margin_headroom!(),
    );
    let leverage = self.rebalance_policy.max_leverage_bps as u128;
    let slippage = self.rebalance_policy.emergency_max_slippage_bps as u128;
    let divergence = self.price_policy.max_mark_divergence_bps as u128;
    let cost_bps = slippage + ((b + slippage) * (venue_fee_bps as u128)).div_ceil(b);
    let cost_at_cap = leverage * cost_bps;
    assert!(cost_at_cap < b * b, blast_boosts_core::errors::initial_margin_headroom!());

    let cash_margin = (b * b - cost_at_cap) * (b - (collateral_haircut_bps as u128));
    let mark_loss = leverage * divergence * b;
    let requirement = leverage * (b + divergence) * (initial_margin_bps as u128);
    assert!(cash_margin > mark_loss + requirement, blast_boosts_core::errors::initial_margin_headroom!());
}

// --- Rebalance Policy ---

public(package) fun target_leverage_bps(self: &RebalancePolicy): u64 {
    self.target_leverage_bps
}

public(package) fun max_leverage_bps(self: &RebalancePolicy): u64 {
    self.max_leverage_bps
}

public(package) fun max_slippage_bps(self: &RebalancePolicy): u64 {
    self.max_slippage_bps
}

public(package) fun min_leverage_improvement_bps(self: &RebalancePolicy): u64 {
    self.min_leverage_improvement_bps
}

/// Returns whether leverage is strictly below the public rebalance band.
///
/// `notional` and `nav` are atomic collateral units. Leverage is
/// `notional / nav`, compared cross-multiplied so no ratio is ever rounded:
/// `notional * 10_000 < nav * rebalance_below_bps`. The band edge itself is
/// healthy, so equality returns false. A zero threshold disables this trigger.
public(package) fun is_leverage_below_band(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    scale_by_denominator(notional) < (nav as u128) * (self.rebalance_below_bps as u128)
}

/// Returns whether leverage lies inside the public rebalance band, edges included.
///
/// Same units and exact comparison as `is_leverage_below_band`.
public(package) fun is_leverage_within_band(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    !self.is_leverage_below_band(notional, nav) && !self.is_leverage_above_band(notional, nav)
}

/// Returns whether leverage is at or below target: `notional * 10_000 <= nav * target_leverage_bps`.
public(package) fun is_leverage_at_most_target(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    scale_by_denominator(notional) <= (nav as u128) * (self.target_leverage_bps as u128)
}

/// Returns whether leverage is strictly below the hard cap: `notional * 10_000 < nav * max_leverage_bps`.
public(package) fun is_leverage_below_max(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    scale_by_denominator(notional) < (nav as u128) * (self.max_leverage_bps as u128)
}

/// Returns whether leverage is strictly above the hard cap that permits wider slippage.
///
/// Same units and exact comparison as `is_leverage_below_band`:
/// `notional * 10_000 > nav * max_leverage_bps`.
public(package) fun is_leverage_above_max(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    scale_by_denominator(notional) > (nav as u128) * (self.max_leverage_bps as u128)
}

/// The bound an order runs under: the emergency one for a reduction placed
/// while leverage is above the hard cap, otherwise the ordinary one. Risk
/// increase and every ordinary rebalance, mint and redemption use the ordinary
/// bound. The finite wider bound does not guarantee executable liquidity or
/// successful deleveraging.
public(package) fun execution_bound(self: &RebalancePolicy, emergency: bool): ExecutionBound {
    ExecutionBound {
        slippage_bps: if (emergency) { self.emergency_max_slippage_bps } else { self.max_slippage_bps },
    }
}

/// The close-only bound `elapsed_duration_ms` after shutdown began: the
/// ordinary bound at first, widening linearly, rounded down to whole basis
/// points, to the emergency bound at `unwind_bound_widening_duration_ms`,
/// where it stays. A caller cannot bring the wide bound forward; only time does.
public(package) fun unwind_execution_bound(self: &RebalancePolicy, elapsed_duration_ms: u64): ExecutionBound {
    let widening_duration_ms = constants::unwind_bound_widening_duration_ms!();
    let elapsed = elapsed_duration_ms.min(widening_duration_ms) as u128;
    // The constructor guarantees the emergency bound is at least the ordinary one.
    let width = (self.emergency_max_slippage_bps - self.max_slippage_bps) as u128;
    let widened = (width * elapsed / (widening_duration_ms as u128)) as u64;

    ExecutionBound { slippage_bps: self.max_slippage_bps + widened }
}

/// Rejects a NAV cap that is zero or so large that
/// `nav_cap * max_leverage_bps / 10_000` overflows `u64`; without that ceiling
/// a Vault at the cap could not compute a target notional and rebalance.
public(package) fun assert_nav_cap_valid(self: &RebalancePolicy, nav_cap: u64) {
    assert!(
        nav_cap > 0
            && (nav_cap as u128) * (self.max_leverage_bps as u128)
                <= (std::u64::max_value!() as u128)
                    * (constants::basis_points_denominator!() as u128),
        blast_boosts_core::errors::invalid_nav_cap!(),
    );
}

/// Necessary configuration bound: even cost-free cap-sized orders must cover
/// the minimum at the deposit ceiling. Live costs, lots and NAV are handled
/// by the core's full-batch completion rule; this is not a liquidity promise.
public(package) fun assert_rebalance_capacity(self: &RebalancePolicy, max_order_notional: u64, nav_cap: u64) {
    assert!(
        (self.min_leverage_improvement_bps as u256) * (nav_cap as u256)
            <= (constants::max_rebalance_orders!() as u256) * (max_order_notional as u256)
                * (constants::basis_points_denominator!() as u256),
        blast_boosts_core::errors::rebalance_capacity!(),
    );
}

/// Rejects a source update outside the two-sided freshness window.
///
/// `price_published_at_ms` is the source's own update time and `now_at_ms` is
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
    price_published_at_ms: u64,
    now_at_ms: u64,
) {
    let fresh = self.is_price_fresh(price_published_at_ms, now_at_ms);

    if (price_published_at_ms > now_at_ms) {
        assert!(fresh, blast_boosts_core::errors::future_price!());
    } else {
        assert!(fresh, blast_boosts_core::errors::stale_price!());
    };
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
public(package) fun assert_confidence_within_bound(
    self: &PricePolicy,
    confidence: u64,
    price: u64,
) {
    assert!(
        price > 0,
        blast_boosts_core::errors::invalid_price!(),
    );
    assert!(
        self.is_confidence_within_bound(confidence, price),
        blast_boosts_core::errors::confidence_exceeds_bound!(),
    );
}

/// Rejects a venue mark that diverges too far from the base oracle.
///
/// The gate is `|mark - oracle| * 10_000 <= max_mark_divergence_bps * oracle`,
/// so it holds exactly when the absolute difference is at most
/// `floor(max_mark_divergence_bps * oracle / 10_000)`. The bound is symmetric:
/// a mark above and a mark below the oracle price are limited by the same fraction of
/// the oracle price.
///
/// This is a venue margin-safety gate. Its result never prices shares, never
/// enters shareholder NAV, and never sizes position; ADR 0064 I25 keeps the
/// base-and-collateral oracle pair as the only share-pricing price. A zero oracle price
/// is rejected before the bound is read, and a zero mark against a positive
/// oracle price is always rejected because the constructor keeps
/// `max_mark_divergence_bps` below 10,000.
public(package) fun assert_mark_within_oracle_divergence(
    self: &PricePolicy,
    mark_price: u64,
    oracle_price: u64,
) {
    assert!(
        oracle_price > 0,
        blast_boosts_core::errors::invalid_price!(),
    );
    assert!(
        self.is_mark_within_oracle_divergence(mark_price, oracle_price),
        blast_boosts_core::errors::mark_oracle_divergence_exceeds_bound!(),
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

/// Returns the issuance mint fee rate in basis points.
public(package) fun initial_mint_fee_bps(self: &VaultPolicy): u64 {
    self.initial_mint_fee_bps
}

/// Returns the issuance redemption fee rate in basis points.
public(package) fun initial_redeem_fee_bps(self: &VaultPolicy): u64 {
    self.initial_redeem_fee_bps
}

/// Returns the minimum proportional order in live venue lots.
public(package) fun min_order_lots(self: &VaultPolicy): u64 {
    self.min_order_lots
}

/// Returns the largest maintenance reserve the policy admits against `notional`.
///
/// Both values are atomic collateral units. Rounds down, so a reserve exactly
/// at the ceiling is admitted and one atom more is released to NAV.
public(package) fun reserve_cap(self: &VaultPolicy, notional: u64): u64 {
    notional.mul_div(self.max_reserve_bps, constants::basis_points_denominator!())
}

public(package) fun assert_fee_limits(
    self: &VaultPolicy,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    admin_share_bps: u64,
) {
    assert!(
        mint_fee_bps <= self.mint_fee_cap_bps
            && redeem_fee_bps <= self.redeem_fee_cap_bps
            && admin_share_bps <= self.admin_share_cap_bps,
        blast_boosts_core::errors::fee_cap_exceeded!(),
    );
}

// === Private Functions ===

/// Returns whether leverage is strictly above the public rebalance band.
///
/// Same units and exact comparison as `is_leverage_below_band`:
/// `notional * 10_000 > nav * rebalance_above_bps`. Equality is healthy.
fun is_leverage_above_band(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    scale_by_denominator(notional) > (nav as u128) * (self.rebalance_above_bps as u128)
}

// --- Price Policy ---

/// Returns whether a source update lies inside the two-sided freshness window.
///
/// The admitted window is the closed interval
/// `[now_at_ms - self.max_price_age_ms, now_at_ms + self.max_price_ahead_ms]`.
/// Unlike `assert_price_fresh`, this predicate never aborts: health may report
/// a stale or future-stamped source without changing lifecycle.
fun is_price_fresh(
    self: &PricePolicy,
    price_published_at_ms: u64,
    now_at_ms: u64,
): bool {
    if (price_published_at_ms > now_at_ms) {
        price_published_at_ms - now_at_ms <= self.max_price_ahead_ms
    } else {
        now_at_ms - price_published_at_ms <= self.max_price_age_ms
    }
}

/// Returns whether a positive share-pricing price has an admitted confidence.
///
/// A zero price returns false instead of aborting so the future objective
/// health check can report the failure without changing lifecycle.
/// `assert_confidence_within_bound` remains the priced-operation guard that
/// reports a zero price separately from an excessive confidence interval.
fun is_confidence_within_bound(
    self: &PricePolicy,
    confidence: u64,
    price: u64,
): bool {
    price > 0
        && (confidence as u128) * (constants::basis_points_denominator!() as u128)
            <= (self.max_confidence_bps as u128) * (price as u128)
}

/// Returns whether a venue mark is inside the admitted base-oracle band.
///
/// A zero oracle price returns false instead of aborting so the future objective
/// health check can report invalid data. The mark may be zero
/// at the type level, but every valid policy rejects it against a positive
/// oracle price because the divergence bound stays below 10,000 basis points.
fun is_mark_within_oracle_divergence(
    self: &PricePolicy,
    mark_price: u64,
    oracle_price: u64,
): bool {
    oracle_price > 0
        && (mark_price.diff(oracle_price) as u128)
            * (constants::basis_points_denominator!() as u128)
            <= (self.max_mark_divergence_bps as u128) * (oracle_price as u128)
}

/// Widens a notional and multiplies it by the basis-point denominator.
///
/// Every leverage comparison in this module cross-multiplies rather than
/// divides, so the notional side always carries the denominator.
fun scale_by_denominator(notional: u64): u128 {
    (notional as u128) * (constants::basis_points_denominator!() as u128)
}

/// Returns whether `executed_price` is within `slippage_bps` of a positive `reference_price`.
///
/// Both values share one unit and scale; the gate is
/// `|executed_price - reference_price| * 10_000 <= slippage_bps * reference_price`,
/// cross-multiplied through `u128`. A zero reference price returns false.
fun is_within_relative_tolerance(
    slippage_bps: u64,
    reference_price: u64,
    executed_price: u64,
): bool {
    reference_price > 0
        && (executed_price.diff(reference_price) as u128)
            * (constants::basis_points_denominator!() as u128)
            <= (slippage_bps as u128) * (reference_price as u128)
}

// === Test-Only Functions ===

#[test_only]
public fun rebalance_below_bps(self: &RebalancePolicy): u64 {
    self.rebalance_below_bps
}

#[test_only]
public fun rebalance_above_bps(self: &RebalancePolicy): u64 {
    self.rebalance_above_bps
}

#[test_only]
public fun emergency_max_slippage_bps(self: &RebalancePolicy): u64 {
    self.emergency_max_slippage_bps
}

#[test_only]
/// Returns the oldest admitted source update age in milliseconds.
public fun max_price_age_ms(self: &PricePolicy): u64 {
    self.max_price_age_ms
}

#[test_only]
/// Returns the admitted forward clock skew in milliseconds.
public fun max_price_ahead_ms(self: &PricePolicy): u64 {
    self.max_price_ahead_ms
}

#[test_only]
/// Returns the admitted confidence interval as basis points of the price.
public fun max_confidence_bps(self: &PricePolicy): u64 {
    self.max_confidence_bps
}

#[test_only]
/// Returns the admitted mark divergence as basis points of the oracle price.
public fun max_mark_divergence_bps(self: &PricePolicy): u64 {
    self.max_mark_divergence_bps
}

#[test_only]
/// Returns the reserve ceiling as basis points of position notional.
public fun max_reserve_bps(self: &VaultPolicy): u64 {
    self.max_reserve_bps
}

#[test_only]
/// Exposes issuance fee rates to the test event reducer without widening production ABI.
public fun initial_fee_rates_for_testing(self: &VaultPolicy): (u64, u64) {
    (self.initial_mint_fee_bps, self.initial_redeem_fee_bps)
}

#[test_only]
public fun is_leverage_above_band_for_testing(self: &RebalancePolicy, notional: u64, nav: u64): bool {
    self.is_leverage_above_band(notional, nav)
}

#[test_only]
public fun is_within_for_testing(self: &ExecutionBound, reference_price: u64, executed_price: u64): bool {
    is_within_relative_tolerance(self.slippage_bps, reference_price, executed_price)
}

#[test_only]
public fun is_price_fresh_for_testing(self: &PricePolicy, price_published_at_ms: u64, now_at_ms: u64): bool {
    self.is_price_fresh(price_published_at_ms, now_at_ms)
}

#[test_only]
public fun is_confidence_within_bound_for_testing(self: &PricePolicy, confidence: u64, price: u64): bool {
    self.is_confidence_within_bound(confidence, price)
}

#[test_only]
public fun is_mark_within_oracle_divergence_for_testing(self: &PricePolicy, mark_price: u64, oracle_price: u64): bool {
    self.is_mark_within_oracle_divergence(mark_price, oracle_price)
}

// === Imports ===

use blast_boosts_core::constants;
