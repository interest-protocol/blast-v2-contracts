// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Adapter-owned Vault: custody of the core state, the venue account, the
/// share currency and the retained cash, plus the public surface that needs
/// no venue object (issuance, shutdown begin and claim, administration).
/// Every venue-touching operation is driven by `operations`; this module
/// never reads the venue, advances a checkpoint or completes a core plan.
module blast_boosts_aftermath::vault;

// === Constants ===

/// Minimum notice for a change to an issued vault’s economic terms.
const POLICY_NOTICE_MS: u64 = 48 * 60 * 60 * 1_000;

/// `10^(share_decimals - collateral_decimals)` for the two precisions this adapter fixes.
const SEED_SHARE_SCALE: u64 = 1_000;

// === Public Types ===

/// Independent notices for the three mutable vault policies.
public struct FeesKey() has copy, drop, store;
public struct NavCapKey() has copy, drop, store;
public struct OrderCapKey() has copy, drop, store;

public struct Fees has copy, drop, store {
    mint_bps: u64,
    redeem_bps: u64,
    admin_share_bps: u64,
}

/// One issued Boost currency before its venue account exists.
///
/// `issue` creates it and `operations::initialize` must consume it in the same
/// transaction: it has no abilities, so an issuance that is not activated cannot
/// be stored or shared, and a failed activation rolls the currency back too.
public struct VaultIssuance<phantom Product, phantom Collateral> {
    issuance: Issuance<Product>,
    treasury_cap: TreasuryCap<BlastBoost<Product>>,
    metadata_cap: MetadataCap<BlastBoost<Product>>,
}

/// Shared adapter custody for one Boost currency, its core state and its venue account.
///
/// This adapter defines `Vault<Product, Collateral>`, so it can issue the corresponding
/// non-OTW currency through Coin Registry. The nested core state has private
/// fields and can change only through core mutation functions. A Vault exists
/// only from activation on, so every field below is always present; the share
/// caps hang off `id` as dynamic object fields.
public struct Vault<phantom Product, phantom Collateral> has key {
    id: UID,
    state: State<Product>,
    fees: DelayedAction<FeesKey, Fees>,
    nav_cap: DelayedAction<NavCapKey, u64>,
    order_cap: DelayedAction<OrderCapKey, u64>,
    /// The bound account's identity, last accepted checkpoint and admin authority.
    venue_account: VenueAccount,
    /// The seed shares minted to the burn address at activation; never redeemable.
    locked_shares: u64,
    /// Earned admin fee collateral, held natively and never sent to the venue.
    admin_cash: Balance<Collateral>,
    /// Recovered holder collateral after finalization, never mixed with admin cash.
    terminal_cash: Balance<Collateral>,
    /// Seed-backed cash and reserve retained by protected size-locked closure.
    /// No holder or admin withdrawal path; adapter upgrade governance remains trusted.
    protected_cash: Balance<Collateral>,
}

/// Dynamic-object-field key for one Vault's share mint authority.
public struct TreasuryKey<phantom Product>() has copy, drop, store;

/// Dynamic-object-field key for one Vault's metadata authority.
public struct MetadataKey<phantom Product>() has copy, drop, store;

// === Public Functions ===

/// Issues one leverage currency and the issuance that `operations::initialize`
/// turns into its Vault in the same transaction.
///
/// `Product` is the currency's identity: `Vault<Product, Collateral>` names the coin and
/// Coin Registry admits each type once. Any non-primitive type may serve; the
/// Vault issuer role is the only authority. The adapter generation is checked
/// before Coin Registry mutation. Package custody is not an input:
/// `package_admin` seals a validated Publisher and UpgradeCap that no other
/// object can hold, so re-reading those fields here would prove nothing this
/// package does not already own.
public fun issue<Product, Collateral>(
    protocol: &Protocol,
    version: &PackageVersion<BLAST_BOOSTS_AFTERMATH>,
    admin_witness: &AdminWitness<VaultIssuer>,
    registry: &mut CoinRegistry,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): VaultIssuance<Product, Collateral> {
    protocol.assert_current();
    version.assert_not_paused(marker::deposits!());

    assert!(
        !type_name::with_original_ids<Product>().is_primitive(),
        blast_boosts_aftermath::errors::invalid_product_witness_type!(),
    );

    let issuance = state::issue<Product>(
        admin_witness,
        vault_policy,
        max_order_notional,
        nav_cap,
        constants::base_decimals!(),
        constants::collateral_decimals!(),
    );
    let (treasury_cap, metadata_cap) =
        blast_boost::new_currency<Product>(
        registry,
        symbol,
        name,
        description,
        icon_url,
        ctx
    );

    events::vault_issued<Product>(
        object::id(&treasury_cap),
        object::id(&metadata_cap),
        vault_policy,
        max_order_notional,
        nav_cap,
    );

    VaultIssuance { issuance, treasury_cap, metadata_cap }
}

