// `blast_leverage_series_one::errors` centralizes package abort codes through zero-cost macros.
// This narrow suppression preserves caller-local abort locations and the stable code map in
// `README.md`.
#[allow(lint(abort_without_constant))]
/// Shared Series1 state and authorized share-currency issuance.
///
/// Issuance creates an inert Vault with no assets and no share supply. A later
/// adapter-backed initialization transition must atomically establish custody,
/// seed the position, mint the initial shares, and activate the lifecycle.
module blast_leverage_series_one::vault;

use blast_leverage_series_one::{
    acl::AdminWitness,
    bounded_value::{Self, BoundedValue},
    constants,
    events,
    lifecycle::{Self, Lifecycle},
    package_version::PackageVersion,
    policy::TierPolicy,
};
use std::{
    string::String,
    type_name::{Self, TypeName},
};
use sui::{
    bag::{Self, Bag},
    coin::TreasuryCap,
    coin_registry::{CoinRegistry, MetadataCap},
    dynamic_object_field,
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

// === Public Types ===

/// Shared canonical state for one Series1 leveraged coin.
///
/// `AdapterRoot` permanently identifies the adapter family that created the
/// share-currency type. The stored adapter witness may later rotate within that
/// original package family without changing the share-currency type.
public struct Vault<phantom AdapterRoot> has key {
    id: UID,
    tier_policy: TierPolicy,
    notional_cap: BoundedValue,
    maintenance_reserve: u64,
    lifecycle: Lifecycle,
    adapter_witness: TypeName,
    risk_module_witness: TypeName,
    adapter_storage: Bag,
}

/// Stable dynamic-object-field key for the Vault's share mint authority.
///
/// Keeping the `TreasuryCap` as an object child preserves its identity and
/// discoverability while the Vault retains exclusive custody.
public struct TreasuryKey<phantom CoinType>() has copy, drop, store;

/// Stable dynamic-object-field key for the Vault's metadata authority.
///
/// Keeping the `MetadataCap` as an object child preserves its identity and
/// discoverability while the Vault retains exclusive custody.
public struct MetadataKey<phantom CoinType>() has copy, drop, store;

// === Public Functions ===

/// Issues one inert Vault and its unique dynamic share currency.
///
/// The package version and issuer role are checked before caller-controlled
/// policy values. Both witness types must be non-primitive nominal types. The
/// currency registry prevents a second Vault currency for the same
/// `Vault<AdapterRoot>` type. The Vault permanently owns both currency
/// capabilities as discoverable dynamic object children.
public fun issue<AdapterRoot, RiskModule>(
    registry: &mut CoinRegistry,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness,
    tier_policy: TierPolicy,
    notional_minimum: u64,
    notional_current: u64,
    notional_maximum: u64,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    admin_witness.assert_role(constants::vault_issuer_role!());

    let mut vault = new<AdapterRoot, RiskModule>(
        tier_policy,
        notional_minimum,
        notional_current,
        notional_maximum,
        ctx,
    );
    let (initializer, treasury_cap) = registry.new_currency<Vault<AdapterRoot>>(
        constants::share_decimals!(),
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    let treasury_cap_id = object::id(&treasury_cap);
    let metadata_cap_id = object::id(&metadata_cap);
    let vault_id = vault.id.to_inner();

    vault.add_treasury_cap(treasury_cap);
    vault.add_metadata_cap(metadata_cap);
    events::vault_issued<AdapterRoot>(
        vault_id,
        treasury_cap_id,
        metadata_cap_id,
        vault.adapter_witness,
        vault.risk_module_witness,
        vault.tier_policy,
        vault.notional_cap,
        0,
    );
    transfer::share_object(vault);
}

// === Private Functions ===

/// Creates one validated but unshared inert Vault.
///
/// The public issuer selects adapter and risk-module types as type arguments.
/// Runtime witness values are unnecessary because `issue` has already checked
/// the package-global issuer role.
fun new<AdapterRoot, RiskModule>(
    tier_policy: TierPolicy,
    notional_minimum: u64,
    notional_current: u64,
    notional_maximum: u64,
    ctx: &mut TxContext,
): Vault<AdapterRoot> {
    let adapter_witness = type_name::with_original_ids<AdapterRoot>();
    assert!(
        !adapter_witness.is_primitive(),
        blast_leverage_series_one::errors::invalid_adapter_witness_type!(),
    );

    let risk_module_witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !risk_module_witness.is_primitive(),
        blast_leverage_series_one::errors::invalid_risk_module_witness_type!(),
    );
    assert!(
        notional_minimum > 0,
        blast_leverage_series_one::errors::invalid_notional_cap!(),
    );

    Vault {
        id: object::new(ctx),
        tier_policy,
        notional_cap: bounded_value::new(
            notional_minimum,
            notional_current,
            notional_maximum,
        ),
        maintenance_reserve: 0,
        lifecycle: lifecycle::new(),
        adapter_witness,
        risk_module_witness,
        adapter_storage: bag::new(ctx),
    }
}

fun add_treasury_cap<AdapterRoot>(
    self: &mut Vault<AdapterRoot>,
    treasury_cap: TreasuryCap<Vault<AdapterRoot>>,
) {
    self.id.add_dynamic_object_field(
        TreasuryKey<Vault<AdapterRoot>>(),
        treasury_cap,
    );
}

fun add_metadata_cap<AdapterRoot>(
    self: &mut Vault<AdapterRoot>,
    metadata_cap: MetadataCap<Vault<AdapterRoot>>,
) {
    self.id.add_dynamic_object_field(
        MetadataKey<Vault<AdapterRoot>>(),
        metadata_cap,
    );
}

// === Test-Only Functions ===

#[test_only]
fun treasury_cap<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): &TreasuryCap<Vault<AdapterRoot>> {
    dynamic_object_field::borrow(
        &self.id,
        TreasuryKey<Vault<AdapterRoot>>(),
    )
}

#[test_only]
fun metadata_cap<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): &MetadataCap<Vault<AdapterRoot>> {
    dynamic_object_field::borrow(
        &self.id,
        MetadataKey<Vault<AdapterRoot>>(),
    )
}

#[test_only]
public fun vault_id_for_testing<AdapterRoot>(self: &Vault<AdapterRoot>): ID {
    self.id.to_inner()
}

#[test_only]
public fun is_uninitialized_for_testing<AdapterRoot>(self: &Vault<AdapterRoot>): bool {
    self.lifecycle.is_uninitialized()
}

#[test_only]
public fun maintenance_reserve_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): u64 {
    self.maintenance_reserve
}

#[test_only]
public fun adapter_storage_is_empty_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): bool {
    self.adapter_storage.is_empty()
}

#[test_only]
public fun tier_policy_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): TierPolicy {
    self.tier_policy
}

#[test_only]
public fun adapter_witness_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): TypeName {
    self.adapter_witness
}

#[test_only]
public fun risk_module_witness_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): TypeName {
    self.risk_module_witness
}

#[test_only]
public fun treasury_cap_id_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): ID {
    object::id(self.treasury_cap())
}

#[test_only]
public fun metadata_cap_id_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): ID {
    object::id(self.metadata_cap())
}

#[test_only]
public fun share_supply_for_testing<AdapterRoot>(
    self: &Vault<AdapterRoot>,
): u64 {
    self.treasury_cap().total_supply()
}
