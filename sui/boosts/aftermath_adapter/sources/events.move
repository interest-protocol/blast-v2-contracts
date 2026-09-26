// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Replay-complete Aftermath adapter events.
module blast_boosts_aftermath::events;

// === Public Types ===

// --- Issuance ---

// Custody creation, upgrade authorization, receipt commit, policy restriction,
// immutability, and generation advance are emitted by `blast_admin` for every
// consumer package. No copy belongs in this registry.

/// Emitted when one leverage currency is issued, before its Vault exists; the
/// `Product` type names the currency for good and `VaultInitialized` follows in
/// the same transaction with the Vault id.
public struct VaultIssued<phantom Product> has copy, drop {
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
}

/// Emitted after one atomic seed activates a bound Aftermath Vault.
public struct VaultInitialized<phantom Product> has copy, drop {
    vault_id: ID,
    binding: Binding,
    seed_amount: u64,
    seed_venue_equity: u64,
    seed_reserve: u64,
    seed_shareholder_nav: u64,
    locked_shares: u64,
    position_base: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
    checkpoint: Checkpoint,
}

// --- Orders ---

/// Emitted once per venue market order the adapter places, seed orders
/// included, after the fill passed the cap and slippage checks. The account is
/// the bound venue account (`VaultInitialized.binding` maps it to the Vault);
/// seed orders run before the Vault id exists. Prices are 9-decimal; the quote
/// is the raw IFixed amount the session moved.
public struct OrderFilled<phantom Product> has copy, drop {
    account_object_id: ID,
    is_ask: bool,
    reduce_only: bool,
    emergency: bool,
    requested_base: u64,
    filled_base: u64,
    filled_quote: u256,
    reference_price: u64,
    executed_price: u64,
}

// --- Mint ---

/// Emitted after an active mint, including its actual contribution and both fee allocations.
public struct Minted<phantom Product> has copy, drop {
    vault_id: ID,
    deposit: u64,
    shares: u64,
    contribution: u64,
    fee: u64,
    admin_fee: u64,
    reserve_fee: u64,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
}

// --- Redemption ---

/// Completed native share burn and exact collateral payout after attributable unwind.
public struct Redeemed<phantom Product> has copy, drop {
    vault_id: ID,
    shares: u64,
    net: u64,
    fee: u64,
    admin_fee: u64,
    reserve_fee: u64,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
}

// --- Partners ---

/// Emitted after a mint or redeem that named a partner, including a partner
/// paid nothing because its share is zero or not yet in force. `partner_fee`
/// left `admin_fee`, the admin fee the operation retained; `admin_cash_after`
/// holds what Blast kept.
public struct PartnerFeePaid<phantom Product> has copy, drop {
    vault_id: ID,
    partner_id: ID,
    admin_fee: u64,
    partner_fee: u64,
    admin_cash_after: u64,
}

// --- Rebalance ---

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

// --- Funding And Donation ---

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

/// A sync found the venue in a state no vault operation explains. The accepted
/// checkpoint stands and priced operations are refused until a later sync
/// finds the venue explainable again; every such sync emits this event. An
/// unwind step that finds such a venue emits it too, then adopts the live
/// state and closes what the venue holds.
public struct CheckpointDrifted<phantom Product> has copy, drop {
    vault_id: ID,
    checkpoint: Checkpoint,
}

/// Completed venue cash deposit allocated entirely to the funding buffer.
public struct Donated<phantom Product> has copy, drop {
    vault_id: ID,
    amount: u64,
    reserve_after: u64,
    checkpoint: Checkpoint,
}

// --- Shutdown ---

/// Emitted after shutdown-role authorization permanently stops ordinary operations.
public struct ShutdownBegun<phantom Product> has copy, drop {
    vault_id: ID,
    reason: ShutdownReason,
}

/// Completed close-only progress with exact raw venue effects: the checkpoint
/// the step adopted after reconciling the stored one, the checkpoint the close
/// left, the market orders placed and the quote they filled. The venue's
/// settlement of a closed market places no order and fills no quote.
public struct UnwindProgress<phantom Product> has copy, drop {
    vault_id: ID,
    before: Checkpoint,
    after: Checkpoint,
    market_orders: u64,
    filled_quote: Option<u256>,
}

