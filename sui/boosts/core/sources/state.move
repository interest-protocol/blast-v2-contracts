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

/// Bounds per-transaction maintenance planning independently of adapter work limits.
const MAX_REBALANCE_ORDERS: u64 = 16;

// === Public Types ===

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
    /// Collateral inside the venue account that share pricing excludes. Every
    /// credit is clamped to the policy ceiling for the live notional, so the
    /// reserve can never grow past the share of the position it protects.
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
    reserve_before: u64,
    deposit: u64,
    expected_contribution: u64,
    reserve_fee: u64,
    admin_fee: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    supply: u64,
    minimum_shares: u64,
    base_to_buy: u64,
}

/// Linear terms for one proportional redemption, before any payout or fee credit.
public struct RedemptionPlan<phantom Product> {
    before: ActivePosition,
    reserve_before: u64,
    shares: u64,
    supply: u64,
    minimum_output: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    base_to_sell: u64,
}

/// Linear maintenance intent, recalculated only from accepted fixed-pair sessions.
public struct RebalancePlan<phantom Product> {
    before: ActivePosition,
    current: ActivePosition,
    /// The stored reserve at preparation; every later step must still see it.
    reserve: u64,
    /// The reserve as the ceiling admits it against `before`; every NAV in the plan uses it.
    reserve_priced: u64,
    increase: bool,
    /// Whether the plan began above the hard cap and so may use the emergency
    /// slippage bound. Such a reduction stops at the cap: below it only the
    /// ordinary bound applies, and a market that cannot fill within it must
    /// not revert the progress already made.
    emergency: bool,
    venue_fee_bps: u64,
    steps: u64,
}

/// Prevalidated funding donation terms held across the adapter deposit.
public struct DonationPlan<phantom Product> {
    before: ActivePosition,
    reserve_before: u64,
    amount: u64,
}

// === Public Functions ===

// --- Issuance ---

/// Creates one validated, uninitialized core state value.
///
/// The adapter must store the returned value inside its Vault. The caller's
/// live admin witness must contain the Vault issuer role. `nav_cap` must
/// satisfy `RebalancePolicy::assert_nav_cap_valid`; it stays adjustable
/// through `set_nav_cap`.
public fun new<Product>(
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
): State<Product> {
    admin_witness.assert_role(domain::vault_issuer_role());
    assert!(max_order_notional > 0, blast_boosts_core::errors::invalid_max_order_notional!());
    vault_policy.rebalance_policy().assert_nav_cap_valid(nav_cap);

    State {
        mint_fee_bps: vault_policy.initial_mint_fee_bps(),
        redeem_fee_bps: vault_policy.initial_redeem_fee_bps(),
        admin_share_bps: 0,
        nav_cap,
        vault_policy,
        max_order_notional,
        maintenance_reserve: 0,
        uncovered_deficit: 0,
        base_unit: 0,
        collateral_unit: 0,
        lifecycle: lifecycle::uninitialized(),
    }
}

// --- Initialization ---

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
    now_ms: u64,
): (u64, u64, u64, u64) {
    self.lifecycle.assert_can_activate();

    let seed_nav = self.seed_nav(&observation, seed_reserve, now_ms);
    assert!(observation.position_base() == 0, blast_boosts_core::errors::invalid_initialization_observation!());
    self.assert_within_nav_cap(seed_nav);

    let target_notional = accounting_math::target_notional_down(
        seed_nav,
        self.vault_policy.rebalance_policy().target_bps(),
    );
    assert!(
        seed_reserve <= self.vault_policy.reserve_cap(target_notional),
        blast_boosts_core::errors::seed_reserve_above_cap!(),
    );

    let (base_price, collateral_price, lot_size) = (
        observation.base_oracle().price(),
        observation.collateral_oracle().price(),
        observation.lot_size(),
    );
    observation.destroy();

    (target_notional, base_price, collateral_price, lot_size)
}

/// Returns the immutable position side and live per-order notional bound used by activation.
///
/// The adapter calls this before any venue mutation. The lifecycle guard makes
/// an installed or otherwise activated State ineligible for a second seed.
public fun initialization_constraints<Product>(
    self: &State<Product>,
): (PositionSide, u64) {
    self.lifecycle.assert_can_activate();

    (self.vault_policy.side(), self.max_order_notional)
}

/// Rejects a seed session whose execution diverges beyond max slippage.
///
/// Initialization always increases risk, so the wider emergency max slippage is
/// never available on this edge.
public fun assert_initialization_execution<Product>(
    self: &State<Product>,
    reference_price: u64,
    execution_price: u64,
) {
    self.lifecycle.assert_can_activate();
    self.vault_policy
        .rebalance_policy()
        .assert_execution_within_max_slippage(
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
        order_notional <= self.max_order_notional,
        blast_boosts_core::errors::order_notional_exceeds_maximum!(),
    );
}