/// Shares one activated adapter Vault.
public fun share<Product, Collateral>(self: Vault<Product, Collateral>) {
    transfer::share_object(self);
}

/// Irreversibly stops ordinary operations without requiring venue or oracle
/// availability. The clock fixes when shutdown began; the close-only execution
/// bound `operations::unwind` prices under widens from that instant.
public fun begin_shutdown<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<ShutdownAdmin>,
    reason: ShutdownReason,
    clock: &Clock,
) {
    protocol.assert_current();

    self.state.begin_shutdown(clock.timestamp_ms());

    events::shutdown_begun<Product>(self.id.to_inner(), reason);
}

/// Burns native eligible shares for local terminal collateral; no venue or oracle access.
public fun redeem_shutdown<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    shares: Coin<BlastBoost<Product>>,
    minimum_collateral: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();

    self.state.assert_settled();
    assert!(
        clock.timestamp_ms() <= deadline_at_ms,
        blast_boosts_aftermath::errors::deadline_expired!()
    );

    let output = self
        .state
        .shutdown_claim_quote(
            self.terminal_cash.value(),
            self.total_share_supply(),
            self.locked_shares,
            shares.value(),
            minimum_collateral,
        );

    let burned = self.burn_redeemed_shares(shares);
    let output_coin = self.terminal_cash.split(output).into_coin(ctx);

    events::shutdown_redeemed<Product>(
        self.id.to_inner(),
        burned,
        output,
        self.terminal_cash.value(),
        self.total_share_supply() - self.locked_shares,
    );

    output_coin
}

// --- Administration ---

/// Updates only future fee collections under the immutable issuance caps.
/// This local administrative edge requires neither venue objects nor prices.
public fun schedule_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<FeeAdmin>,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    admin_share_bps: u64,
    clock: &Clock,
) {
    protocol.assert_current();
    self.state.assert_fee_update(mint_fee_bps, redeem_fee_bps, admin_share_bps);
    self.fees.schedule(Fees { mint_bps: mint_fee_bps, redeem_bps: redeem_fee_bps, admin_share_bps }, clock);
}

public fun cancel_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<CancelAdmin>,
) {
    protocol.assert_current();
    self.fees.cancel();
}

public fun apply_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    clock: &Clock,
) {
    protocol.assert_current();
    let Fees { mint_bps: mint_fee_bps, redeem_bps: redeem_fee_bps, admin_share_bps } = self.fees.take_action(clock);
    let (previous_mint, previous_redeem, previous_admin) =
        self
        .state
        .set_fees(mint_fee_bps, redeem_fee_bps, admin_share_bps);

    events::fees_updated<Product>(
        self.id.to_inner(),
        previous_mint,
        previous_redeem,
        previous_admin,
        mint_fee_bps,
        redeem_fee_bps,
        admin_share_bps,
    );
}

/// Replaces the NAV cap that bounds post-mint shareholder NAV.
/// This local administrative edge requires neither venue objects nor prices.
public fun schedule_nav_cap<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<RiskAdmin>,
    nav_cap: u64,
    clock: &Clock,
) {
    protocol.assert_current();
    self.state.assert_nav_cap_update(nav_cap);
    self.nav_cap.schedule(nav_cap, clock);
}

public fun cancel_nav_cap<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<CancelAdmin>,
) {
    protocol.assert_current();
    self.nav_cap.cancel();
}

public fun apply_nav_cap<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    clock: &Clock,
) {
    protocol.assert_current();
    let nav_cap = self.nav_cap.take_action(clock);
    let previous = self.state.set_nav_cap(nav_cap);

    events::nav_cap_updated<Product>(self.id.to_inner(), previous, nav_cap);
}

