#[allow(unused_const)]
/// Numeric abort registry for the Aftermath adapter package.
///
/// Codes run from zero with no gaps: a removed check renumbers what follows
/// until the package is published, after which codes are append-only.
module blast_boosts_aftermath::errors;

// === Errors ===

#[test_only]
/// A Publisher was not claimed by the canonical adapter module.
const EInvalidPackagePublisher: u64 = 0;

#[test_only]
/// A product witness is primitive and cannot identify a sealed product module.
const EInvalidProductWitnessType: u64 = 1;

#[test_only]
/// An Aftermath admin capability is bound to another account object.
const EAdminCapAccountMismatch: u64 = 2;

#[test_only]
/// An Aftermath account object does not match the immutable binding.
const EAccountObjectMismatch: u64 = 3;

#[test_only]
/// An Aftermath account number does not match the immutable binding.
const EAccountNumberMismatch: u64 = 4;

#[test_only]
/// An Aftermath Registry does not match the immutable binding.
const ERegistryMismatch: u64 = 5;

#[test_only]
/// An Aftermath ClearingHouse does not match the immutable binding.
const EClearingHouseMismatch: u64 = 6;

#[test_only]
/// A base price-feed storage is not the one the bound market prices with.
const EBaseOracleMismatch: u64 = 7;

#[test_only]
/// A collateral price-feed storage is not the one the bound market prices with.
const ECollateralOracleMismatch: u64 = 8;

#[test_only]
/// The venue's named price is not the bound feed's price.
const EOracleObservationMismatch: u64 = 9;

#[test_only]
/// A normalized venue value cannot fit its declared atomic unit.
const ENormalizationOverflow: u64 = 10;

#[test_only]
/// Initialization collateral, and the market's collateral scale, must be six atomic decimals.
const EInvalidCollateralDecimals: u64 = 11;

#[test_only]
/// Initialization seed collateral must be positive.
const EInvalidSeed: u64 = 12;

#[test_only]
/// The maintenance reserve must leave positive seed shareholder NAV.
const EInvalidSeedReserve: u64 = 13;

#[test_only]
/// The target or order cap cannot fund one complete base lot.
const EInvalidInitializationOrderSize: u64 = 14;

#[test_only]
/// Initialization did not fill the exact planned base on the required side.
const EInitializationFillMismatch: u64 = 15;

#[test_only]
/// The selected IMR is negative or the final position IMR differs from it.
const EInitializationImrMismatch: u64 = 16;

#[test_only]
/// Scaling seed NAV into nine-decimal locked shares overflowed `u64`.
const ELockedSharesOverflow: u64 = 17;

#[test_only]
/// Atomic initialization requires more venue orders than the adapter permits.
const EInitializationOrderCountExceeded: u64 = 18;

#[test_only]
/// A collateral input or withdrawal must be positive.
const EZeroAmount: u64 = 19;

#[test_only]
/// Earned local admin collateral cannot cover this withdrawal.
const EInsufficientAdminCash: u64 = 20;

#[test_only]
/// A cash operation changed more or less than its exact authenticated collateral delta.
const ECashCheckpointMismatch: u64 = 21;

#[test_only]
/// A market session failed to make a positive whole-lot fill on the selected side.
const EFillMismatch: u64 = 22;

#[test_only]
/// A market session left posted orders.
const EOrdersPosted: u64 = 23;

#[test_only]
/// A market session reported liquidation or bad debt.
const ELiquidation: u64 = 24;

#[test_only]
/// The active atomic operation exhausted its market-session bound.
const EActiveOrderCountExceeded: u64 = 25;

#[test_only]
/// The caller's deadline has passed.
const EDeadlineExpired: u64 = 26;

#[test_only]
/// An active venue session changed a field outside its authenticated execution.
const EActiveCheckpointMismatch: u64 = 27;

#[test_only]
/// The held native share coin differs from the sealed redemption amount.
const ERedemptionShareMismatch: u64 = 28;

#[test_only]
/// Authenticated ordinary plus priority fees exceed a representable conservative rate.
const EVenueFeeUnusable: u64 = 29;

#[test_only]
/// A financial operation observed a venue change not reconciled into the accepted checkpoint.
const EUnresolvedCheckpoint: u64 = 30;

#[test_only]
/// Terminal recovery requires exact flat exposure, settled liabilities and integral cash.
const ETerminalVenueUnsettled: u64 = 31;

#[test_only]
/// A close requires positive exact whole-lot base in the bound product direction.
const EInvalidUnwindExposure: u64 = 32;

#[test_only]
/// The venue cannot serve the operation: open orders, unsafe margin, a paused market, or a frozen clearing house.
const EVenueNotReady: u64 = 33;

#[test_only]
/// A metadata update must change the name, the description, or the icon.
const EMetadataUnchanged: u64 = 34;

macro public(package) fun invalid_package_publisher(): u64 { 0 }
macro public(package) fun invalid_product_witness_type(): u64 { 1 }
macro public(package) fun admin_cap_account_mismatch(): u64 { 2 }
macro public(package) fun account_object_mismatch(): u64 { 3 }
macro public(package) fun account_number_mismatch(): u64 { 4 }
macro public(package) fun registry_mismatch(): u64 { 5 }
macro public(package) fun clearing_house_mismatch(): u64 { 6 }
macro public(package) fun base_oracle_mismatch(): u64 { 7 }
macro public(package) fun collateral_oracle_mismatch(): u64 { 8 }
macro public(package) fun oracle_observation_mismatch(): u64 { 9 }
macro public(package) fun normalization_overflow(): u64 { 10 }
macro public(package) fun invalid_collateral_decimals(): u64 { 11 }
macro public(package) fun invalid_seed(): u64 { 12 }
macro public(package) fun invalid_seed_reserve(): u64 { 13 }
macro public(package) fun invalid_initialization_order_size(): u64 { 14 }
macro public(package) fun initialization_fill_mismatch(): u64 { 15 }
macro public(package) fun initialization_imr_mismatch(): u64 { 16 }
macro public(package) fun locked_shares_overflow(): u64 { 17 }
macro public(package) fun initialization_order_count_exceeded(): u64 { 18 }
macro public(package) fun zero_amount(): u64 { 19 }
macro public(package) fun insufficient_admin_cash(): u64 { 20 }
macro public(package) fun cash_checkpoint_mismatch(): u64 { 21 }
macro public(package) fun fill_mismatch(): u64 { 22 }
macro public(package) fun orders_posted(): u64 { 23 }
macro public(package) fun liquidation(): u64 { 24 }
macro public(package) fun active_order_count_exceeded(): u64 { 25 }
macro public(package) fun deadline_expired(): u64 { 26 }
macro public(package) fun active_checkpoint_mismatch(): u64 { 27 }
macro public(package) fun redemption_share_mismatch(): u64 { 28 }
macro public(package) fun venue_fee_unusable(): u64 { 29 }
macro public(package) fun unresolved_checkpoint(): u64 { 30 }
macro public(package) fun terminal_venue_unsettled(): u64 { 31 }
macro public(package) fun invalid_unwind_exposure(): u64 { 32 }
macro public(package) fun venue_not_ready(): u64 { 33 }
macro public(package) fun metadata_unchanged(): u64 { 34 }