/// Activates one fully observed long or short seed.
///
/// Returns the seed's reserve-excluded shareholder NAV in atomic collateral
/// units and the priced seed position. Every lifecycle, accounting, price,
/// capacity, leverage, and minimum-operation guard runs before reserve or
/// lifecycle mutation. No administrative witness is accepted after State
/// construction.
public fun initialize<Product>(
    self: &mut State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    base_decimals: u8,
    collateral_decimals: u8,
    now_ms: u64,
): (u64, ActivePosition) {
    self.lifecycle.assert_can_activate();
    assert!(
        base_decimals <= constants::max_asset_decimals!()
            && collateral_decimals <= constants::max_asset_decimals!(),
        blast_boosts_core::errors::invalid_asset_decimals!(),
    );

    // The units are pure facts about the assets; the seed is valued in them below.
    self.base_unit = 10u64.pow(base_decimals);
    self.collateral_unit = 10u64.pow(collateral_decimals);
    let (seed_nav, seeded) = validated_initialization_nav(self, observation, seed_reserve, now_ms);

    self.lifecycle.activate();
    self.maintenance_reserve = seed_reserve;

    (seed_nav, seeded)
}

// --- Active Operations ---

/// Rejects unavailable active lifecycle before the adapter touches the venue.
public fun assert_active<Product>(self: &State<Product>) {
    self.lifecycle.assert_active();
}

/// Returns policy-derived direction and the current per-order cap while active.
public fun active_constraints<Product>(self: &State<Product>): (PositionSide, u64) {
    self.lifecycle.assert_active();

    (self.vault_policy.side(), self.max_order_notional)
}

/// Applies max slippage to ordinary active mint and redemption sessions.
public fun assert_active_execution<Product>(self: &State<Product>, reference: u64, executed: u64) {
    self.lifecycle.assert_active();
    self.vault_policy.rebalance_policy().assert_execution_within_max_slippage(reference, executed);
}

// --- Mint ---

/// Seals a proportional increase from reserve-excluded NAV and the user's limits.
/// The adapter must authenticate the observation and native share supply.
public fun prepare_mint<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    deposit: u64,
    supply: u64,
    minimum_shares: u64,
    now_ms: u64,
): MintPlan<Product> {
    self.lifecycle.assert_active();
    assert!(supply > 0, blast_boosts_core::errors::invalid_share_supply!());

    let before = validated_active_position(self, observation, now_ms);
    let reserve_priced = self.admitted_reserve(&before);
    assert!(
        self.is_within_band(&before, reserve_priced),
        blast_boosts_core::errors::mint_outside_rebalance_band!(),
    );
    let nav = accounting_math::shareholder_nav(before.equity, reserve_priced);

    let (fee, admin_fee, reserve_fee) = self.fee_allocation(deposit, true);
    let expected_contribution = deposit - fee;
    assert!(expected_contribution > 0, blast_boosts_core::errors::nonpositive_contribution!());
    let base_to_buy = accounting_math::mint_base_to_buy_down(
        expected_contribution, before.base, nav, before.lot_size, self.vault_policy.min_order_lots(),
    );

    MintPlan {
        before,
        reserve_before: self.maintenance_reserve,
        deposit,
        expected_contribution,
        reserve_fee,
        admin_fee,
        fee_bps: self.mint_fee_bps,
        admin_share_bps: self.admin_share_bps,
        supply,
        minimum_shares,
        base_to_buy,
    }
}

/// Returns the entire required whole-lot increase, not caller-selected sizing.
public fun base_to_buy<Product>(self: &MintPlan<Product>): u64 { self.base_to_buy }

/// Returns the admin cash the adapter must retain before depositing collateral.
public fun admin_fee<Product>(self: &MintPlan<Product>): u64 { self.admin_fee }

/// Returns the sealed input for completed adapter accounting facts.
public fun mint_deposit<Product>(self: &MintPlan<Product>): u64 { self.deposit }

/// The position the mint was priced against; the adapter trades at its pair and lot.
public fun mint_position<Product>(self: &MintPlan<Product>): ActivePosition { self.before }

