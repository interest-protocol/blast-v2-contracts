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

#[test_only]
/// A Series NAV cap must be positive.
const EInvalidSeriesNavCap: u64 = 23;

#[test_only]
/// A valuation maximum age must be positive.
const EInvalidMaxPriceAge: u64 = 24;

#[test_only]
/// A valuation confidence bound must be below the basis-point denominator.
const EInvalidMaxConfidenceBps: u64 = 25;

#[test_only]
/// A mark divergence bound must be below the basis-point denominator.
const EInvalidMaxMarkDivergenceBps: u64 = 26;

#[test_only]
/// A valuation observation is older than the policy freshness budget.
const EStaleValuation: u64 = 27;

#[test_only]
/// A valuation observation is stamped further ahead than the policy skew budget.
const EFutureValuation: u64 = 28;

#[test_only]
/// A gated valuation price must be positive.
const EInvalidValuationPrice: u64 = 29;

#[test_only]
/// A valuation confidence interval exceeds the policy bound.
const EConfidenceExceedsBound: u64 = 30;

#[test_only]
/// The venue mark diverges from the index beyond the policy bound.
const EMarkIndexDivergenceExceedsBound: u64 = 31;

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
