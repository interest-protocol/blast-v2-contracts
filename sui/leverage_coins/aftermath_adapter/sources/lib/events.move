/// Replay-complete Aftermath adapter events.
module blast_leverage_aftermath::events;

use blast_leverage_aftermath::venue_account::Checkpoint;
use blast_leverage_series_one::policy::{PositionSide, TierPolicy};
use std::type_name::TypeName;

// === Constants ===

/// Health policy rejected an otherwise clean authenticated checkpoint.
const HEALTH_REASON_OBJECTIVE_FAILURE: u8 = 0;

/// Stored or settlement checkpoint comparison found an unrelated mutation.
const HEALTH_REASON_UNEXPECTED_CHECKPOINT: u8 = 1;

// === Public Structs ===

// Custody creation, upgrade authorization, receipt commit, policy restriction,
// immutability, and generation advance are emitted by `blast_admin` for every
// consumer package. No copy belongs in this registry.

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

/// Emitted after one nonzero isolated funding change is reconciled.
public struct FundingSettled<phantom Product> has copy, drop {
    vault_id: ID,
    is_cost: bool,
    raw_amount: u256,
    amount: u64,
    absorbed_by_reserve: u64,
    uncovered_cost: u64,
    reserve_after: u64,
    previous_checkpoint: Checkpoint,
    checkpoint: Checkpoint,
}

/// Emitted after health degrades or an unexpected checkpoint is persisted.
public struct HealthSynchronized<phantom Product> has copy, drop {
    vault_id: ID,
    reason: u8,
    lifecycle_changed: bool,
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

public(package) fun funding_settled<Product>(
    vault_id: ID,
    is_cost: bool,
    raw_amount: u256,
    amount: u64,
    absorbed_by_reserve: u64,
    uncovered_cost: u64,
    reserve_after: u64,
    previous_checkpoint: Checkpoint,
    checkpoint: Checkpoint,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(
        FundingSettled<Product> {
            vault_id,
            is_cost,
            raw_amount,
            amount,
            absorbed_by_reserve,
            uncovered_cost,
            reserve_after,
            previous_checkpoint,
            checkpoint,
        },
    );
}

public(package) fun health_synchronized<Product>(
    vault_id: ID,
    reason: u8,
    lifecycle_changed: bool,
    checkpoint: Checkpoint,
) {
    blast_leverage_aftermath::events_wrapper::emit_event(
        HealthSynchronized<Product> {
            vault_id,
            reason,
            lifecycle_changed,
            checkpoint,
        },
    );
}

public(package) fun objective_failure_reason(): u8 {
    HEALTH_REASON_OBJECTIVE_FAILURE
}

public(package) fun unexpected_checkpoint_reason(): u8 {
    HEALTH_REASON_UNEXPECTED_CHECKPOINT
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
public fun funding_settled_fields<Product>(
    self: &FundingSettled<Product>,
): (ID, bool, u256, u64, u64, u64, u64, Checkpoint, Checkpoint) {
    (
        self.vault_id,
        self.is_cost,
        self.raw_amount,
        self.amount,
        self.absorbed_by_reserve,
        self.uncovered_cost,
        self.reserve_after,
        self.previous_checkpoint,
        self.checkpoint,
    )
}

#[test_only]
public fun health_synchronized_fields<Product>(
    self: &HealthSynchronized<Product>,
): (ID, u8, bool, Checkpoint) {
    (
        self.vault_id,
        self.reason,
        self.lifecycle_changed,
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