/// Completes a full proportional fill and credits only its reserve allocation.
/// The credited contribution is capped at the deposit net of the whole fee, so
/// a favorable fill accrues to existing holders (ADR 0084 D3).
/// The returned shares are minted through the adapter's native share authority.
/// Returns shares, contribution, fee, admin, reserve and the two sealed rates.
public fun complete_mint<Product>(
    self: &mut State<Product>,
    plan: MintPlan<Product>,
    observation: PositionObservation,
    now_ms: u64,
): (u64, u64, u64, u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let MintPlan {
        before, reserve_before, deposit: _, expected_contribution, reserve_fee,
        admin_fee, fee_bps, admin_share_bps, supply, minimum_shares, base_to_buy,
    } = plan;
    assert!(self.maintenance_reserve == reserve_before, blast_boosts_core::errors::active_checkpoint_changed!());

    let after = validated_active_position(self, observation, now_ms);
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
    let (nav_after, contribution, shares) = accounting_math::allocated_mint_quote(
        before.equity, after.equity, reserve_priced, reserve_after, expected_contribution,
        supply, minimum_shares,
    );
    accounting_math::assert_mint_base_within_bounds(
        after.base, expected_contribution, contribution, before.base,
        accounting_math::shareholder_nav(before.equity, reserve_priced),
        before.lot_size, self.vault_policy.min_order_lots(),
    );
    self.assert_within_nav_cap(nav_after);
    assert!(
        accounting_math::is_accounting_leverage_below_limit(
            after.notional, after.equity, reserve_after,
            self.vault_policy.rebalance_policy().max_leverage_bps(),
        ),
        blast_boosts_core::errors::active_leverage_above_cap!(),
    );

    self.maintenance_reserve = reserve_after;

    (shares, contribution, admin_fee + reserve_fee, admin_fee, reserve_fee, fee_bps, admin_share_bps)
}

// --- Redemption ---

/// Seals a rounded-up attributable close and the redeemer's output/fee limits.
public fun prepare_redemption<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    shares: u64,
    supply: u64,
    minimum_output: u64,
    now_ms: u64,
): RedemptionPlan<Product> {
    self.lifecycle.assert_active();

    let before = validated_active_position(self, observation, now_ms);
    let (minimum_base, _) = accounting_math::redemption_base_bounds(
        shares, before.base, supply, before.lot_size, self.vault_policy.min_order_lots(),
    );
    let base_to_sell = before.base - minimum_base;

    RedemptionPlan {
        before, reserve_before: self.maintenance_reserve, shares, supply, minimum_output,
        fee_bps: self.redeem_fee_bps, admin_share_bps: self.admin_share_bps, base_to_sell,
    }
}

/// Returns the full reduce-only order amount; flat redemptions require no order.
public fun base_to_sell<Product>(self: &RedemptionPlan<Product>): u64 { self.base_to_sell }

/// The position the redemption was priced against.
public fun redemption_position<Product>(self: &RedemptionPlan<Product>): ActivePosition { self.before }

/// Shares the redeemer must burn.
public fun redemption_shares<Product>(self: &RedemptionPlan<Product>): u64 { self.shares }

/// Base that must remain after the sealed close.
public fun base_after_sell<Product>(self: &RedemptionPlan<Product>): u64 { self.before.base - self.base_to_sell }

/// Redemption fee rate sealed with the plan.
public fun redemption_fee_bps<Product>(self: &RedemptionPlan<Product>): u64 { self.fee_bps }

/// Admin allocation rate sealed with the plan.
public fun redemption_admin_share_bps<Product>(self: &RedemptionPlan<Product>): u64 { self.admin_share_bps }

/// Validates actual post-withdrawal backing and margin before a native share burn.
public fun assert_redemption_cash_out<Product>(
    self: &State<Product>, observation: PositionObservation, equity: u64, base: u64,
    base_price: u64, collateral_price: u64, now_ms: u64,
) {
    self.lifecycle.assert_active();

    let after = validated_active_position(self, observation, now_ms);
    assert!(
        after.equity == equity && after.base == base && after.is_priced_at(base_price, collateral_price),
        blast_boosts_core::errors::active_checkpoint_changed!(),
    );
}

/// Computes payout after unwind and credits the fee once, excluding admin cash.
/// The gross is capped at the proportional claim, so a favorable unwind accrues
/// to the remaining holders (ADR 0084 D3).
/// Returns user payout, locally retained admin cash, and required final venue equity.
/// The adapter must withdraw exactly their sum and prove the final cash checkpoint.
public fun complete_redemption<Product>(
    self: &mut State<Product>,
    plan: RedemptionPlan<Product>,
    observation: PositionObservation,
    now_ms: u64,
): (u64, u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let RedemptionPlan {
        before, reserve_before, shares, supply, minimum_output, fee_bps, admin_share_bps, base_to_sell,
    } = plan;
    assert!(self.maintenance_reserve == reserve_before, blast_boosts_core::errors::active_checkpoint_changed!());

    let after = validated_active_position(self, observation, now_ms);
    assert!(before.is_same_checkpoint(&after), blast_boosts_core::errors::active_checkpoint_changed!());
    assert!(
        before.base >= after.base && before.base - after.base == base_to_sell,
        blast_boosts_core::errors::active_fill_incomplete!(),
    );
    accounting_math::assert_redemption_base_within_bounds(
        after.base, shares, before.base, supply, before.lot_size, self.vault_policy.min_order_lots(),
    );

    let (reserve_with_fee, nav_kept, fee, net) = accounting_math::redemption_accounting_quote(
        shares, before.equity, after.equity, self.admitted_reserve(&before), supply, fee_bps,
    );
    assert!(net >= minimum_output, blast_boosts_core::errors::redemption_output_below_minimum!());
    let admin = accounting_math::admin_share_down(fee, admin_share_bps);
    let reserve_retained = reserve_with_fee - admin;
    let final_equity = nav_kept.checked_add(reserve_retained)
        .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());

    self.maintenance_reserve = self.reserve_within_cap(reserve_retained, &after);

    (net, admin, final_equity, fee, fee - admin)
}

