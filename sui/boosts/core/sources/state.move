// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Venue-neutral state for one core leveraged product.
///
/// The selected adapter stores this value inside its own shared Vault. Only
/// functions in this module can inspect or change the private core fields.
/// Currency, venue custody, ACL routing, and versioning belong to the adapter.
/// The core reads no clock: every `now_ms` is the adapter's
/// `Clock::timestamp_ms()` for the transaction, and oracle freshness is
/// judged against it.
module blast_boosts_core::state;

// === Constants ===

/// Two signed equity components and their fixed-point collateral conversion.
const REBALANCE_CAPTURE_ROUNDING_ALLOWANCE: u128 = 3;

// === Public Types ===

/// An issued product before its seed position exists: the immutable policy
/// and the two live knobs the issuer set.
///
/// The adapter opens the seed position under these terms, then `activate`
/// turns them and the seeded observation into the `State`. The value has no
/// abilities, so an issuance that is not activated cannot be stored: a
/// product is either live or never existed.
public struct Issuance<phantom Product> {
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
    /// `10^decimals` of the venue's base asset and of the bound collateral:
    /// facts about the assets, fixed here so the seed orders and the live
    /// state price base the same way.
    base_unit: u64,
    collateral_unit: u64,
}

/// Sealed core state stored inside one adapter-owned Vault.
///
/// The value can be stored but cannot be copied or dropped. `Product`
/// separates independent leveraged products at the type level.
public struct State<phantom Product> has store {
    vault_policy: VaultPolicy,
    /// Largest atomic-collateral notional of one adapter order, adjustable by
    /// the selected risk module. Execution slippage is bounded separately by
    /// the immutable rebalance policy, so this value only paces orders.
    max_order_notional: u64,
    /// Recorded collateral buffer inside the venue account. Mint, redemption
    /// and donation credits clamp at their observation; funding can leave an
    /// excess. Priced operations admit the live ceiling (flat positions keep all).
    maintenance_reserve: u64,
    /// Funding cost holders bore while the reserve was exhausted; later credits
    /// repay it to NAV before any credit rebuilds the reserve.
    uncovered_deficit: u64,
    /// `10^decimals` of the venue's base asset, fixed at initialization.
    base_unit: u64,
    /// `10^decimals` of the bound collateral, fixed at initialization.
    collateral_unit: u64,
    lifecycle: Lifecycle,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    admin_share_bps: u64,
    /// Inclusive ceiling on post-mint shareholder NAV, adjustable by the admin.
    /// Only mints check it: NAV may exceed it through position profit, which
    /// just blocks further mints until NAV falls back under or the cap is raised.
    nav_cap: u64,
}

/// The position priced at one oracle pair: equity, base, base valued at the
/// pair, the lot, and the pair itself. Sealed into every plan and reported
/// back to the adapter; never persisted as a second ledger.
public struct ActivePosition has copy, drop {
    equity: u64,
    base: u64,
    notional: u64,
    lot_size: u64,
    base_price: u64,
    collateral_price: u64,
}

/// Linear, transaction-local mint terms. Only State can construct or finish them.
public struct MintPlan<phantom Product> {
    before: ActivePosition,
    expected_contribution: u64,
    reserve_fee: u64,
    admin_fee: u64,
    total_share_supply: u64,
    minimum_shares: u64,
    base_to_buy: u64,
    /// Only a below-band position with no executable standalone increase qualifies.
    recovery: bool,
}

/// Linear terms for one proportional redemption, before any payout or fee credit.
public struct RedemptionPlan<phantom Product> {
    before: ActivePosition,
    shares_to_redeem: u64,
    total_share_supply: u64,
    minimum_collateral_out: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    base_to_sell: u64,
}

/// Linear maintenance intent, advanced only by accepted fixed-pair fills.
public struct RebalancePlan<phantom Product> {
    before: ActivePosition,
    current: ActivePosition,
    /// Opening reserve for before-progress NAV; later positions admit their own reserve.
    reserve_priced: u64,
    increase: bool,
    /// Whether the plan began above the hard cap and so may use the emergency
    /// execution bound. Such a reduction sizes toward the cap and stops when
    /// actual leverage reaches it. A later plan gets fresh admission; only
    /// ordinary bounds apply if that plan starts at or below the cap.
    emergency: bool,
    venue_fee_bps: u64,
    steps: u64,
    /// Every ordinary reduction fill matched its order and fresh core sizing.
    full_fills: bool,
    /// The last accepted increase used the sealed one-lot band exception.
    band_landing: bool,
}

/// The next whole-lot order a rebalance places: its size, direction, whether
/// the position is still above the hard cap, and the execution bound it is
/// priced and proved under. A zero size ends the plan.
public struct RebalanceOrder has drop {
    base: u64,
    increase: bool,
    emergency: bool,
    bound: ExecutionBound,
    /// A single lot may cross target only when it lands inside the full band.
    band_landing: bool,
}

/// Linear terms for one bounded close-and-reopen that realizes existing profit.
/// The final base must equal the starting base; all trading costs remain in NAV.
public struct ProfitRealizationPlan<phantom Product> {
    before: ActivePosition,
    base_to_realize: u64,
    max_cost: u64,
    reserve_priced: u64,
}

// === Public Functions ===

// --- Issuance ---

/// Issues one product. The caller signs in as a Vault issuer; `nav_cap` must
/// satisfy `RebalancePolicy::assert_nav_cap_valid` and stays adjustable through
/// `set_nav_cap`. The asset decimals fix the units every base valuation of this
/// product uses.
public fun issue<Product>(
    _: &AdminWitness<VaultIssuer>,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
    base_decimals: u8,
    collateral_decimals: u8,
): Issuance<Product> {
    assert!(max_order_notional > 0, blast_boosts_core::errors::invalid_max_order_notional!());
    vault_policy.rebalance_policy().assert_nav_cap_valid(nav_cap);
    vault_policy.rebalance_policy().assert_rebalance_capacity(max_order_notional, nav_cap);
    assert!(
        base_decimals <= constants::max_asset_decimals!()
            && collateral_decimals <= constants::max_asset_decimals!(),
        blast_boosts_core::errors::invalid_asset_decimals!(),
    );

    Issuance {
        vault_policy, max_order_notional, nav_cap,
        base_unit: 10u64.pow(base_decimals), collateral_unit: 10u64.pow(collateral_decimals),
    }
}

/// Checks live venue rates against this issuance's immutable execution and
/// leverage policy. The adapter rounds each nonnegative rate upward to bps.
public fun assert_initial_margin_headroom<Product>(
    self: &Issuance<Product>,
    initial_margin_bps: u64,
    collateral_haircut_bps: u64,
    venue_fee_bps: u64,
) {
    self.vault_policy.assert_initial_margin_headroom(initial_margin_bps, collateral_haircut_bps, venue_fee_bps);
}

/// Sizes the opening position from a flat seed observation: the whole-lot
/// target base, the whole-lot base one order may carry, and the priced flat
/// seed whose pair and lot the orders are placed under.
///
/// Sizing only. Every guard runs in `activate` against the position actually
/// filled, in the same transaction; a copy here could not refuse a state that
/// `activate` admits.
public fun seed_terms<Product>(
    self: &Issuance<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
): (u64, u64, ActivePosition) {
    let seed_nav = accounting_math::shareholder_nav(observation.venue_equity(), seed_reserve);
    let target_notional =
        accounting_math::target_notional_down(seed_nav, self.vault_policy.rebalance_policy().target_leverage_bps());
    let seed = flat_position(observation);
    let target_base = base_for_notional(target_notional, &seed, self.base_unit, self.collateral_unit);
    let max_order_base = execution_order_base(
        self.max_order_notional, &seed, self.seed_execution_bound(), false, self.base_unit, self.collateral_unit,
    );
    assert_minimum_order_capacity(max_order_base, seed.lot_size, self.vault_policy.min_order_lots());

    (target_base, max_order_base, seed)
}

/// Turns the issuance and the observation the adapter took after the seed
/// position opened into the live state.
///
/// Returns the state, the seed's reserve-excluded shareholder NAV in atomic
/// collateral units, and the priced seed position. Every price, capacity,
/// leverage and minimum-order guard runs before the state exists.
public fun activate<Product>(
    self: Issuance<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    now_at_ms: u64,
): (State<Product>, u64, ActivePosition) {
    let Issuance { vault_policy, max_order_notional, nav_cap, base_unit, collateral_unit } = self;
    let state = State {
        mint_fee_bps: vault_policy.initial_mint_fee_bps(),
        redeem_fee_bps: vault_policy.initial_redeem_fee_bps(),
        admin_share_bps: 0,
        nav_cap,
        vault_policy,
        max_order_notional,
        maintenance_reserve: seed_reserve,
        uncovered_deficit: 0,
        base_unit,
        collateral_unit,
        lifecycle: lifecycle::active(),
    };

    let venue_equity = observation.venue_equity();
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        blast_boosts_core::errors::invalid_nav!(),
    );
    state.vault_policy.assert_observation_priced(&observation, now_at_ms);
    assert!(
        observation.observed_side() == state.vault_policy.side(),
        blast_boosts_core::errors::invalid_initialization_observation!(),
    );
    let seed_nav = accounting_math::shareholder_nav(venue_equity, seed_reserve);
    state.assert_within_nav_cap(seed_nav);

    let seeded = state.priced_position(observation);
    assert!(
        state.vault_policy.rebalance_policy().is_leverage_within_band(seeded.notional, seed_nav),
        blast_boosts_core::errors::initialization_leverage_unhealthy!(),
    );
    assert!(
        seed_reserve <= state.vault_policy.reserve_cap(seeded.notional),
        blast_boosts_core::errors::seed_reserve_above_cap!(),
    );
    assert!(
        accounting_math::is_base_above_min_order(seeded.base, seeded.lot_size, state.vault_policy.min_order_lots()),
        blast_boosts_core::errors::initialization_base_below_min_order!(),
    );

    (state, seed_nav, seeded)
}

