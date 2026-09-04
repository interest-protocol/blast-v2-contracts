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
