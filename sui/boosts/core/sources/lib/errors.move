#[allow(unused_const)]
/// Numeric abort registry for the Blast Boosts core package.
///
/// Codes run from zero with no gaps: a removed check renumbers what follows
/// until the package is published, after which codes are append-only. Each
/// module raises these through the macros so the abort location stays the
/// raising module.
module blast_boosts_core::errors;

// === Errors ===

#[test_only]
/// A fee calculation requires a positive atomic collateral amount.
const EZeroAmount: u64 = 0;

#[test_only]
/// A fee rate must be below the full basis-point denominator.
const EInvalidFeeBps: u64 = 1;

#[test_only]
/// A priced operation requires positive shareholder NAV.
const EInvalidNav: u64 = 2;

#[test_only]
/// A priced operation requires positive share supply.
const EInvalidShareSupply: u64 = 3;

#[test_only]
/// Presented shares must be positive and below the live supply.
const EInvalidShareAmount: u64 = 4;

#[test_only]
/// A mint requires a positive shareholder NAV contribution.
const ENonpositiveContribution: u64 = 5;

#[test_only]
/// A positive credited contribution rounded down to zero shares.
const EZeroSharesOut: u64 = 6;

#[test_only]
/// Post-unwind NAV does not exceed the equity kept for remaining shares.
const ENonpositiveGross: u64 = 7;

#[test_only]
/// The redemption fee consumed the complete gross claim.
const EZeroNetPayout: u64 = 8;

#[test_only]
/// A target leverage rate must be positive.
const EInvalidTargetLeverageBps: u64 = 9;

#[test_only]
/// A venue lot size must be positive.
const EInvalidLotSize: u64 = 10;

#[test_only]
/// A proportional mint requires positive pre-mint absolute base.
const EInvalidBase: u64 = 11;

#[test_only]
/// A proportional mint or redemption order is below the required minimum lot multiple.
const EOrderBelowMinLots: u64 = 12;

#[test_only]
/// The final absolute base exceeds the proportional remaining base.
const ERedemptionUnderReduced: u64 = 13;

#[test_only]
/// The final absolute base is more than one lot below the proportional remaining base without reaching flat.
const ERedemptionOverReduced: u64 = 14;

#[test_only]
/// An arithmetic result exceeds the supported u64 range.
const EArithmeticOverflow: u64 = 15;

#[test_only]
/// The maintenance reserve exceeds the venue equity that backs it.
const EMaintenanceReserveExceedsEquity: u64 = 16;

#[test_only]
/// The lifecycle cannot make the requested transition.
const EInvalidLifecycleTransition: u64 = 17;

#[test_only]
/// The lifecycle does not permit the requested operation.
const EOperationNotPermittedInLifecycle: u64 = 18;

#[test_only]
/// The final absolute base exceeds the pre-mint base plus the planned proportional order.
const EMintBaseAboveBound: u64 = 19;

#[test_only]
/// The final absolute base is below the pre-mint base plus the proportional order funded by the actual credited contribution.
const EMintBaseBelowBound: u64 = 20;

#[test_only]
/// A minimum order lot multiple must be positive.
const EInvalidMinOrderLots: u64 = 21;

#[test_only]
/// Rebalance thresholds are not strictly ordered.
const EInvalidRebalancePolicy: u64 = 22;

#[test_only]
/// A NAV cap must be positive and admit a target notional at max leverage.
const EInvalidNavCap: u64 = 23;

#[test_only]
/// A price maximum age must be positive.
const EInvalidMaxPriceAge: u64 = 24;

#[test_only]
/// A confidence bound must be below the basis-point denominator.
const EInvalidMaxConfidenceBps: u64 = 25;

#[test_only]
/// A mark-divergence bound must be below the basis-point denominator.
const EInvalidMaxMarkDivergenceBps: u64 = 26;

#[test_only]
/// A price is older than its freshness budget.
const EStalePrice: u64 = 27;

#[test_only]
/// A price is too far ahead of the reference time.
const EFuturePrice: u64 = 28;

#[test_only]
/// A price used for pricing or gating is zero.
const EInvalidPrice: u64 = 29;

#[test_only]
/// Confidence exceeds its relative bound.
const EConfidenceExceedsBound: u64 = 30;