/// Actual recovered holder cash and fixed eligible supply after venue finality.
public struct ShutdownFinalized<phantom Product> has copy, drop {
    vault_id: ID,
    recovered_cash: u64,
    eligible_supply: u64,
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

// --- Administration ---

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

/// Emitted after the active risk module changes the live maximum order notional.
public struct MaxOrderNotionalUpdated<phantom Product> has copy, drop {
    vault_id: ID,
    previous: u64,
    max_order_notional: u64,
}

/// Completed Coin Registry metadata update; the symbol and supply are untouched.
public struct MetadataUpdated<phantom Product> has copy, drop {
    vault_id: ID,
    name: String,
    description: String,
    icon_url: String,
}

/// Completed withdrawal from native admin cash; no holder or buffer claim is created.
public struct AdminFeesWithdrawn<phantom Product> has copy, drop {
    vault_id: ID,
    amount: u64,
    remaining: u64,
}

// === Package Functions ===

// --- Issuance ---

public(package) fun vault_issued<Product>(
    treasury_cap_id: ID,
    metadata_cap_id: ID,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
) {
    emit_event(VaultIssued<Product> {
        treasury_cap_id,
        metadata_cap_id,
        vault_policy,
        max_order_notional,
        nav_cap,
    });
}

public(package) fun vault_initialized<Product>(
    vault_id: ID,
    binding: Binding,
    seed_amount: u64,
    seed_venue_equity: u64,
    seed_reserve: u64,
    seed_shareholder_nav: u64,
    locked_shares: u64,
    position_base: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
    checkpoint: Checkpoint,
) {
    emit_event(
        VaultInitialized<Product> {
            vault_id,
            binding,
            seed_amount,
            seed_venue_equity,
            seed_reserve,
            seed_shareholder_nav,
            locked_shares,
            position_base,
            lot_size,
            position_side,
            position_imr,
            checkpoint,
        },
    );
}

// --- Orders ---

public(package) fun order_filled<Product>(
    account_object_id: ID,
    is_ask: bool,
    reduce_only: bool,
    emergency: bool,
    requested_base: u64,
    filled_base: u64,
    filled_quote: u256,
    reference_price: u64,
    executed_price: u64,
) {
    emit_event(OrderFilled<Product> {
        account_object_id,
        is_ask,
        reduce_only,
        emergency,
        requested_base,
        filled_base,
        filled_quote,
        reference_price,
        executed_price,
    });
}

// --- Mint ---

public(package) fun minted<Product>(
    vault_id: ID,
    deposit: u64,
    shares: u64,
    contribution: u64,
    fee: u64,
    admin_fee: u64,
    reserve_fee: u64,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
) {
    emit_event(Minted<Product> {
        vault_id, deposit, shares, contribution, fee, admin_fee, reserve_fee,
        reserve_after, admin_cash_after, supply_after, checkpoint,
    });
}

// --- Redemption ---

public(package) fun redeemed<Product>(
    vault_id: ID,
    shares: u64,
    net: u64,
    fee: u64,
    admin_fee: u64,
    reserve_fee: u64,
    reserve_after: u64,
    admin_cash_after: u64,
    supply_after: u64,
    checkpoint: Checkpoint,
) {
    emit_event(Redeemed<Product> {
        vault_id, shares, net, fee, admin_fee, reserve_fee, reserve_after, admin_cash_after, supply_after, checkpoint,
    });
}

// --- Partners ---

public(package) fun partner_fee_paid<Product>(
    vault_id: ID,
    partner_id: ID,
    admin_fee: u64,
    partner_fee: u64,
    admin_cash_after: u64,
) {
    emit_event(PartnerFeePaid<Product> { vault_id, partner_id, admin_fee, partner_fee, admin_cash_after });
}

// --- Rebalance ---

/// The signed equity delta is the actual net execution effect at the fixed oracle pair.
public(package) fun rebalanced<Product>(
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
) {
    emit_event(Rebalanced<Product> {
        vault_id, equity_before, equity_after, base_before, base_after, increase,
        reserve_after, admin_cash_after, supply_after, checkpoint,
    });
}

// --- Funding And Donation ---

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
    emit_event(
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

public(package) fun checkpoint_drifted<Product>(vault_id: ID, checkpoint: Checkpoint) {
    emit_event(CheckpointDrifted<Product> { vault_id, checkpoint });
}

public(package) fun donated<Product>(vault_id: ID, amount: u64, reserve_after: u64, checkpoint: Checkpoint) {
    emit_event(Donated<Product> {
        vault_id, amount, reserve_after, checkpoint,
    });
}

// --- Shutdown ---

public(package) fun shutdown_begun<Product>(vault_id: ID, reason: ShutdownReason) {
    emit_event(
        ShutdownBegun<Product> { vault_id, reason },
    );
}

public(package) fun unwind_progress<Product>(
    vault_id: ID,
    before: Checkpoint,
    after: Checkpoint,
    market_orders: u64,
    filled_quote: Option<u256>,
) {
    emit_event(UnwindProgress<Product> {
        vault_id, before, after, market_orders, filled_quote,
    });
}

public(package) fun shutdown_finalized<Product>(
    vault_id: ID,
    recovered_cash: u64,
    eligible_supply: u64,
    checkpoint: Checkpoint,
    unrecoverable_collateral_raw: u256,
) {
    emit_event(ShutdownFinalized<Product> {
        vault_id, recovered_cash, eligible_supply, checkpoint, unrecoverable_collateral_raw,
    });
}

public(package) fun shutdown_redeemed<Product>(
    vault_id: ID,
    shares: u64,
    cash_paid: u64,
    cash_remaining: u64,
    eligible_remaining: u64,
) {
    emit_event(ShutdownRedeemed<Product> {
        vault_id, shares, cash_paid, cash_remaining, eligible_remaining,
    });
}

// --- Administration ---

public(package) fun fees_updated<Product>(
    vault_id: ID,
    previous_mint_bps: u64,
    previous_redeem_bps: u64,
    previous_admin_bps: u64,
    mint_bps: u64,
    redeem_bps: u64,
    admin_share_bps: u64,
) {
    emit_event(FeesUpdated<Product> {
        vault_id, previous_mint_bps, previous_redeem_bps, previous_admin_bps,
        mint_bps, redeem_bps, admin_share_bps,
    });
}

public(package) fun nav_cap_updated<Product>(vault_id: ID, previous_nav_cap: u64, nav_cap: u64) {
    emit_event(NavCapUpdated<Product> {
        vault_id, previous_nav_cap, nav_cap,
    });
}

public(package) fun max_order_notional_updated<Product>(vault_id: ID, previous: u64, max_order_notional: u64) {
    emit_event(
        MaxOrderNotionalUpdated<Product> { vault_id, previous, max_order_notional },
    );
}

public(package) fun metadata_updated<Product>(vault_id: ID, name: String, description: String, icon_url: String) {
    emit_event(MetadataUpdated<Product> { vault_id, name, description, icon_url });
}

public(package) fun admin_fees_withdrawn<Product>(vault_id: ID, amount: u64, remaining: u64) {
    emit_event(AdminFeesWithdrawn<Product> {
        vault_id, amount, remaining,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    events_by_type<Event<T>>().do!(
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

// --- Issuance ---

#[test_only]
public fun vault_issued_fields<Product>(
    self: &VaultIssued<Product>,
): (ID, ID, VaultPolicy, u64, u64) {
    (
        self.treasury_cap_id,
        self.metadata_cap_id,
        self.vault_policy,
        self.max_order_notional,
        self.nav_cap,
    )
}

#[test_only]
public fun vault_initialized_fields<Product>(
    self: &VaultInitialized<Product>,
): (
    ID,
    Binding,
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
        self.binding,
        self.seed_amount,
        self.seed_venue_equity,
        self.seed_reserve,
        self.seed_shareholder_nav,
        self.locked_shares,
        self.position_base,
        self.lot_size,
        self.position_side,
        self.position_imr,
        self.checkpoint,
    )
}

// --- Mint ---

#[test_only]
public fun minted_checkpoint_fields<Product>(self: &Minted<Product>): (ID, Checkpoint) {
    (self.vault_id, self.checkpoint)
}

#[test_only]
public fun minted_amounts<Product>(self: &Minted<Product>): (u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    (self.deposit, self.shares, self.contribution, self.fee, self.admin_fee, self.reserve_fee,
        self.reserve_after, self.admin_cash_after, self.supply_after)
}

// --- Redemption ---

#[test_only]
public fun redeemed_checkpoint_fields<Product>(self: &Redeemed<Product>): (ID, Checkpoint) {
    (self.vault_id, self.checkpoint)
}

#[test_only]
public fun partner_fee_paid_fields<Product>(self: &PartnerFeePaid<Product>): (ID, ID, u64, u64, u64) {
    (self.vault_id, self.partner_id, self.admin_fee, self.partner_fee, self.admin_cash_after)
}

#[test_only]
public fun redeemed_amounts<Product>(self: &Redeemed<Product>): vector<u64> {
    vector[self.shares, self.net, self.fee, self.admin_fee, self.reserve_fee,
        self.reserve_after, self.admin_cash_after, self.supply_after]
}

// --- Rebalance ---

#[test_only]
public fun rebalanced_checkpoint_fields<Product>(self: &Rebalanced<Product>): (ID, u64, u64, u64, Checkpoint) {
    (self.vault_id, self.reserve_after, self.admin_cash_after, self.supply_after, self.checkpoint)
}

#[test_only]
public fun rebalanced_amounts<Product>(self: &Rebalanced<Product>): (u64, u64, u64, u64, bool) {
    (self.equity_before, self.equity_after, self.base_before, self.base_after, self.increase)
}

// --- Funding And Donation ---

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
public fun checkpoint_drifted_fields<Product>(self: &CheckpointDrifted<Product>): (ID, Checkpoint) {
    (self.vault_id, self.checkpoint)
}

#[test_only]
public fun donated_fields<Product>(self: &Donated<Product>): (ID, u64, u64, Checkpoint) {
    (self.vault_id, self.amount, self.reserve_after, self.checkpoint)
}

// --- Shutdown ---

#[test_only]
public fun shutdown_reason<Product>(self: &ShutdownBegun<Product>): ShutdownReason {
    self.reason
}

#[test_only]
public fun shutdown_begun_vault_id<Product>(
    self: &ShutdownBegun<Product>,
): ID {
    self.vault_id
}

#[test_only]
public fun unwind_progress_fields<Product>(
    self: &UnwindProgress<Product>,
): (ID, Checkpoint, Checkpoint, u64, Option<u256>) {
    (self.vault_id, self.before, self.after, self.market_orders, self.filled_quote)
}

#[test_only]
public fun shutdown_finalized_fields<Product>(
    self: &ShutdownFinalized<Product>,
): (ID, u64, u64, Checkpoint, u256) {
    (
        self.vault_id, self.recovered_cash, self.eligible_supply,
        self.checkpoint, self.unrecoverable_collateral_raw,
    )
}

#[test_only]
public fun shutdown_redeemed_fields<Product>(self: &ShutdownRedeemed<Product>): (ID, u64, u64, u64, u64) {
    (self.vault_id, self.shares, self.cash_paid, self.cash_remaining, self.eligible_remaining)
}

// --- Administration ---

#[test_only]
public fun fees_updated_fields<Product>(self: &FeesUpdated<Product>): (ID, u64, u64, u64, u64, u64, u64) {
    (self.vault_id, self.previous_mint_bps, self.previous_redeem_bps, self.previous_admin_bps,
        self.mint_bps, self.redeem_bps, self.admin_share_bps)
}

#[test_only]
public fun nav_cap_updated_fields<Product>(self: &NavCapUpdated<Product>): (ID, u64, u64) {
    (self.vault_id, self.previous_nav_cap, self.nav_cap)
}

#[test_only]
public fun max_order_notional_updated_fields<Product>(
    self: &MaxOrderNotionalUpdated<Product>,
): (ID, u64, u64) {
    (self.vault_id, self.previous, self.max_order_notional)
}

#[test_only]
public fun metadata_updated_fields<Product>(self: &MetadataUpdated<Product>): (ID, String, String, String) {
    (self.vault_id, self.name, self.description, self.icon_url)
}

#[test_only]
public fun admin_fees_withdrawn_fields<Product>(self: &AdminFeesWithdrawn<Product>): (ID, u64, u64) {
    (self.vault_id, self.amount, self.remaining)
}

#[test_only]
public fun order_filled_fields<Product>(
    self: &OrderFilled<Product>,
): (ID, bool, bool, bool, u64, u64, u256, u64, u64) {
    (
        self.account_object_id, self.is_ask, self.reduce_only, self.emergency, self.requested_base,
        self.filled_base, self.filled_quote, self.reference_price, self.executed_price,
    )
}

// === Imports ===

use blast_boosts_aftermath::{blast_events::{Event, emit_event}, checkpoint::Checkpoint, venue_account::Binding};

use blast_boosts_core::{lifecycle::ShutdownReason, policy::{PositionSide, VaultPolicy}};

use std::string::String;

#[test_only]
use sui::event::events_by_type;
