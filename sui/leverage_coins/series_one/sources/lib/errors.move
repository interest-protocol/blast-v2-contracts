#[allow(unused_const)]
module blast_leverage_series_one::errors;

// === Errors ===

// Append-only package error registry. Never reuse a retired numeric code.
// Codes 38-39, 62-63, and 65-73 are retired by ADR 0073 and remain reserved.

#[test_only]
/// A fee calculation requires a positive atomic collateral amount.
const EZeroAmount: u64 = 0;

#[test_only]
/// A fee rate must be below the full basis-point denominator.
const EInvalidFeeBps: u64 = 1;

#[test_only]
/// A priced operation requires positive Series NAV.
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
/// A proportional mint requires positive pre-mint absolute base exposure.
const EInvalidBaseExposure: u64 = 11;

#[test_only]
/// A proportional mint or redemption exposure delta is below the required
/// minimum lot multiple.
const ESubLotExposureDelta: u64 = 12;

#[test_only]
/// The final absolute base exceeds the proportional remaining base.
const ERedemptionUnderReduced: u64 = 13;

#[test_only]
/// The final absolute base is more than one lot below the proportional
/// remaining base without reaching flat.
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
/// The final absolute base exceeds the pre-mint base plus the planned
/// proportional delta.
const EMintOverExposed: u64 = 19;

#[test_only]
/// The final absolute base is below the pre-mint base plus the proportional
/// delta funded by the actual credited contribution.
const EMintUnderExposed: u64 = 20;

#[test_only]
/// A minimum exposure lot multiple must be positive.
const EInvalidMinExposureLots: u64 = 21;

#[test_only]
/// Rebalance thresholds are not strictly ordered.
const EInvalidRebalancePolicy: u64 = 22;

#[test_only]
/// A Series NAV cap must be positive.
const EInvalidSeriesNavCap: u64 = 23;

#[test_only]
/// A valuation maximum age must be positive.
const EInvalidMaxPriceAge: u64 = 24;

#[test_only]
/// A confidence bound must be below the basis-point denominator.
const EInvalidMaxConfidenceBps: u64 = 25;

#[test_only]
/// A mark-divergence bound must be below the basis-point denominator.
const EInvalidMaxMarkDivergenceBps: u64 = 26;

#[test_only]
/// A valuation is older than its freshness budget.
const EStaleValuation: u64 = 27;

#[test_only]
/// A valuation is too far ahead of the reference time.
const EFutureValuation: u64 = 28;

#[test_only]
/// A gated valuation price is zero.
const EInvalidValuationPrice: u64 = 29;

#[test_only]
/// Confidence exceeds its relative bound.
const EConfidenceExceedsBound: u64 = 30;

#[test_only]
/// Venue mark diverges too far from its index.
const EMarkIndexDivergenceExceedsBound: u64 = 31;

#[test_only]
/// Mint contribution exceeds its favorable-divergence bound.
const EMintContributionExceedsBound: u64 = 32;

#[test_only]
/// Mint-contribution divergence must be below the basis-point denominator.
const EInvalidMaxMintContributionDivergenceBps: u64 = 33;

#[test_only]
/// A bounded value must satisfy minimum <= current <= maximum.
const EInvalidBoundedValue: u64 = 34;

#[test_only]
/// Strict execution tolerance must be below the basis-point denominator.
const EInvalidStrictToleranceBps: u64 = 35;

#[test_only]
/// Emergency tolerance must include strict tolerance and remain below the denominator.
const EInvalidEmergencyToleranceBps: u64 = 36;

#[test_only]
/// Minimum leverage improvement must be positive.
const EInvalidMinimumImprovementBps: u64 = 37;

#[test_only]
/// The supplied super-admin capability is no longer active.
const EInvalidSuperAdminCap: u64 = 40;

#[test_only]
/// The supplied admin capability is not registered in this authority.
const EInvalidAdminCap: u64 = 41;

#[test_only]
/// A new admin capability targeted the zero address.
const EInvalidAdminRecipient: u64 = 42;

#[test_only]
/// The bounded live-admin registry is full.
const EAdminCapacityReached: u64 = 43;

#[test_only]
/// An initial admin role set is empty or contains an unknown bit.
const EInvalidAdminRoles: u64 = 44;

#[test_only]
/// An operation did not select exactly one recognized admin role.
const EInvalidAdminRole: u64 = 45;

#[test_only]
/// The selected role is already assigned to the admin capability.
const EAdminRoleAlreadyGranted: u64 = 46;

#[test_only]
/// The admin role bitmap does not contain the required role.
const EAdminRoleNotGranted: u64 = 47;

