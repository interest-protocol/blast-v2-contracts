#[allow(unused_const)]
/// Stable numeric abort registry for the Aftermath adapter package.
module blast_boosts_aftermath::errors;

// === Errors ===

// Codes 0 and 1 retired: operational-generation checking and its checked
// arithmetic moved to `blast_admin::operational_version`.

#[test_only]
/// A risk-module witness is primitive or originates from the adapter package.
const EInvalidRiskModuleWitnessType: u64 = 2;

#[test_only]
/// A risk-module rotation selected the active witness type.
const ERiskModuleWitnessUnchanged: u64 = 3;

#[test_only]
/// A Publisher was not claimed by the canonical adapter module.
const EInvalidPackagePublisher: u64 = 4;

// Codes 5, 6, and 7 retired: UpgradeCap provenance, digest length, and policy
// narrowing moved to `blast_admin::upgrade_custody`.

#[test_only]
/// A product witness is primitive and cannot identify a sealed product module.
const EInvalidProductWitnessType: u64 = 8;

// Code 9 retired: the `Product<Tag>` wrapper and its package-origin check
// gave way to a plain product witness type owned by its defining module.

#[test_only]
/// A call did not present the risk-module type selected by this Vault.
const ERiskModuleWitnessMismatch: u64 = 10;

#[test_only]
/// An Aftermath admin capability is bound to another account object.
const EAdminCapAccountMismatch: u64 = 11;

#[test_only]
/// An Aftermath account object does not match the immutable binding.
const EAccountObjectMismatch: u64 = 12;

#[test_only]
/// An Aftermath account number does not match the immutable binding.
const EAccountNumberMismatch: u64 = 13;

#[test_only]
/// An Aftermath Registry does not match the immutable binding.
const ERegistryMismatch: u64 = 14;

#[test_only]
/// An Aftermath ClearingHouse does not match the immutable binding.
const EClearingHouseMismatch: u64 = 15;

#[test_only]
/// A base oracle object does not match the immutable binding.
const EBaseOracleMismatch: u64 = 16;

#[test_only]
/// A collateral oracle object does not match the immutable binding.
const ECollateralOracleMismatch: u64 = 17;

#[test_only]
/// A collateral type does not match the immutable binding.
const ECollateralTypeMismatch: u64 = 18;

// Code 19 retired: a Vault is built with its venue account, so nothing can
// install one twice.

#[test_only]
/// An oracle storage id differs from the bound market parameter.
const EOracleStorageMismatch: u64 = 20;

#[test_only]
/// An oracle source id differs from the bound market parameter.
const EOracleSourceMismatch: u64 = 21;

#[test_only]
/// An Aftermath feed does not originate from the presented Pyth object.
const EPythPriceInfoMismatch: u64 = 22;

// Codes 23 and 24 retired: a negative or unrepresentable Pyth component is one
// unrepresentable oracle leg, refused by a strict capture as `normalization_overflow`.

#[test_only]
/// Pyth and Aftermath observations do not describe one price update.
const EOracleObservationMismatch: u64 = 25;

#[test_only]
/// A normalized venue value cannot fit its declared atomic unit.
const ENormalizationOverflow: u64 = 26;

#[test_only]
/// Position base and quote signs do not express one coherent direction.
const EIncoherentPositionSigns: u64 = 27;

#[test_only]
/// Initialization collateral must use six atomic decimals.
const EInvalidCollateralDecimals: u64 = 28;

#[test_only]
/// Initialization seed collateral must be positive.
const EInvalidSeed: u64 = 29;

#[test_only]
/// The maintenance reserve must leave positive seed shareholder NAV.
const EInvalidSeedReserve: u64 = 30;

// Code 31 retired: an issuance mints nothing before its locked seed shares,
// so the zero-supply precondition holds by construction.

#[test_only]
/// The target or order cap cannot fund one complete base lot.
const EInvalidInitializationOrderSize: u64 = 32;

#[test_only]
/// Initialization did not fill the exact planned base on the required side.
const EInitializationFillMismatch: u64 = 33;

#[test_only]
/// Initialization left one or more posted orders.
const EInitializationOrdersPosted: u64 = 34;

#[test_only]
/// Initialization observed liquidation or bad debt in its session.
const EInitializationLiquidation: u64 = 35;

#[test_only]
/// The selected IMR is negative or the final position IMR differs from it.
const EInitializationImrMismatch: u64 = 36;

#[test_only]
/// Scaling seed NAV into nine-decimal locked shares overflowed `u64`.
const ELockedSharesOverflow: u64 = 37;

#[test_only]
/// Atomic initialization requires more venue orders than the adapter permits.
const EInitializationOrderCountExceeded: u64 = 38;

// Code 39 retired: no Vault exists before its venue account does.

#[test_only]
/// A collateral input or withdrawal must be positive.
const EZeroAmount: u64 = 40;

#[test_only]
/// Earned local admin collateral cannot cover this withdrawal.
const EInsufficientAdminCash: u64 = 41;