// --- Rebalance ---

/// Whether a rebalance would be admitted against this observation: the position,
/// priced against the admitted reserve, sits outside the band. A keeper's dry
/// run; `prepare_rebalance` asks the same question and aborts on `false`.
public fun needs_rebalance<Product>(self: &State<Product>, observation: PositionObservation, now_ms: u64): bool {
    self.lifecycle.assert_active();

    let position = validated_active_position(self, observation, now_ms);

    !self.is_within_band(&position, self.admitted_reserve(&position))
}

/// Derives public maintenance intent from exact outside-band ratios, never caller orders.
public fun prepare_rebalance<Product>(
    self: &State<Product>, observation: PositionObservation, venue_fee_bps: u64, now_ms: u64,
): RebalancePlan<Product> {
    self.lifecycle.assert_active();
    assert!(
        venue_fee_bps <= constants::basis_points_denominator!(),
        blast_boosts_core::errors::venue_fee_unusable!(),
    );

    let before = validated_active_position(self, observation, now_ms);
    let reserve_priced = self.admitted_reserve(&before);
    assert!(!self.is_within_band(&before, reserve_priced), blast_boosts_core::errors::rebalance_inside_band!());

    let nav = accounting_math::shareholder_nav(before.equity, reserve_priced);
    let rebalance = self.vault_policy.rebalance_policy();
    let increase = rebalance.is_leverage_below_band(before.notional, nav);

    RebalancePlan {
        before,
        current: before,
        reserve: self.maintenance_reserve,
        reserve_priced,
        increase,
        emergency: !increase && rebalance.is_leverage_above_max(before.notional, nav),
        venue_fee_bps,
        steps: 0,
    }
}

/// Returns next whole-lot size, increase intent and current wider-slippage permission.
///
/// A zero size finishes planning; the adapter independently caps work at
/// sixteen sessions. An emergency reduction finishes as soon as leverage is
/// no longer above the hard cap, so the wider bound never covers an order
/// placed below it and a wide market cannot revert the orders placed above it.
public fun rebalance_order<Product>(self: &State<Product>, plan: &RebalancePlan<Product>): (u64, bool, bool) {
    self.lifecycle.assert_active();
    assert!(self.maintenance_reserve == plan.reserve, blast_boosts_core::errors::active_checkpoint_changed!());
    if (plan.steps == MAX_REBALANCE_ORDERS) return (0, plan.increase, false);

    let position = &plan.current;
    let nav = accounting_math::shareholder_nav(position.equity, plan.reserve_priced);
    if (plan.increase) return (self.increase_order(position, nav, plan.venue_fee_bps), true, false);

    let wide = self.vault_policy.rebalance_policy().is_leverage_above_max(position.notional, nav);
    if (plan.emergency && !wide) return (0, false, false);

    (self.reduction_order(position, nav), false, wide)
}

/// The position the rebalance was priced against.
public fun rebalance_position<Product>(self: &RebalancePlan<Product>): ActivePosition { self.before }

/// The current authenticated ratio alone selects ordinary or wider max slippage.
public fun assert_rebalance_execution<Product>(
    self: &State<Product>, plan: &RebalancePlan<Product>, reference: u64, executed: u64,
) {
    let (_, _, wide) = self.rebalance_order(plan);
    let rebalance = self.vault_policy.rebalance_policy();

    if (wide) {
        rebalance.assert_execution_within_emergency_max_slippage(reference, executed);
    } else {
        rebalance.assert_execution_within_max_slippage(reference, executed);
    };
}