#[test_only]
/// A root transfer targeted zero or the current sender.
const EInvalidSuperAdminRecipient: u64 = 48;

#[test_only]
/// No pending root transfer exists.
const ENoPendingSuperAdminTransfer: u64 = 49;

#[test_only]
/// The sender is not the proposed root recipient.
const ENotPendingSuperAdminRecipient: u64 = 50;

#[test_only]
/// The root-transfer acceptance delay has not elapsed.
const ESuperAdminTransferNotReady: u64 = 51;

#[test_only]
/// The root-transfer ready timestamp would overflow `u64`.
const ESuperAdminTransferTimeOverflow: u64 = 52;

#[test_only]
/// The active root capability cannot be destroyed.
const ESuperAdminCapStillActive: u64 = 53;

#[test_only]
/// A root-transfer proposal repeated the pending recipient.
const ESuperAdminTransferUnchanged: u64 = 54;

#[test_only]
/// Redemption gross claim exceeds its favorable-divergence bound.
const ERedemptionGrossExceedsBound: u64 = 55;

#[test_only]
/// Redemption-gross divergence must be below the basis-point denominator.
const EInvalidMaxRedemptionGrossDivergenceBps: u64 = 56;

#[test_only]
/// A mint produced fewer shares than the caller's stated minimum.
const ESharesOutBelowMinimum: u64 = 57;

#[test_only]
/// A rebalance does not move leverage toward target by the minimum improvement.
const EInsufficientLeverageImprovement: u64 = 58;

#[test_only]
/// Shareholder NAV exceeds the immutable Series NAV cap.
const ESeriesNavCapExceeded: u64 = 59;

#[test_only]
/// An executed value diverges from its reference beyond the execution tolerance.
const EExecutionOutsideTolerance: u64 = 60;

#[test_only]
/// Forward clock skew must not exceed the staleness budget.
const EInvalidFreshnessWindow: u64 = 61;

#[test_only]
/// The maximum-order-notional minimum must be positive.
const EInvalidMaxOrderNotional: u64 = 64;

#[test_only]
/// A maximum-order-notional update repeated the current setting.
const EMaxOrderNotionalUnchanged: u64 = 74;

#[test_only]
/// A normalized price observation must be positive.
const EInvalidObservationPrice: u64 = 75;

#[test_only]
/// A normalized position observation must use a positive venue lot size.
const EInvalidObservationLotSize: u64 = 76;

#[test_only]
/// A normalized position must be flat or use positive, lot-aligned base and notional.
const EInvalidPositionObservation: u64 = 77;

#[test_only]
/// An order exceeds the live per-order maximum notional.
const EOrderNotionalExceedsMaximum: u64 = 78;

#[test_only]
/// A seed observation's position side differs from the immutable product side.
const EInvalidInitializationObservation: u64 = 79;

#[test_only]
/// Seed activation observed one or more pending venue orders.
const EInitializationOrdersNotEmpty: u64 = 80;

#[test_only]
/// Seed activation observed a paused, frozen, or otherwise unavailable venue.
const EInitializationVenueNotOperational: u64 = 81;

#[test_only]
/// Seed activation observed an unreconciled venue checkpoint.
const EInitializationCheckpointDirty: u64 = 82;

#[test_only]
/// Seed activation observed unsafe venue margin.
const EInitializationMarginUnsafe: u64 = 83;

#[test_only]
/// Seed activation leverage lies outside the immutable healthy band.
const EInitializationLeverageUnhealthy: u64 = 84;

#[test_only]
/// Seed activation exposure cannot support the immutable minimum operation.
const EInitializationExposureBelowMinimum: u64 = 85;

macro public(package) fun zero_amount(): u64 {
    0
}

macro public(package) fun invalid_fee_bps(): u64 {
    1
}

macro public(package) fun invalid_nav(): u64 {
    2
}

macro public(package) fun invalid_share_supply(): u64 {
    3
}

macro public(package) fun invalid_share_amount(): u64 {
    4
}

macro public(package) fun nonpositive_contribution(): u64 {
    5
}

macro public(package) fun zero_shares_out(): u64 {
    6
}

macro public(package) fun nonpositive_gross(): u64 {
    7
}

macro public(package) fun zero_net_payout(): u64 {
    8
}

macro public(package) fun invalid_target_leverage_bps(): u64 {
    9
}

macro public(package) fun invalid_lot_size(): u64 {
    10
}

macro public(package) fun invalid_base_exposure(): u64 {
    11
}

macro public(package) fun sub_lot_exposure_delta(): u64 {
    12
}

macro public(package) fun redemption_under_reduced(): u64 {
    13
}

