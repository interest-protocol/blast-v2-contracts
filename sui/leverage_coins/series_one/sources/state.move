// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Venue-neutral state for one Series1 leveraged product.
///
/// The selected adapter stores this value inside its own shared Vault. Only
/// functions in this module can inspect or change the private Series1 fields.
/// Currency, venue custody, ACL routing, and versioning belong to the adapter.
module blast_leverage_series_one::state;

use blast_admin::acl::AdminWitness;
use blast_leverage_series_one::{
    accounting_math,
    bounded_value::{Self, BoundedValue},
    constants,
    lifecycle::{Self, Lifecycle},
    observation::{Self, FundingSettlement, PositionObservation},
    policy::{PositionSide, TierPolicy},
    rebalance_math,
    series_one_domain::{Self, SERIES_ONE_DOMAIN},
};

// === Constants ===

/// Bounds per-transaction maintenance planning independently of adapter work limits.
const MAX_REBALANCE_ORDERS: u64 = 16;

// === Public Types ===

/// Sealed Series1 state stored inside one adapter-owned Vault.
///
/// The value can be stored but cannot be copied or dropped. `Product`
/// separates independent leveraged products at the type level.
public struct State<phantom Product> has store {
    tier_policy: TierPolicy,
    max_order_notional: BoundedValue,
    maintenance_reserve: u64,
    lifecycle: Lifecycle,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    admin_allocation_bps: u64,
}

/// Linear, transaction-local mint terms. Only State can construct or finish them.
public struct MintPlan<phantom Product> {
    before: ActivePosition,
    reserve_before: u64,
    deposit: u64,
    expected_contribution: u64,
    buffer_fee: u64,
    admin_fee: u64,
    fee_bps: u64,
    admin_bps: u64,
    supply: u64,
    minimum_shares: u64,
    order_base: u64,
}

/// Linear terms for one proportional redemption, before any payout or fee credit.
public struct RedemptionPlan<phantom Product> {
    before: ActivePosition,
    reserve_before: u64,
    shares: u64,
    supply: u64,
    minimum_output: u64,
    fee_bps: u64,
    admin_bps: u64,
    order_base: u64,
}

/// Prevalidated funding donation terms held across the adapter deposit.
public struct DonationPlan<phantom Product> {
    before: ActivePosition,
    reserve_before: u64,
    amount: u64,
}

/// Validated values at one canonical pair; never persisted as a second ledger.
public struct ActivePosition has copy, drop {
    equity: u64,
    base: u64,
    notional: u64,
    lot: u64,
    base_price: u64,
    collateral_price: u64,
}

/// Linear maintenance intent, recalculated only from accepted fixed-pair sessions.
public struct RebalancePlan<phantom Product> {
    before: ActivePosition,
    current: ActivePosition,
    reserve: u64,
    increase: bool,
    venue_fee_bps: u64,
    steps: u64,
}

// === Public Functions ===

/// Derives public maintenance intent from exact outside-band ratios, never caller orders.
public fun prepare_rebalance<Product>(
    self: &State<Product>, observation: PositionObservation, venue_fee_bps: u64, now: u64,
): RebalancePlan<Product> {
    self.lifecycle.assert_active();
    assert!(venue_fee_bps <= 10_000, blast_leverage_series_one::errors::venue_fee_unusable!());
    let before = validated_active_position(self, observation, now);
    let nav = accounting_math::shareholder_nav(before.equity, self.maintenance_reserve);
    let risk = self.tier_policy.rebalance_policy();
    let scaled = (before.notional as u128) * 10_000;
    let increase = scaled < (nav as u128) * (risk.public_lower_bps() as u128);
    assert!(increase || scaled > (nav as u128) * (risk.public_upper_bps() as u128),
        blast_leverage_series_one::errors::rebalance_inside_public_band!());
    RebalancePlan { before, current: before, reserve: self.maintenance_reserve, increase, venue_fee_bps, steps: 0 }
}

/// Returns next whole-lot size, increase intent and current wider-tolerance permission.
/// A zero size finishes planning; the adapter independently caps work at sixteen sessions.
public fun rebalance_order<Product>(self: &State<Product>, plan: &RebalancePlan<Product>): (u64, bool, bool) {
    self.lifecycle.assert_active();
    assert!(self.maintenance_reserve == plan.reserve, blast_leverage_series_one::errors::active_checkpoint_changed!());
    let p = &plan.current;
    let nav = accounting_math::shareholder_nav(p.equity, plan.reserve);
    let risk = self.tier_policy.rebalance_policy();
    if (plan.steps == MAX_REBALANCE_ORDERS) { return (0, plan.increase, false) };
    if (plan.increase) {
        (rebalance_math::increase_base_down(nav, p.notional, risk.target_bps(), p.base_price,
            p.collateral_price, p.lot, self.max_order_notional.current(), plan.venue_fee_bps,
            risk.strict_tolerance_bps()), true, false)
    } else {
        let target_notional = (nav as u128) * (risk.target_bps() as u128) / 10_000;
        assert!(target_notional <= std::u64::max_value!() as u128, blast_leverage_series_one::errors::arithmetic_overflow!());
        let target_base = rebalance_math::base_for_notional_down(target_notional as u64, p.base_price, p.collateral_price, p.lot);
        let cap_base = rebalance_math::base_for_notional_down(self.max_order_notional.current(), p.base_price, p.collateral_price, p.lot);
        let base = if (p.base > target_base) { (p.base - target_base).min(cap_base) / p.lot * p.lot } else { 0 };
        (base, false, (p.notional as u128) * 10_000 > (nav as u128) * (risk.hard_cap_bps() as u128))
    }
}