// --- Order Terms ---

/// The immutable direction every seed order takes.
public fun seed_side<Product>(self: &Issuance<Product>): PositionSide {
    self.vault_policy.side()
}

/// Rejects one seed order above the per-order notional cap.
public fun assert_seed_order_notional_allowed<Product>(self: &Issuance<Product>, order_notional: u64) {
    assert_order_notional_within(self.max_order_notional, order_notional);
}

/// The bound every seed order is priced and proved under: the ordinary one,
/// because opening a position always increases risk.
public fun seed_execution_bound<Product>(self: &Issuance<Product>): ExecutionBound {
    self.vault_policy.rebalance_policy().execution_bound(false)
}

/// The immutable direction every order of this product takes.
public fun side<Product>(self: &State<Product>): PositionSide {
    self.vault_policy.side()
}

/// Whole-lot capacity under the ordinary execution bound. Closing orders may
/// use exactly one venue lot when the configured cap cannot cover one lot.
public fun max_order_base<Product>(self: &State<Product>, position: &ActivePosition, reduce_only: bool): u64 {
    execution_order_base(
        self.max_order_notional, position, self.execution_bound(), reduce_only, self.base_unit, self.collateral_unit,
    )
}

/// Checks the actual filled quote against the cap. The adapter must prove
/// the fill is reduce-only and exactly one live venue lot for the sole
/// exception; the same execution-price bound still applies to that fill.
public fun assert_order_notional_allowed<Product>(
    self: &State<Product>, order_notional: u64, filled_base: u64, lot_size: u64, reduce_only: bool,
) {
    assert!(
        order_notional <= self.max_order_notional || (reduce_only && lot_size > 0 && filled_base == lot_size),
        blast_boosts_core::errors::order_notional_exceeds_maximum!(),
    );
}

/// The bound every mint, redemption and ordinary rebalance order is priced and
/// proved under. A rebalance order carries its own bound, which is the wider
/// emergency one only while the position is above the hard cap, and a
/// close-only order takes the bound `unwind_constraints` prices at.
public fun execution_bound<Product>(self: &State<Product>): ExecutionBound {
    self.vault_policy.rebalance_policy().execution_bound(false)
}

// --- Mint ---

/// Seals proportional exposure, or deposit-funded catch-up for untradeable lot dust.
/// The adapter authenticates the observation, supply and ordinary taker fee.
/// Both paths must complete inside the band; the user's share floor is unchanged.
public fun prepare_mint<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    collateral_deposit: u64,
    total_share_supply: u64,
    minimum_shares: u64,
    venue_fee_bps: u64,
    now_at_ms: u64,
): MintPlan<Product> {
    self.lifecycle.assert_active();
    assert!(total_share_supply > 0, blast_boosts_core::errors::invalid_share_supply!());

    assert!(venue_fee_bps <= constants::basis_points_denominator!(), blast_boosts_core::errors::venue_fee_unusable!());
    let before = self.validated_active_position(observation, now_at_ms);
    let reserve_priced = self.admitted_reserve(&before);
    let nav = accounting_math::shareholder_nav(before.equity, reserve_priced);
    let recovery = !self.is_within_band(&before, reserve_priced);
    if (recovery) {
        assert!(
            self.vault_policy.rebalance_policy().is_leverage_below_band(before.notional, nav),
            blast_boosts_core::errors::mint_outside_rebalance_band!(),
        );
        let (standalone_base, _) = self.increase_order(&before, venue_fee_bps);
        assert!(standalone_base == 0, blast_boosts_core::errors::mint_outside_rebalance_band!());
    };

    let (fee, admin_fee, reserve_fee) = self.fee_allocation(collateral_deposit, true);
    let expected_contribution = collateral_deposit - fee;
    assert!(expected_contribution > 0, blast_boosts_core::errors::nonpositive_contribution!());
    let proportional_base = accounting_math::mint_base_to_buy_down(
        expected_contribution, before.base, nav, before.lot_size, self.vault_policy.min_order_lots(),
    );
    let base_to_buy = if (recovery) {
        self.recovery_mint_base(&before, nav, expected_contribution, proportional_base, venue_fee_bps)
    } else {
        proportional_base
    };

    MintPlan {
        before,
        expected_contribution,
        reserve_fee,
        admin_fee,
        total_share_supply,
        minimum_shares,
        base_to_buy,
        recovery,
    }
}

/// Returns the entire required whole-lot increase, not caller-selected sizing.
public fun base_to_buy<Product>(self: &MintPlan<Product>): u64 { self.base_to_buy }

/// Returns the admin cash the adapter must retain before depositing collateral.
public fun admin_fee<Product>(self: &MintPlan<Product>): u64 { self.admin_fee }

/// Returns the sealed input for completed adapter accounting facts.
/// The position the mint was priced against; the adapter trades at its pair and lot.
public fun mint_position<Product>(self: &MintPlan<Product>): ActivePosition { self.before }

/// Completes the sealed proportional or recovery fill and credits its reserve allocation.
/// The credited contribution is capped at the deposit net of the whole fee, so
/// a favorable fill accrues to existing holders (ADR 0084 D3).
/// The returned shares are minted through the adapter's native share authority.
/// The actual final position must remain inside both inclusive band edges.
/// Returns shares, contribution, fee, admin, reserve and the two sealed rates.
public fun complete_mint<Product>(
    self: &mut State<Product>,
    plan: MintPlan<Product>,
    observation: PositionObservation,
    now_at_ms: u64,
): (u64, u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let MintPlan {
        before, expected_contribution, reserve_fee, admin_fee, total_share_supply, minimum_shares, base_to_buy, recovery,
    } = plan;

    let after = self.validated_active_position(observation, now_at_ms);
    assert!(before.is_same_checkpoint(&after), blast_boosts_core::errors::active_checkpoint_changed!());
    assert!(
        after.base >= before.base && after.base - before.base == base_to_buy,
        blast_boosts_core::errors::active_fill_incomplete!(),
    );

    let reserve_priced = self.admitted_reserve(&before);
    let reserve_after = self.reserve_within_cap(
        reserve_priced.checked_add(reserve_fee)
            .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!()),
        &after,
    );
    let nav_before = accounting_math::shareholder_nav(before.equity, reserve_priced);
    let (nav_after, contribution, shares) = accounting_math::allocated_mint_quote(
        before.equity, after.equity, reserve_priced, reserve_after, expected_contribution,
        total_share_supply, minimum_shares,
    );
    if (recovery) {
        // Catch-up exposure is sealed in the plan; actual contribution must still
        // fund the minimum proportional order. Costs reduce the depositor's shares.
        let attributable_base = accounting_math::mint_base_to_buy_down(
            contribution, before.base, nav_before, before.lot_size, self.vault_policy.min_order_lots(),
        );
        assert!(base_to_buy >= attributable_base, blast_boosts_core::errors::mint_base_below_bound!());
    } else {
        accounting_math::assert_mint_base_within_bounds(
            after.base, expected_contribution, contribution, before.base, nav_before,
            before.lot_size, self.vault_policy.min_order_lots(),
        );
    };
    self.assert_within_nav_cap(nav_after);
    assert!(
        self.is_within_band(&after, reserve_after),
        blast_boosts_core::errors::mint_outside_rebalance_band!(),
    );

    self.maintenance_reserve = reserve_after;
    assert_holders_not_diluted(nav_before, total_share_supply, nav_after, total_share_supply + shares);

    (shares, contribution, admin_fee + reserve_fee, admin_fee, reserve_fee)
}

// --- Redemption ---

/// Seals a rounded-up attributable close and the redeemer's output floor.
public fun prepare_redemption<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    shares_to_redeem: u64,
    total_share_supply: u64,
    minimum_collateral_out: u64,
    now_at_ms: u64,
): RedemptionPlan<Product> {
    self.lifecycle.assert_active();

    let before = self.validated_active_position(observation, now_at_ms);
    let (minimum_base, _) = accounting_math::redemption_base_bounds(
        shares_to_redeem, before.base, total_share_supply, before.lot_size, self.vault_policy.min_order_lots(),
    );
    let base_to_sell = before.base - minimum_base;

    RedemptionPlan {
        before, shares_to_redeem, total_share_supply, minimum_collateral_out,
        fee_bps: self.redeem_fee_bps, admin_share_bps: self.admin_share_bps, base_to_sell,
    }
}

