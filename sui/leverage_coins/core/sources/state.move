/// Venue-neutral state for one Series1 leveraged product.
///
/// The selected adapter stores this value inside its own shared Vault. Only
/// functions in this module can inspect or change the private Series1 fields.
/// Currency, venue custody, ACL routing, and versioning belong to the adapter.
module blast_leverage_core::state;

use blast_admin::acl::AdminWitness;
use blast_leverage_core::{
    accounting_math,
    constants,
    lifecycle::{Self, Lifecycle},
    observation::{Self, FundingSettlement, PositionObservation, PriceObservation},
    policy::{PositionSide, VaultPolicy},
    rebalance_math,
    blast_leverage_core::{Self as domain, BLAST_LEVERAGE_CORE},
};

// === Errors ===

#[error(code = 0)]
const EZeroAmount: vector<u8> = b"A fee calculation requires a positive atomic collateral amount.";

#[error(code = 2)]
const EInvalidNav: vector<u8> = b"A priced operation requires positive Series NAV.";

#[error(code = 3)]
const EInvalidShareSupply: vector<u8> = b"A priced operation requires positive share supply.";

#[error(code = 4)]
const EInvalidShareAmount: vector<u8> = b"Presented shares must be positive and below the live supply.";

#[error(code = 5)]
const ENonpositiveContribution: vector<u8> = b"A mint requires a positive shareholder NAV contribution.";

#[error(code = 8)]
const EZeroNetPayout: vector<u8> = b"The redemption fee consumed the complete gross claim.";

#[error(code = 15)]
const EArithmeticOverflow: vector<u8> = b"An arithmetic result exceeds the supported u64 range.";

#[error(code = 16)]
const EMaintenanceReserveExceedsEquity: vector<u8> = b"The maintenance reserve exceeds the venue equity that backs it.";

#[error(code = 18)]
const EOperationNotPermittedInLifecycle: vector<u8> = b"The lifecycle does not permit the requested operation.";

#[error(code = 59)]
const ENavCapExceeded: vector<u8> = b"Shareholder NAV exceeds the Vault NAV cap.";

#[error(code = 64)]
const EInvalidMaxOrderNotional: vector<u8> = b"The maximum-order-notional minimum must be positive.";

#[error(code = 74)]
const EMaxOrderNotionalUnchanged: vector<u8> = b"A maximum-order-notional update repeated the current setting.";

#[error(code = 77)]
const EInvalidPositionObservation: vector<u8> = b"A normalized position must be flat or use positive, lot-aligned base and notional.";

#[error(code = 78)]
const EOrderNotionalExceedsMaximum: vector<u8> = b"An order exceeds the live per-order maximum notional.";

#[error(code = 79)]
const EInvalidInitializationObservation: vector<u8> = b"A seed observation's position side differs from the immutable product side.";

#[error(code = 80)]
const EInitializationOrdersNotEmpty: vector<u8> = b"Seed activation observed one or more pending venue orders.";

#[error(code = 81)]
const EInitializationVenueNotOperational: vector<u8> = b"Seed activation observed a paused, frozen, or otherwise unavailable venue.";

#[error(code = 82)]
const EInitializationCheckpointDirty: vector<u8> = b"Seed activation observed an unreconciled venue checkpoint.";

#[error(code = 83)]
const EInitializationMarginUnsafe: vector<u8> = b"Seed activation observed unsafe venue margin.";

#[error(code = 84)]
const EInitializationLeverageUnhealthy: vector<u8> = b"Seed activation leverage lies outside the immutable healthy band.";

#[error(code = 85)]
const EInitializationExposureBelowMinimum: vector<u8> = b"Seed activation exposure cannot support the immutable minimum operation.";

#[error(code = 87)]
const EFeeSettingsUnchanged: vector<u8> = b"A fee update must change at least one live setting.";

#[error(code = 88)]
const EUserFeeLimitExceeded: vector<u8> = b"The live fee exceeds the ceiling the user accepted.";

#[error(code = 89)]
const EMintOutsidePublicBand: vector<u8> = b"Post-mint leverage lies outside the public rebalance band.";

#[error(code = 90)]
const EActiveCheckpointChanged: vector<u8> = b"The observation pair changed between plan and completion.";

#[error(code = 91)]
const EActiveFillIncomplete: vector<u8> = b"The venue fill does not match the planned base delta.";

#[error(code = 92)]
const EActiveLeverageAboveCap: vector<u8> = b"Post-operation leverage exceeds the policy maximum.";

#[error(code = 93)]
const EActiveObservationUnusable: vector<u8> = b"The active observation is not usable for pricing.";

#[error(code = 94)]
const ERedemptionOutputBelowMinimum: vector<u8> = b"The redemption pays less than the holder's stated minimum.";