/// Fixed valuation terms for the venue adapter's execution and checkpoint proofs.
public fun rebalance_valuation<Product>(self: &RebalancePlan<Product>): (u64, u64, u64) {
    (self.before.base_price, self.before.collateral_price, self.before.lot)
}

/// The current authenticated ratio alone selects ordinary or wider execution tolerance.
public fun assert_rebalance_execution<Product>(self: &State<Product>, plan: &RebalancePlan<Product>, reference: u64, executed: u64) {
    let (_, _, wide) = self.rebalance_order(plan);
    let risk = self.tier_policy.rebalance_policy();
    if (wide) { risk.assert_execution_within_emergency_tolerance(reference, executed); }
    else { risk.assert_execution_within_strict_tolerance(reference, executed); };
}

/// Advances only exact partial whole-lot fills under sealed intent and the fixed oracle pair.
public fun accept_rebalance_fill<Product>(
    self: &State<Product>, plan: &mut RebalancePlan<Product>, observation: PositionObservation, filled: u64, now: u64,
) {
    let (requested, increase, _) = self.rebalance_order(plan);
    assert!(filled > 0 && filled <= requested && filled % plan.current.lot == 0,
        blast_leverage_series_one::errors::active_fill_incomplete!());
    let after = validated_active_position(self, observation, now);
    assert!(after.base_price == plan.before.base_price && after.collateral_price == plan.before.collateral_price
        && after.lot == plan.before.lot, blast_leverage_series_one::errors::active_checkpoint_changed!());
    let expected_base = if (increase) { plan.current.base.checked_add(filled).destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!()) } else { plan.current.base - filled };
    assert!(after.base == expected_base, blast_leverage_series_one::errors::active_fill_incomplete!());
    if (increase) {
        let nav = accounting_math::shareholder_nav(after.equity, plan.reserve);
        let risk = self.tier_policy.rebalance_policy();
        assert!((after.notional as u128) * 10_000 <= (nav as u128) * (risk.target_bps() as u128)
            && (after.notional as u128) * 10_000 < (nav as u128) * (risk.hard_cap_bps() as u128),
            blast_leverage_series_one::errors::active_leverage_above_cap!());
    };
    plan.current = after;
    plan.steps = plan.steps + 1;
}

/// Completes holder-funded maintenance without changing reserve, supply or admin cash.
/// Returns authenticated before/after equity and base for one completed event.
public fun complete_rebalance<Product>(self: &State<Product>, plan: RebalancePlan<Product>): (u64, u64, u64, u64, bool) {
    self.lifecycle.assert_active();
    let RebalancePlan { before, current, reserve, increase, venue_fee_bps: _, steps } = plan;
    assert!(reserve == self.maintenance_reserve, blast_leverage_series_one::errors::active_checkpoint_changed!());
    assert!(steps > 0, blast_leverage_series_one::errors::rebalance_no_progress!());
    let before_nav = accounting_math::shareholder_nav(before.equity, reserve);
    let after_nav = accounting_math::shareholder_nav(current.equity, reserve);
    let risk = self.tier_policy.rebalance_policy();
    let improved = if (increase) {
        current.base > before.base && (current.notional as u128) * (before_nav as u128) > (before.notional as u128) * (after_nav as u128)
    } else {
        current.base < before.base && rebalance_math::reduction_is_sufficient(before.notional, before_nav,
            current.notional, after_nav, risk.target_bps(), risk.minimum_improvement_bps(),
            rebalance_math::index_notional_up(current.lot, current.base_price, current.collateral_price))
    };
    assert!(improved, blast_leverage_series_one::errors::rebalance_no_progress!());
    (before.equity, current.equity, before.base, current.base, increase)
}