/// Returns the full reduce-only order amount; flat redemptions require no order.
public fun base_to_sell<Product>(self: &RedemptionPlan<Product>): u64 { self.base_to_sell }

/// The position the redemption was priced against.
public fun redemption_position<Product>(self: &RedemptionPlan<Product>): ActivePosition { self.before }

/// Shares the redeemer must burn.
public fun redemption_shares<Product>(self: &RedemptionPlan<Product>): u64 { self.shares_to_redeem }

/// Computes the payout after the sell and credits the fee once, excluding admin cash.
/// The gross is capped at the proportional claim, so a favorable sell accrues
/// to the remaining holders (ADR 0084 D3).
/// Returns the user payout, the admin cash, the fee, and the fee's reserve share.
/// The adapter withdraws exactly payout plus admin cash and proves that on the checkpoint.
public fun complete_redemption<Product>(
    self: &mut State<Product>,
    plan: RedemptionPlan<Product>,
    observation: PositionObservation,
    now_at_ms: u64,
): (u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let RedemptionPlan {
        before, shares_to_redeem, total_share_supply, minimum_collateral_out, fee_bps, admin_share_bps, base_to_sell,
    } = plan;

    let after = self.validated_active_position(observation, now_at_ms);
    assert!(before.is_same_checkpoint(&after), blast_boosts_core::errors::active_checkpoint_changed!());
    assert!(
        before.base >= after.base && before.base - after.base == base_to_sell,
        blast_boosts_core::errors::active_fill_incomplete!(),
    );
    accounting_math::assert_redemption_base_within_bounds(
        after.base, shares_to_redeem, before.base, total_share_supply, before.lot_size, self.vault_policy.min_order_lots(),
    );

    let reserve_priced = self.admitted_reserve(&before);
    let (reserve_with_fee, nav_kept, fee, net) = accounting_math::redemption_accounting_quote(
        shares_to_redeem, before.equity, after.equity, reserve_priced, total_share_supply, fee_bps,
    );
    assert!(net >= minimum_collateral_out, blast_boosts_core::errors::redemption_output_below_minimum!());
    let admin = accounting_math::admin_share_down(fee, admin_share_bps);
    let reserve_retained = reserve_with_fee - admin;
    assert!(
        nav_kept <= std::u64::max_value!() - reserve_retained,
        blast_boosts_core::errors::arithmetic_overflow!(),
    );

    self.maintenance_reserve = self.reserve_within_cap(reserve_retained, &after);
    assert_holders_not_diluted(
        accounting_math::shareholder_nav(before.equity, reserve_priced),
        total_share_supply,
        nav_kept,
        total_share_supply - shares_to_redeem,
    );

    (net, admin, fee, fee - admin)
}

// --- Rebalance ---

/// Core-owned bound shared by the adapter's loop and the progress projection.
public fun max_rebalance_orders(): u64 { constants::max_rebalance_orders!() }

/// Whether an outside-band position has a sizeable order the adapter permits.
/// `increases_allowed` only filters this read-only keeper hint; real execution
/// still prepares a linear plan and rechecks the venue's opening admission.
/// Sizing uses the authenticated ordinary fee; lot dust or an unsafe flat close returns false.
public fun needs_rebalance<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    increases_allowed: bool,
    venue_fee_bps: u64,
    now_at_ms: u64,
): bool {
    self.lifecycle.assert_active();

    let mark = observation.mark_price();
    let position = self.validated_oracle_position(observation, now_at_ms);
    let nav = accounting_math::shareholder_nav(position.equity, self.admitted_reserve(&position));
    let rebalance = self.vault_policy.rebalance_policy();
    if (!rebalance.is_leverage_above_max(position.notional, nav)) {
        self.vault_policy.price_policy().assert_mark_within_oracle_divergence(mark, position.base_price);
    };

    if (rebalance.is_leverage_within_band(position.notional, nav)) return false;
    if (!rebalance.is_leverage_below_band(position.notional, nav)) {
        return self.reduction_order(&position, rebalance.is_leverage_above_max(position.notional, nav), venue_fee_bps) > 0
    };
    if (!increases_allowed) return false;
    let (base, _) = self.increase_order(&position, venue_fee_bps);

    base > 0
}

/// Derives public maintenance intent from exact outside-band ratios, never caller orders.
public fun prepare_rebalance<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    venue_fee_bps: u64,
    now_at_ms: u64,
): RebalancePlan<Product> {
    self.lifecycle.assert_active();
    assert!(
        venue_fee_bps <= constants::basis_points_denominator!(),
        blast_boosts_core::errors::venue_fee_unusable!(),
    );

    let mark = observation.mark_price();
    let before = self.validated_oracle_position(observation, now_at_ms);
    let reserve_priced = self.admitted_reserve(&before);
    let nav = accounting_math::shareholder_nav(before.equity, reserve_priced);
    let rebalance = self.vault_policy.rebalance_policy();
    let emergency = rebalance.is_leverage_above_max(before.notional, nav);
    if (!emergency) {
        self.vault_policy.price_policy().assert_mark_within_oracle_divergence(mark, before.base_price);
    };
    assert!(!self.is_within_band(&before, reserve_priced), blast_boosts_core::errors::rebalance_inside_band!());

    let increase = rebalance.is_leverage_below_band(before.notional, nav);
    if (increase) {
        let (base, _) = self.increase_order(&before, venue_fee_bps);
        assert!(base > 0, blast_boosts_core::errors::rebalance_not_actionable!());
    } else {
        assert!(self.reduction_order(&before, emergency, venue_fee_bps) > 0, blast_boosts_core::errors::rebalance_not_actionable!());
    };

    RebalancePlan {
        before,
        current: before,
        reserve_priced,
        increase,
        emergency,
        venue_fee_bps,
        steps: 0,
        full_fills: true,
        band_landing: false,
    }
}

/// The next order toward the band, sized from the position the last fill left.
///
/// A zero size ends the plan; core and adapter share the core-owned order budget. An
/// emergency reduction sizes toward the hard cap using current equity and
/// the remaining position's reserve, then stops once actual leverage reaches
/// the cap. Costs and lot rounding can require several orders. A later
/// ordinary plan uses ordinary bounds; missing fills can still abort a batch.
public fun next_rebalance_order<Product>(self: &State<Product>, plan: &RebalancePlan<Product>): RebalanceOrder {
    let position = &plan.current;
    let rebalance = self.vault_policy.rebalance_policy();
    let ordinary = rebalance.execution_bound(false);

    if (plan.steps >= max_rebalance_orders()) {
        return RebalanceOrder { base: 0, increase: plan.increase, emergency: false, bound: ordinary, band_landing: false }
    };

    if (plan.increase) {
        let (base, band_landing) = self.increase_order(position, plan.venue_fee_bps);
        return RebalanceOrder { base, increase: true, emergency: false, bound: ordinary, band_landing }
    };

    let nav = accounting_math::shareholder_nav(position.equity, self.admitted_reserve(position));
    // The opening decision cannot widen through a plan's own fills. Stop an
    // emergency plan at the actual cap; a later plan gets fresh admission.
    if (plan.emergency) {
        if (!rebalance.is_leverage_above_max(position.notional, nav)) {
            return RebalanceOrder { base: 0, increase: false, emergency: false, bound: ordinary, band_landing: false }
        };
        return RebalanceOrder {
            base: self.reduction_order(position, true, plan.venue_fee_bps), increase: false, emergency: true,
            bound: rebalance.execution_bound(true), band_landing: false,
        }
    };

    RebalanceOrder { base: self.reduction_order(position, false, plan.venue_fee_bps), increase: false, emergency: false, bound: ordinary, band_landing: false }
}

/// The position the rebalance was priced against.
public fun rebalance_position<Product>(self: &RebalancePlan<Product>): ActivePosition { self.before }

/// Whether the plan buys toward the target rather than sells.
public fun is_increasing<Product>(self: &RebalancePlan<Product>): bool { self.increase }

/// Whether the authenticated starting position was strictly above the hard cap.
/// Fixed for the plan: its own fills cannot promote ordinary maintenance.
public fun is_emergency_rebalance<Product>(self: &RebalancePlan<Product>): bool { self.emergency }

public fun order_base(self: &RebalanceOrder): u64 { self.base }

public fun is_increase(self: &RebalanceOrder): bool { self.increase }

public fun is_emergency(self: &RebalanceOrder): bool { self.emergency }

/// The bound the order is priced and proved under.
public fun bound(self: &RebalanceOrder): ExecutionBound { self.bound }