#[error(code = 95)]
const EBufferReleaseExceedsBalance: vector<u8> = b"A buffer release exceeds the maintenance reserve.";

#[error(code = 96)]
const ERebalanceInsidePublicBand: vector<u8> = b"An active rebalance was requested at or inside the one public band.";

#[error(code = 97)]
const ERebalanceNoProgress: vector<u8> = b"No admissible whole-lot rebalance progress was completed.";

#[error(code = 98)]
const EVenueFeeUnusable: vector<u8> = b"A venue fee or execution bound cannot be represented conservatively.";

#[error(code = 99)]
const EInvalidAssetDecimals: vector<u8> = b"An asset precision exceeds the widest the notional formulas support.";

#[error(code = 100)]
const ENavCapUnchanged: vector<u8> = b"A NAV cap update must change the cap.";

// === Constants ===

/// Bounds per-transaction maintenance planning independently of adapter work limits.
const MAX_REBALANCE_ORDERS: u64 = 16;

// === Public Types ===

/// Sealed Series1 state stored inside one adapter-owned Vault.
///
/// The value can be stored but cannot be copied or dropped. `Product`
/// separates independent leveraged products at the type level.
public struct State<phantom Product> has store {
    vault_policy: VaultPolicy,
    /// Inclusive immutable floor for `max_order_notional`.
    max_order_notional_minimum: u64,
    max_order_notional: u64,
    /// Inclusive immutable ceiling for `max_order_notional`.
    max_order_notional_maximum: u64,
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
    admin_allocation_bps: u64,
    /// Inclusive ceiling on post-mint shareholder NAV, adjustable by the admin.
    /// Only mints check it: NAV may exceed it through position profit, which
    /// just blocks further mints until NAV falls back under or the cap is raised.
    nav_cap: u64,
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

/// Linear maintenance intent, recalculated only from accepted fixed-pair sessions.
public struct RebalancePlan<phantom Product> {
    before: ActivePosition,
    current: ActivePosition,
    reserve: u64,
    increase: bool,
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

/// Creates one validated, uninitialized Series1 state value.
///
/// The adapter must store the returned value inside its Vault. The caller's
/// live admin witness must contain the Vault issuer role.
public fun new<Product>(
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    vault_policy: VaultPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
): State<Product> {
    admin_witness.assert_role(domain::vault_issuer_role());
    assert!(
        max_order_notional_minimum > 0
            && max_order_notional_minimum <= max_order_notional_current
            && max_order_notional_current <= max_order_notional_maximum,
        EInvalidMaxOrderNotional,
    );

    State {
        mint_fee_bps: vault_policy.mint_fee_bps(),
        redeem_fee_bps: vault_policy.redeem_fee_bps(),
        admin_allocation_bps: 0,
        nav_cap: vault_policy.nav_cap(),
        vault_policy,
        max_order_notional_minimum,
        max_order_notional: max_order_notional_current,
        max_order_notional_maximum,
        maintenance_reserve: 0,
        uncovered_deficit: 0,
        base_unit: 0,
        collateral_unit: 0,
        lifecycle: lifecycle::new(),
    }
}

// --- Administration ---

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
        EOperationNotPermittedInLifecycle,
    );
    self.vault_policy.assert_fee_limits(mint_bps, redeem_bps, admin_bps);
    let previous_mint = self.mint_fee_bps;
    let previous_redeem = self.redeem_fee_bps;
    let previous_admin = self.admin_allocation_bps;
    assert!(
        self.mint_fee_bps != mint_bps || self.redeem_fee_bps != redeem_bps
            || self.admin_allocation_bps != admin_bps,
        EFeeSettingsUnchanged,
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

/// Checks a user's fee ceiling before the adapter interacts with the venue.
public fun assert_user_fee_limit<Product>(self: &State<Product>, mint: bool, maximum: u64) {
    assert!((if (mint) { self.mint_fee_bps } else { self.redeem_fee_bps }) <= maximum,
        EUserFeeLimitExceeded);
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
    let previous = self.max_order_notional;
    assert!(
        current != previous,
        EMaxOrderNotionalUnchanged,
    );
    assert!(
        self.max_order_notional_minimum <= current && current <= self.max_order_notional_maximum,
        EInvalidMaxOrderNotional,
    );

    self.max_order_notional = current;
    previous
}

/// Replaces the NAV cap and returns the previous one.
///
/// Adapter custody owns authentication. The new cap must satisfy the same
/// bound the policy applies to the initial cap; it may be lowered below the
/// current NAV, which only blocks further mints.
public fun set_nav_cap<Product>(self: &mut State<Product>, nav_cap: u64): u64 {
    let previous = self.nav_cap;
    assert!(nav_cap != previous, ENavCapUnchanged);
    self.vault_policy.rebalance_policy().assert_valid_nav_cap(nav_cap);

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
/// events. Reserve mutation remains exclusive to Series1 transitions.
public fun maintenance_reserve<Product>(self: &State<Product>): u64 {
    self.maintenance_reserve
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
    reference_time_ms: u64,
): (u64, u64, u64, u64) {
    self.lifecycle.assert_can_activate();

    let venue_equity = observation.venue_equity();
    let position_base = observation.position_base();
    let position_collateral = observation.position_collateral();
    let lot_size = observation.lot_size();
    let pending_order_count = observation.pending_order_count();
    let margin_safe = observation.is_margin_safe();
    let venue_operational = observation.is_venue_operational();
    let checkpoint_clean = observation.is_checkpoint_clean();
    let base_index_price = observation.base_index().price();
    let base_confidence = observation.base_index().confidence();
    let base_publish_time_ms = observation.base_index().publish_time_ms();
    let collateral_price = observation.collateral_oracle().price();
    let collateral_confidence = observation.collateral_oracle().confidence();
    let collateral_publish_time_ms = observation.collateral_oracle().publish_time_ms();
    let mark_price = observation.mark_price();
    observation.destroy();

    assert!(
        accounting_math::is_reserve_backed(venue_equity, seed_reserve),
        EMaintenanceReserveExceedsEquity,
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        EInvalidNav,
    );

    let price_policy = self.vault_policy.price_policy();
    price_policy.assert_price_fresh(base_publish_time_ms, reference_time_ms);
    price_policy.assert_confidence_within_bound(base_confidence, base_index_price);
    price_policy.assert_price_fresh(collateral_publish_time_ms, reference_time_ms);
    price_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    price_policy.assert_mark_within_index_divergence(mark_price, base_index_price);
    assert!(
        position_base == 0 && position_collateral == 0,
        EInvalidInitializationObservation,
    );
    assert!(
        pending_order_count == 0,
        EInitializationOrdersNotEmpty,
    );
    assert!(
        venue_operational,
        EInitializationVenueNotOperational,
    );
    assert!(
        checkpoint_clean,
        EInitializationCheckpointDirty,
    );
    assert!(
        margin_safe,
        EInitializationMarginUnsafe,
    );

    let seed_nav = accounting_math::shareholder_nav(venue_equity, seed_reserve);
    self.assert_within_nav_cap(seed_nav);
    let target_notional = accounting_math::target_notional_down(
        seed_nav,
        self.vault_policy.rebalance_policy().target_bps(),
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
        self.vault_policy.side(),
        self.max_order_notional,
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
        EOrderNotionalExceedsMaximum,
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
    base_decimals: u8,
    collateral_decimals: u8,
    reference_time_ms: u64,
): u64 {
    self.lifecycle.assert_can_activate();
    assert!(
        base_decimals <= constants::max_asset_decimals!()
            && collateral_decimals <= constants::max_asset_decimals!(),
        EInvalidAssetDecimals,
    );

    let seed_nav = validated_initialization_nav(
        self,
        observation,
        seed_reserve,
        reference_time_ms,
    );

    self.lifecycle.activate();
    self.maintenance_reserve = seed_reserve;
    self.base_unit = 10u64.pow(base_decimals);
    self.collateral_unit = 10u64.pow(collateral_decimals);

    seed_nav
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

/// Consumes an intermediate active observation at the operation's fixed valuation pair.
public fun assert_active_observation<Product>(
    self: &State<Product>, observation: PositionObservation, base_price: u64, collateral_price: u64, now: u64,
) {
    self.lifecycle.assert_active();
    let position = validated_active_position(self, observation, now);
    assert!(position.base_price == base_price && position.collateral_price == collateral_price,
        EActiveCheckpointChanged);
}

/// Applies strict tolerance to ordinary active mint and redemption sessions.
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
    maximum_fee_bps: u64,
    reference_time_ms: u64,
): MintPlan<Product> {
    self.lifecycle.assert_active();
    assert!(supply > 0, EInvalidShareSupply);
    assert!(self.mint_fee_bps <= maximum_fee_bps, EUserFeeLimitExceeded);
    let before = validated_active_position(self, observation, reference_time_ms);
    let nav = accounting_math::shareholder_nav(before.equity, self.maintenance_reserve);
    let risk = self.vault_policy.rebalance_policy();
    let scaled = (before.notional as u128) * (constants::basis_points_denominator!() as u128);
    assert!(
        scaled >= (nav as u128) * (risk.rebalance_below_bps() as u128)
            && scaled <= (nav as u128) * (risk.rebalance_above_bps() as u128),
        EMintOutsidePublicBand,
    );
    let (fee, admin_fee, buffer_fee) = self.fee_allocation(deposit, true);
    let expected_contribution = deposit - fee;
    assert!(expected_contribution > 0, ENonpositiveContribution);
    let order_base = accounting_math::mint_base_delta_down(
        expected_contribution, before.base, nav, before.lot, self.vault_policy.min_exposure_lots(),
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

/// Sealed base index price used to size this mint.
public fun mint_base_price<Product>(self: &MintPlan<Product>): u64 { self.before.base_price }

/// Sealed collateral price used to size this mint.
public fun mint_collateral_price<Product>(self: &MintPlan<Product>): u64 { self.before.collateral_price }

/// Venue lot size sealed with the mint plan.
public fun mint_lot<Product>(self: &MintPlan<Product>): u64 { self.before.lot }

/// Completes a full proportional fill and credits only its buffer allocation.
/// The credited contribution is capped at the deposit net of the whole fee, so
/// a favorable fill accrues to existing holders (ADR 0084 D3).
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
        before, reserve_before, deposit: _, expected_contribution, buffer_fee,
        admin_fee, fee_bps, admin_bps, supply, minimum_shares, order_base,
    } = plan;
    assert!(self.maintenance_reserve == reserve_before, EActiveCheckpointChanged);
    let after = validated_active_position(self, observation, reference_time_ms);
    assert!(
        before.base_price == after.base_price && before.collateral_price == after.collateral_price
            && before.lot == after.lot,
        EActiveCheckpointChanged,
    );
    assert!(
        after.base >= before.base && after.base - before.base == order_base,
        EActiveFillIncomplete,
    );
    let reserve_after = reserve_before.checked_add(buffer_fee)
        .destroy_or!(abort EArithmeticOverflow);
    let (nav_after, contribution, shares) = accounting_math::allocated_mint_quote(
        before.equity, after.equity, reserve_before, reserve_after, expected_contribution,
        supply, minimum_shares,
    );
    accounting_math::assert_mint_base_within_bounds(
        after.base, expected_contribution, contribution, before.base,
        accounting_math::shareholder_nav(before.equity, reserve_before),
        before.lot, self.vault_policy.min_exposure_lots(),
    );
    self.assert_within_nav_cap(nav_after);
    assert!(
        accounting_math::is_accounting_leverage_below_limit(
            after.notional, after.equity, reserve_after,
            self.vault_policy.rebalance_policy().max_leverage_bps(),
        ),
        EActiveLeverageAboveCap,
    );
    self.maintenance_reserve = reserve_after;
    (shares, contribution, admin_fee + buffer_fee, admin_fee, buffer_fee, fee_bps, admin_bps)
}

// --- Redemption ---

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
    assert!(self.redeem_fee_bps <= maximum_fee_bps, EUserFeeLimitExceeded);
    let before = validated_active_position(self, observation, reference_time_ms);
    let (minimum_base, _) = accounting_math::redemption_base_bounds(
        shares, before.base, supply, before.lot, self.vault_policy.min_exposure_lots(),
    );
    let order_base = before.base - minimum_base;
    RedemptionPlan {
        before, reserve_before: self.maintenance_reserve, shares, supply, minimum_output,
        fee_bps: self.redeem_fee_bps, admin_bps: self.admin_allocation_bps, order_base,
    }
}

/// Returns the full reduce-only order amount; flat redemptions require no order.
public fun redemption_order_base<Product>(self: &RedemptionPlan<Product>): u64 { self.order_base }

/// Sealed base index price used by the attributable close.
public fun redemption_base_price<Product>(self: &RedemptionPlan<Product>): u64 { self.before.base_price }

/// Sealed collateral price used by the attributable close.
public fun redemption_collateral_price<Product>(self: &RedemptionPlan<Product>): u64 { self.before.collateral_price }

/// Venue lot size sealed with the redemption plan.
public fun redemption_lot<Product>(self: &RedemptionPlan<Product>): u64 { self.before.lot }

/// Shares the redeemer must burn.
public fun redemption_shares<Product>(self: &RedemptionPlan<Product>): u64 { self.shares }

/// Base exposure that must remain after the sealed close.
public fun redemption_final_base<Product>(self: &RedemptionPlan<Product>): u64 { self.before.base - self.order_base }

/// Redemption fee rate sealed with the plan.
public fun redemption_fee_bps<Product>(self: &RedemptionPlan<Product>): u64 { self.fee_bps }

/// Admin allocation rate sealed with the plan.
public fun redemption_admin_bps<Product>(self: &RedemptionPlan<Product>): u64 { self.admin_bps }

/// Validates actual post-withdrawal backing and margin before a native share burn.
public fun assert_redemption_cash_out<Product>(
    self: &State<Product>, observation: PositionObservation, equity: u64, base: u64,
    base_price: u64, collateral_price: u64, now: u64,
) {
    self.lifecycle.assert_active();
    let after = validated_active_position(self, observation, now);
    assert!(after.equity == equity && after.base == base && after.base_price == base_price
        && after.collateral_price == collateral_price,
        EActiveCheckpointChanged);
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
    reference_time_ms: u64,
): (u64, u64, u64, u64, u64) {
    self.lifecycle.assert_active();
    let RedemptionPlan {
        before, reserve_before, shares, supply, minimum_output, fee_bps, admin_bps, order_base,
    } = plan;
    assert!(self.maintenance_reserve == reserve_before, EActiveCheckpointChanged);
    let after = validated_active_position(self, observation, reference_time_ms);
    assert!(
        before.base_price == after.base_price && before.collateral_price == after.collateral_price
            && before.lot == after.lot,
        EActiveCheckpointChanged,
    );
    assert!(
        before.base >= after.base && before.base - after.base == order_base,
        EActiveFillIncomplete,
    );
    accounting_math::assert_redemption_base_within_bounds(
        after.base, shares, before.base, supply, before.lot, self.vault_policy.min_exposure_lots(),
    );
    let (reserve_with_fee, _, nav_kept, _, _, fee, net) = accounting_math::redemption_accounting_quote(
        shares, before.equity, after.equity, reserve_before, supply, fee_bps,
    );
    assert!(net >= minimum_output, ERedemptionOutputBelowMinimum);
    let admin = fee.mul_div(admin_bps, constants::basis_points_denominator!());
    let reserve_after = reserve_with_fee - admin;
    let final_equity = nav_kept.checked_add(reserve_after)
        .destroy_or!(abort EArithmeticOverflow);
    self.maintenance_reserve = reserve_after;
    (net, admin, final_equity, fee, fee - admin)
}

// --- Rebalance ---

/// Derives public maintenance intent from exact outside-band ratios, never caller orders.
public fun prepare_rebalance<Product>(
    self: &State<Product>, observation: PositionObservation, venue_fee_bps: u64, now: u64,
): RebalancePlan<Product> {
    self.lifecycle.assert_active();
    assert!(
        venue_fee_bps <= constants::basis_points_denominator!(),
        EVenueFeeUnusable,
    );
    let before = validated_active_position(self, observation, now);
    let nav = accounting_math::shareholder_nav(before.equity, self.maintenance_reserve);
    let risk = self.vault_policy.rebalance_policy();
    let scaled = (before.notional as u128) * (constants::basis_points_denominator!() as u128);
    let increase = scaled < (nav as u128) * (risk.rebalance_below_bps() as u128);
    assert!(increase || scaled > (nav as u128) * (risk.rebalance_above_bps() as u128),
        ERebalanceInsidePublicBand);
    RebalancePlan { before, current: before, reserve: self.maintenance_reserve, increase, venue_fee_bps, steps: 0 }
}

/// Returns next whole-lot size, increase intent and current wider-tolerance permission.
/// A zero size finishes planning; the adapter independently caps work at sixteen sessions.
public fun rebalance_order<Product>(self: &State<Product>, plan: &RebalancePlan<Product>): (u64, bool, bool) {
    self.lifecycle.assert_active();
    assert!(self.maintenance_reserve == plan.reserve, EActiveCheckpointChanged);
    let p = &plan.current;
    let nav = accounting_math::shareholder_nav(p.equity, plan.reserve);
    let risk = self.vault_policy.rebalance_policy();
    if (plan.steps == MAX_REBALANCE_ORDERS) { return (0, plan.increase, false) };
    if (plan.increase) {
        (rebalance_math::increase_base_down(nav, p.notional, risk.target_bps(), p.base_price,
            p.collateral_price, p.lot, self.max_order_notional, plan.venue_fee_bps,
            risk.max_slippage_bps(), self.base_unit, self.collateral_unit), true, false)
    } else {
        let target_notional = (nav as u128) * (risk.target_bps() as u128) / (constants::basis_points_denominator!() as u128);
        assert!(target_notional <= std::u64::max_value!() as u128, EArithmeticOverflow);
        let target_base = rebalance_math::base_for_notional_down(
            target_notional as u64, p.base_price, p.collateral_price, p.lot, self.base_unit, self.collateral_unit,
        );
        let cap_base = rebalance_math::base_for_notional_down(
            self.max_order_notional, p.base_price, p.collateral_price, p.lot, self.base_unit, self.collateral_unit,
        );
        let base = if (p.base > target_base) { (p.base - target_base).min(cap_base) / p.lot * p.lot } else { 0 };
        (base, false, (p.notional as u128) * (constants::basis_points_denominator!() as u128) > (nav as u128) * (risk.max_leverage_bps() as u128))
    }
}

/// Sealed base index price the rebalance sizes and proves execution against.
public fun base_price<Product>(self: &RebalancePlan<Product>): u64 { self.before.base_price }

/// Sealed collateral price the rebalance sizes and proves execution against.
public fun collateral_price<Product>(self: &RebalancePlan<Product>): u64 { self.before.collateral_price }

/// Venue lot size sealed with the rebalance plan.
public fun lot<Product>(self: &RebalancePlan<Product>): u64 { self.before.lot }

/// The current authenticated ratio alone selects ordinary or wider execution tolerance.
public fun assert_rebalance_execution<Product>(self: &State<Product>, plan: &RebalancePlan<Product>, reference: u64, executed: u64) {
    let (_, _, wide) = self.rebalance_order(plan);
    let risk = self.vault_policy.rebalance_policy();
    if (wide) { risk.assert_execution_within_emergency_max_slippage(reference, executed); }
    else { risk.assert_execution_within_max_slippage(reference, executed); };
}

/// Advances only exact partial whole-lot fills under sealed intent and the fixed oracle pair.
public fun accept_rebalance_fill<Product>(
    self: &State<Product>, plan: &mut RebalancePlan<Product>, observation: PositionObservation, filled: u64, now: u64,
) {
    let (requested, increase, _) = self.rebalance_order(plan);
    assert!(filled > 0 && filled <= requested && filled % plan.current.lot == 0,
        EActiveFillIncomplete);
    let after = validated_active_position(self, observation, now);
    assert!(after.base_price == plan.before.base_price && after.collateral_price == plan.before.collateral_price
        && after.lot == plan.before.lot, EActiveCheckpointChanged);
    let expected_base = if (increase) { plan.current.base.checked_add(filled).destroy_or!(abort EArithmeticOverflow) } else { plan.current.base - filled };
    assert!(after.base == expected_base, EActiveFillIncomplete);
    if (increase) {
        let nav = accounting_math::shareholder_nav(after.equity, plan.reserve);
        let risk = self.vault_policy.rebalance_policy();
        assert!((after.notional as u128) * (constants::basis_points_denominator!() as u128) <= (nav as u128) * (risk.target_bps() as u128)
            && (after.notional as u128) * (constants::basis_points_denominator!() as u128) < (nav as u128) * (risk.max_leverage_bps() as u128),
            EActiveLeverageAboveCap);
    };
    plan.current = after;
    plan.steps = plan.steps + 1;
}

/// Completes holder-funded maintenance without changing reserve, supply or admin cash.
/// Returns authenticated before/after equity and base for one completed event.
public fun complete_rebalance<Product>(self: &State<Product>, plan: RebalancePlan<Product>): (u64, u64, u64, u64, bool) {
    self.lifecycle.assert_active();
    let RebalancePlan { before, current, reserve, increase, venue_fee_bps: _, steps } = plan;
    assert!(reserve == self.maintenance_reserve, EActiveCheckpointChanged);
    assert!(steps > 0, ERebalanceNoProgress);
    let before_nav = accounting_math::shareholder_nav(before.equity, reserve);
    let after_nav = accounting_math::shareholder_nav(current.equity, reserve);
    let risk = self.vault_policy.rebalance_policy();
    let improved = if (increase) {
        current.base > before.base && (current.notional as u128) * (before_nav as u128) > (before.notional as u128) * (after_nav as u128)
    } else {
        current.base < before.base && rebalance_math::reduction_is_sufficient(before.notional, before_nav,
            current.notional, after_nav, risk.target_bps(), risk.min_leverage_improvement_bps(),
            rebalance_math::index_notional_up(
                current.lot, current.base_price, current.collateral_price, self.base_unit, self.collateral_unit,
            ))
    };
    assert!(improved, ERebalanceNoProgress);
    (before.equity, current.equity, before.base, current.base, increase)
}

// --- Funding And Buffer ---

/// Applies one adapter-authenticated funding classification to the reserve.
///
/// Returns `(absorbed_by_reserve, uncovered_cost, restored_to_holders)` in
/// atomic collateral units. A cost consumes the reserve first; what it cannot
/// cover is borne by holder NAV and recorded as the uncovered deficit. A credit
/// repays that deficit first, by staying in NAV, and only its remainder
/// rebuilds the reserve. The adapter owns exact-once funding checkpoint
/// authentication; the core stores no venue cursor and never infers funding
/// from an equity delta.
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
            .destroy_or!(abort EArithmeticOverflow);

        (absorbed, uncovered, 0)
    } else {
        let restored = amount.min(self.uncovered_deficit);
        self.uncovered_deficit = self.uncovered_deficit - restored;
        self.maintenance_reserve = self.maintenance_reserve
            .checked_add(amount - restored)
            .destroy_or!(abort EArithmeticOverflow);

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
    reference_time_ms: u64,
): DonationPlan<Product> {
    self.lifecycle.assert_active();
    assert!(amount > 0, EZeroAmount);
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
    assert!(reserve_before == self.maintenance_reserve, EActiveCheckpointChanged);
    let after = validated_active_position(self, after, reference_time_ms);
    assert!(
        before.base == after.base && before.notional == after.notional && before.lot == after.lot
            && before.base_price == after.base_price && before.collateral_price == after.collateral_price
            && after.equity >= before.equity && after.equity - before.equity == amount,
        EActiveCheckpointChanged,
    );
    self.maintenance_reserve = self.maintenance_reserve.checked_add(amount)
        .destroy_or!(abort EArithmeticOverflow);
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
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= self.maintenance_reserve, EBufferReleaseExceedsBalance);
    let position = validated_active_position(self, observation, reference_time_ms);
    let reserve_after = self.maintenance_reserve - amount;
    let nav = accounting_math::shareholder_nav(position.equity, reserve_after);
    self.maintenance_reserve = reserve_after;
    nav
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
    self.lifecycle.assert_shutdown_close_allowed();
}

/// Prices only a close-only order; insolvency and the buffer do not gate an exit.
public fun unwind_constraints<Product>(
    self: &State<Product>, base_index: PriceObservation, collateral_oracle: PriceObservation, now: u64,
): (PositionSide, u64, u64, u64) {
    self.assert_unwinding();
    let base_price = base_index.price();
    let base_confidence = base_index.confidence();
    let base_time = base_index.publish_time_ms();
    let collateral_price = collateral_oracle.price();
    let collateral_confidence = collateral_oracle.confidence();
    let collateral_time = collateral_oracle.publish_time_ms();
    base_index.destroy();
    collateral_oracle.destroy();
    let price_policy = self.vault_policy.price_policy();
    price_policy.assert_price_fresh(base_time, now);
    price_policy.assert_confidence_within_bound(base_confidence, base_price);
    price_policy.assert_price_fresh(collateral_time, now);
    price_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    (self.vault_policy.side(), self.max_order_notional, base_price, collateral_price)
}

/// Shutdown uses its immutable wider bound without an active leverage/NAV prerequisite.
public fun assert_unwind_execution<Product>(self: &State<Product>, reference: u64, executed: u64) {
    self.assert_unwinding();
    self.vault_policy.rebalance_policy().assert_execution_within_emergency_max_slippage(reference, executed);
}

/// Consumes the buffer book entry only after the adapter proves complete local cash recovery.
public fun finalize_shutdown<Product>(self: &mut State<Product>, native_supply: u64, locked: u64): u64 {
    assert!(native_supply >= locked, EInvalidShareSupply);
    self.lifecycle.finalize_shutdown();
    self.maintenance_reserve = 0;
    native_supply - locked
}

/// Rejects terminal claims before any adapter cash-field access.
public fun assert_settled<Product>(self: &State<Product>) {
    self.lifecycle.assert_shutdown_redemption_allowed();
}

/// Fee-free claim against current cash and native supply, excluding the immutable seed.
public fun shutdown_claim_quote<Product>(
    self: &State<Product>, cash: u64, native_supply: u64, locked: u64, shares: u64, minimum: u64,
): u64 {
    self.lifecycle.assert_shutdown_redemption_allowed();
    assert!(native_supply >= locked, EInvalidShareSupply);
    let eligible = native_supply - locked;
    assert!(shares > 0 && shares <= eligible, EInvalidShareAmount);
    let output = cash.mul_div(shares, eligible);
    assert!(cash == 0 || output > 0, EZeroNetPayout);
    assert!(output >= minimum, ERedemptionOutputBelowMinimum);
    output
}

// === Private Functions ===

fun assert_within_nav_cap<Product>(self: &State<Product>, nav: u64) {
    assert!(self.is_within_nav_cap(nav), ENavCapExceeded);
}

/// All active priced paths consume fresh, attributable venue facts before mutation.
fun validated_active_position<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    reference_time_ms: u64,
): ActivePosition {
    let equity = observation.venue_equity();
    let base = observation.position_base();
    let notional = observation.position_collateral();
    let lot = observation.lot_size();
    let side = observation.observed_side();
    let orders = observation.pending_order_count();
    let margin_safe = observation.is_margin_safe();
    let operational = observation.is_venue_operational();
    let clean = observation.is_checkpoint_clean();
    let base_price = observation.base_index().price();
    let base_confidence = observation.base_index().confidence();
    let base_time = observation.base_index().publish_time_ms();
    let collateral_price = observation.collateral_oracle().price();
    let collateral_confidence = observation.collateral_oracle().confidence();
    let collateral_time = observation.collateral_oracle().publish_time_ms();
    let mark = observation.mark_price();
    observation.destroy();
    let price_policy = self.vault_policy.price_policy();
    price_policy.assert_price_fresh(base_time, reference_time_ms);
    price_policy.assert_confidence_within_bound(base_confidence, base_price);
    price_policy.assert_price_fresh(collateral_time, reference_time_ms);
    price_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    price_policy.assert_mark_within_index_divergence(mark, base_price);
    assert!(
        (base == 0 && notional == 0) || side == self.vault_policy.side(),
        EInvalidPositionObservation,
    );
    assert!(orders == 0 && margin_safe && operational && clean, EActiveObservationUnusable);
    assert!(accounting_math::is_shareholder_nav_positive(equity, self.maintenance_reserve), EInvalidNav);
    ActivePosition { equity, base, notional, lot, base_price, collateral_price }
}