/// Creates one validated, uninitialized Series1 state value.
///
/// The adapter must store the returned value inside its Vault. The caller's
/// live admin witness must contain the Vault issuer role.
public fun new<Product>(
    admin_witness: &AdminWitness<SERIES_ONE_DOMAIN>,
    tier_policy: TierPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
): State<Product> {
    admin_witness.assert_role(series_one_domain::vault_issuer_role());
    assert!(
        max_order_notional_minimum > 0,
        blast_leverage_series_one::errors::invalid_max_order_notional!(),
    );

    State {
        mint_fee_bps: tier_policy.mint_fee_bps(),
        redeem_fee_bps: tier_policy.redeem_fee_bps(),
        admin_allocation_bps: tier_policy.initial_admin_allocation_bps(),
        tier_policy,
        max_order_notional: bounded_value::new(
            max_order_notional_minimum,
            max_order_notional_current,
            max_order_notional_maximum,
        ),
        maintenance_reserve: 0,
        lifecycle: lifecycle::new(),
    }
}

/// Updates future fee collections under immutable issuance caps.
/// Adapter custody owns authentication; no assets or past allocations move.
public fun set_fees<Product>(
    self: &mut State<Product>,
    mint_bps: u64,
    redeem_bps: u64,
    admin_bps: u64,
): (u64, u64, u64) {
    assert!(
        self.lifecycle.is_uninitialized() || self.lifecycle.is_active(),
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
    );
    self.tier_policy.assert_fee_limits(mint_bps, redeem_bps, admin_bps);
    let previous_mint = self.mint_fee_bps;
    let previous_redeem = self.redeem_fee_bps;
    let previous_admin = self.admin_allocation_bps;
    assert!(
        self.mint_fee_bps != mint_bps || self.redeem_fee_bps != redeem_bps
            || self.admin_allocation_bps != admin_bps,
        blast_leverage_series_one::errors::fee_settings_unchanged!(),
    );
    self.mint_fee_bps = mint_bps;
    self.redeem_fee_bps = redeem_bps;
    self.admin_allocation_bps = admin_bps;
    (previous_mint, previous_redeem, previous_admin)
}

/// Returns fee, local admin allocation, and buffer allocation in collateral atoms.
/// The fee rounds up, admin share rounds down, and buffer receives the remainder.
public fun fee_allocation<Product>(self: &State<Product>, amount: u64, mint: bool): (u64, u64, u64) {
    accounting_math::fee_allocation(
        amount,
        if (mint) { self.mint_fee_bps } else { self.redeem_fee_bps },
        self.admin_allocation_bps,
    )
}

/// Reads the currently applied rates without changing historical allocations.
public fun fee_settings<Product>(self: &State<Product>): (u64, u64, u64) {
    (self.mint_fee_bps, self.redeem_fee_bps, self.admin_allocation_bps)
}

/// Checks a user's fee ceiling before the adapter interacts with the venue.
public fun assert_user_fee_limit<Product>(self: &State<Product>, mint: bool, maximum: u64) {
    assert!((if (mint) { self.mint_fee_bps } else { self.redeem_fee_bps }) <= maximum,
        blast_leverage_series_one::errors::user_fee_limit_exceeded!());
}

/// Seals a proportional increase from reserve-excluded NAV and the user's limits.
/// The adapter must authenticate the observation and native share supply.
public fun prepare_mint<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    deposit: u64,
    supply: u64,
    minimum_shares: u64,
    maximum_fee_bps: u64,
    reference_time_ms: u64,
): MintPlan<Product> {
    self.lifecycle.assert_active();
    assert!(supply > 0, blast_leverage_series_one::errors::invalid_share_supply!());
    assert!(self.mint_fee_bps <= maximum_fee_bps, blast_leverage_series_one::errors::user_fee_limit_exceeded!());
    let before = validated_active_position(self, observation, reference_time_ms);
    let nav = accounting_math::shareholder_nav(before.equity, self.maintenance_reserve);
    let risk = self.tier_policy.rebalance_policy();
    let scaled = (before.notional as u128) * 10_000;
    assert!(
        scaled >= (nav as u128) * (risk.public_lower_bps() as u128)
            && scaled <= (nav as u128) * (risk.public_upper_bps() as u128),
        blast_leverage_series_one::errors::mint_outside_public_band!(),
    );
    let (fee, admin_fee, buffer_fee) = self.fee_allocation(deposit, true);
    let expected_contribution = deposit - fee;
    assert!(expected_contribution > 0, blast_leverage_series_one::errors::nonpositive_contribution!());
    let order_base = accounting_math::mint_base_delta_from_equity_down(
        expected_contribution, before.base, before.equity, self.maintenance_reserve,
        before.lot, self.tier_policy.min_exposure_lots(),
    );
    MintPlan {
        before,
        reserve_before: self.maintenance_reserve,
        deposit,
        expected_contribution,
        buffer_fee,
        admin_fee,
        fee_bps: self.mint_fee_bps,
        admin_bps: self.admin_allocation_bps,
        supply,
        minimum_shares,
        order_base,
    }
}