/// Advances the plan by one accepted whole-lot fill of `order` under the fixed oracle pair.
public fun accept_rebalance_fill<Product>(
    self: &State<Product>,
    plan: &mut RebalancePlan<Product>,
    order: RebalanceOrder,
    observation: PositionObservation,
    filled_base: u64,
    now_at_ms: u64,
) {
    let RebalanceOrder { base: requested, increase, emergency: _, bound: _, band_landing } = order;
    assert!(plan.steps < max_rebalance_orders(), blast_boosts_core::errors::rebalance_order_limit!());
    assert!(
        filled_base > 0 && filled_base <= requested && filled_base % plan.current.lot_size == 0,
        blast_boosts_core::errors::active_fill_incomplete!(),
    );

    // Keep the opening emergency decision through the cap-restoring fill.
    // Reclassifying that fill would reintroduce the divergence check and undo recovery.
    let after = if (plan.emergency) {
        self.validated_oracle_position(observation, now_at_ms)
    } else {
        self.validated_active_position(observation, now_at_ms)
    };
    assert!(plan.before.is_same_checkpoint(&after), blast_boosts_core::errors::active_checkpoint_changed!());
    let expected_base = if (increase) {
        plan.current.base.checked_add(filled_base).destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!())
    } else {
        plan.current.base - filled_base
    };
    assert!(after.base == expected_base, blast_boosts_core::errors::active_fill_incomplete!());

    if (increase) {
        self.assert_increase_leverage(&after, band_landing);
        plan.band_landing = band_landing;
    };

    // Prove full fills against fresh core sizing, not a retained or foreign order.
    plan.full_fills = !plan.emergency && !plan.increase && !increase && plan.full_fills && filled_base == requested
        && filled_base == self.next_rebalance_order(plan).base;
    plan.current = after;
    plan.steps = plan.steps + 1;
}

/// Completes holder-funded maintenance without changing reserve, supply or admin cash.
/// Returns authenticated before/after equity and base for one completed event.
public fun complete_rebalance<Product>(
    self: &State<Product>,
    plan: RebalancePlan<Product>,
): (u64, u64, u64, u64, bool) {
    self.lifecycle.assert_active();
    let RebalancePlan { before, current, reserve_priced, increase, emergency, venue_fee_bps, steps, full_fills, band_landing } = plan;
    assert!(steps > 0, blast_boosts_core::errors::rebalance_no_progress!());

    let before_nav = accounting_math::shareholder_nav(before.equity, reserve_priced);
    let reserve_after = self.admitted_reserve(&current);
    assert!(accounting_math::is_shareholder_nav_positive(current.equity, reserve_after), blast_boosts_core::errors::invalid_nav!());
    let after_nav = accounting_math::shareholder_nav(current.equity, reserve_after);
    if (increase) self.assert_increase_leverage(&current, band_landing);
    let rebalance = self.vault_policy.rebalance_policy();
    let improved = if (increase) {
        current.base > before.base
            && rebalance_math::leverage_rose(before.notional, before_nav, current.notional, after_nav)
    } else if (emergency) {
        // A costly but real emergency reduction may worsen the ratio. Require
        // less exposure, not the ordinary minimum or a fully filled batch.
        current.base < before.base && current.notional < before.notional
    } else {
        current.base < before.base
            && (rebalance_math::reduction_is_sufficient(
                before.notional, before_nav, current.notional, after_nav,
                rebalance.target_leverage_bps(), rebalance.min_leverage_improvement_bps(),
                rebalance_math::oracle_notional_up(
                    current.lot_size, current.base_price, current.collateral_price,
                    self.base_unit, self.collateral_unit,
                ),
            ) || (steps == max_rebalance_orders() && full_fills
                && self.reduction_matches_capacity(&before, &current, venue_fee_bps)))
    };
    assert!(improved, blast_boosts_core::errors::rebalance_no_progress!());

    (before.equity, current.equity, before.base, current.base, increase)
}

// --- Profit Realization ---

/// Sizes a whole-lot recovery of an adapter-authenticated cash shortfall and
/// an economical rounding minimum, capped to one opening-sized order. Larger deficits need further
/// transactions. No caller selects the size, price bound or cost allowance.
public fun prepare_profit_realization<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    cash_shortfall: u64,
    unrealized_profit: u64,
    venue_fee_bps: u64,
    now_at_ms: u64,
): ProfitRealizationPlan<Product> {
    self.lifecycle.assert_active();
    assert!(cash_shortfall > 0 && unrealized_profit > 0, blast_boosts_core::errors::profit_realization_not_needed!());
    assert!(venue_fee_bps <= constants::basis_points_denominator!(), blast_boosts_core::errors::venue_fee_unusable!());
    let before = self.validated_active_position(observation, now_at_ms);
    assert!(before.base > 0, blast_boosts_core::errors::profit_realization_not_needed!());
    let reserve_priced = self.admitted_reserve(&before);
    self.assert_realization_leverage(&before, reserve_priced);

    let denominator = constants::basis_points_denominator!() as u128;
    let slippage = self.execution_bound().slippage_bps() as u128;
    let cost_bps = 2 * (slippage + ((venue_fee_bps as u128) * (denominator + slippage)).div_ceil(denominator));
    let full_cost = ((before.notional as u128) * cost_bps).div_ceil(denominator);
    assert!(2 * full_cost < unrealized_profit as u128, blast_boosts_core::errors::profit_realization_uneconomic!());
    // Do not pay to convert gains when even realizing the whole position at
    // the cost allowance cannot cover the cash-only margin requirement.
    assert!(
        (cash_shortfall as u128) + 3 <= (unrealized_profit as u128) - full_cost,
        blast_boosts_core::errors::profit_realization_uneconomic!(),
    );

    // Two collateral atoms cover normalization across the two trades; a third
    // targets positive cash headroom instead of stopping exactly on the floor.
    let needed = (((cash_shortfall as u256) + 3) * (before.base as u256))
        .div_ceil((unrealized_profit as u256) - (full_cost as u256));
    // A tiny shortfall must not demand a trade whose fixed rounding allowance
    // costs more than its profit. This minimum covers both cost roundings.
    let rounding_allowance = 2 + cost_bps.div_ceil(denominator);
    let economical = (((2 * rounding_allowance + 3) as u256) * (before.base as u256))
        .div_ceil((unrealized_profit as u256) - 2 * (full_cost as u256));
    let rounded = needed.max(economical).div_ceil(before.lot_size as u256) * (before.lot_size as u256);
    let base_to_realize = (rounded.min(before.base as u256) as u64).min(self.max_order_base(&before, false));
    let trade_notional = rebalance_math::oracle_notional_up(
        base_to_realize, before.base_price, before.collateral_price, self.base_unit, self.collateral_unit,
    );
    let max_cost = ((trade_notional as u128) * cost_bps).div_ceil(denominator) + 2;
    let realized_profit = (unrealized_profit as u128) * (base_to_realize as u128) / (before.base as u128);
    // Even at the cost limit, more cash is released than holders spend.
    assert!(realized_profit > 2 * max_cost, blast_boosts_core::errors::profit_realization_uneconomic!());

    ProfitRealizationPlan { before, base_to_realize, max_cost: max_cost as u64, reserve_priced }
}

/// The fixed oracle pair and starting position used by both recovery orders.
public fun realization_position<Product>(self: &ProfitRealizationPlan<Product>): ActivePosition { self.before }

/// Exact base to close and reopen in the same transaction.
public fun base_to_realize<Product>(self: &ProfitRealizationPlan<Product>): u64 { self.base_to_realize }

/// Proves unchanged exposure, bounded actual cost and a healthy final position.
/// Does not change supply, reserve, funding deficit, fees or lifecycle.
public fun complete_profit_realization<Product>(
    self: &State<Product>,
    plan: ProfitRealizationPlan<Product>,
    observation: PositionObservation,
    now_at_ms: u64,
): (u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let ProfitRealizationPlan { before, base_to_realize, max_cost, reserve_priced } = plan;
    let after = self.validated_active_position(observation, now_at_ms);
    assert!(before.is_same_checkpoint(&after), blast_boosts_core::errors::active_checkpoint_changed!());
    assert!(before.base == after.base, blast_boosts_core::errors::active_fill_incomplete!());
    let cost = before.equity - before.equity.min(after.equity);
    assert!(cost <= max_cost, blast_boosts_core::errors::profit_realization_uneconomic!());
    self.assert_realization_leverage(&after, reserve_priced);

    (before.equity, after.equity, base_to_realize, cost)
}

// --- Funding And Reserve ---

/// Applies one adapter-authenticated funding classification to the reserve.
///
/// Returns `(absorbed_by_reserve, uncovered_cost, restored_to_holders)` in
/// atomic collateral units. A cost consumes the reserve first; what it cannot
/// cover is borne by holder NAV and recorded as the uncovered deficit. A credit
/// repays that deficit first, by staying in NAV, and only its remainder
/// rebuilds the reserve. The adapter owns exact-once funding checkpoint
/// authentication; the core stores no venue cursor and never infers funding
/// from an equity change.
public fun settle_funding<Product>(
    self: &mut State<Product>,
    settlement: FundingSettlement,
): (u64, u64, u64) {
    self.lifecycle.assert_can_sync();

    let amount = settlement.amount();
    let reserve_before = self.maintenance_reserve;

    if (settlement.is_cost()) {
        let (reserve_after, absorbed, uncovered) = accounting_math::absorb_funding_cost(reserve_before, amount);

        self.maintenance_reserve = reserve_after;
        self.uncovered_deficit = self.uncovered_deficit
            .checked_add(uncovered)
            .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());
        assert_invariant(reserve_after + absorbed == reserve_before && absorbed + uncovered == amount);

        (absorbed, uncovered, 0)
    } else {
        let restored = amount.min(self.uncovered_deficit);

        self.uncovered_deficit = self.uncovered_deficit - restored;
        self.maintenance_reserve = reserve_before
            .checked_add(amount - restored)
            .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());
        assert_invariant(self.maintenance_reserve + restored == reserve_before + amount);

        (0, 0, restored)
    }
}

