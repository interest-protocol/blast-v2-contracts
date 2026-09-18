/// Replay-complete Aftermath adapter events.
module blast_boosts_aftermath::events;

// === Constants ===

/// A sync found a mutation no vault operation explains; the vault now holds an
/// unresolved diagnostic and refuses priced operations until it clears.
const HEALTH_DIAGNOSTIC_RAISED: u8 = 1;

/// A later sync, or terminal settlement, produced a clean checkpoint again.
const HEALTH_DIAGNOSTIC_CLEARED: u8 = 2;

// === Public Structs ===

/// Completed close-only progress with exact raw venue effects.
/// Ordinary market closes expose the isolated funding checkpoint and filled quote.
/// Direct frozen settlement has neither a market order nor a synthetic funding/fill attribution.
public struct UnwindProgress<phantom Product> has copy, drop {
    vault_id: ID,
    before: Checkpoint,
    after_funding: Option<Checkpoint>,
    after: Checkpoint,
    market_orders: u64,
    filled_quote: Option<u256>,
}

/// Actual recovered holder cash and frozen eligible supply after venue finality.
/// A beneficiary is present only for the zero-eligible-supply fallback transfer.
public struct ShutdownFinalized<phantom Product> has copy, drop {
    vault_id: ID,
    recovered_cash: u64,
    eligible_supply: u64,
    seed_funder_payment: Option<address>,
    checkpoint: Checkpoint,
    // Nonnegative collateral-token IFixed, strictly below 10^12 raw units (one USDC atom).
    unrecoverable_collateral_raw: u256,
}

/// Completed native share burn and fee-free local collateral payout.
public struct ShutdownRedeemed<phantom Product> has copy, drop {
    vault_id: ID,
    shares: u64,
    cash_paid: u64,
    cash_remaining: u64,
    eligible_remaining: u64,
}

/// Completed native share burn and exact collateral payout after attributable unwind.
public struct Redeemed<phantom Product> has copy, drop {
    vault_id: ID,
    shares: u64,
    net: u64,
    fee: u64,
    admin_fee: u64,
    reserve_fee: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
}

/// Completed maintenance with actual equity/exposure effects and unchanged allocations.
public struct Rebalanced<phantom Product> has copy, drop {
    vault_id: ID,
    equity_before: u64,
    equity_after: u64,
    base_before: u64,
    base_after: u64,
    increase: bool,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
}

/// Completed active mint, including its actual contribution and both fee allocations.
public struct Minted<phantom Product> has copy, drop {
    vault_id: ID,
    deposit: u64,
    shares: u64,
    contribution: u64,
    fee: u64,
    admin_fee: u64,
    reserve_fee: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
}

// Custody creation, upgrade authorization, receipt commit, policy restriction,
// immutability, and generation advance are emitted by `blast_admin` for every
// consumer package. No copy belongs in this registry.

/// Emitted after one adapter Vault and its leverage currency are issued.
public struct VaultIssued<phantom Product> has copy, drop {
    vault_id: ID,
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    risk_module_witness: TypeName,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
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
    seed_funder: address,
    position_base: u64,
    position_collateral: u64,
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
    restored_to_holders: u64,
    reserve_after: u64,
    previous_checkpoint: Checkpoint,
    checkpoint: Checkpoint,
}