/// Returns the entire required whole-lot increase, not caller-selected sizing.
public fun order_base<Product>(self: &MintPlan<Product>): u64 { self.order_base }

/// Returns the admin cash the adapter must retain before depositing collateral.
public fun admin_fee<Product>(self: &MintPlan<Product>): u64 { self.admin_fee }

/// Returns the sealed input for completed adapter accounting facts.
public fun mint_deposit<Product>(self: &MintPlan<Product>): u64 { self.deposit }

/// Copies the sealed valuation pair and venue lot used to size this mint.
public fun mint_valuation<Product>(self: &MintPlan<Product>): (u64, u64, u64) {
    (self.before.base_price, self.before.collateral_price, self.before.lot)
}

/// Returns policy-derived direction and the current per-order cap while active.
public fun active_constraints<Product>(self: &State<Product>): (PositionSide, u64) {
    self.lifecycle.assert_active();
    (self.tier_policy.side(), self.max_order_notional.current())
}

/// Applies strict tolerance to ordinary active mint and redemption sessions.
public fun assert_active_execution<Product>(self: &State<Product>, reference: u64, executed: u64) {
    self.lifecycle.assert_active();
    self.tier_policy.rebalance_policy().assert_execution_within_strict_tolerance(reference, executed);
}

/// Consumes an intermediate active observation at the operation's fixed valuation pair.
public fun assert_active_observation<Product>(
    self: &State<Product>, observation: PositionObservation, base_price: u64, collateral_price: u64, now: u64,
) {
    self.lifecycle.assert_active();
    let position = validated_active_position(self, observation, now);
    assert!(position.base_price == base_price && position.collateral_price == collateral_price,
        blast_leverage_series_one::errors::active_checkpoint_changed!());
}

/// Completes a full proportional fill and credits only its buffer allocation.
/// The returned shares are minted through the adapter's native share authority.
/// Returns shares, contribution, fee, admin, buffer and the two sealed rates.
public fun complete_mint<Product>(
    self: &mut State<Product>,
    plan: MintPlan<Product>,
    observation: PositionObservation,
    reference_time_ms: u64,
): (u64, u64, u64, u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let MintPlan {
        before, reserve_before, deposit, expected_contribution, buffer_fee,
        admin_fee, fee_bps, admin_bps, supply, minimum_shares, order_base,
    } = plan;
    assert!(self.maintenance_reserve == reserve_before, blast_leverage_series_one::errors::active_checkpoint_changed!());
    let after = validated_active_position(self, observation, reference_time_ms);
    assert!(
        before.base_price == after.base_price && before.collateral_price == after.collateral_price
            && before.lot == after.lot,
        blast_leverage_series_one::errors::active_checkpoint_changed!(),
    );
    assert!(
        after.base >= before.base && after.base - before.base == order_base,
        blast_leverage_series_one::errors::active_fill_incomplete!(),
    );
    let reserve_after = reserve_before.checked_add(buffer_fee)
        .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!());
    let (nav_after, contribution, shares) = accounting_math::allocated_mint_quote(
        before.equity, after.equity, reserve_before, reserve_after, supply, minimum_shares,
    );
    self.tier_policy.assert_mint_contribution_within_bound(deposit, contribution);
    accounting_math::assert_mint_base_within_bounds_from_equity(
        after.base, expected_contribution, contribution, before.base, before.equity,
        reserve_before, before.lot, self.tier_policy.min_exposure_lots(),
    );
    self.tier_policy.assert_within_nav_cap(nav_after);
    assert!(
        accounting_math::is_accounting_leverage_below_limit(
            after.notional, after.equity, reserve_after,
            self.tier_policy.rebalance_policy().hard_cap_bps(),
        ),
        blast_leverage_series_one::errors::active_leverage_above_cap!(),
    );
    self.maintenance_reserve = reserve_after;
    (shares, contribution, admin_fee + buffer_fee, admin_fee, buffer_fee, fee_bps, admin_bps)
}

/// Seals a rounded-up attributable close and the redeemer's output/fee limits.
public fun prepare_redemption<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    shares: u64,
    supply: u64,
    minimum_output: u64,
    maximum_fee_bps: u64,
    reference_time_ms: u64,
): RedemptionPlan<Product> {
    self.lifecycle.assert_active();
    assert!(self.redeem_fee_bps <= maximum_fee_bps, blast_leverage_series_one::errors::user_fee_limit_exceeded!());
    let before = validated_active_position(self, observation, reference_time_ms);
    let (minimum_base, _) = accounting_math::redemption_base_bounds(
        shares, before.base, supply, before.lot, self.tier_policy.min_exposure_lots(),
    );
    let order_base = before.base - minimum_base;
    RedemptionPlan {
        before, reserve_before: self.maintenance_reserve, shares, supply, minimum_output,
        fee_bps: self.redeem_fee_bps, admin_bps: self.admin_allocation_bps, order_base,
    }
}