/// Advances only exact partial whole-lot fills under sealed intent and the fixed oracle pair.
public fun accept_rebalance_fill<Product>(
    self: &State<Product>, plan: &mut RebalancePlan<Product>, observation: PositionObservation,
    filled: u64, now_ms: u64,
) {
    let (requested, increase, _) = self.rebalance_order(plan);
    assert!(
        filled > 0 && filled <= requested && filled % plan.current.lot_size == 0,
        blast_boosts_core::errors::active_fill_incomplete!(),
    );

    let after = validated_active_position(self, observation, now_ms);
    assert!(plan.before.is_same_checkpoint(&after), blast_boosts_core::errors::active_checkpoint_changed!());
    let expected_base = if (increase) {
        plan.current.base.checked_add(filled).destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!())
    } else {
        plan.current.base - filled
    };
    assert!(after.base == expected_base, blast_boosts_core::errors::active_fill_incomplete!());

    if (increase) {
        let nav = accounting_math::shareholder_nav(after.equity, plan.reserve_priced);
        let rebalance = self.vault_policy.rebalance_policy();
        assert!(
            rebalance.is_leverage_at_most_target(after.notional, nav)
                && rebalance.is_leverage_below_max(after.notional, nav),
            blast_boosts_core::errors::active_leverage_above_cap!(),
        );
    };

    plan.current = after;
    plan.steps = plan.steps + 1;
}

/// Completes holder-funded maintenance without changing reserve, supply or admin cash.
/// Returns authenticated before/after equity and base for one completed event.
public fun complete_rebalance<Product>(
    self: &State<Product>, plan: RebalancePlan<Product>,
): (u64, u64, u64, u64, bool) {
    self.lifecycle.assert_active();
    let RebalancePlan {
        before, current, reserve, reserve_priced, increase, emergency: _, venue_fee_bps: _, steps,
    } = plan;
    assert!(reserve == self.maintenance_reserve, blast_boosts_core::errors::active_checkpoint_changed!());
    assert!(steps > 0, blast_boosts_core::errors::rebalance_no_progress!());

    let before_nav = accounting_math::shareholder_nav(before.equity, reserve_priced);
    let after_nav = accounting_math::shareholder_nav(current.equity, reserve_priced);
    let rebalance = self.vault_policy.rebalance_policy();
    let improved = if (increase) {
        current.base > before.base
            && rebalance_math::leverage_rose(before.notional, before_nav, current.notional, after_nav)
    } else {
        current.base < before.base
            && rebalance_math::reduction_is_sufficient(
                before.notional, before_nav, current.notional, after_nav,
                rebalance.target_bps(), rebalance.min_leverage_improvement_bps(),
                rebalance_math::oracle_notional_up(
                    current.lot_size, current.base_price, current.collateral_price,
                    self.base_unit, self.collateral_unit,
                ),
            )
    };
    assert!(improved, blast_boosts_core::errors::rebalance_no_progress!());

    (before.equity, current.equity, before.base, current.base, increase)
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
    let is_cost = settlement.is_cost();
    let amount = settlement.amount();
    settlement.destroy();

    if (is_cost) {
        let (reserve_after, absorbed, uncovered) = accounting_math::absorb_funding_cost(
            self.maintenance_reserve,
            amount,
        );

        self.maintenance_reserve = reserve_after;
        self.uncovered_deficit = self.uncovered_deficit
            .checked_add(uncovered)
            .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());

        (absorbed, uncovered, 0)
    } else {
        let restored = amount.min(self.uncovered_deficit);

        self.uncovered_deficit = self.uncovered_deficit - restored;
        self.maintenance_reserve = self.maintenance_reserve
            .checked_add(amount - restored)
            .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());

        (0, 0, restored)
    }
}

/// Returns the funding cost holders still carry from exhausted-reserve intervals.
public fun uncovered_deficit<Product>(self: &State<Product>): u64 {
    self.uncovered_deficit
}

/// Validates donation accounting before the adapter sends collateral to the venue.
public fun prepare_donation<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    amount: u64,
    now_ms: u64,
): DonationPlan<Product> {
    self.lifecycle.assert_active();
    assert!(amount > 0, blast_boosts_core::errors::zero_amount!());

    DonationPlan {
        before: validated_active_position(self, observation, now_ms),
        reserve_before: self.maintenance_reserve,
        amount,
    }
}

/// Finishes an exact donation without creating any supply or admin entitlement.
public fun complete_donation<Product>(
    self: &mut State<Product>,
    plan: DonationPlan<Product>,
    after: PositionObservation,
    now_ms: u64,
) {
    self.lifecycle.assert_active();
    let DonationPlan { before, reserve_before, amount } = plan;
    assert!(reserve_before == self.maintenance_reserve, blast_boosts_core::errors::active_checkpoint_changed!());

    let after = validated_active_position(self, after, now_ms);
    assert!(
        before.is_same_checkpoint(&after) && before.base == after.base && before.notional == after.notional
            && after.equity >= before.equity && after.equity - before.equity == amount,
        blast_boosts_core::errors::active_checkpoint_changed!(),
    );

    let reserve_funded = self.maintenance_reserve.checked_add(amount)
        .destroy_or!(abort blast_boosts_core::errors::arithmetic_overflow!());

    self.maintenance_reserve = self.reserve_within_cap(reserve_funded, &after);
}