#[test_only]
/// A cash operation changed more or less than its exact authenticated collateral delta.
const ECashCheckpointMismatch: u64 = 42;

#[test_only]
/// An active session failed to make a positive whole-lot fill on the selected side.
const EActiveFillMismatch: u64 = 43;

#[test_only]
/// An active market session left posted orders.
const EActiveOrdersPosted: u64 = 44;

#[test_only]
/// An active market session reported liquidation or bad debt.
const EActiveLiquidation: u64 = 45;

#[test_only]
/// The active atomic operation exhausted its market-session bound.
const EActiveOrderCountExceeded: u64 = 46;

#[test_only]
/// The caller's deadline has passed.
const EDeadlineExpired: u64 = 47;

#[test_only]
/// An active venue session changed a field outside its authenticated execution.
const EActiveCheckpointMismatch: u64 = 48;

#[test_only]
/// The held native share coin differs from the sealed redemption amount.
const ERedemptionShareMismatch: u64 = 49;

#[test_only]
/// Authenticated ordinary plus priority fees exceed a representable conservative rate.
const EVenueFeeUnusable: u64 = 50;

#[test_only]
/// Activation ownership is immutable and can be recorded only before any shares exist.
const ESeedAlreadyRecorded: u64 = 51;

#[test_only]
/// The immutable seed cash beneficiary must not be the zero address.
const EInvalidSeedFunder: u64 = 52;

#[test_only]
/// A financial operation observed a venue change not reconciled into the accepted checkpoint.
const EUnresolvedCheckpoint: u64 = 53;

#[test_only]
/// Terminal recovery requires exact flat exposure, settled liabilities and integral cash.
const ETerminalVenueUnsettled: u64 = 54;

#[test_only]
/// A close requires positive exact whole-lot base in the bound product direction.
const EInvalidUnwindExposure: u64 = 55;

// === Package Functions ===

macro public(package) fun invalid_risk_module_witness_type(): u64 { 2 }
macro public(package) fun risk_module_witness_unchanged(): u64 { 3 }
macro public(package) fun invalid_package_publisher(): u64 { 4 }
macro public(package) fun invalid_product_witness_type(): u64 { 8 }
macro public(package) fun risk_module_witness_mismatch(): u64 { 10 }
macro public(package) fun admin_cap_account_mismatch(): u64 { 11 }
macro public(package) fun account_object_mismatch(): u64 { 12 }
macro public(package) fun account_number_mismatch(): u64 { 13 }
macro public(package) fun registry_mismatch(): u64 { 14 }
macro public(package) fun clearing_house_mismatch(): u64 { 15 }
macro public(package) fun base_oracle_mismatch(): u64 { 16 }
macro public(package) fun collateral_oracle_mismatch(): u64 { 17 }
macro public(package) fun collateral_type_mismatch(): u64 { 18 }
macro public(package) fun oracle_storage_mismatch(): u64 { 20 }
macro public(package) fun oracle_source_mismatch(): u64 { 21 }
macro public(package) fun pyth_price_info_mismatch(): u64 { 22 }
macro public(package) fun oracle_observation_mismatch(): u64 { 25 }
macro public(package) fun normalization_overflow(): u64 { 26 }
macro public(package) fun incoherent_position_signs(): u64 { 27 }
macro public(package) fun invalid_collateral_decimals(): u64 { 28 }
macro public(package) fun invalid_seed(): u64 { 29 }
macro public(package) fun invalid_seed_reserve(): u64 { 30 }
macro public(package) fun invalid_initialization_order_size(): u64 { 32 }
macro public(package) fun initialization_fill_mismatch(): u64 { 33 }
macro public(package) fun initialization_orders_posted(): u64 { 34 }
macro public(package) fun initialization_liquidation(): u64 { 35 }
macro public(package) fun initialization_imr_mismatch(): u64 { 36 }
macro public(package) fun locked_shares_overflow(): u64 { 37 }
macro public(package) fun initialization_order_count_exceeded(): u64 { 38 }
macro public(package) fun zero_amount(): u64 { 40 }
macro public(package) fun insufficient_admin_cash(): u64 { 41 }
macro public(package) fun cash_checkpoint_mismatch(): u64 { 42 }
macro public(package) fun active_fill_mismatch(): u64 { 43 }
macro public(package) fun active_orders_posted(): u64 { 44 }
macro public(package) fun active_liquidation(): u64 { 45 }
macro public(package) fun active_order_count_exceeded(): u64 { 46 }
macro public(package) fun deadline_expired(): u64 { 47 }
macro public(package) fun active_checkpoint_mismatch(): u64 { 48 }
macro public(package) fun redemption_share_mismatch(): u64 { 49 }
macro public(package) fun venue_fee_unusable(): u64 { 50 }
macro public(package) fun seed_already_recorded(): u64 { 51 }
macro public(package) fun invalid_seed_funder(): u64 { 52 }
macro public(package) fun unresolved_checkpoint(): u64 { 53 }
macro public(package) fun terminal_venue_unsettled(): u64 { 54 }
macro public(package) fun invalid_unwind_exposure(): u64 { 55 }