/// Returns the full reduce-only order amount; flat redemptions require no order.
public fun redemption_order_base<Product>(self: &RedemptionPlan<Product>): u64 { self.order_base }

/// Copies the fixed valuation and lot used by the attributable close.
public fun redemption_valuation<Product>(self: &RedemptionPlan<Product>): (u64, u64, u64) {
    (self.before.base_price, self.before.collateral_price, self.before.lot)
}

/// Returns sealed burn, final exposure, valuation and applied rates for a cash receipt.
public fun redemption_terms<Product>(self: &RedemptionPlan<Product>): (u64, u64, u64, u64, u64, u64) {
    (self.shares, self.before.base - self.order_base, self.before.base_price,
        self.before.collateral_price, self.fee_bps, self.admin_bps)
}

/// Validates actual post-withdrawal backing and margin before a native share burn.
public fun assert_redemption_cash_out<Product>(
    self: &State<Product>, observation: PositionObservation, equity: u64, base: u64,
    base_price: u64, collateral_price: u64, now: u64,
) {
    self.lifecycle.assert_active();
    let after = validated_active_position(self, observation, now);
    assert!(after.equity == equity && after.base == base && after.base_price == base_price
        && after.collateral_price == collateral_price,
        blast_leverage_series_one::errors::active_checkpoint_changed!());
}

/// Computes payout after unwind and credits the fee once, excluding admin cash.
/// Returns user payout, locally retained admin cash, and required final venue equity.
/// The adapter must withdraw exactly their sum and prove the final cash checkpoint.
public fun complete_redemption<Product>(
    self: &mut State<Product>,
    plan: RedemptionPlan<Product>,
    observation: PositionObservation,
    reference_time_ms: u64,
): (u64, u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let RedemptionPlan {
        before, reserve_before, shares, supply, minimum_output, fee_bps, admin_bps, order_base,
    } = plan;
    assert!(self.maintenance_reserve == reserve_before, blast_leverage_series_one::errors::active_checkpoint_changed!());
    let after = validated_active_position(self, observation, reference_time_ms);
    assert!(
        before.base_price == after.base_price && before.collateral_price == after.collateral_price
            && before.lot == after.lot,
        blast_leverage_series_one::errors::active_checkpoint_changed!(),
    );
    assert!(
        before.base >= after.base && before.base - after.base == order_base,
        blast_leverage_series_one::errors::active_fill_incomplete!(),
    );
    accounting_math::assert_redemption_base_within_bounds(
        after.base, shares, before.base, supply, before.lot, self.tier_policy.min_exposure_lots(),
    );
    let (reserve_with_fee, _, keep, claim, gross, fee, net) = accounting_math::redemption_accounting_quote(
        shares, before.equity, after.equity, reserve_before, supply, fee_bps,
    );
    self.tier_policy.assert_redemption_gross_within_bound(claim, gross);
    assert!(net >= minimum_output, blast_leverage_series_one::errors::redemption_output_below_minimum!());
    let admin = fee.mul_div(admin_bps, 10_000);
    let reserve_after = reserve_with_fee - admin;
    let final_equity = keep.checked_add(reserve_after)
        .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!());
    self.maintenance_reserve = reserve_after;
    (net, admin, final_equity, fee, fee - admin)
}

/// Rejects unavailable active lifecycle before the adapter touches the venue.
public fun assert_active<Product>(self: &State<Product>) {
    self.lifecycle.assert_active();
}

/// Validates donation accounting before the adapter sends collateral to the venue.
public fun prepare_donation<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    amount: u64,
    reference_time_ms: u64,
): DonationPlan<Product> {
    self.lifecycle.assert_active();
    assert!(amount > 0, blast_leverage_series_one::errors::zero_amount!());
    DonationPlan {
        before: validated_active_position(self, observation, reference_time_ms),
        reserve_before: self.maintenance_reserve,
        amount,
    }
}

/// Finishes an exact donation without creating any supply or admin entitlement.
public fun complete_donation<Product>(
    self: &mut State<Product>,
    plan: DonationPlan<Product>,
    after: PositionObservation,
    reference_time_ms: u64,
) {
    self.lifecycle.assert_active();
    let DonationPlan { before, reserve_before, amount } = plan;
    assert!(reserve_before == self.maintenance_reserve, blast_leverage_series_one::errors::active_checkpoint_changed!());
    let after = validated_active_position(self, after, reference_time_ms);
    assert!(
        before.base == after.base && before.notional == after.notional && before.lot == after.lot
            && before.base_price == after.base_price && before.collateral_price == after.collateral_price
            && after.equity >= before.equity && after.equity - before.equity == amount,
        blast_leverage_series_one::errors::active_checkpoint_changed!(),
    );
    self.maintenance_reserve = self.maintenance_reserve.checked_add(amount)
        .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!());
}

