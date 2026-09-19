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

/// Converts six-decimal seed NAV atoms to nine-decimal share atoms.
const SEED_SHARE_SCALE: u64 = 1_000;

// === Public Types ===

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
    /// The bound account's identity, last accepted checkpoint and admin authority.
    venue_account: VenueAccount,
    /// The seed shares minted to the burn address at activation; never redeemable.
    locked_shares: u64,
}

/// Dynamic-object-field key for one Vault's share mint authority.
public struct TreasuryKey<phantom Product>() has copy, drop, store;

/// Dynamic-object-field key for one Vault's metadata authority.
public struct MetadataKey<phantom Product>() has copy, drop, store;

/// One native balance of the exact bound collateral, separate from venue equity.
public struct AdminCashKey() has copy, drop, store;

/// Native terminal holder cash, never mixed with the administrator's balance.
public struct TerminalCashKey() has copy, drop, store;

// === Public Functions ===

/// Issues one leverage currency and the issuance that `operations::initialize`
/// turns into its Vault in the same transaction.
///
/// `Product` is the currency's identity: `Vault<Product, Collateral>` names the coin and
/// Coin Registry admits each type once. Any non-primitive type may serve; the
/// core issuer role is the only authority. The adapter generation and that
/// role are checked before Coin Registry mutation. Package custody is not an
/// input: `package_admin` seals a validated Publisher and UpgradeCap that no
/// other object can hold, so re-reading those fields here would prove nothing
/// this package does not already own.
public fun issue<Product: drop, Collateral>(
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
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
    assert!(
        !type_name::with_original_ids<Product>().is_primitive(),
        blast_boosts_aftermath::errors::invalid_product_witness_type!(),
    );
    let issuance = state::issue<Product>(
        admin_witness, vault_policy, max_order_notional, nav_cap,
        constants::base_decimals!(), constants::collateral_decimals!(),
    );
    let (treasury_cap, metadata_cap) =
        blast_boost::new_currency<Product>(registry, symbol, name, description, icon_url, ctx);
    events::vault_issued<Product>(
        object::id(&treasury_cap), object::id(&metadata_cap), vault_policy, max_order_notional, nav_cap,
    );

    VaultIssuance { issuance, treasury_cap, metadata_cap }
}

/// Shares one activated adapter Vault.
public fun share<Product, Collateral>(self: Vault<Product, Collateral>) {
    transfer::share_object(self);
}

/// Irreversibly stops ordinary operations without requiring venue or oracle availability.
public fun begin_shutdown<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    reason: ShutdownReason,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::shutdown_admin_role());

    self.state.begin_shutdown();

    events::shutdown_begun<Product>(self.id.to_inner(), reason);
}

/// Burns native eligible shares for local terminal collateral; no venue or oracle access.
public fun redeem_shutdown<Product, Collateral>(
    self: &mut Vault<Product, Collateral>, protocol: &Protocol, shares: Coin<BlastBoost<Product>>,
    minimum_collateral: u64, deadline_ms: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    self.state.assert_settled();
    assert!(clock.timestamp_ms() <= deadline_ms, blast_boosts_aftermath::errors::deadline_expired!());

    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, TerminalCashKey());
    let output = self.state.shutdown_claim_quote(
        cash.value(), self.total_share_supply(), self.locked_shares, shares.value(), minimum_collateral,
    );

    let burned = self.burn_redeemed_shares(shares);
    let cash = dynamic_field::borrow_mut<_, Balance<Collateral>>(&mut self.id, TerminalCashKey());
    let output_coin = coin::from_balance(cash.split(output), ctx);
    let remaining = cash.value();

    events::shutdown_redeemed<Product>(
        self.id.to_inner(), burned, output, remaining, self.total_share_supply() - self.locked_shares,
    );

    output_coin
}

// --- Administration ---

/// Updates only future fee collections under the immutable issuance caps.
/// This local administrative edge requires neither venue objects nor prices.
public fun set_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    mint_fee_bps: u64,
    redeem_fee_bps: u64,
    admin_share_bps: u64,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let (previous_mint, previous_redeem, previous_admin) =
        self.state.set_fees(mint_fee_bps, redeem_fee_bps, admin_share_bps);

    events::fees_updated<Product>(
        self.id.to_inner(), previous_mint, previous_redeem, previous_admin,
        mint_fee_bps, redeem_fee_bps, admin_share_bps,
    );
}