/// Replaces the Boost currency's display name, description and icon in Coin
/// Registry. The symbol is fixed at issuance; the registry has no setter for it.
/// At least one of the three must change, so every emitted update is a real one.
/// This local administrative edge requires neither venue objects nor prices.
public fun update_metadata<Product, Collateral>(
    self: &Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<VaultIssuer>,
    currency: &mut Currency<BlastBoost<Product>>,
    name: String,
    description: String,
    icon_url: String,
) {
    protocol.assert_current();

    assert!(
        currency.name() != name || currency.description() != description || currency.icon_url() != icon_url,
        blast_boosts_aftermath::errors::metadata_unchanged!(),
    );

    let metadata_cap = self.metadata_cap();
    currency.set_name(metadata_cap, name);
    currency.set_description(metadata_cap, description);
    currency.set_icon_url(metadata_cap, icon_url);

    events::metadata_updated<Product>(self.id.to_inner(), name, description, icon_url);
}

/// Pays earned collateral to the current shared Blast treasury destination.
public fun withdraw_admin_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    witness: &AdminWitness<TreasuryAdmin>,
    treasury: &Treasury,
    amount: u64,
    ctx: &mut TxContext,
) {
    let earnings = self.take_admin_fees(protocol, witness, amount, ctx);
    transfer::public_transfer(earnings, treasury.destination());
}

/// Schedules a new order cap. Execution checks current venue prices and lot size.
public fun schedule_max_order_notional<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<RiskAdmin>,
    value: u64,
    clock: &Clock,
) {
    protocol.assert_current();
    self.state.assert_max_order_notional_update(value);
    self.order_cap.schedule(value, clock);
}

public fun cancel_max_order_notional<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<CancelAdmin>,
) {
    protocol.assert_current();
    self.order_cap.cancel();
}

// === Package Functions ===

/// Changes the live per-order notional cap.
///
/// The cap uses collateral atoms and does not limit total open exposure.
/// An exact one-lot reduce-only fill may exceed it; price checks still apply.
/// Execution uses current venue capacity after the scheduled notice. It changes no exposure and therefore
/// remains available in every lifecycle state.
public(package) fun apply_order_cap<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    clock: &Clock,
    base_oracle: PriceObservation,
    collateral_oracle: PriceObservation,
    lot_size: u64,
) {
    protocol.assert_current();

    let max_order_notional = self.order_cap.take_action(clock);
    let previous = self
        .state
        .set_max_order_notional(
            max_order_notional,
            base_oracle,
            collateral_oracle,
            lot_size,
            clock.timestamp_ms(),
        );

    events::max_order_notional_updated<Product>(self.id.to_inner(), previous, max_order_notional);
}

// --- Core And Venue ---

/// The core accounting state; the adapter drives it directly and the Vault only stores it.
public(package) fun state<Product, Collateral>(self: &Vault<Product, Collateral>): &State<Product> {
    &self.state
}

public(package) fun state_mut<Product, Collateral>(
    self: &mut Vault<Product, Collateral>
): &mut State<Product> { &mut self.state }

/// The bound venue account: identity, last accepted checkpoint, and custody calls.
public(package) fun venue<Product, Collateral>(self: &Vault<Product, Collateral>): &VenueAccount {
    &self.venue_account
}

public(package) fun venue_mut<Product, Collateral>(
    self: &mut Vault<Product, Collateral>
): &mut VenueAccount { &mut self.venue_account }

/// The issuer's terms, which size and bound the seed position before the state exists.
public(package) fun issuance<Product, Collateral>(
    self: &VaultIssuance<Product, Collateral>
): &Issuance<Product> { &self.issuance }

// --- Initialization ---