/// Relabels active buffer as shareholder NAV without trading or moving collateral.
/// Adapter custody must authenticate the risk administrator before this call.
/// NAV-cap and ordinary leverage-band checks intentionally do not gate release.
public fun release_buffer<Product>(
    self: &mut State<Product>,
    observation: PositionObservation,
    amount: u64,
    reference_time_ms: u64,
): u64 {
    self.lifecycle.assert_active();
    assert!(amount > 0, blast_leverage_series_one::errors::zero_amount!());
    assert!(amount <= self.maintenance_reserve, blast_leverage_series_one::errors::buffer_release_exceeds_balance!());
    let position = validated_active_position(self, observation, reference_time_ms);
    let reserve_after = self.maintenance_reserve - amount;
    let nav = accounting_math::shareholder_nav(position.equity, reserve_after);
    self.maintenance_reserve = reserve_after;
    nav
}

/// Validates one flat seed observation and returns policy-owned sizing inputs.
///
/// The target uses atomic collateral units. Prices and lot size come from the
/// same consumed strict observation that the adapter uses for the opening
/// session; direction and the live order cap are read by the earlier
/// initialization-constraints guard.
public fun prepare_initialization<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): (u64, u64, u64, u64) {
    self.lifecycle.assert_can_activate();

    let (
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        _,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    ) = observation.unpack_position();
    let (base_index_price, base_confidence, base_publish_time_ms) =
        base_index.unpack_price();
    let (collateral_price, collateral_confidence, collateral_publish_time_ms) =
        collateral_oracle.unpack_price();

    assert!(
        accounting_math::is_reserve_backed(venue_equity, seed_reserve),
        blast_leverage_series_one::errors::maintenance_reserve_exceeds_equity!(),
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        blast_leverage_series_one::errors::invalid_nav!(),
    );

    let valuation_policy = self.tier_policy.valuation_policy();
    valuation_policy.assert_price_fresh(base_publish_time_ms, reference_time_ms);
    valuation_policy.assert_confidence_within_bound(base_confidence, base_index_price);
    valuation_policy.assert_price_fresh(collateral_publish_time_ms, reference_time_ms);
    valuation_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    valuation_policy.assert_mark_within_index_divergence(mark_price, base_index_price);
    assert!(
        absolute_base == 0 && absolute_notional == 0,
        blast_leverage_series_one::errors::invalid_initialization_observation!(),
    );
    assert!(
        pending_order_count == 0,
        blast_leverage_series_one::errors::initialization_orders_not_empty!(),
    );
    assert!(
        venue_operational,
        blast_leverage_series_one::errors::initialization_venue_not_operational!(),
    );
    assert!(
        checkpoint_clean,
        blast_leverage_series_one::errors::initialization_checkpoint_dirty!(),
    );
    assert!(
        margin_safe,
        blast_leverage_series_one::errors::initialization_margin_unsafe!(),
    );

    let seed_nav = accounting_math::shareholder_nav(venue_equity, seed_reserve);
    self.tier_policy.assert_within_nav_cap(seed_nav);
    let target_notional = accounting_math::target_notional_from_equity_down(
        venue_equity,
        seed_reserve,
        self.tier_policy.rebalance_policy().target_bps(),
    );

    (
        target_notional,
        base_index_price,
        collateral_price,
        lot_size,
    )
}

/// Returns the immutable position side and live per-order notional bound used by activation.
///
/// The adapter calls this before any venue mutation. The lifecycle guard makes
/// an installed or otherwise activated State ineligible for a second seed.
public fun initialization_constraints<Product>(
    self: &State<Product>,
): (PositionSide, u64) {
    self.lifecycle.assert_can_activate();
    (
        self.tier_policy.side(),
        self.max_order_notional.current(),
    )
}

/// Rejects a seed session whose execution diverges beyond strict tolerance.
///
/// Initialization always increases risk, so the wider emergency tolerance is
/// never available on this edge.
public fun assert_initialization_execution<Product>(
    self: &State<Product>,
    reference_price: u64,
    execution_price: u64,
) {
    self.lifecycle.assert_can_activate();
    self.tier_policy
        .rebalance_policy()
        .assert_execution_within_strict_tolerance(
            reference_price,
            execution_price,
        );
}

/// Rejects one adapter order above the live atomic-collateral notional limit.
public fun assert_order_notional_allowed<Product>(
    self: &State<Product>,
    order_notional: u64,
) {
    assert!(
        order_notional <= self.max_order_notional.current(),
        blast_leverage_series_one::errors::order_notional_exceeds_maximum!(),
    );
}