/// Replaces the NAV cap that bounds post-mint shareholder NAV.
/// This local administrative edge requires neither venue objects nor prices.
public fun set_nav_cap<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    nav_cap: u64,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let previous = self.state.set_nav_cap(nav_cap);

    events::nav_cap_updated<Product>(self.id.to_inner(), previous, nav_cap);
}

/// Changes the live per-call maximum order notional.
///
/// This value limits the absolute atomic-USDC notional of one Aftermath order.
/// It does not limit a user's deposit or the Vault's total open position.
/// The risk administrator may raise or lower the current value without a
/// cooldown. This transition changes no live position exposure and therefore
/// remains available in every lifecycle state.
public fun set_max_order_notional<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    max_order_notional: u64,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let previous = self.state.set_max_order_notional(max_order_notional);

    events::max_order_notional_updated<Product>(self.id.to_inner(), previous, max_order_notional);
}

/// Returns only earned local admin collateral, including during venue/oracle outages.
public fun withdraw_admin_fees<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());
    assert!(amount > 0, blast_boosts_aftermath::errors::zero_amount!());

    let available = self.admin_cash_balance<_, Collateral>();
    assert!(amount <= available, blast_boosts_aftermath::errors::insufficient_admin_cash!());

    let cash = dynamic_field::borrow_mut<_, Balance<Collateral>>(&mut self.id, AdminCashKey());
    let output = coin::from_balance(cash.split(amount), ctx);

    events::admin_fees_withdrawn<Product>(self.id.to_inner(), amount, available - amount);

    output
}

// === Package Functions ===

// --- Core And Venue ---

/// The core accounting state; the adapter drives it directly and the Vault only stores it.
public(package) fun state<Product, Collateral>(self: &Vault<Product, Collateral>): &State<Product> { &self.state }

public(package) fun state_mut<Product, Collateral>(self: &mut Vault<Product, Collateral>): &mut State<Product> { &mut self.state }

/// The bound venue account: identity, last accepted checkpoint, and custody calls.
public(package) fun venue<Product, Collateral>(self: &Vault<Product, Collateral>): &VenueAccount { &self.venue_account }

public(package) fun venue_mut<Product, Collateral>(self: &mut Vault<Product, Collateral>): &mut VenueAccount { &mut self.venue_account }

/// The issuer's terms, which size and bound the seed position before the state exists.
public(package) fun issuance<Product, Collateral>(self: &VaultIssuance<Product, Collateral>): &Issuance<Product> { &self.issuance }

// --- Initialization ---

/// Activates the core on the seeded observation, mints the locked seed shares
/// to the burn address, and builds the Vault around the venue account, with
/// the share caps hanging off the new id. Returns the Vault, the seed's
/// shareholder NAV, and the priced seed position. The seed is a permanent
/// gift to the product: its shares are never redeemable and its cash, once
/// every other share has left, becomes admin cash.
public(package) fun activate<Product, Collateral>(
    self: VaultIssuance<Product, Collateral>,
    seeded: PositionObservation,
    seed_reserve: u64,
    venue_account: VenueAccount,
    now_ms: u64,
    ctx: &mut TxContext,
): (Vault<Product, Collateral>, u64, ActivePosition) {
    let VaultIssuance { issuance, mut treasury_cap, metadata_cap } = self;
    let (state, seed_nav, seeded) = issuance.activate(seeded, seed_reserve, now_ms);

    let locked_shares = seed_shares(seed_nav);
    transfer::public_transfer(coin::mint(&mut treasury_cap, locked_shares, ctx), @0x0);

    let mut vault = Vault {
        id: object::new(ctx),
        state,
        venue_account,
        locked_shares,
    };
    vault.id.add_dynamic_object_field(TreasuryKey<Product>(), treasury_cap);
    vault.id.add_dynamic_object_field(MetadataKey<Product>(), metadata_cap);

    (vault, seed_nav, seeded)
}

// --- Mint ---

/// Mints only through this Vault's retained native TreasuryCap.
public(package) fun mint_shares<Product, Collateral>(
    self: &mut Vault<Product, Collateral>, amount: u64, ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    coin::mint(self.treasury_cap_mut(), amount, ctx)
}

// --- Redemption ---

/// Burns only through this Vault's retained native TreasuryCap.
public(package) fun burn_redeemed_shares<Product, Collateral>(self: &mut Vault<Product, Collateral>, shares: Coin<BlastBoost<Product>>): u64 {
    coin::burn(self.treasury_cap_mut(), shares)
}

// --- Shutdown ---