/// Credits an exact donation to the reserve, clamped to the ceiling, without
/// creating supply or an admin entitlement. The adapter proves the venue took
/// exactly `amount` on the raw checkpoint; the core prices the position it left.
public fun donate<Product>(self: &mut State<Product>, observation: PositionObservation, amount: u64, now_at_ms: u64) {
    self.lifecycle.assert_active();
    assert!(amount > 0, blast_boosts_core::errors::zero_amount!());

    let after = self.validated_active_position(observation, now_at_ms);
    let reserve_funded = self.maintenance_reserve
        .checked_add(amount)
        .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());

    self.maintenance_reserve = self.reserve_within_cap(reserve_funded, &after);
    assert_invariant(self.maintenance_reserve <= reserve_funded && self.maintenance_reserve <= after.equity);
}

/// Rejects an ordinary operation outside Active, before the adapter touches the venue.
public fun assert_active<Product>(self: &State<Product>) {
    self.lifecycle.assert_active();
}

/// Checks a recovery observation against the same prices, side and positive
/// shareholder NAV required by ordinary operations. Recovery changes no core
/// allocation: the authenticated venue loss is reflected in the next valuation.
public fun assert_recoverable_position<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    now_at_ms: u64,
) {
    self.lifecycle.assert_active();
    let _ = self.validated_active_position(observation, now_at_ms);
}

/// Rejects venue synchronization after the local cash pool has been sealed.
public fun assert_can_sync<Product>(self: &State<Product>) {
    self.lifecycle.assert_can_sync();
}

// --- Shutdown ---

/// Irreversibly stops ordinary operations. The owning adapter authenticates shutdown authority.
/// Moves the Vault to Unwinding at the adapter's clock reading `now_at_ms`,
/// from which the close-only execution bound widens.
public fun begin_shutdown<Product>(self: &mut State<Product>, now_at_ms: u64) {
    self.lifecycle.begin_shutdown(now_at_ms);
}

/// Starts protected closure only when even all circulating shares cannot
/// meet the ordinary redemption minimum. The adapter authenticates raw base,
/// lot size and native supply; no price, equity or caller-sized burn is needed.
public fun begin_protected_shutdown<Product>(
    self: &mut State<Product>,
    base: u64,
    lot_size: u64,
    total_share_supply: u64,
    locked_shares: u64,
    now_at_ms: u64,
) {
    self.lifecycle.assert_active();
    assert!(
        accounting_math::is_redemption_size_locked(
            base, total_share_supply, locked_shares, lot_size, self.vault_policy.min_order_lots(),
        ),
        blast_boosts_core::errors::protected_shutdown_not_allowed!(),
    );

    self.lifecycle.begin_protected_shutdown(now_at_ms);
}

/// Authorizes only close-only venue progress before finalization.
public fun assert_unwinding<Product>(self: &State<Product>) {
    self.lifecycle.assert_unwinding();
}

/// Prices a close-only order, sizes the per-order cap in whole lots at that
/// price, and fixes the execution bound every close order of this step is
/// priced and proved under: the ordinary bound when shutdown has just begun,
/// widening with the time since to the emergency bound. Insolvency and the
/// reserve do not gate an exit.
public fun unwind_constraints<Product>(
    self: &State<Product>,
    base_oracle: PriceObservation,
    collateral_oracle: PriceObservation,
    lot_size: u64,
    now_at_ms: u64,
): (PositionSide, u64, u64, u64, ExecutionBound) {
    self.assert_unwinding();
    let price_policy = self.vault_policy.price_policy();
    price_policy.assert_oracle_admitted(&base_oracle, now_at_ms);
    price_policy.assert_oracle_admitted(&collateral_oracle, now_at_ms);

    let (base_price, collateral_price) = (base_oracle.price(), collateral_oracle.price());
    let shutdown_began_at_ms = self.lifecycle.shutdown_began_at_ms();
    let elapsed_duration_ms = if (now_at_ms > shutdown_began_at_ms) { now_at_ms - shutdown_began_at_ms } else { 0 };
    let bound = self.vault_policy.rebalance_policy().unwind_execution_bound(elapsed_duration_ms);
    let max_order_base = rebalance_math::base_for_execution_notional_down(
        self.max_order_notional, base_price, collateral_price, lot_size, bound.slippage_bps(),
        self.base_unit, self.collateral_unit,
    ).max(lot_size);

    (self.vault_policy.side(), max_order_base, base_price, collateral_price, bound)
}

/// Consumes the reserve book entry only after complete local cash recovery.
/// Returns eligible supply, protected reserve cash and protected seed cash.
/// Protected closure first retains the full recorded reserve up to recovered
/// cash, then floors the circulating holders' fraction of the remainder using
/// total supply including the locked seed. The adapter must segregate both
/// protected amounts with no holder/admin withdrawal path. Admin shutdown retains its
/// original distribution. Venue losses can reduce every allocation.
public fun finalize_shutdown<Product>(
    self: &mut State<Product>,
    total_share_supply: u64,
    locked_shares: u64,
    recovered_cash: u64,
): (u64, u64, u64) {
    assert!(total_share_supply >= locked_shares, blast_boosts_core::errors::invalid_share_supply!());
    let protect_balances = self.lifecycle.protects_shutdown_balances();

    let eligible = total_share_supply - locked_shares;
    let (protected_reserve, protected_seed) = if (protect_balances) {
        assert!(locked_shares > 0 && eligible > 0, blast_boosts_core::errors::invalid_share_supply!());
        let reserve_cash = self.maintenance_reserve.min(recovered_cash);
        let share_cash = recovered_cash - reserve_cash;
        let holder_cash = share_cash.mul_div(eligible, total_share_supply);

        (reserve_cash, share_cash - holder_cash)
    } else {
        (0, 0)
    };

    self.lifecycle.finalize_shutdown();
    self.maintenance_reserve = 0;

    (eligible, protected_reserve, protected_seed)
}

/// Rejects terminal claims before any adapter cash-field access.
public fun assert_settled<Product>(self: &State<Product>) {
    self.lifecycle.assert_settled();
}

/// Fee-free claim against current cash and total share supply, excluding the immutable seed.
public fun shutdown_claim_quote<Product>(
    self: &State<Product>,
    recovered_cash: u64,
    total_share_supply: u64,
    locked_shares: u64,
    shares_to_claim: u64,
    minimum_collateral_out: u64,
): u64 {
    self.lifecycle.assert_settled();
    assert!(total_share_supply >= locked_shares, blast_boosts_core::errors::invalid_share_supply!());
    let eligible = total_share_supply - locked_shares;
    assert!(shares_to_claim > 0 && shares_to_claim <= eligible, blast_boosts_core::errors::invalid_share_amount!());

    let output = recovered_cash.mul_div(shares_to_claim, eligible);
    assert!(recovered_cash == 0 || output > 0, blast_boosts_core::errors::zero_net_payout!());
    assert!(output >= minimum_collateral_out, blast_boosts_core::errors::redemption_output_below_minimum!());

    output
}

// --- Administration ---

/// Updates future fee collections under immutable issuance caps.
/// Adapter custody owns authentication; no assets or past allocations move.
public fun set_fees<Product>(
    self: &mut State<Product>,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    admin_share_bps: u64,
): (u64, u64, u64) {
    self.lifecycle.assert_active();
    self.vault_policy.assert_fee_limits(mint_fee_bps, redeem_fee_bps, admin_share_bps);

    let (previous_mint, previous_redeem, previous_admin) =
        (self.mint_fee_bps, self.redeem_fee_bps, self.admin_share_bps);
    assert!(
        previous_mint != mint_fee_bps || previous_redeem != redeem_fee_bps || previous_admin != admin_share_bps,
        blast_boosts_core::errors::fee_settings_unchanged!(),
    );

    self.mint_fee_bps = mint_fee_bps;
    self.redeem_fee_bps = redeem_fee_bps;
    self.admin_share_bps = admin_share_bps;

    (previous_mint, previous_redeem, previous_admin)
}

/// Checks locally decidable cap inputs before an adapter reads external prices.
public fun assert_max_order_notional_update<Product>(self: &State<Product>, max_order_notional: u64) {
    assert!(max_order_notional != self.max_order_notional, blast_boosts_core::errors::max_order_notional_unchanged!());
    assert!(max_order_notional > 0, blast_boosts_core::errors::invalid_max_order_notional!());
    self.vault_policy.rebalance_policy().assert_rebalance_capacity(max_order_notional, self.nav_cap);
}