/// Activates one fully observed long or short seed.
///
/// Returns the seed's reserve-excluded shareholder NAV in atomic collateral
/// units. The adapter must authenticate the linear observation before calling
/// this function. Every lifecycle, accounting, valuation, position, venue,
/// capacity, leverage, and minimum-operation guard runs before reserve or
/// lifecycle mutation. No administrative witness is accepted after State
/// construction.
public fun initialize<Product>(
    self: &mut State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): u64 {
    self.lifecycle.assert_can_activate();

    let seed_nav = validated_initialization_nav(
        self,
        observation,
        seed_reserve,
        reference_time_ms,
    );

    self.lifecycle.activate();
    self.maintenance_reserve = seed_reserve;

    seed_nav
}

/// Applies one adapter-authenticated funding classification to the reserve.
///
/// Returns `(absorbed_by_reserve, uncovered_cost)` in atomic collateral units.
/// A positive net credit belongs entirely to the buffer. The
/// adapter owns exact-once funding checkpoint authentication; Series1 stores
/// no venue cursor and never infers funding from an equity delta.
public fun settle_funding<Product>(
    self: &mut State<Product>,
    settlement: FundingSettlement,
): (u64, u64) {
    let (_, is_cost, amount) = settlement.unpack_funding();

    if (is_cost) {
        let (reserve_after, absorbed, uncovered) = accounting_math::absorb_funding_cost(
            self.maintenance_reserve,
            amount,
        );
        self.maintenance_reserve = reserve_after;

        (absorbed, uncovered)
    } else {
        self.maintenance_reserve = self.maintenance_reserve
            .checked_add(amount)
            .destroy_or!(abort blast_leverage_series_one::errors::arithmetic_overflow!());
        (0, 0)
    }
}

/// Returns the authoritative funding-only maintenance reserve.
///
/// Adapter operations use this value only for replay-complete post-state
/// events. Reserve mutation remains exclusive to Series1 transitions.
public fun maintenance_reserve<Product>(self: &State<Product>): u64 {
    self.maintenance_reserve
}

/// Updates the live per-call maximum order notional within its frozen bounds.
///
/// This value limits the absolute atomic-USDC notional of one adapter order.
/// It does not limit a user's deposit or the Vault's total open position.
/// Adapter custody of `State<Product>` determines who can present mutable
/// access. The adapter must authenticate its currently selected risk module
/// before calling this function. Updates are available in every lifecycle
/// state because they change only the size of later calls, not live exposure.
public fun set_max_order_notional<Product>(
    self: &mut State<Product>,
    current: u64,
): u64 {
    let previous = self.max_order_notional.current();
    assert!(
        current != previous,
        blast_leverage_series_one::errors::max_order_notional_unchanged!(),
    );

    self.max_order_notional.set_current(current);
    previous
}

/// Disables new risk for an active Series1 product.
///
/// The adapter that owns this State must authorize the operation before this
/// call. This transition cannot activate an uninitialized product, resume a
/// reduced product, or begin shutdown.
public fun enter_reduce_only<Product>(
    self: &mut State<Product>,
) {
    self.lifecycle.enter_reduce_only();
}

// === Private Functions ===

/// All active priced paths consume fresh, attributable venue facts before mutation.
fun validated_active_position<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    reference_time_ms: u64,
): ActivePosition {
    let (equity, base, notional, lot, side, orders, margin_safe, operational, clean,
        base_index, collateral_oracle, mark) = observation.unpack_position();
    let (base_price, base_confidence, base_time) = base_index.unpack_price();
    let (collateral_price, collateral_confidence, collateral_time) = collateral_oracle.unpack_price();
    let valuation = self.tier_policy.valuation_policy();
    valuation.assert_price_fresh(base_time, reference_time_ms);
    valuation.assert_confidence_within_bound(base_confidence, base_price);
    valuation.assert_price_fresh(collateral_time, reference_time_ms);
    valuation.assert_confidence_within_bound(collateral_confidence, collateral_price);
    valuation.assert_mark_within_index_divergence(mark, base_price);
    assert!(
        (base == 0 && notional == 0) || side == self.tier_policy.side(),
        blast_leverage_series_one::errors::invalid_position_observation!(),
    );
    assert!(orders == 0 && margin_safe && operational && clean, blast_leverage_series_one::errors::active_observation_unusable!());
    assert!(accounting_math::is_shareholder_nav_positive(equity, self.maintenance_reserve), blast_leverage_series_one::errors::invalid_nav!());
    ActivePosition { equity, base, notional, lot, base_price, collateral_price }
}