/// Seals the proven terminal withdrawal as holder cash: the coin becomes the
/// terminal claim balance, or admin cash when no eligible share is left to
/// claim what the locked seed backed. Returns the final checkpoint and the
/// raw collateral the venue could not release.
public(package) fun seal_terminal_cash<Product, Collateral>(
    self: &mut Vault<Product, Collateral>, withdrawal: TerminalWithdrawal<Collateral>, eligible: u64,
): (Checkpoint, u256) {
    let (recovered, checkpoint, unrecoverable_collateral_raw) = withdrawal.into_recovered_cash();
    let cash = if (eligible == 0) {
        self.retain_admin_cash(recovered);
        balance::zero()
    } else {
        recovered.into_balance()
    };

    dynamic_field::add(&mut self.id, TerminalCashKey(), cash);

    (checkpoint, unrecoverable_collateral_raw)
}

// --- Admin Cash ---

/// Retains an operation's already allocated admin coin without changing venue accounting.
public(package) fun retain_admin_cash<Product, Collateral>(
    self: &mut Vault<Product, Collateral>,
    cash: Coin<Collateral>,
) {
    if (cash.value() == 0) {
        cash.destroy_zero();
        return
    };
    let balance = dynamic_field::borrow_mut_or_add!(
        &mut self.id, AdminCashKey(), balance::zero<Collateral>(),
    );
    balance.join(cash.into_balance());
}

/// Native cash is authoritative; no mirrored numerical admin ledger is stored.
public(package) fun admin_cash_balance<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    if (!dynamic_field::exists(&self.id, AdminCashKey())) { return 0 };
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, AdminCashKey());
    cash.value()
}

// --- Reads ---

/// Returns the stable Vault identity used by adapter events.
public(package) fun id<Product, Collateral>(self: &Vault<Product, Collateral>): ID {
    self.id.to_inner()
}

/// Returns the authoritative leverage-currency supply from the retained cap.
public(package) fun total_share_supply<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.treasury_cap().total_supply()
}

/// The seed shares locked at activation, excluded from every terminal claim.
public(package) fun locked_shares<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.locked_shares
}

// === Private Functions ===

/// Six-decimal seed NAV atoms as nine-decimal share atoms; the seed is never dust.
fun seed_shares(seed_nav: u64): u64 {
    seed_nav.checked_mul(SEED_SHARE_SCALE).destroy_or!(abort blast_boosts_aftermath::errors::locked_shares_overflow!())
}

fun treasury_cap<Product, Collateral>(self: &Vault<Product, Collateral>): &TreasuryCap<BlastBoost<Product>> {
    dynamic_object_field::borrow(&self.id, TreasuryKey<Product>())
}

fun treasury_cap_mut<Product, Collateral>(self: &mut Vault<Product, Collateral>): &mut TreasuryCap<BlastBoost<Product>> {
    dynamic_object_field::borrow_mut(&mut self.id, TreasuryKey<Product>())
}

// === Test-Only Functions ===

#[test_only]
public fun seed_shares_for_testing(seed_nav: u64): u64 {
    seed_shares(seed_nav)
}

#[test_only]
public fun terminal_cash_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, TerminalCashKey());
    cash.value()
}

#[test_only]
fun metadata_cap<Product, Collateral>(self: &Vault<Product, Collateral>): &MetadataCap<BlastBoost<Product>> {
    dynamic_object_field::borrow(&self.id, MetadataKey<Product>())
}

#[test_only]
public fun max_order_notional_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.state.max_order_notional_for_testing()
}

#[test_only]
public fun vault_policy_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): VaultPolicy {
    self.state.vault_policy_for_testing()
}

#[test_only]
public fun nav_cap_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): u64 {
    self.state.nav_cap_for_testing()
}

#[test_only]
public fun fee_settings_for_testing<Product, Collateral>(self: &Vault<Product, Collateral>): (u64, u64, u64) {
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

use blast_admin::acl::AdminWitness;

use blast_boosts_aftermath::{
    blast_boost::{Self, BlastBoost},
    constants,
    events,
    protocol::Protocol,
    venue_account::{Checkpoint, TerminalWithdrawal, VenueAccount},
};

use blast_boosts_core::{
    observation::PositionObservation,
    policy::VaultPolicy,
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    lifecycle::ShutdownReason,
    state::{Self, ActivePosition, Issuance, State},
};

use std::{string::String, type_name};

use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{CoinRegistry, MetadataCap},
    clock::Clock,
    dynamic_field,
    dynamic_object_field,
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
