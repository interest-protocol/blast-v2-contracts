#[allow(unused_const)]
/// Stable numeric abort registry for the Aftermath adapter package.
module blast_leverage_aftermath::errors;

// === Errors ===

#[test_only]
/// Shared adapter state does not match this package generation.
const EPackageVersionMismatch: u64 = 0;

#[test_only]
/// Advancing the adapter version would overflow `u64`.
const EPackageVersionOverflow: u64 = 1;

#[test_only]
/// A risk-module witness is primitive and cannot identify a sealed module.
const EInvalidRiskModuleWitnessType: u64 = 2;

#[test_only]
/// A risk-module rotation selected the active witness type.
const ERiskModuleWitnessUnchanged: u64 = 3;

#[test_only]
/// A Publisher was not claimed by the canonical adapter module.
const EInvalidPackagePublisher: u64 = 4;

#[test_only]
/// An UpgradeCap does not belong to the original adapter package.
const EInvalidUpgradeCap: u64 = 5;

#[test_only]
/// A package-upgrade digest is not exactly 32 bytes.
const EInvalidPackageDigest: u64 = 6;

#[test_only]
/// An upgrade policy is unchanged or less restrictive.
const EUpgradePolicyNotMoreRestrictive: u64 = 7;

#[test_only]
/// A product witness is primitive and cannot identify a sealed product module.
const EInvalidProductWitnessType: u64 = 8;

#[test_only]
/// A product witness does not originate from this adapter package family.
const EProductWitnessPackageMismatch: u64 = 9;

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

#[test_only]
/// A Vault already contains its one Aftermath venue account.
const EVenueAccountAlreadyInstalled: u64 = 19;

#[test_only]
/// An oracle storage id differs from the bound market parameter.
const EOracleStorageMismatch: u64 = 20;

#[test_only]
/// An oracle source id differs from the bound market parameter.
const EOracleSourceMismatch: u64 = 21;

#[test_only]
/// An Aftermath feed does not originate from the presented Pyth object.
const EPythPriceInfoMismatch: u64 = 22;

#[test_only]
/// A Pyth price is negative or cannot normalize into the adapter unit.
const EInvalidPythPrice: u64 = 23;

#[test_only]
/// A Pyth exponent or normalized value cannot fit the adapter unit.
const EPythNormalizationOverflow: u64 = 24;

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

#[test_only]
/// Initialization requires the leverage currency to have zero supply.
const EShareSupplyNotZero: u64 = 31;

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

macro public(package) fun package_version_mismatch(): u64 {
    0
}

macro public(package) fun package_version_overflow(): u64 {
    1
}

macro public(package) fun invalid_risk_module_witness_type(): u64 {
    2
}

macro public(package) fun risk_module_witness_unchanged(): u64 {
    3
}

macro public(package) fun invalid_package_publisher(): u64 {
    4
}

macro public(package) fun invalid_upgrade_cap(): u64 {
    5
}

macro public(package) fun invalid_package_digest(): u64 {
    6
}

macro public(package) fun upgrade_policy_not_more_restrictive(): u64 {
    7
}

macro public(package) fun invalid_product_witness_type(): u64 {
    8
}

macro public(package) fun product_witness_package_mismatch(): u64 {
    9
}

macro public(package) fun risk_module_witness_mismatch(): u64 {
    10
}

macro public(package) fun admin_cap_account_mismatch(): u64 {
    11
}

macro public(package) fun account_object_mismatch(): u64 {
    12
}

macro public(package) fun account_number_mismatch(): u64 {
    13
}

macro public(package) fun registry_mismatch(): u64 {
    14
}

macro public(package) fun clearing_house_mismatch(): u64 {
    15
}

macro public(package) fun base_oracle_mismatch(): u64 {
    16
}

macro public(package) fun collateral_oracle_mismatch(): u64 {
    17
}

macro public(package) fun collateral_type_mismatch(): u64 {
    18
}

macro public(package) fun venue_account_already_installed(): u64 {
    19
}

macro public(package) fun oracle_storage_mismatch(): u64 { 20 }

macro public(package) fun oracle_source_mismatch(): u64 { 21 }

macro public(package) fun pyth_price_info_mismatch(): u64 { 22 }

macro public(package) fun invalid_pyth_price(): u64 { 23 }

macro public(package) fun pyth_normalization_overflow(): u64 { 24 }

macro public(package) fun oracle_observation_mismatch(): u64 { 25 }

macro public(package) fun normalization_overflow(): u64 { 26 }

macro public(package) fun incoherent_position_signs(): u64 { 27 }

macro public(package) fun invalid_collateral_decimals(): u64 { 28 }

macro public(package) fun invalid_seed(): u64 { 29 }

macro public(package) fun invalid_seed_reserve(): u64 { 30 }

macro public(package) fun share_supply_not_zero(): u64 { 31 }

macro public(package) fun invalid_initialization_order_size(): u64 { 32 }

macro public(package) fun initialization_fill_mismatch(): u64 { 33 }

macro public(package) fun initialization_orders_posted(): u64 { 34 }

macro public(package) fun initialization_liquidation(): u64 { 35 }

macro public(package) fun initialization_imr_mismatch(): u64 { 36 }

macro public(package) fun locked_shares_overflow(): u64 { 37 }