/// Consumes and validates a complete seed without mutable access to State.
fun validated_initialization_nav<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): u64 {
    let venue_equity = observation.venue_equity();
    let position_base = observation.position_base();
    let position_collateral = observation.position_collateral();
    let lot_size = observation.lot_size();
    let observed_side = observation.observed_side();
    let pending_order_count = observation.pending_order_count();
    let margin_safe = observation.is_margin_safe();
    let venue_operational = observation.is_venue_operational();
    let checkpoint_clean = observation.is_checkpoint_clean();
    let base_index_price = observation.base_index().price();
    let base_confidence = observation.base_index().confidence();
    let base_publish_time_ms = observation.base_index().publish_time_ms();
    let collateral_price = observation.collateral_oracle().price();
    let collateral_confidence = observation.collateral_oracle().confidence();
    let collateral_publish_time_ms = observation.collateral_oracle().publish_time_ms();
    let mark_price = observation.mark_price();
    observation.destroy();

    assert!(
        accounting_math::is_reserve_backed(venue_equity, seed_reserve),
        EMaintenanceReserveExceedsEquity,
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        EInvalidNav,
    );

    let price_policy = self.vault_policy.price_policy();
    price_policy.assert_price_fresh(base_publish_time_ms, reference_time_ms);
    price_policy.assert_confidence_within_bound(base_confidence, base_index_price);
    price_policy.assert_price_fresh(collateral_publish_time_ms, reference_time_ms);
    price_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    price_policy.assert_mark_within_index_divergence(mark_price, base_index_price);
    assert!(
        observed_side == self.vault_policy.side(),
        EInvalidInitializationObservation,
    );
    assert!(
        pending_order_count == 0,
        EInitializationOrdersNotEmpty,
    );
    assert!(
        venue_operational,
        EInitializationVenueNotOperational,
    );
    assert!(
        checkpoint_clean,
        EInitializationCheckpointDirty,
    );
    assert!(
        margin_safe,
        EInitializationMarginUnsafe,
    );

    let seed_nav = accounting_math::shareholder_nav(venue_equity, seed_reserve);
    self.assert_within_nav_cap(seed_nav);
    let rebalance_policy = self.vault_policy.rebalance_policy();
    let scaled = (position_collateral as u128) * (constants::basis_points_denominator!() as u128);
    assert!(
        scaled >= (seed_nav as u128) * (rebalance_policy.rebalance_below_bps() as u128)
            && scaled <= (seed_nav as u128) * (rebalance_policy.rebalance_above_bps() as u128),
        EInitializationLeverageUnhealthy,
    );
    assert!(
        observation::is_position_structurally_valid(
            position_base,
            position_collateral,
            lot_size,
        ),
        EInvalidPositionObservation,
    );
    assert!(
        accounting_math::is_exposure_above_minimum_operation(
            position_base,
            lot_size,
            self.vault_policy.min_exposure_lots(),
        ),
        EInitializationExposureBelowMinimum,
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
/// Returns the immutable vault policy.
public fun vault_policy_for_testing<Product>(self: &State<Product>): VaultPolicy {
    self.vault_policy
}

#[test_only]
/// Returns the complete maximum-order-notional tuple.
public fun max_order_notional_for_testing<Product>(self: &State<Product>): (u64, u64, u64) {
    (self.max_order_notional_minimum, self.max_order_notional, self.max_order_notional_maximum)
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
/// Returns `(mint_fee_bps, redeem_fee_bps, admin_allocation_bps)` for test assertions.
public fun fee_settings<Product>(self: &State<Product>): (u64, u64, u64) {
    (self.mint_fee_bps, self.redeem_fee_bps, self.admin_allocation_bps)
}

#[test_only]
/// Consumes an isolated state value at the end of a unit test.
public fun destroy_for_testing<Product>(self: State<Product>) {
    let State { .. } = self;
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