/// Updates the live per-order notional cap.
///
/// The cap uses collateral atoms and does not limit total open exposure.
/// An exact one-lot reduce-only fill may exceed it; price checks still apply.
/// Adapter custody of `State<Product>` determines who can present mutable
/// access. The adapter must authenticate its currently selected risk module
/// before calling this function. Updates are available in every lifecycle
/// state because they change only the size of later calls, not the live position.
public fun set_max_order_notional<Product>(
    self: &mut State<Product>, max_order_notional: u64,
    base_oracle: PriceObservation, collateral_oracle: PriceObservation, lot_size: u64, now_at_ms: u64,
): u64 {
    self.assert_max_order_notional_update(max_order_notional);
    let previous = self.max_order_notional;
    let price_policy = self.vault_policy.price_policy();
    price_policy.assert_oracle_admitted(&base_oracle, now_at_ms);
    price_policy.assert_oracle_admitted(&collateral_oracle, now_at_ms);
    let max_order_base = rebalance_math::base_for_execution_notional_down(
        max_order_notional, base_oracle.price(), collateral_oracle.price(), lot_size,
        self.execution_bound().slippage_bps(), self.base_unit, self.collateral_unit,
    );
    assert_minimum_order_capacity(max_order_base, lot_size, self.vault_policy.min_order_lots());

    self.max_order_notional = max_order_notional;

    previous
}

/// Replaces the NAV cap and returns the previous one.
///
/// Adapter custody owns authentication. The new cap must satisfy the same
/// bound issuance applies; it may be lowered below the current NAV, which
/// only blocks further mints.
public fun set_nav_cap<Product>(self: &mut State<Product>, nav_cap: u64): u64 {
    let previous = self.nav_cap;
    assert!(nav_cap != previous, blast_boosts_core::errors::nav_cap_unchanged!());
    self.vault_policy.rebalance_policy().assert_nav_cap_valid(nav_cap);
    self.vault_policy.rebalance_policy().assert_rebalance_capacity(self.max_order_notional, nav_cap);

    self.nav_cap = nav_cap;

    previous
}

/// Returns the authoritative funding-only maintenance reserve.
///
/// Adapter operations use this value only for replay-complete post-state
/// events. Reserve mutation remains exclusive to core transitions.
public fun maintenance_reserve<Product>(self: &State<Product>): u64 {
    self.maintenance_reserve
}

// --- Priced Position Reads ---

public fun equity(self: &ActivePosition): u64 { self.equity }

public fun base(self: &ActivePosition): u64 { self.base }

public fun notional(self: &ActivePosition): u64 { self.notional }

public fun lot_size(self: &ActivePosition): u64 { self.lot_size }

public fun base_price(self: &ActivePosition): u64 { self.base_price }

public fun collateral_price(self: &ActivePosition): u64 { self.collateral_price }

// === Private Functions ===

/// Returns fee, local admin share, and reserve allocation in collateral atoms.
/// The fee rounds up, admin share rounds down, and reserve receives the remainder.
fun fee_allocation<Product>(self: &State<Product>, amount: u64, is_mint: bool): (u64, u64, u64) {
    accounting_math::fee_allocation(amount, self.live_fee_bps(is_mint), self.admin_share_bps)
}

/// Prices a flat seed observation for the orders that will open its position:
/// `equity` is the seed the adapter funded, and base and notional are zero
/// because the adapter opens the seed on an account it created in the same
/// transaction.
fun flat_position(observation: PositionObservation): ActivePosition {
    ActivePosition {
        equity: observation.venue_equity(),
        base: 0,
        notional: 0,
        lot_size: observation.lot_size(),
        base_price: observation.base_oracle().price(),
        collateral_price: observation.collateral_oracle().price(),
    }
}

fun assert_order_notional_within(max_order_notional: u64, order_notional: u64) {
    assert!(order_notional <= max_order_notional, blast_boosts_core::errors::order_notional_exceeds_maximum!());
}

/// Returns whether two positions share one oracle pair and one venue lot, so their
/// base and equity deltas can be attributed to the fills between them.
fun is_same_checkpoint(self: &ActivePosition, other: &ActivePosition): bool {
    self.base_price == other.base_price && self.collateral_price == other.collateral_price
        && self.lot_size == other.lot_size
}

/// The vault's `k`: no priced operation may lower NAV per share for the holders who stay.
/// Cross-multiplied so no division rounds the comparison.
fun assert_holders_not_diluted(nav_before: u64, supply_before: u64, nav_after: u64, supply_after: u64) {
    assert_invariant((nav_after as u128) * (supply_before as u128) >= (nav_before as u128) * (supply_after as u128));
}

/// A fact the arithmetic above establishes by construction; checked anyway, because a
/// mutation that breaks it must never be committed.
fun assert_invariant(holds: bool) {
    assert!(holds, blast_boosts_core::errors::invariant_violated!());
}

/// Returns `reserve` clamped to the policy ceiling for `position`'s notional.
///
/// The clamp moves nothing: collateral above the ceiling stays in venue
/// equity and simply counts as shareholder NAV from this checkpoint on. A
/// flat position has no funding exposure to size the ceiling against, so it
/// keeps the reserve intact for the position that reopens.
fun reserve_within_cap<Product>(self: &State<Product>, reserve: u64, position: &ActivePosition): u64 {
    if (position.notional == 0) reserve else reserve.min(self.vault_policy.reserve_cap(position.notional))
}

/// Profit recovery reopens exposure, so it cannot precede needed emergency reduction.
fun assert_realization_leverage<Product>(self: &State<Product>, position: &ActivePosition, reserve_priced: u64) {
    let nav = accounting_math::shareholder_nav(position.equity, reserve_priced);
    assert!(
        !self.vault_policy.rebalance_policy().is_leverage_above_max(position.notional, nav),
        blast_boosts_core::errors::active_leverage_above_cap!(),
    );
}

/// Returns the stored reserve as the ceiling admits it against `position`.
///
/// Every priced operation values shares against this, never the raw stored
/// reserve, so a release that a shrinking notional or a funding credit left
/// pending accrues to the holders at the checkpoint, not to the caller.
fun admitted_reserve<Product>(self: &State<Product>, position: &ActivePosition): u64 {
    self.reserve_within_cap(self.maintenance_reserve, position)
}

/// Whether leverage, priced against `reserve_priced`, is inside the rebalance band.
fun is_within_band<Product>(self: &State<Product>, position: &ActivePosition, reserve_priced: u64): bool {
    let nav = accounting_math::shareholder_nav(position.equity, reserve_priced);
    self.vault_policy.rebalance_policy().is_leverage_within_band(position.notional, nav)
}

/// The live rate one side of the vault charges.
fun live_fee_bps<Product>(self: &State<Product>, is_mint: bool): u64 {
    if (is_mint) { self.mint_fee_bps } else { self.redeem_fee_bps }
}

/// Whole-lot base worth at most `notional` at the position's sealed oracle pair.
fun base_for_notional(notional: u64, position: &ActivePosition, base_unit: u64, collateral_unit: u64): u64 {
    rebalance_math::base_for_oracle_notional_down(
        notional, position.base_price, position.collateral_price, position.lot_size, base_unit, collateral_unit,
    )
}

/// Prices the cap with the same bound as execution; only closes have the
/// one-lot escape hatch. A zero opening capacity has a specific diagnostic.
fun execution_order_base(
    cap: u64, position: &ActivePosition, bound: ExecutionBound, reduce_only: bool, base_unit: u64, collateral_unit: u64,
): u64 {
    let base = rebalance_math::base_for_execution_notional_down(
        cap, position.base_price, position.collateral_price, position.lot_size, bound.slippage_bps(),
        base_unit, collateral_unit,
    );
    if (reduce_only) return base.max(position.lot_size);
    assert!(base > 0, blast_boosts_core::errors::order_cap_below_minimum!());

    base
}

/// Configuration must cover a minimum proportional operation in one order.
/// Prices and venue lot sizes can change later; closes retain the one-lot path.
fun assert_minimum_order_capacity(max_order_base: u64, lot_size: u64, min_order_lots: u64) {
    assert!(
        max_order_base / lot_size >= min_order_lots,
        blast_boosts_core::errors::order_cap_below_minimum!(),
    );
}

/// Sizes against the reserve admitted by the resulting position and rounded-up
/// execution cost. Only one lot may cross target, and only into the full band.
fun increase_order<Product>(self: &State<Product>, position: &ActivePosition, venue_fee_bps: u64): (u64, bool) {
    let nav = accounting_math::shareholder_nav(position.equity, self.admitted_reserve(position));
    let rebalance = self.vault_policy.rebalance_policy();
    if ((position.notional as u128) * (constants::basis_points_denominator!() as u128)
        >= (nav as u128) * (rebalance.target_leverage_bps() as u128)) return (0, false);

    // The cap must permit a lot even when the target cannot; no opening escape hatch.
    let mut high = (self.max_order_base(position, false) / position.lot_size)
        .min((std::u64::max_value!() - position.base) / position.lot_size);
    let mut low = 0;
    while (low < high) {
        let candidate = low + (high - low).div_ceil(2);
        if (self.increase_fits(position, candidate * position.lot_size, venue_fee_bps, false)) {
            low = candidate;
        } else {
            high = candidate - 1;
        };
    };
    if (low > 0) return (low * position.lot_size, false);
    if (!rebalance.is_leverage_below_band(position.notional, nav)
        || !self.increase_fits(position, position.lot_size, venue_fee_bps, true)) return (0, false);

    (position.lot_size, true)
}