/// Rejects venue synchronization after the local cash pool has been sealed.
public fun assert_can_sync<Product>(self: &State<Product>) {
    self.lifecycle.assert_can_sync();
}

// --- Shutdown ---

/// Irreversibly stops ordinary operations. The owning adapter authenticates shutdown authority.
public fun begin_shutdown<Product>(self: &mut State<Product>) {
    self.lifecycle.begin_shutdown();
}

/// Authorizes only close-only venue progress before finalization.
public fun assert_unwinding<Product>(self: &State<Product>) {
    self.lifecycle.assert_unwinding();
}

/// Prices only a close-only order; insolvency and the reserve do not gate an exit.
public fun unwind_constraints<Product>(
    self: &State<Product>, base_oracle: PriceObservation, collateral_oracle: PriceObservation, now_ms: u64,
): (PositionSide, u64, u64, u64) {
    self.assert_unwinding();
    let price_policy = self.vault_policy.price_policy();
    assert_oracle_admitted(&price_policy, &base_oracle, now_ms);
    assert_oracle_admitted(&price_policy, &collateral_oracle, now_ms);
    let (base_price, collateral_price) = (base_oracle.price(), collateral_oracle.price());
    base_oracle.destroy();
    collateral_oracle.destroy();

    (self.vault_policy.side(), self.max_order_notional, base_price, collateral_price)
}

/// Shutdown uses its immutable wider bound without an active leverage/NAV prerequisite.
public fun assert_unwind_execution<Product>(self: &State<Product>, reference: u64, executed: u64) {
    self.assert_unwinding();
    self.vault_policy.rebalance_policy().assert_execution_within_emergency_max_slippage(reference, executed);
}

/// Consumes the reserve book entry only after the adapter proves complete local cash recovery.
public fun finalize_shutdown<Product>(self: &mut State<Product>, native_supply: u64, locked: u64): u64 {
    assert!(native_supply >= locked, blast_boosts_core::errors::invalid_share_supply!());

    self.lifecycle.finalize_shutdown();
    self.maintenance_reserve = 0;

    native_supply - locked
}

/// Rejects terminal claims before any adapter cash-field access.
public fun assert_settled<Product>(self: &State<Product>) {
    self.lifecycle.assert_settled();
}

/// Fee-free claim against current cash and native supply, excluding the immutable seed.
public fun shutdown_claim_quote<Product>(
    self: &State<Product>, cash: u64, native_supply: u64, locked: u64, shares: u64, minimum: u64,
): u64 {
    self.lifecycle.assert_settled();
    assert!(native_supply >= locked, blast_boosts_core::errors::invalid_share_supply!());
    let eligible = native_supply - locked;
    assert!(shares > 0 && shares <= eligible, blast_boosts_core::errors::invalid_share_amount!());

    let output = cash.mul_div(shares, eligible);
    assert!(cash == 0 || output > 0, blast_boosts_core::errors::zero_net_payout!());
    assert!(output >= minimum, blast_boosts_core::errors::redemption_output_below_minimum!());

    output
}

// --- Administration ---

/// Updates future fee collections under immutable issuance caps.
/// Adapter custody owns authentication; no assets or past allocations move.
public fun set_fees<Product>(
    self: &mut State<Product>,
    mint_bps: u64,
    redeem_bps: u64,
    admin_share_bps: u64,
): (u64, u64, u64) {
    assert!(
        self.lifecycle.is_uninitialized() || self.lifecycle.is_active(),
        blast_boosts_core::errors::operation_not_permitted_in_lifecycle!(),
    );
    self.vault_policy.assert_fee_limits(mint_bps, redeem_bps, admin_share_bps);

    let (previous_mint, previous_redeem, previous_admin) =
        (self.mint_fee_bps, self.redeem_fee_bps, self.admin_share_bps);
    assert!(
        previous_mint != mint_bps || previous_redeem != redeem_bps || previous_admin != admin_share_bps,
        blast_boosts_core::errors::fee_settings_unchanged!(),
    );

    self.mint_fee_bps = mint_bps;
    self.redeem_fee_bps = redeem_bps;
    self.admin_share_bps = admin_share_bps;

    (previous_mint, previous_redeem, previous_admin)
}

/// Returns fee, local admin share, and reserve allocation in collateral atoms.
/// The fee rounds up, admin share rounds down, and reserve receives the remainder.
public fun fee_allocation<Product>(self: &State<Product>, amount: u64, mint: bool): (u64, u64, u64) {
    accounting_math::fee_allocation(amount, self.live_fee_bps(mint), self.admin_share_bps)
}

/// Checks a user's fee ceiling before the adapter interacts with the venue.
public fun assert_user_fee_limit<Product>(self: &State<Product>, mint: bool, maximum: u64) {
    assert!(self.live_fee_bps(mint) <= maximum, blast_boosts_core::errors::user_fee_limit_exceeded!());
}