/// Consumes and validates a complete seed without mutable access to State.
fun validated_initialization_nav<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): u64 {
    let (
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    ) = observation.unpack_position();
    let (base_index_price, base_confidence, base_publish_time_ms) =
        base_index.unpack_price();
    let (collateral_price, collateral_confidence, collateral_publish_time_ms) =
        collateral_oracle.unpack_price();

    assert!(
        accounting_math::is_reserve_backed(venue_equity, seed_reserve),
        blast_leverage_series_one::errors::maintenance_reserve_exceeds_equity!(),
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        blast_leverage_series_one::errors::invalid_nav!(),
    );

    let valuation_policy = self.tier_policy.valuation_policy();
    valuation_policy.assert_price_fresh(base_publish_time_ms, reference_time_ms);
    valuation_policy.assert_confidence_within_bound(base_confidence, base_index_price);
    valuation_policy.assert_price_fresh(collateral_publish_time_ms, reference_time_ms);
    valuation_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    valuation_policy.assert_mark_within_index_divergence(mark_price, base_index_price);
    assert!(
        observed_side == self.tier_policy.side(),
        blast_leverage_series_one::errors::invalid_initialization_observation!(),
    );
    assert!(
        pending_order_count == 0,
        blast_leverage_series_one::errors::initialization_orders_not_empty!(),
    );
    assert!(
        venue_operational,
        blast_leverage_series_one::errors::initialization_venue_not_operational!(),
    );
    assert!(
        checkpoint_clean,
        blast_leverage_series_one::errors::initialization_checkpoint_dirty!(),
    );
    assert!(
        margin_safe,
        blast_leverage_series_one::errors::initialization_margin_unsafe!(),
    );

    let seed_nav = accounting_math::shareholder_nav(venue_equity, seed_reserve);
    self.tier_policy.assert_within_nav_cap(seed_nav);
    let rebalance_policy = self.tier_policy.rebalance_policy();
    let scaled = (absolute_notional as u128) * 10_000;
    assert!(
        scaled >= (seed_nav as u128) * (rebalance_policy.public_lower_bps() as u128)
            && scaled <= (seed_nav as u128) * (rebalance_policy.public_upper_bps() as u128),
        blast_leverage_series_one::errors::initialization_leverage_unhealthy!(),
    );
    assert!(
        observation::is_position_structurally_valid(
            absolute_base,
            absolute_notional,
            lot_size,
        ),
        blast_leverage_series_one::errors::invalid_position_observation!(),
    );
    assert!(
        accounting_math::is_exposure_above_minimum_operation(
            absolute_base,
            lot_size,
            self.tier_policy.min_exposure_lots(),
        ),
        blast_leverage_series_one::errors::initialization_exposure_below_minimum!(),
    );

    seed_nav
}

// === Test-Only Functions ===

#[test_only]
/// Returns whether the embedded lifecycle is uninitialized.
public fun is_uninitialized_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_uninitialized()
}

#[test_only]
/// Returns whether the embedded lifecycle is active.
public fun is_active_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_active()
}

#[test_only]
/// Returns the initial and live maintenance reserve.
public fun maintenance_reserve_for_testing<Product>(self: &State<Product>): u64 {
    self.maintenance_reserve
}

#[test_only]
/// Returns the immutable tier policy.
public fun tier_policy_for_testing<Product>(self: &State<Product>): TierPolicy {
    self.tier_policy
}

#[test_only]
/// Returns the complete maximum-order-notional tuple.
public fun max_order_notional_for_testing<Product>(self: &State<Product>): (u64, u64, u64) {
    (
        self.max_order_notional.minimum(),
        self.max_order_notional.current(),
        self.max_order_notional.maximum(),
    )
}

#[test_only]
/// Forces shutdown-pending state for focused adapter tests.
public fun set_shutdown_pending_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle.set_shutdown_pending_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is shutdown-pending.
public fun is_shutdown_pending_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_shutdown_pending()
}

#[test_only]
/// Forces shutdown-settled state for focused monotonicity tests.
public fun set_shutdown_settled_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle = lifecycle::shutdown_settled_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is shutdown-settled.
public fun is_shutdown_settled_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_shutdown_settled()
}

#[test_only]
/// Forces active state for focused transition and adapter tests.
public fun set_active_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle = lifecycle::active_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is reduce-only.
public fun is_reduce_only_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_reduce_only()
}

#[test_only]
/// Consumes an isolated state value at the end of a unit test.
public fun destroy_for_testing<Product>(self: State<Product>) {
    let State {
        tier_policy: _,
        max_order_notional: _,
        maintenance_reserve: _,
        lifecycle: _,
        mint_fee_bps: _,
        redeem_fee_bps: _,
        admin_allocation_bps: _,
    } = self;
}

#[test_only]
/// Credits only authenticated newly deposited collateral to the active buffer.
/// This edge creates no shares and no admin entitlement.
public fun donate<Product>(
    self: &mut State<Product>,
    before: PositionObservation,
    after: PositionObservation,
    amount: u64,
    reference_time_ms: u64,
) {
    let plan = self.prepare_donation(before, amount, reference_time_ms);
    self.complete_donation(plan, after, reference_time_ms);
}