/// Activates the core on the seeded observation, mints the locked seed shares
/// to the burn address, and builds the Vault around the venue account, with
/// the share caps hanging off the new id. Returns the Vault, the seed's
/// shareholder NAV, and the priced seed position. The seed is a permanent
/// gift to the product: its shares are never redeemable. Admin seed-only
/// shutdown routes recovery to admin cash; protected shutdown keeps its
/// allocated seed cash separate with no holder or admin withdrawal path.
public(package) fun activate<Product, Collateral>(
    self: VaultIssuance<Product, Collateral>,
    seeded: PositionObservation,
    seed_reserve: u64,
    venue_account: VenueAccount,
    now_at_ms: u64,
    ctx: &mut TxContext,
): (Vault<Product, Collateral>, u64, ActivePosition) {
    let VaultIssuance { issuance, mut treasury_cap, metadata_cap } = self;
    let (state, seed_nav, seeded) = issuance.activate(seeded, seed_reserve, now_at_ms);

    let locked_shares = seed_shares(seed_nav);
    transfer::public_transfer(treasury_cap.mint(locked_shares, ctx), @0x0);

    let id = object::new(ctx);
    let fees = delayed_action::new(FeesKey(), &id, POLICY_NOTICE_MS);
    let nav_cap = delayed_action::new(NavCapKey(), &id, POLICY_NOTICE_MS);
    let order_cap = delayed_action::new(OrderCapKey(), &id, POLICY_NOTICE_MS);
    let mut vault = Vault {
        id,
        fees,
        nav_cap,
        order_cap,
        state,
        venue_account,
        locked_shares,
        admin_cash: balance::zero(),
        terminal_cash: balance::zero(),
        protected_cash: balance::zero(),
    };
    vault.id.add_dynamic_object_field(TreasuryKey<Product>(), treasury_cap);
    vault.id.add_dynamic_object_field(MetadataKey<Product>(), metadata_cap);

    (vault, seed_nav, seeded)
}

// --- Mint ---

/// Mints only through this Vault's retained native TreasuryCap.
public(package) fun mint_shares<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    self.treasury_cap_mut().mint(amount, ctx)
}

// --- Redemption ---

/// Burns only through this Vault's retained native TreasuryCap.
public(package) fun burn_redeemed_shares<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    shares: Coin<BlastBoost<Product>>
): u64 {
    self.treasury_cap_mut().burn(shares)
}

// --- Shutdown ---

/// Segregates protected cash before sealing the holder claim pool.
/// Only an administrator-approved, seed-only shutdown sends recovery to admin cash.
public(package) fun seal_terminal_cash<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    recovered: Coin<Collateral>,
    eligible: u64,
    protected_reserve: u64,
    protected_seed: u64,
) {
    let mut recovered = recovered.into_balance();
    let protected_amount = protected_reserve + protected_seed;
    if (protected_amount > 0) {
        self.protected_cash.join(recovered.split(protected_amount));
    };

    if (eligible == 0) {
        self.retain_admin_cash(recovered);
    } else {
        self.terminal_cash.join(recovered);
    };
}

// --- Admin Cash ---

/// Adds collateral to Blast's admin cash without changing venue accounting.
public(package) fun retain_admin_cash<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    cash: Balance<Collateral>,
) {
    self.admin_cash.join(cash);
}

/// Takes `amount` back out of Blast's admin cash, to pay a partner its share of
/// the admin fee an operation just retained.
public(package) fun take_admin_cash<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    amount: u64,
): Balance<Collateral> {
    self.admin_cash.split(amount)
}

/// Native cash is authoritative; no mirrored numerical admin ledger is stored.
public(package) fun admin_cash_balance<Product, Collateral>(
    self: &Vault<Product, Collateral>
): u64 {
    self.admin_cash.value()
}

// --- Reads ---

/// Returns the stable Vault identity used by adapter events.
public(package) fun id<Product, Collateral>(self: &Vault<Product, Collateral>): ID {
    self.id.to_inner()
}

/// Returns the authoritative leverage-currency supply from the retained cap.
public(package) fun total_share_supply<Product, Collateral>(
    self: &Vault<Product, Collateral>
): u64 {
    self.treasury_cap().total_supply()
}

/// Returns the identity of the retained native share mint authority.
public(package) fun treasury_cap_id<Product, Collateral>(self: &Vault<Product, Collateral>): ID {
    object::id(self.treasury_cap())
}

/// The seed shares locked at activation, excluded from every terminal claim.
public(package) fun locked_shares<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.locked_shares
}

// === Private Functions ===