/// Updates the live per-call maximum order notional.
///
/// This value limits the absolute atomic-USDC notional of one adapter order.
/// It does not limit a user's deposit or the Vault's total open position.
/// Adapter custody of `State<Product>` determines who can present mutable
/// access. The adapter must authenticate its currently selected risk module
/// before calling this function. Updates are available in every lifecycle
/// state because they change only the size of later calls, not the live position.
public fun set_max_order_notional<Product>(self: &mut State<Product>, max_order_notional: u64): u64 {
    let previous = self.max_order_notional;
    assert!(max_order_notional != previous, blast_boosts_core::errors::max_order_notional_unchanged!());
    assert!(max_order_notional > 0, blast_boosts_core::errors::invalid_max_order_notional!());

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

    self.nav_cap = nav_cap;
    previous
}

public fun nav_cap<Product>(self: &State<Product>): u64 {
    self.nav_cap
}

/// Returns whether shareholder NAV is at or below the cap.
///
/// The cap is inclusive and is tied to executable book depth, not headline
/// open interest. The mint transition applies it to post-mint shareholder
/// NAV from the canonical accounting checkpoint.
public fun is_within_nav_cap<Product>(self: &State<Product>, nav: u64): bool {
    nav <= self.nav_cap
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

/// Returns whether the position was valued at exactly this oracle pair.
fun is_priced_at(self: &ActivePosition, base_price: u64, collateral_price: u64): bool {
    self.base_price == base_price && self.collateral_price == collateral_price
}

/// Returns whether two positions share one oracle pair and one venue lot, so their
/// base and equity deltas can be attributed to the fills between them.
fun is_same_checkpoint(self: &ActivePosition, other: &ActivePosition): bool {
    self.is_priced_at(other.base_price, other.collateral_price) && self.lot_size == other.lot_size
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
fun live_fee_bps<Product>(self: &State<Product>, mint: bool): u64 {
    if (mint) { self.mint_fee_bps } else { self.redeem_fee_bps }
}

/// Whole-lot base worth at most `notional` at the position's sealed oracle pair.
fun base_for_notional<Product>(self: &State<Product>, notional: u64, position: &ActivePosition): u64 {
    rebalance_math::base_for_notional_down(
        notional, position.base_price, position.collateral_price, position.lot_size,
        self.base_unit, self.collateral_unit,
    )
}

/// The largest next buy that lands at or under target after its own execution cost, capped per order.
fun increase_order<Product>(self: &State<Product>, position: &ActivePosition, nav: u64, venue_fee_bps: u64): u64 {
    let rebalance = self.vault_policy.rebalance_policy();

    rebalance_math::increase_base_down(
        nav, position.notional, rebalance.target_bps(), position.base_price, position.collateral_price,
        position.lot_size, self.max_order_notional, venue_fee_bps, rebalance.max_slippage_bps(),
        self.base_unit, self.collateral_unit,
    )
}

/// The next sell toward the target position, capped per order; zero at or under target.
fun reduction_order<Product>(self: &State<Product>, position: &ActivePosition, nav: u64): u64 {
    let target_notional =
        accounting_math::target_notional_down(nav, self.vault_policy.rebalance_policy().target_bps());
    let target_base = self.base_for_notional(target_notional, position);
    if (position.base <= target_base) return 0;

    let cap_base = self.base_for_notional(self.max_order_notional, position);

    (position.base - target_base).min(cap_base) / position.lot_size * position.lot_size
}

fun assert_within_nav_cap<Product>(self: &State<Product>, nav: u64) {
    assert!(self.is_within_nav_cap(nav), blast_boosts_core::errors::nav_cap_exceeded!());
}

/// All active priced paths consume fresh, attributable venue facts before mutation.
fun validated_active_position<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    now_ms: u64,
): ActivePosition {
    self.assert_observation_priced(&observation, now_ms);
    assert!(
        observation.position_base() == 0 || observation.observed_side() == self.vault_policy.side(),
        blast_boosts_core::errors::invalid_position_observation!(),
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(observation.venue_equity(), self.maintenance_reserve),
        blast_boosts_core::errors::invalid_nav!(),
    );

    self.priced_position(observation)
}

/// Reads a consumed observation into a position priced at its own pair; the
/// notional is the base valued at that pair, rounded up.
fun priced_position<Product>(self: &State<Product>, observation: PositionObservation): ActivePosition {
    let (base_price, collateral_price) = (observation.base_oracle().price(), observation.collateral_oracle().price());
    let base = observation.position_base();
    let position = ActivePosition {
        equity: observation.venue_equity(),
        base,
        notional: rebalance_math::oracle_notional_up(
            base, base_price, collateral_price, self.base_unit, self.collateral_unit,
        ),
        lot_size: observation.lot_size(),
        base_price,
        collateral_price,
    };
    observation.destroy();

    position
}

/// Rejects an observation whose oracle pair is stale, uncertain, or diverges from the venue mark.
fun assert_observation_priced<Product>(
    self: &State<Product>,
    observation: &PositionObservation,
    now_ms: u64,
) {
    let price_policy = self.vault_policy.price_policy();

    assert_oracle_admitted(&price_policy, observation.base_oracle(), now_ms);
    assert_oracle_admitted(&price_policy, observation.collateral_oracle(), now_ms);
    price_policy.assert_mark_within_oracle_divergence(
        observation.mark_price(),
        observation.base_oracle().price(),
    );
}

/// Rejects one oracle price that is stale or carries too wide a confidence interval.
fun assert_oracle_admitted(price_policy: &PricePolicy, oracle: &PriceObservation, now_ms: u64) {
    price_policy.assert_price_fresh(oracle.publish_time_ms(), now_ms);
    price_policy.assert_confidence_within_bound(oracle.confidence(), oracle.price());
}

/// Returns the seed's reserve-excluded shareholder NAV after the backing and price guards.
///
/// Guard order is the reserve backing, positive NAV, then the oracle pair.
fun seed_nav<Product>(
    self: &State<Product>,
    observation: &PositionObservation,
    seed_reserve: u64,
    now_ms: u64,
): u64 {
    let venue_equity = observation.venue_equity();
    assert!(
        accounting_math::is_reserve_backed(venue_equity, seed_reserve),
        blast_boosts_core::errors::maintenance_reserve_exceeds_equity!(),
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        blast_boosts_core::errors::invalid_nav!(),
    );
    self.assert_observation_priced(observation, now_ms);

    accounting_math::shareholder_nav(venue_equity, seed_reserve)
}

/// Consumes and validates a complete seed without mutable access to State.
fun validated_initialization_nav<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    now_ms: u64,
): (u64, ActivePosition) {
    let seed_nav = self.seed_nav(&observation, seed_reserve, now_ms);
    assert!(
        observation.observed_side() == self.vault_policy.side(),
        blast_boosts_core::errors::invalid_initialization_observation!(),
    );
    self.assert_within_nav_cap(seed_nav);

    let seeded = self.priced_position(observation);
    assert!(
        self.vault_policy.rebalance_policy().is_leverage_within_band(seeded.notional, seed_nav),
        blast_boosts_core::errors::initialization_leverage_unhealthy!(),
    );
    assert!(
        seed_reserve <= self.vault_policy.reserve_cap(seeded.notional),
        blast_boosts_core::errors::seed_reserve_above_cap!(),
    );
    assert!(
        accounting_math::is_base_above_min_order(seeded.base, seeded.lot_size, self.vault_policy.min_order_lots()),
        blast_boosts_core::errors::initialization_base_below_min_order!(),
    );

    (seed_nav, seeded)
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
/// Returns the immutable vault policy.
public fun vault_policy_for_testing<Product>(self: &State<Product>): VaultPolicy {
    self.vault_policy
}

#[test_only]
/// Returns the live maximum order notional.
public fun max_order_notional_for_testing<Product>(self: &State<Product>): u64 {
    self.max_order_notional
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
/// Forces Settled for focused monotonicity tests.
public fun set_settled_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle = lifecycle::settled_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is Settled.
public fun is_settled_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_settled()
}

#[test_only]
/// Forces active state for focused transition and adapter tests.
public fun set_active_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle = lifecycle::active_for_testing();
}

#[test_only]
/// Returns `(mint_fee_bps, redeem_fee_bps, admin_share_bps)` for test assertions.
public fun fee_settings<Product>(self: &State<Product>): (u64, u64, u64) {
    (self.mint_fee_bps, self.redeem_fee_bps, self.admin_share_bps)
}

#[test_only]
/// Consumes an isolated state value at the end of a unit test.
public fun destroy_for_testing<Product>(self: State<Product>) {
    let State { .. } = self;
}

#[test_only]
/// Credits only authenticated newly deposited collateral to the reserve.
/// This edge creates no shares and no admin entitlement.
public fun donate<Product>(
    self: &mut State<Product>,
    before: PositionObservation,
    after: PositionObservation,
    amount: u64,
    now_ms: u64,
) {
    let plan = self.prepare_donation(before, amount, now_ms);
    self.complete_donation(plan, after, now_ms);
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_boosts_core::{
    accounting_math,
    constants,
    lifecycle::{Self, Lifecycle},
    observation::{Self, FundingSettlement, PositionObservation, PriceObservation},
    policy::{PositionSide, PricePolicy, VaultPolicy},
    rebalance_math,
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
};
