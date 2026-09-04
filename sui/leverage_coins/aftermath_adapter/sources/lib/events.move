/// Replay-complete Aftermath adapter events.
module blast_leverage_aftermath::events;

use blast_leverage_aftermath::venue_account::Checkpoint;
use blast_leverage_series_one::policy::{PositionSide, TierPolicy};
use std::type_name::TypeName;

// === Public Structs ===

/// Emitted after checked activation advances the adapter cutover.
public struct PackageVersionAdvanced has copy, drop {
    previous_version: u64,
    new_version: u64,
}

/// Emitted after the Publisher and UpgradeCap enter adapter custody.
public struct PackageAdminCreated has copy, drop {
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    package_version: u64,
    policy: u8,
}

/// Emitted after one exact adapter package digest is authorized.
public struct UpgradeAuthorized has copy, drop {
    package_id: ID,
    package_version: u64,
    policy: u8,
    digest: vector<u8>,
}

/// Emitted after a native receipt advances the adapter UpgradeCap.
public struct UpgradeCommitted has copy, drop {
    package_id: ID,
    previous_version: u64,
    new_version: u64,
}

/// Emitted after the adapter upgrade policy becomes more restrictive.
public struct UpgradePolicyRestricted has copy, drop {
    previous_policy: u8,
    new_policy: u8,
}

/// Emitted after one adapter Vault and its leverage currency are issued.
public struct VaultIssued<phantom Product> has copy, drop {
    vault_id: ID,
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    risk_module_witness: TypeName,
    tier_policy: TierPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
    maintenance_reserve: u64,
}

/// Emitted after one atomic seed activates a bound Aftermath Vault.
public struct VaultInitialized<phantom Product> has copy, drop {
    vault_id: ID,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
    seed_amount: u64,
    seed_venue_equity: u64,
    seed_reserve: u64,
    seed_shareholder_nav: u64,
    locked_shares: u64,
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
    checkpoint: Checkpoint,
}

/// Emitted after the trusted risk-module witness changes.
public struct RiskModuleWitnessRotated<phantom Product> has copy, drop {
    vault_id: ID,
    previous_witness: TypeName,
    new_witness: TypeName,
}

/// Emitted after the active risk module changes the live maximum order notional.
public struct MaxOrderNotionalUpdated<phantom Product> has copy, drop {
    vault_id: ID,
    previous_current: u64,
    new_current: u64,
}

/// Emitted after the Series1 risk administrator disables new risk.
public struct ReduceOnlyEntered<phantom Product> has copy, drop {
    vault_id: ID,
}

// === Package Functions ===

public(package) fun package_version_advanced(previous_version: u64, new_version: u64) {
    blast_leverage_aftermath::events_wrapper::emit_event(PackageVersionAdvanced {
        previous_version,
        new_version,
    });
}

public(package) fun package_admin_created(
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    package_version: u64,
    policy: u8,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(PackageAdminCreated {
        package_admin_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        package_version,
        policy,
    });
}

public(package) fun upgrade_authorized(
    package_id: ID,
    package_version: u64,
    policy: u8,
    digest: vector<u8>,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(UpgradeAuthorized {
        package_id,
        package_version,
        policy,
        digest,
    });
}

public(package) fun upgrade_committed(
    package_id: ID,
    previous_version: u64,
    new_version: u64,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(UpgradeCommitted {
        package_id,
        previous_version,
        new_version,
    });
}

public(package) fun upgrade_policy_restricted(previous_policy: u8, new_policy: u8) {
    blast_leverage_aftermath::events_wrapper::emit_event(UpgradePolicyRestricted {
        previous_policy,
        new_policy,
    });
}

public(package) fun vault_issued<Product>(
    vault_id: ID,
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    risk_module_witness: TypeName,
    tier_policy: TierPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
    maintenance_reserve: u64,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(VaultIssued<Product> {
        vault_id,
        treasury_cap_id,
        metadata_cap_id,
        risk_module_witness,
        tier_policy,
        max_order_notional_minimum,
        max_order_notional_current,
        max_order_notional_maximum,
        maintenance_reserve,
    });
}

public(package) fun vault_initialized<Product>(
    vault_id: ID,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
    seed_amount: u64,
    seed_venue_equity: u64,
    seed_reserve: u64,
    seed_shareholder_nav: u64,
    locked_shares: u64,
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
    checkpoint: Checkpoint,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(
        VaultInitialized<Product> {
            vault_id,
            account_object_id,
            account_number,
            registry_id,
            clearing_house_id,
            base_oracle_id,
            collateral_oracle_id,
            collateral_type,
            seed_amount,
            seed_venue_equity,
            seed_reserve,
            seed_shareholder_nav,
            locked_shares,
            absolute_base,
            absolute_notional,
            lot_size,
            position_side,
            position_imr,
            checkpoint,
        },
    );
}