/// Returns only earned local admin collateral, including during venue/oracle outages.
fun take_admin_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    _: &AdminWitness<TreasuryAdmin>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();

    assert!(amount > 0, blast_boosts_aftermath::errors::zero_amount!());

    let available = self.admin_cash.value();
    assert!(amount <= available, blast_boosts_aftermath::errors::insufficient_admin_cash!());

    let output = self.admin_cash.split(amount).into_coin(ctx);

    events::admin_fees_withdrawn<Product>(self.id.to_inner(), amount, available - amount);

    output
}

/// Six-decimal seed NAV atoms as nine-decimal share atoms; the seed is never dust.
fun seed_shares(seed_nav: u64): u64 {
    seed_nav
        .checked_mul(SEED_SHARE_SCALE)
        .destroy_or!(abort blast_boosts_aftermath::errors::locked_shares_overflow!())
}

fun treasury_cap<Product, Collateral>(
    self: &Vault<Product, Collateral>
): &TreasuryCap<BlastBoost<Product>> {
    self.id.borrow_dynamic_object_field(TreasuryKey<Product>())
}

fun treasury_cap_mut<Product, Collateral>(
    self: &mut Vault<Product, Collateral>
): &mut TreasuryCap<BlastBoost<Product>> {
    self.id.borrow_dynamic_object_field_mut(TreasuryKey<Product>())
}

fun metadata_cap<Product, Collateral>(
    self: &Vault<Product, Collateral>
): &MetadataCap<BlastBoost<Product>> {
    self.id.borrow_dynamic_object_field(MetadataKey<Product>())
}

// === Test-Only Functions ===

#[test_only]
public fun take_admin_fees_for_testing<P, C>(
    self: &mut Vault<P, C>, protocol: &Protocol, witness: &AdminWitness<TreasuryAdmin>,
    amount: u64, ctx: &mut TxContext,
): Coin<C> {
    self.take_admin_fees(protocol, witness, amount, ctx)
}

#[test_only]
public fun seed_shares_for_testing(seed_nav: u64): u64 {
    seed_shares(seed_nav)
}

#[test_only]
public fun terminal_cash_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.terminal_cash.value()
}

#[test_only]
public fun protected_cash_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.protected_cash.value()
}

#[test_only]
public fun max_order_notional_for_testing<Product, Collateral>(
    self: &Vault<Product, Collateral>
): u64 {
    self.state.max_order_notional_for_testing()
}

#[test_only]
public fun vault_policy_for_testing<Product, Collateral>(
    self: &Vault<Product, Collateral>
): VaultPolicy {
    self.state.vault_policy_for_testing()
}

#[test_only]
public fun nav_cap_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.state.nav_cap_for_testing()
}

#[test_only]
public fun fee_settings_for_testing<Product, Collateral>(
    self: &Vault<Product, Collateral>
): (u64, u64, u64) {
    self.state.fee_settings()
}

#[test_only]
public fun treasury_cap_id_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): ID {
    object::id(self.treasury_cap())
}

#[test_only]
public fun metadata_cap_id_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): ID {
    object::id(self.metadata_cap())
}

#[test_only]
public fun set_unwinding_for_testing<Product, Collateral>(self: &mut Vault<Product, Collateral>) {
    self.state.set_unwinding_for_testing();
}

#[test_only]
public fun is_unwinding_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): bool {
    self.state.is_unwinding_for_testing()
}

// === Imports ===

use blast_core::{blast_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, blast_treasury::Treasury};

use blast_admin::{blast_acl::AdminWitness, delayed_action::{Self, DelayedAction}, package_version::PackageVersion};

use blast_boosts_aftermath::{
    blast_boost::{Self, BlastBoost},
    constants,
    events,
    blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH, Protocol},
    venue_account::VenueAccount,
};

use blast_boosts_core::{
    observation::{PositionObservation, PriceObservation},
    policy::VaultPolicy,
    blast_boosts_core::{RiskAdmin, ShutdownAdmin, VaultIssuer},
    lifecycle::ShutdownReason,
    state::{Self, ActivePosition, Issuance, State},
};

use std::{string::String, type_name};

use sui::{
    balance::{Self, Balance},
    coin::{Coin, TreasuryCap},
    coin_registry::{CoinRegistry, Currency, MetadataCap},
    clock::Clock,
    dynamic_object_field,
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow as UID.borrow_dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.borrow_dynamic_object_field_mut;