#[test_only]
/// Venue mark diverges too far from its oracle.
const EMarkOracleDivergenceExceedsBound: u64 = 31;

#[test_only]
/// Strict max slippage must be below the basis-point denominator.
const EInvalidMaxSlippageBps: u64 = 32;

#[test_only]
/// Emergency slippage must include max slippage and remain below the denominator.
const EInvalidEmergencyMaxSlippageBps: u64 = 33;

#[test_only]
/// Minimum leverage improvement must be positive.
const EInvalidMinLeverageImprovementBps: u64 = 34;

#[test_only]
/// A mint produced fewer shares than the caller's stated minimum.
const ESharesOutBelowMinimum: u64 = 35;

#[test_only]
/// Shareholder NAV exceeds the Vault NAV cap.
const ENavCapExceeded: u64 = 36;

#[test_only]
/// An executed value diverges from its reference beyond the max slippage.
const EExecutionOutsideMaxSlippage: u64 = 37;

#[test_only]
/// Forward clock skew must not exceed the staleness budget.
const EInvalidFreshnessWindow: u64 = 38;

#[test_only]
/// The maximum order notional must be positive.
const EInvalidMaxOrderNotional: u64 = 39;

#[test_only]
/// A maximum-order-notional update repeated the current setting.
const EMaxOrderNotionalUnchanged: u64 = 40;

#[test_only]
/// A normalized position observation must use a positive venue lot size.
const EInvalidObservationLotSize: u64 = 41;

#[test_only]
/// A normalized position must be flat or use positive, lot-aligned base and notional.
const EInvalidPositionObservation: u64 = 42;

#[test_only]
/// An order exceeds the live per-order maximum notional.
const EOrderNotionalExceedsMaximum: u64 = 43;

#[test_only]
/// A seed observation's position side differs from the immutable product side.
const EInvalidInitializationObservation: u64 = 44;

#[test_only]
/// Seed activation leverage lies outside the immutable healthy band.
const EInitializationLeverageUnhealthy: u64 = 45;

#[test_only]
/// Seed activation position cannot support the immutable minimum operation.
const EInitializationBaseBelowMinOrder: u64 = 46;

#[test_only]
/// A live fee or allocation exceeds its immutable issuance ceiling.
const EFeeCapExceeded: u64 = 47;

#[test_only]
/// A fee update must change at least one live setting.
const EFeeSettingsUnchanged: u64 = 48;

#[test_only]
/// The live fee exceeds the ceiling the user accepted.
const EUserFeeLimitExceeded: u64 = 49;

#[test_only]
/// Post-mint leverage lies outside the rebalance band.
const EMintOutsideRebalanceBand: u64 = 50;

#[test_only]
/// The observation pair changed between plan and completion.
const EActiveCheckpointChanged: u64 = 51;

#[test_only]
/// The venue fill does not match the planned base order.
const EActiveFillIncomplete: u64 = 52;

#[test_only]
/// Post-operation leverage exceeds the policy maximum.
const EActiveLeverageAboveCap: u64 = 53;

#[test_only]
/// The redemption pays less than the holder's stated minimum.
const ERedemptionOutputBelowMinimum: u64 = 54;

#[test_only]
/// An active rebalance was requested at or inside the one rebalance band.
const ERebalanceInsideBand: u64 = 55;

#[test_only]
/// No admissible whole-lot rebalance progress was completed.
const ERebalanceNoProgress: u64 = 56;

#[test_only]
/// A venue fee or execution bound cannot be represented conservatively.
const EVenueFeeUnusable: u64 = 57;

#[test_only]
/// An asset precision exceeds the widest the notional formulas support.
const EInvalidAssetDecimals: u64 = 58;

#[test_only]
/// A NAV cap update must change the cap.
const ENavCapUnchanged: u64 = 59;

#[test_only]
/// The reserve ceiling must be a positive share of notional, at most 100%.
const EInvalidMaxReserveBps: u64 = 60;

#[test_only]
/// A seed reserve exceeds the policy ceiling for the opening notional.
const ESeedReserveAboveCap: u64 = 61;

// === Package Functions ===