public(package) fun risk_module_witness_rotated<Product>(
    vault_id: ID,
    previous_witness: TypeName,
    new_witness: TypeName,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(
        RiskModuleWitnessRotated<Product> {
            vault_id,
            previous_witness,
            new_witness,
        },
    );
}

public(package) fun max_order_notional_updated<Product>(
    vault_id: ID,
    previous_current: u64,
    new_current: u64,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(
        MaxOrderNotionalUpdated<Product> {
            vault_id,
            previous_current,
            new_current,
        },
    );
}

public(package) fun reduce_only_entered<Product>(vault_id: ID) {
    blast_leverage_aftermath::events_wrapper::emit_event(
        ReduceOnlyEntered<Product> { vault_id },
    );
}

// === Test-Only Functions ===

#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_leverage_aftermath::events_wrapper::Event<T>>().do!(
        |event| out.push_back(event.unwrap()),
    );

    out
}

#[test_only]
#[allow(lint(abort_without_constant))]
public fun collect_one<T: copy + drop>(abort_code: u64): T {
    let mut events = collect<T>();

    assert!(events.length() == 1, abort_code);

    events.pop_back()
}

#[test_only]
public fun package_version_advanced_fields(
    self: &PackageVersionAdvanced,
): (u64, u64) {
    (self.previous_version, self.new_version)
}

#[test_only]
public fun vault_issued_fields<Product>(
    self: &VaultIssued<Product>,
): (ID, ID, ID, TypeName, TierPolicy, u64, u64, u64, u64) {
    (
        self.vault_id,
        self.treasury_cap_id,
        self.metadata_cap_id,
        self.risk_module_witness,
        self.tier_policy,
        self.max_order_notional_minimum,
        self.max_order_notional_current,
        self.max_order_notional_maximum,
        self.maintenance_reserve,
    )
}

#[test_only]
public fun vault_initialized_fields<Product>(
    self: &VaultInitialized<Product>,
): (
    ID,
    ID,
    u64,
    ID,
    ID,
    ID,
    ID,
    TypeName,
    u64,
    u64,
    u64,
    u64,
    u64,
    u64,
    u64,
    u64,
    PositionSide,
    u256,
    Checkpoint,
) {
    (
        self.vault_id,
        self.account_object_id,
        self.account_number,
        self.registry_id,
        self.clearing_house_id,
        self.base_oracle_id,
        self.collateral_oracle_id,
        self.collateral_type,
        self.seed_amount,
        self.seed_venue_equity,
        self.seed_reserve,
        self.seed_shareholder_nav,
        self.locked_shares,
        self.absolute_base,
        self.absolute_notional,
        self.lot_size,
        self.position_side,
        self.position_imr,
        self.checkpoint,
    )
}

#[test_only]
public fun risk_module_witness_rotated_fields<Product>(
    self: &RiskModuleWitnessRotated<Product>,
): (ID, TypeName, TypeName) {
    (self.vault_id, self.previous_witness, self.new_witness)
}

#[test_only]
public fun max_order_notional_updated_fields<Product>(
    self: &MaxOrderNotionalUpdated<Product>,
): (ID, u64, u64) {
    (self.vault_id, self.previous_current, self.new_current)
}

#[test_only]
public fun reduce_only_entered_vault_id<Product>(
    self: &ReduceOnlyEntered<Product>,
): ID {
    self.vault_id
}

#[test_only]
public fun package_admin_created_fields(
    self: &PackageAdminCreated,
): (ID, ID, ID, ID, u64, u8) {
    (
        self.package_admin_id,
        self.publisher_id,
        self.upgrade_cap_id,
        self.package_id,
        self.package_version,
        self.policy,
    )
}

#[test_only]
public fun upgrade_authorized_fields(
    self: &UpgradeAuthorized,
): (ID, u64, u8, vector<u8>) {
    (self.package_id, self.package_version, self.policy, self.digest)
}

#[test_only]
public fun upgrade_committed_fields(self: &UpgradeCommitted): (ID, u64, u64) {
    (self.package_id, self.previous_version, self.new_version)
}

#[test_only]
public fun upgrade_policy_restricted_fields(
    self: &UpgradePolicyRestricted,
): (u8, u8) {
    (self.previous_policy, self.new_policy)
}