/// A monotone target predicate: more base cannot lower costs or the admitted
/// reserve. Price the resulting total base once so fractional lots cannot
/// overstate the band landing. Unrepresentable candidates are never executable.
fun increase_fits<Product>(
    self: &State<Product>, position: &ActivePosition, base: u64, venue_fee_bps: u64, band_landing: bool,
): bool {
    if (base > std::u64::max_value!() - position.base) return false;
    let order_notional = rebalance_math::oracle_notional_up(
        base, position.base_price, position.collateral_price, self.base_unit, self.collateral_unit,
    );
    if ((position.notional as u128) + (order_notional as u128) > std::u64::max_value!() as u128) return false;
    let notional_after = rebalance_math::oracle_notional_up(
        position.base + base, position.base_price, position.collateral_price, self.base_unit, self.collateral_unit,
    );
    let reserve_after = self.maintenance_reserve.min(self.vault_policy.reserve_cap(notional_after));
    let rebalance = self.vault_policy.rebalance_policy();
    let cost = rebalance_math::execution_cost_up(order_notional, venue_fee_bps, rebalance.max_slippage_bps());
    if (cost + (reserve_after as u128) >= position.equity as u128) return false;
    let nav_after = position.equity - reserve_after - (cost as u64);

    if (band_landing) rebalance.is_leverage_within_band(notional_after, nav_after)
    else rebalance.is_leverage_at_most_target(notional_after, nav_after)
}

/// Each fill and completion must use the reserve the next checkpoint will admit.
/// The ordinary target and sealed one-lot band landing remain distinct promises.
fun assert_increase_leverage<Product>(self: &State<Product>, position: &ActivePosition, band_landing: bool) {
    let nav = accounting_math::shareholder_nav(position.equity, self.admitted_reserve(position));
    let rebalance = self.vault_policy.rebalance_policy();
    if (band_landing) {
        assert!(rebalance.is_leverage_within_band(position.notional, nav), blast_boosts_core::errors::rebalance_outside_band!());
    } else {
        assert!(
            rebalance.is_leverage_at_most_target(position.notional, nav)
                && rebalance.is_leverage_below_max(position.notional, nav),
            blast_boosts_core::errors::active_leverage_above_cap!(),
        );
    };
}

/// Deposit-funded catch-up is at most one ordinary capped order. All execution
/// costs reduce the credited contribution, never existing holders' share value.
/// Actual completion independently requires both band edges and the NAV cap.
fun recovery_mint_base<Product>(
    self: &State<Product>, before: &ActivePosition, nav: u64, contribution: u64, proportional_base: u64, venue_fee_bps: u64,
): u64 {
    let funded_nav = nav.checked_add(contribution).destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());
    let base = self.funded_mint_increase_order(before, funded_nav, venue_fee_bps);
    let final_base = before.base.checked_add(base).destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());
    let final_notional = rebalance_math::oracle_notional_up(
        final_base, before.base_price, before.collateral_price, self.base_unit, self.collateral_unit,
    );
    assert!(
        base >= proportional_base && self.vault_policy.rebalance_policy().is_leverage_within_band(final_notional, funded_nav),
        blast_boosts_core::errors::mint_outside_rebalance_band!(),
    );

    base
}

/// Mint catch-up uses opening admitted reserve plus its fee credit at completion,
/// not the raw stored reserve used by maintenance. Keep its funded NAV basis.
fun funded_mint_increase_order<Product>(self: &State<Product>, position: &ActivePosition, nav: u64, venue_fee_bps: u64): u64 {
    let rebalance = self.vault_policy.rebalance_policy();

    rebalance_math::increase_base_down(
        nav, position.notional, rebalance.target_leverage_bps(), position.base_price, position.collateral_price,
        position.lot_size, self.max_order_notional, venue_fee_bps, rebalance.max_slippage_bps(),
        self.base_unit, self.collateral_unit,
    )
}

/// A fully filled batch may keep smaller progress if its actual result matches
/// the net improvement of a conservative full-batch projection. Full execution
/// is proved while accepting each fill, so cheaper/favorable fills may shrink
/// the final orders without failing an independently projected base threshold.
fun reduction_matches_capacity<Product>(
    self: &State<Product>, before: &ActivePosition, after: &ActivePosition, venue_fee_bps: u64,
): bool {
    let rebalance = self.vault_policy.rebalance_policy();
    let mut projected = *before;
    let mut steps = 0;
    while (steps < max_rebalance_orders()) {
        let base = self.reduction_order(&projected, false, venue_fee_bps);
        if (base == 0) break;
        let notional = rebalance_math::oracle_notional_up(
            base, before.base_price, before.collateral_price, self.base_unit, self.collateral_unit,
        );
        let cost = rebalance_math::execution_cost_up(notional, venue_fee_bps, rebalance.max_slippage_bps());
        if (cost >= projected.equity as u128) return false;
        projected.equity = projected.equity - (cost as u64);
        projected.base = projected.base - base;
        projected.notional = rebalance_math::oracle_notional_up(
            projected.base, before.base_price, before.collateral_price, self.base_unit, self.collateral_unit,
        );
        if (!accounting_math::is_shareholder_nav_positive(projected.equity, self.admitted_reserve(&projected))) return false;
        steps = steps + 1;
    };

    rebalance_math::reduction_matches_capacity(
        before.notional, accounting_math::shareholder_nav(before.equity, self.admitted_reserve(before)),
        after.notional, accounting_math::shareholder_nav(after.equity, self.admitted_reserve(after)),
        projected.notional, accounting_math::shareholder_nav(projected.equity, self.admitted_reserve(&projected)),
        rebalance.target_leverage_bps(),
    )
}

/// Sell toward target (ordinary) or the hard cap (emergency), using the reserve
/// admitted by the remaining exposure. Size at unchanged equity: charging the
/// worst cost here would oversell when actual fills are cheaper. Reprice after
/// each actual fill. The search includes only positive remaining positions;
/// a flat position keeps the full reserve and needs a separate cost check.
fun reduction_order<Product>(self: &State<Product>, position: &ActivePosition, emergency: bool, venue_fee_bps: u64): u64 {
    let rebalance = self.vault_policy.rebalance_policy();
    let target = if (emergency) rebalance.max_leverage_bps() else rebalance.target_leverage_bps();
    let nav = accounting_math::shareholder_nav(position.equity, self.admitted_reserve(position));
    if ((position.notional as u128) * (constants::basis_points_denominator!() as u128) <= (nav as u128) * (target as u128)) return 0;
    let lots = position.base / position.lot_size;
    let remaining = self.reduction_target_lots(position, target);
    let bound = rebalance.execution_bound(emergency);
    let max_base = execution_order_base(self.max_order_notional, position, bound, true, self.base_unit, self.collateral_unit);
    let mut base = ((lots - remaining) * position.lot_size).min(max_base);
    if (base == 0) return 0;
    // Flatness admits the full stored reserve. Keep one lot when that final
    // step cannot preserve positive holder value under the cost allowance.
    if (base == position.base && !self.reduction_preserves_nav(position, base, bound, venue_fee_bps)) {
        base = base - position.lot_size;
    };
    if (base == 0 || !emergency) return base;
    if (self.reduction_cost_up(position, base, bound, venue_fee_bps) < nav as u128) return base;

    // Bound costs by current admitted NAV, preserving value even on partial
    // fills before the reserve ceiling starts releasing funds. This predicate
    // is monotone despite ceiling and quote rounding. Reprice after every fill;
    // never reuse the plan's opening reserve for this affordability limit.
    let mut low = 0;
    let mut high = base / position.lot_size;
    while (low < high) {
        let candidate = low + (high - low).div_ceil(2);
        if (self.reduction_cost_up(position, candidate * position.lot_size, bound, venue_fee_bps) < nav as u128) {
            low = candidate;
        } else {
            high = candidate - 1;
        };
    };
    if (low > 0) return low * position.lot_size;
    // A single lot can still fit because it releases reserve. Retain that
    // minimum-sized close instead of imposing the old reserve on every fill.
    if (self.reduction_preserves_nav(position, position.lot_size, bound, venue_fee_bps)) return position.lot_size;

    0
}

/// Quote the actual remaining reserve, including the flat-position exception.
/// A partial fill and completion still prove positive NAV on their real facts.
fun reduction_preserves_nav<Product>(
    self: &State<Product>, position: &ActivePosition, base: u64, bound: ExecutionBound, venue_fee_bps: u64,
): bool {
    let mut after = *position;
    after.base = position.base - base;
    after.notional = rebalance_math::oracle_notional_up(
        after.base, position.base_price, position.collateral_price, self.base_unit, self.collateral_unit,
    );

    self.reduction_cost_up(position, base, bound, venue_fee_bps) + (self.admitted_reserve(&after) as u128)
        < position.equity as u128
}