macro public(package) fun zero_amount(): u64 { 0 }
macro public(package) fun invalid_fee_bps(): u64 { 1 }
macro public(package) fun invalid_nav(): u64 { 2 }
macro public(package) fun invalid_share_supply(): u64 { 3 }
macro public(package) fun invalid_share_amount(): u64 { 4 }
macro public(package) fun nonpositive_contribution(): u64 { 5 }
macro public(package) fun zero_shares_out(): u64 { 6 }
macro public(package) fun nonpositive_gross(): u64 { 7 }
macro public(package) fun zero_net_payout(): u64 { 8 }
macro public(package) fun invalid_target_leverage_bps(): u64 { 9 }
macro public(package) fun invalid_lot_size(): u64 { 10 }
macro public(package) fun invalid_base(): u64 { 11 }
macro public(package) fun order_below_min_lots(): u64 { 12 }
macro public(package) fun redemption_under_reduced(): u64 { 13 }
macro public(package) fun redemption_over_reduced(): u64 { 14 }
macro public(package) fun arithmetic_overflow(): u64 { 15 }
macro public(package) fun maintenance_reserve_exceeds_equity(): u64 { 16 }
macro public(package) fun invalid_lifecycle_transition(): u64 { 17 }
macro public(package) fun operation_not_permitted_in_lifecycle(): u64 { 18 }
macro public(package) fun mint_base_above_bound(): u64 { 19 }
macro public(package) fun mint_base_below_bound(): u64 { 20 }
macro public(package) fun invalid_min_order_lots(): u64 { 21 }
macro public(package) fun invalid_rebalance_policy(): u64 { 22 }
macro public(package) fun invalid_nav_cap(): u64 { 23 }
macro public(package) fun invalid_max_price_age(): u64 { 24 }
macro public(package) fun invalid_max_confidence_bps(): u64 { 25 }
macro public(package) fun invalid_max_mark_divergence_bps(): u64 { 26 }
macro public(package) fun stale_price(): u64 { 27 }
macro public(package) fun future_price(): u64 { 28 }
macro public(package) fun invalid_price(): u64 { 29 }
macro public(package) fun confidence_exceeds_bound(): u64 { 30 }
macro public(package) fun mark_oracle_divergence_exceeds_bound(): u64 { 31 }
macro public(package) fun invalid_max_slippage_bps(): u64 { 32 }
macro public(package) fun invalid_emergency_max_slippage_bps(): u64 { 33 }
macro public(package) fun invalid_min_leverage_improvement_bps(): u64 { 34 }
macro public(package) fun shares_out_below_minimum(): u64 { 35 }
macro public(package) fun nav_cap_exceeded(): u64 { 36 }
macro public(package) fun execution_outside_max_slippage(): u64 { 37 }
macro public(package) fun invalid_freshness_window(): u64 { 38 }
macro public(package) fun invalid_max_order_notional(): u64 { 39 }
macro public(package) fun max_order_notional_unchanged(): u64 { 40 }
macro public(package) fun invalid_observation_lot_size(): u64 { 41 }
macro public(package) fun invalid_position_observation(): u64 { 42 }
macro public(package) fun order_notional_exceeds_maximum(): u64 { 43 }
macro public(package) fun invalid_initialization_observation(): u64 { 44 }
macro public(package) fun initialization_leverage_unhealthy(): u64 { 45 }
macro public(package) fun initialization_base_below_min_order(): u64 { 46 }
macro public(package) fun fee_cap_exceeded(): u64 { 47 }
macro public(package) fun fee_settings_unchanged(): u64 { 48 }
macro public(package) fun user_fee_limit_exceeded(): u64 { 49 }
macro public(package) fun mint_outside_rebalance_band(): u64 { 50 }
macro public(package) fun active_checkpoint_changed(): u64 { 51 }
macro public(package) fun active_fill_incomplete(): u64 { 52 }
macro public(package) fun active_leverage_above_cap(): u64 { 53 }
macro public(package) fun redemption_output_below_minimum(): u64 { 54 }
macro public(package) fun rebalance_inside_band(): u64 { 55 }
macro public(package) fun rebalance_no_progress(): u64 { 56 }
macro public(package) fun venue_fee_unusable(): u64 { 57 }
macro public(package) fun invalid_asset_decimals(): u64 { 58 }
macro public(package) fun nav_cap_unchanged(): u64 { 59 }
macro public(package) fun invalid_max_reserve_bps(): u64 { 60 }
macro public(package) fun seed_reserve_above_cap(): u64 { 61 }