macro public(package) fun redemption_over_reduced(): u64 {
    14
}

macro public(package) fun arithmetic_overflow(): u64 {
    15
}

macro public(package) fun maintenance_reserve_exceeds_equity(): u64 {
    16
}

macro public(package) fun invalid_lifecycle_transition(): u64 {
    17
}

macro public(package) fun operation_not_permitted_in_lifecycle(): u64 {
    18
}

macro public(package) fun mint_over_exposed(): u64 {
    19
}

macro public(package) fun mint_under_exposed(): u64 {
    20
}

macro public(package) fun invalid_min_exposure_lots(): u64 {
    21
}

macro public(package) fun invalid_rebalance_policy(): u64 {
    22
}

macro public(package) fun invalid_series_nav_cap(): u64 {
    23
}

macro public(package) fun invalid_max_price_age(): u64 {
    24
}

macro public(package) fun invalid_max_confidence_bps(): u64 {
    25
}

macro public(package) fun invalid_max_mark_divergence_bps(): u64 {
    26
}

macro public(package) fun stale_valuation(): u64 {
    27
}

macro public(package) fun future_valuation(): u64 {
    28
}

macro public(package) fun invalid_valuation_price(): u64 {
    29
}

macro public(package) fun confidence_exceeds_bound(): u64 {
    30
}

macro public(package) fun mark_index_divergence_exceeds_bound(): u64 {
    31
}

macro public(package) fun mint_contribution_exceeds_bound(): u64 {
    32
}

macro public(package) fun invalid_max_mint_contribution_divergence_bps(): u64 {
    33
}

macro public(package) fun invalid_bounded_value(): u64 {
    34
}

macro public(package) fun invalid_strict_tolerance_bps(): u64 {
    35
}

macro public(package) fun invalid_emergency_tolerance_bps(): u64 {
    36
}

macro public(package) fun invalid_minimum_improvement_bps(): u64 {
    37
}

macro public(package) fun invalid_super_admin_cap(): u64 {
    40
}

macro public(package) fun invalid_admin_cap(): u64 {
    41
}

macro public(package) fun invalid_admin_recipient(): u64 {
    42
}

macro public(package) fun admin_capacity_reached(): u64 {
    43
}

macro public(package) fun invalid_admin_roles(): u64 {
    44
}

macro public(package) fun invalid_admin_role(): u64 {
    45
}

macro public(package) fun admin_role_already_granted(): u64 {
    46
}

macro public(package) fun admin_role_not_granted(): u64 {
    47
}

macro public(package) fun invalid_super_admin_recipient(): u64 {
    48
}

macro public(package) fun no_pending_super_admin_transfer(): u64 {
    49
}

macro public(package) fun not_pending_super_admin_recipient(): u64 {
    50
}

macro public(package) fun super_admin_transfer_not_ready(): u64 {
    51
}

macro public(package) fun super_admin_transfer_time_overflow(): u64 {
    52
}

macro public(package) fun super_admin_cap_still_active(): u64 {
    53
}

macro public(package) fun super_admin_transfer_unchanged(): u64 {
    54
}

macro public(package) fun redemption_gross_exceeds_bound(): u64 {
    55
}

macro public(package) fun invalid_max_redemption_gross_divergence_bps(): u64 {
    56
}

macro public(package) fun shares_out_below_minimum(): u64 {
    57
}

macro public(package) fun insufficient_leverage_improvement(): u64 {
    58
}

macro public(package) fun series_nav_cap_exceeded(): u64 {
    59
}

macro public(package) fun execution_outside_tolerance(): u64 {
    60
}

macro public(package) fun invalid_freshness_window(): u64 {
    61
}

macro public(package) fun invalid_max_order_notional(): u64 {
    64
}

macro public(package) fun max_order_notional_unchanged(): u64 {
    74
}

macro public(package) fun invalid_observation_price(): u64 {
    75
}

macro public(package) fun invalid_observation_lot_size(): u64 {
    76
}

macro public(package) fun invalid_position_observation(): u64 {
    77
}

macro public(package) fun order_notional_exceeds_maximum(): u64 {
    78
}

macro public(package) fun invalid_initialization_observation(): u64 {
    79
}

macro public(package) fun initialization_orders_not_empty(): u64 {
    80
}

macro public(package) fun initialization_venue_not_operational(): u64 {
    81
}

macro public(package) fun initialization_checkpoint_dirty(): u64 {
    82
}

macro public(package) fun initialization_margin_unsafe(): u64 {
    83
}

macro public(package) fun initialization_leverage_unhealthy(): u64 {
    84
}

macro public(package) fun initialization_exposure_below_minimum(): u64 {
    85
}