/// Price truncation can hide up to one normalized oracle-price atom per base
/// unit. Charge that full value, its fee, and capture rounding separately from
/// slippage: multiplying an upper quote by slippage alone would miss the loss.
/// Applying the allowance to both sides keeps the bound venue-neutral.
fun reduction_cost_up<Product>(
    self: &State<Product>, position: &ActivePosition, base: u64, bound: ExecutionBound, venue_fee_bps: u64,
): u128 {
    let notional = rebalance_math::oracle_notional_up(
        base, position.base_price, position.collateral_price, self.base_unit, self.collateral_unit,
    );
    let price_rounding = rebalance_math::oracle_notional_up(
        base, 1, position.collateral_price, self.base_unit, self.collateral_unit,
    ) as u128;
    let fee_rounding = (price_rounding * (venue_fee_bps as u128)).div_ceil(constants::basis_points_denominator!() as u128);

    rebalance_math::execution_cost_up(notional, venue_fee_bps, bound.slippage_bps())
        + price_rounding + fee_rounding + REBALANCE_CAPTURE_ROUNDING_ALLOWANCE
}

/// Largest remaining whole-lot count under target at unchanged equity. The
/// common fully admitted reserve has a direct solution; search only when the
/// ceiling changes it. Observations already require whole-lot positions.
fun reduction_target_lots<Product>(self: &State<Product>, position: &ActivePosition, target: u64): u64 {
    if (self.maintenance_reserve < position.equity) {
        let target_notional = (((position.equity - self.maintenance_reserve) as u128) * (target as u128)
            / (constants::basis_points_denominator!() as u128)).min(position.notional as u128) as u64;
        let target_base = base_for_notional(target_notional, position, self.base_unit, self.collateral_unit).min(position.base);
        let notional = rebalance_math::oracle_notional_up(
            target_base, position.base_price, position.collateral_price, self.base_unit, self.collateral_unit,
        );
        if (self.maintenance_reserve <= self.vault_policy.reserve_cap(notional)) return target_base / position.lot_size;
    };
    let lots = position.base / position.lot_size;
    let mut low = 0;
    let mut high = lots;
    while (low < high) {
        let candidate = low + (high - low).div_ceil(2);
        let notional = rebalance_math::oracle_notional_up(
            candidate * position.lot_size, position.base_price, position.collateral_price,
            self.base_unit, self.collateral_unit,
        );
        let reserve = self.maintenance_reserve.min(self.vault_policy.reserve_cap(notional));
        let nav = position.equity - reserve;
        if ((notional as u128) * (constants::basis_points_denominator!() as u128) <= (nav as u128) * (target as u128)) {
            low = candidate;
        } else {
            high = candidate - 1;
        };
    };
    low
}

/// The cap is inclusive; the mint transition applies it to post-mint shareholder NAV.
fun assert_within_nav_cap<Product>(self: &State<Product>, nav: u64) {
    assert!(nav <= self.nav_cap, blast_boosts_core::errors::nav_cap_exceeded!());
}

/// All active priced paths consume fresh, attributable venue facts before mutation.
///
/// Shareholder NAV must be positive against the reserve the ceiling admits at
/// this position, the same figure every priced operation values against, so a
/// funding credit that lifted the stored reserve above the ceiling cannot lock
/// holders out of the operation that releases the excess to them.
fun validated_active_position<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    now_at_ms: u64,
): ActivePosition {
    self.vault_policy.assert_observation_priced(&observation, now_at_ms);

    self.active_position(observation)
}

/// Validates the oracle pair without requiring the venue mark to track it.
/// Only rebalance admission and fills of a sealed emergency plan use this path.
fun validated_oracle_position<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    now_at_ms: u64,
): ActivePosition {
    self.vault_policy.price_policy().assert_observation_oracles(&observation, now_at_ms);

    self.active_position(observation)
}

/// The position side and positive holder backing are required under either price admission.
fun active_position<Product>(self: &State<Product>, observation: PositionObservation): ActivePosition {
    assert!(
        observation.position_base() == 0 || observation.observed_side() == self.vault_policy.side(),
        blast_boosts_core::errors::invalid_position_observation!(),
    );

    let position = self.priced_position(observation);
    assert!(
        accounting_math::is_shareholder_nav_positive(position.equity, self.admitted_reserve(&position)),
        blast_boosts_core::errors::invalid_nav!(),
    );

    position
}

/// Reads a consumed observation into a position priced at its own pair; the
/// notional is the base valued at that pair, rounded up.
fun priced_position<Product>(self: &State<Product>, observation: PositionObservation): ActivePosition {
    let (base_price, collateral_price) = (observation.base_oracle().price(), observation.collateral_oracle().price());
    let base = observation.position_base();

    ActivePosition {
        equity: observation.venue_equity(),
        base,
        notional: rebalance_math::oracle_notional_up(
            base, base_price, collateral_price, self.base_unit, self.collateral_unit,
        ),
        lot_size: observation.lot_size(),
        base_price,
        collateral_price,
    }
}

/// Rejects an observation whose oracle pair is stale, uncertain, or diverges from the venue mark.
fun assert_observation_priced(vault_policy: &VaultPolicy, observation: &PositionObservation, now_at_ms: u64) {
    let price_policy = vault_policy.price_policy();

    price_policy.assert_observation_oracles(observation, now_at_ms);
    price_policy.assert_mark_within_oracle_divergence(
        observation.mark_price(),
        observation.base_oracle().price(),
    );
}

/// Both valuation sources remain fresh and sufficiently certain, including in emergencies.
fun assert_observation_oracles(price_policy: &PricePolicy, observation: &PositionObservation, now_at_ms: u64) {
    price_policy.assert_oracle_admitted(observation.base_oracle(), now_at_ms);
    price_policy.assert_oracle_admitted(observation.collateral_oracle(), now_at_ms);
}

/// Rejects one oracle price that is stale or carries too wide a confidence interval.
fun assert_oracle_admitted(price_policy: &PricePolicy, oracle: &PriceObservation, now_at_ms: u64) {
    price_policy.assert_price_fresh(oracle.publish_time_ms(), now_at_ms);
    price_policy.assert_confidence_within_bound(oracle.confidence(), oracle.price());
}

// === Test-Only Functions ===

#[test_only]
/// Returns the funding cost holders still carry from exhausted-reserve intervals.
public fun uncovered_deficit<Product>(self: &State<Product>): u64 {
    self.uncovered_deficit
}

#[test_only]
/// Returns whether the embedded lifecycle is active.
public fun is_active_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_active()
}

#[test_only]
/// Returns the immutable vault policy.
public fun vault_policy_for_testing<Product>(self: &State<Product>): VaultPolicy {
    self.vault_policy
}

#[test_only]
public fun max_order_notional_for_testing<Product>(self: &State<Product>): u64 {
    self.max_order_notional
}

#[test_only]
public fun nav_cap_for_testing<Product>(self: &State<Product>): u64 {
    self.nav_cap
}

#[test_only]
public fun is_within_nav_cap_for_testing<Product>(self: &State<Product>, nav: u64): bool {
    nav <= self.nav_cap
}

#[test_only]
public fun fee_allocation_for_testing<Product>(self: &State<Product>, amount: u64, is_mint: bool): (u64, u64, u64) {
    self.fee_allocation(amount, is_mint)
}

#[test_only]
/// Forces Unwinding for focused adapter tests.
public fun set_unwinding_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle.set_unwinding_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is Unwinding.
public fun is_unwinding_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_unwinding()
}

#[test_only]
/// Returns whether the lifecycle is Settled.
public fun is_settled_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_settled()
}

#[test_only]
/// Returns `(mint_fee_bps, redeem_fee_bps, admin_share_bps)` for test assertions.
public fun fee_settings<Product>(self: &State<Product>): (u64, u64, u64) {
    (self.mint_fee_bps, self.redeem_fee_bps, self.admin_share_bps)
}

#[test_only]
/// Exposes the dilution invariant so a test can prove it trips on a losing transition.
public fun assert_holders_not_diluted_for_testing(
    nav_before: u64,
    shares_before: u64,
    nav_after: u64,
    shares_after: u64,
) {
    assert_holders_not_diluted(nav_before, shares_before, nav_after, shares_after);
}

#[test_only]
/// Consumes an isolated state value at the end of a unit test.
public fun destroy_for_testing<Product>(self: State<Product>) {
    let State { .. } = self;
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_boosts_core::{
    accounting_math,
    constants,
    lifecycle::{Self, Lifecycle},
    observation::{Self, FundingSettlement, PositionObservation, PriceObservation},
    policy::{ExecutionBound, PositionSide, PricePolicy, VaultPolicy},
    rebalance_math,
    blast_boosts_core::VaultIssuer,
};

use fun assert_observation_priced as VaultPolicy.assert_observation_priced;
use fun assert_observation_oracles as PricePolicy.assert_observation_oracles;

use fun assert_oracle_admitted as PricePolicy.assert_oracle_admitted;