/// Diagnostic novelty or reconciliation; ordinary health never changes lifecycle.
public struct HealthSynchronized<phantom Product> has copy, drop {
    vault_id: ID,
    reason: u8,
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

/// Emitted after shutdown-role authorization permanently stops ordinary operations.
public struct ShutdownBegun<phantom Product> has copy, drop {
    vault_id: ID,
    reason: blast_boosts_core::lifecycle::ShutdownReason,
}

/// Completed live-setting update; immutable caps and existing balances do not change.
public struct FeesUpdated<phantom Product> has copy, drop {
    vault_id: ID,
    previous_mint_bps: u64,
    previous_redeem_bps: u64,
    previous_admin_bps: u64,
    mint_bps: u64,
    redeem_bps: u64,
    admin_share_bps: u64,
}

/// Completed NAV cap update; existing NAV and balances do not change.
public struct NavCapUpdated<phantom Product> has copy, drop {
    vault_id: ID,
    previous_nav_cap: u64,
    nav_cap: u64,
}

/// Completed withdrawal from native admin cash; no holder or buffer claim is created.
public struct AdminFeesWithdrawn<phantom Product> has copy, drop {
    vault_id: ID,
    amount: u64,
    remaining: u64,
}

/// Completed venue cash deposit allocated entirely to the funding buffer.
public struct Donated<phantom Product> has copy, drop {
    vault_id: ID,
    amount: u64,
    reserve_after: u64,
    checkpoint: Checkpoint,
}

// === Package Functions ===

/// The signed equity delta is the actual net execution effect at the fixed oracle pair.
public(package) fun rebalanced<Product>(
    vault_id: ID, equity_before: u64, equity_after: u64, base_before: u64, base_after: u64,
    increase: bool, reserve_after: u64, admin_cash_after: u64, supply_after: u64, checkpoint: Checkpoint,
) {
    blast_boosts_aftermath::blast_events::emit_event(Rebalanced<Product> {
        vault_id, equity_before, equity_after, base_before, base_after, increase,
        reserve_after, admin_cash_after, supply_after, checkpoint,
    });
}

public(package) fun redeemed<Product>(
    vault_id: ID, shares: u64, net: u64, fee: u64, admin_fee: u64, reserve_fee: u64,
    fee_bps: u64, admin_share_bps: u64, reserve_after: u64, admin_cash_after: u64,
    supply_after: u64, checkpoint: Checkpoint,
) {
    blast_boosts_aftermath::blast_events::emit_event(Redeemed<Product> {
        vault_id, shares, net, fee, admin_fee, reserve_fee, fee_bps, admin_share_bps,
        reserve_after, admin_cash_after, supply_after, checkpoint,
    });
}

public(package) fun minted<Product>(
    vault_id: ID, deposit: u64, shares: u64, contribution: u64, fee: u64, admin_fee: u64,
    reserve_fee: u64, fee_bps: u64, admin_share_bps: u64, reserve_after: u64, admin_cash_after: u64,
    supply_after: u64, checkpoint: Checkpoint,
) {
    blast_boosts_aftermath::blast_events::emit_event(Minted<Product> {
        vault_id, deposit, shares, contribution, fee, admin_fee, reserve_fee, fee_bps, admin_share_bps,
        reserve_after, admin_cash_after, supply_after, checkpoint,
    });
}

public(package) fun donated<Product>(vault_id: ID, amount: u64, reserve_after: u64, checkpoint: Checkpoint) {
    blast_boosts_aftermath::blast_events::emit_event(Donated<Product> {
        vault_id, amount, reserve_after, checkpoint,
    });
}

public(package) fun admin_fees_withdrawn<Product>(vault_id: ID, amount: u64, remaining: u64) {
    blast_boosts_aftermath::blast_events::emit_event(AdminFeesWithdrawn<Product> {
        vault_id, amount, remaining,
    });
}

public(package) fun fees_updated<Product>(
    vault_id: ID,
    previous_mint_bps: u64,
    previous_redeem_bps: u64,
    previous_admin_bps: u64,
    mint_bps: u64,
    redeem_bps: u64,
    admin_share_bps: u64,
) {
    blast_boosts_aftermath::blast_events::emit_event(FeesUpdated<Product> {
        vault_id, previous_mint_bps, previous_redeem_bps, previous_admin_bps,
        mint_bps, redeem_bps, admin_share_bps,
    });
}

public(package) fun nav_cap_updated<Product>(vault_id: ID, previous_nav_cap: u64, nav_cap: u64) {
    blast_boosts_aftermath::blast_events::emit_event(NavCapUpdated<Product> {
        vault_id, previous_nav_cap, nav_cap,
    });
}

public(package) fun vault_issued<Product>(
    vault_id: ID,
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    risk_module_witness: TypeName,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
    maintenance_reserve: u64,
) {
    blast_boosts_aftermath::blast_events::emit_event(VaultIssued<Product> {
        vault_id,
        treasury_cap_id,
        metadata_cap_id,
        risk_module_witness,
        vault_policy,
        max_order_notional,
        nav_cap,
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
    seed_funder: address,
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
    checkpoint: Checkpoint,
) {
    blast_boosts_aftermath::blast_events::emit_event(
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
            seed_funder,
            position_base,
            position_collateral,
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
    restored_to_holders: u64,
    reserve_after: u64,
    previous_checkpoint: Checkpoint,
    checkpoint: Checkpoint,
) {
    blast_boosts_aftermath::blast_events::emit_event(
        FundingSettled<Product> {
            vault_id,
            is_cost,
            raw_amount,
            amount,
            absorbed_by_reserve,
            uncovered_cost,
            restored_to_holders,
            reserve_after,
            previous_checkpoint,
            checkpoint,
        },
    );
}

public(package) fun health_synchronized<Product>(
    vault_id: ID,
    reason: u8,
    checkpoint: Checkpoint,
) {
    blast_boosts_aftermath::blast_events::emit_event(
        HealthSynchronized<Product> {
            vault_id,
            reason,
            checkpoint,
        },
    );
}

public(package) fun diagnostic_raised_reason(): u8 { HEALTH_DIAGNOSTIC_RAISED }

public(package) fun diagnostic_cleared_reason(): u8 { HEALTH_DIAGNOSTIC_CLEARED }

public(package) fun risk_module_witness_rotated<Product>(
    vault_id: ID,
    previous_witness: TypeName,
    new_witness: TypeName,
) {
    blast_boosts_aftermath::blast_events::emit_event(
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
    blast_boosts_aftermath::blast_events::emit_event(
        MaxOrderNotionalUpdated<Product> {
            vault_id,
            previous_current,
            new_current,
        },
    );
}

public(package) fun shutdown_finalized<Product>(
    vault_id: ID, recovered_cash: u64, eligible_supply: u64, seed_funder_payment: Option<address>,
    checkpoint: Checkpoint, unrecoverable_collateral_raw: u256,
) {
    blast_boosts_aftermath::blast_events::emit_event(ShutdownFinalized<Product> {
        vault_id, recovered_cash, eligible_supply, seed_funder_payment, checkpoint, unrecoverable_collateral_raw,
    });
}

public(package) fun unwind_progress<Product>(
    vault_id: ID, before: Checkpoint, after_funding: Option<Checkpoint>, after: Checkpoint,
    market_orders: u64, filled_quote: Option<u256>,
) {
    blast_boosts_aftermath::blast_events::emit_event(UnwindProgress<Product> {
        vault_id, before, after_funding, after, market_orders, filled_quote,
    });
}

public(package) fun shutdown_redeemed<Product>(
    vault_id: ID, shares: u64, cash_paid: u64, cash_remaining: u64, eligible_remaining: u64,
) {
    blast_boosts_aftermath::blast_events::emit_event(ShutdownRedeemed<Product> {
        vault_id, shares, cash_paid, cash_remaining, eligible_remaining,
    });
}

public(package) fun shutdown_begun<Product>(vault_id: ID, reason: blast_boosts_core::lifecycle::ShutdownReason) {
    blast_boosts_aftermath::blast_events::emit_event(
        ShutdownBegun<Product> { vault_id, reason },
    );
}

// === Test-Only Functions ===

#[test_only]
public fun unwind_progress_fields<Product>(
    self: &UnwindProgress<Product>,
): (ID, Checkpoint, Option<Checkpoint>, Checkpoint, u64, Option<u256>) {
    (self.vault_id, self.before, self.after_funding, self.after, self.market_orders, self.filled_quote)
}

#[test_only]
public fun shutdown_finalized_fields<Product>(
    self: &ShutdownFinalized<Product>,
): (ID, u64, u64, Option<address>, Checkpoint, u256) {
    (
        self.vault_id, self.recovered_cash, self.eligible_supply, self.seed_funder_payment,
        self.checkpoint, self.unrecoverable_collateral_raw,
    )
}

#[test_only]
public fun shutdown_redeemed_fields<Product>(self: &ShutdownRedeemed<Product>): (ID, u64, u64, u64, u64) {
    (self.vault_id, self.shares, self.cash_paid, self.cash_remaining, self.eligible_remaining)
}

#[test_only]
public fun minted_checkpoint_fields<Product>(self: &Minted<Product>): (ID, Checkpoint) {
    (self.vault_id, self.checkpoint)
}

#[test_only]
public fun redeemed_checkpoint_fields<Product>(self: &Redeemed<Product>): (ID, Checkpoint) {
    (self.vault_id, self.checkpoint)
}

#[test_only]
public fun rebalanced_checkpoint_fields<Product>(self: &Rebalanced<Product>): (ID, u64, u64, u64, Checkpoint) {
    (self.vault_id, self.reserve_after, self.admin_cash_after, self.supply_after, self.checkpoint)
}

#[test_only]
public fun redeemed_amounts<Product>(self: &Redeemed<Product>): vector<u64> {
    vector[self.shares, self.net, self.fee, self.admin_fee, self.reserve_fee,
        self.fee_bps, self.admin_share_bps, self.reserve_after, self.admin_cash_after, self.supply_after]
}

#[test_only]
public fun vault_initialized_seed_funder<Product>(self: &VaultInitialized<Product>): address {
    self.seed_funder
}

#[test_only]
public fun minted_amounts<Product>(self: &Minted<Product>): (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    (self.deposit, self.shares, self.contribution, self.fee, self.admin_fee, self.reserve_fee,
        self.fee_bps, self.admin_share_bps, self.reserve_after, self.admin_cash_after, self.supply_after)
}

#[test_only]
public fun rebalanced_amounts<Product>(self: &Rebalanced<Product>): (u64, u64, u64, u64, bool) {
    (self.equity_before, self.equity_after, self.base_before, self.base_after, self.increase)
}

#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_boosts_aftermath::blast_events::Event<T>>().do!(
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
): (ID, ID, ID, TypeName, VaultPolicy, u64, u64, u64) {
    (
        self.vault_id,
        self.treasury_cap_id,
        self.metadata_cap_id,
        self.risk_module_witness,
        self.vault_policy,
        self.max_order_notional,
        self.nav_cap,
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
        self.position_base,
        self.position_collateral,
        self.lot_size,
        self.position_side,
        self.position_imr,
        self.checkpoint,
    )
}

#[test_only]
public fun funding_settled_fields<Product>(
    self: &FundingSettled<Product>,
): (ID, bool, u256, u64, u64, u64, u64, u64, Checkpoint, Checkpoint) {
    (
        self.vault_id,
        self.is_cost,
        self.raw_amount,
        self.amount,
        self.absorbed_by_reserve,
        self.uncovered_cost,
        self.restored_to_holders,
        self.reserve_after,
        self.previous_checkpoint,
        self.checkpoint,
    )
}

#[test_only]
public fun health_synchronized_fields<Product>(
    self: &HealthSynchronized<Product>,
): (ID, u8, Checkpoint) {
    (
        self.vault_id,
        self.reason,
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
public fun nav_cap_updated_fields<Product>(self: &NavCapUpdated<Product>): (ID, u64, u64) {
    (self.vault_id, self.previous_nav_cap, self.nav_cap)
}

#[test_only]
public fun shutdown_reason<Product>(self: &ShutdownBegun<Product>): blast_boosts_core::lifecycle::ShutdownReason {
    self.reason
}

#[test_only]
public fun shutdown_begun_vault_id<Product>(
    self: &ShutdownBegun<Product>,
): ID {
    self.vault_id
}

#[test_only]
public fun fees_updated_fields<Product>(self: &FeesUpdated<Product>): (ID, u64, u64, u64, u64, u64, u64) {
    (self.vault_id, self.previous_mint_bps, self.previous_redeem_bps, self.previous_admin_bps,
        self.mint_bps, self.redeem_bps, self.admin_share_bps)
}

#[test_only]
public fun admin_fees_withdrawn_fields<Product>(self: &AdminFeesWithdrawn<Product>): (ID, u64, u64) {
    (self.vault_id, self.amount, self.remaining)
}

#[test_only]
public fun donated_fields<Product>(self: &Donated<Product>): (ID, u64, u64, Checkpoint) {
    (self.vault_id, self.amount, self.reserve_after, self.checkpoint)
}

// === Imports ===

use blast_boosts_aftermath::venue_account::Checkpoint;

use blast_boosts_core::policy::{PositionSide, VaultPolicy};

use std::type_name::TypeName;
