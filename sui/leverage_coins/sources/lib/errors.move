#[allow(unused_const)]
module blast_leverage_coins::errors;

// === Errors ===

// Append-only package error registry. Never reuse a retired numeric code.
// `README.md` maps every code to its macro, raising module, and meaning.

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
/// The current Series lifecycle cannot make the requested state transition.
const EInvalidLifecycleTransition: u64 = 17;

#[test_only]
/// The current Series lifecycle does not permit the requested operation.
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
/// Series leverage bounds must satisfy 0 < lower < target < upper < hard cap.
const EInvalidLeverageBounds: u64 = 22;

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

macro public(package) fun invalid_leverage_bounds(): u64 {
    22
}
