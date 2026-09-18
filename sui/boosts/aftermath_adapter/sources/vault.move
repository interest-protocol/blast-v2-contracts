// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Adapter-owned Vault, leverage currency, and venue storage.
module blast_boosts_aftermath::vault;

// === Public Types ===

/// One issued Boost currency before its venue account exists.
///
/// `issue` creates it and `operations::initialize` must consume it in the same
/// transaction: it has no abilities, so an issuance that is not activated cannot
/// be stored or shared, and a failed activation rolls the currency back too.
public struct VaultIssuance<phantom Product> {
    state: State<Product>,
    risk_module_witness: TypeName,
    treasury_cap: TreasuryCap<BlastBoost<Product>>,
    metadata_cap: MetadataCap<BlastBoost<Product>>,
}

/// Shared adapter custody for one Boost currency, its core state and its venue account.
///
/// This adapter defines `Vault<Product>`, so it can issue the corresponding
/// non-OTW currency through Coin Registry. The nested core state has private
/// fields and can change only through core mutation functions. A Vault exists
/// only from activation on, so every field below is always present; the share
/// caps hang off `id` as dynamic object fields.
public struct Vault<phantom Product> has key {
    id: UID,
    state: State<Product>,
    risk_module_witness: TypeName,
    /// The bound account's identity, last accepted checkpoint and admin authority.
    venue_account: VenueAccount,
    seed_facts: SeedFacts,
    /// Digest of the drifted checkpoint while a health diagnostic is open.
    unresolved_checkpoint_digest: Option<vector<u8>>,
}

/// Immutable activation ownership facts; not a terminal claim or cash ledger.
public struct SeedFacts has copy, drop, store {
    locked_shares: u64,
    funder: address,
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
/// `Product` is the currency's identity: `Vault<Product>` names the coin and
/// Coin Registry admits each type once. Any non-primitive type may serve; the
/// core issuer role is the only authority. The adapter generation and that
/// role are checked before Coin Registry mutation. Package custody is not an
/// input: `package_admin` seals a validated Publisher and UpgradeCap that no
/// other object can hold, so re-reading those fields here would prove nothing
/// this package does not already own.
public fun issue<Product: drop, RiskModule: drop>(
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    _risk_module: RiskModule,
    registry: &mut CoinRegistry,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): VaultIssuance<Product> {
    protocol.assert_current();
    assert!(
        !type_name::with_original_ids<Product>().is_primitive(),
        blast_boosts_aftermath::errors::invalid_product_witness_type!(),
    );
    let risk_module_witness = valid_risk_module_type<RiskModule>();

    let state = state::new<Product>(admin_witness, vault_policy, max_order_notional, nav_cap);
    let (treasury_cap, metadata_cap) =
        blast_boost::new_currency<Product>(registry, symbol, name, description, icon_url, ctx);
    events::vault_issued<Product>(
        object::id(&treasury_cap), object::id(&metadata_cap), risk_module_witness, vault_policy,
        max_order_notional, nav_cap,
    );

    VaultIssuance { state, risk_module_witness, treasury_cap, metadata_cap }
}

/// Shares one activated adapter Vault.
public fun share<Product>(self: Vault<Product>) {
    transfer::share_object(self);
}

/// Irreversibly stops ordinary operations without requiring venue or oracle availability.
public fun begin_shutdown<Product>(
    self: &mut Vault<Product>,
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
    self: &mut Vault<Product>, protocol: &Protocol, shares: Coin<BlastBoost<Product>>,
    minimum_collateral: u64, deadline_ms: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    self.state.assert_settled();
    assert!(clock.timestamp_ms() <= deadline_ms, blast_boosts_aftermath::errors::deadline_expired!());
    self.assert_collateral_type<_, Collateral>();

    let (locked, _) = self.seed_facts();
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, TerminalCashKey());
    let output = self.state.shutdown_claim_quote(
        cash.value(), self.share_supply(), locked, shares.value(), minimum_collateral,
    );

    let burned = self.burn_redeemed_shares(shares);
    let cash = dynamic_field::borrow_mut<_, Balance<Collateral>>(&mut self.id, TerminalCashKey());
    let output_coin = coin::from_balance(cash.split(output), ctx);
    let remaining = cash.value();

    events::shutdown_redeemed<Product>(self.id.to_inner(), burned, output, remaining, self.share_supply() - locked);

    output_coin
}

// --- Administration ---

/// Updates only future fee collections under the immutable issuance caps.
/// This local administrative edge requires neither venue objects nor prices.
public fun set_fees<Product>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    mint_bps: u64,
    redeem_bps: u64,
    admin_share_bps: u64,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let (previous_mint, previous_redeem, previous_admin) =
        self.state.set_fees(mint_bps, redeem_bps, admin_share_bps);

    events::fees_updated<Product>(
        self.id.to_inner(), previous_mint, previous_redeem, previous_admin,
        mint_bps, redeem_bps, admin_share_bps,
    );
}

/// Replaces the NAV cap that bounds post-mint shareholder NAV.
/// This local administrative edge requires neither venue objects nor prices.
public fun set_nav_cap<Product>(
    self: &mut Vault<Product>,
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
/// The selected risk module may raise or lower the current value without a
/// cooldown. This transition changes no live position exposure and therefore
/// remains available in every lifecycle state.
public fun set_max_order_notional<Product, RiskModule: drop>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    _: RiskModule,
    max_order_notional: u64,
) {
    protocol.assert_current();
    assert_selected_risk_module<RiskModule>(self.risk_module_witness);

    let previous = self.state.set_max_order_notional(max_order_notional);

    events::max_order_notional_updated<Product>(self.id.to_inner(), previous, max_order_notional);
}

/// Replaces the risk-module witness accepted by this adapter Vault.
///
/// Rotation is available in every lifecycle state. It changes no core
/// policy, accounting value, currency capability, or adapter version.
public fun rotate_risk_module<Product, RiskModule: drop>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    _risk_module: RiskModule,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let new_witness = valid_risk_module_type<RiskModule>();
    assert!(
        new_witness != self.risk_module_witness,
        blast_boosts_aftermath::errors::risk_module_witness_unchanged!(),
    );

    let previous_witness = self.risk_module_witness;
    self.risk_module_witness = new_witness;

    events::risk_module_witness_rotated<Product>(self.id.to_inner(), previous_witness, new_witness);
}

/// Returns only earned local admin collateral, including during venue/oracle outages.
public fun withdraw_admin_fees<Product, Collateral>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());
    self.assert_collateral_type<_, Collateral>();
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
public(package) fun state<Product>(self: &Vault<Product>): &State<Product> { &self.state }

public(package) fun state_mut<Product>(self: &mut Vault<Product>): &mut State<Product> { &mut self.state }

/// The bound venue account: identity, last accepted checkpoint, and custody calls.
public(package) fun venue<Product>(self: &Vault<Product>): &VenueAccount { &self.venue_account }

public(package) fun venue_mut<Product>(self: &mut Vault<Product>): &mut VenueAccount { &mut self.venue_account }

/// The core state of an issuance while activation is proving the seed.
public(package) fun seed_state<Product>(self: &VaultIssuance<Product>): &State<Product> { &self.state }

public(package) fun seed_state_mut<Product>(self: &mut VaultIssuance<Product>): &mut State<Product> { &mut self.state }

// --- Initialization ---

/// The caller's risk module is the one the issuance selected.
public(package) fun assert_risk_module<Product, RiskModule: drop>(self: &VaultIssuance<Product>, _: &RiskModule) {
    assert_selected_risk_module<RiskModule>(self.risk_module_witness);
}

/// Mints the one locked seed position, makes it permanently inaccessible, and
/// returns the ownership facts the Vault records.
public(package) fun mint_locked_shares<Product>(
    self: &mut VaultIssuance<Product>,
    amount: u64,
    funder: address,
    ctx: &mut TxContext,
): SeedFacts {
    assert!(self.treasury_cap.total_supply() == 0, blast_boosts_aftermath::errors::seed_already_recorded!());
    assert_seed_funder(funder);
    assert!(amount > 0, blast_boosts_aftermath::errors::zero_amount!());

    transfer::public_transfer(coin::mint(&mut self.treasury_cap, amount, ctx), @0x0);

    SeedFacts { locked_shares: amount, funder }
}

/// Turns the issuance into the Vault once the venue account exists, hanging
/// the share caps off the new id.
public(package) fun activate<Product>(
    self: VaultIssuance<Product>, venue_account: VenueAccount, seed_facts: SeedFacts, ctx: &mut TxContext,
): Vault<Product> {
    let VaultIssuance { state, risk_module_witness, treasury_cap, metadata_cap } = self;
    let mut vault = Vault {
        id: object::new(ctx),
        state,
        risk_module_witness,
        venue_account,
        seed_facts,
        unresolved_checkpoint_digest: option::none(),
    };
    vault.id.add_dynamic_object_field(TreasuryKey<Product>(), treasury_cap);
    vault.id.add_dynamic_object_field(MetadataKey<Product>(), metadata_cap);

    vault
}

// --- Active Guards ---

// --- Mint ---

/// Mints only the shares priced by the completed core transition.
public(package) fun complete_mint<Product>(
    self: &mut Vault<Product>,
    plan: MintPlan<Product>,
    after: PositionObservation,
    now_ms: u64,
    ctx: &mut TxContext,
): (Coin<BlastBoost<Product>>, u64, u64, u64, u64, u64, u64) {
    let (amount, contribution, fee, admin, reserve_fee, fee_bps, admin_share_bps) =
        self.state.complete_mint(plan, after, now_ms);

    (coin::mint(self.treasury_cap_mut(), amount, ctx), contribution, fee, admin, reserve_fee, fee_bps, admin_share_bps)
}

// --- Redemption ---

/// Burns only through this Vault's retained native TreasuryCap.
public(package) fun burn_redeemed_shares<Product>(self: &mut Vault<Product>, shares: Coin<BlastBoost<Product>>): u64 {
    coin::burn(self.treasury_cap_mut(), shares)
}

// --- Rebalance ---

// --- Funding And Donation ---

/// Applies one authenticated nonzero funding classification to the core.
public(package) fun settle_funding<Product>(
    self: &mut Vault<Product>,
    is_cost: bool,
    amount: u64,
): (u64, u64, u64, u64) {
    let (absorbed, uncovered, restored) = self.state.settle_funding(if (is_cost) {
        observation::funding_cost(amount)
    } else {
        observation::funding_credit(amount)
    });

    (absorbed, uncovered, restored, self.state.maintenance_reserve())
}

/// Records only diagnostic novelty; it never accepts an economic checkpoint.
public(package) fun note_checkpoint_health<Product>(
    self: &mut Vault<Product>,
    checkpoint: &Checkpoint,
    clean: bool,
): bool {
    let next = if (clean) {
        option::none()
    } else {
        option::some(sui::hash::blake2b256(&std::bcs::to_bytes(checkpoint)))
    };
    let changed = self.unresolved_checkpoint_digest != next;
    self.unresolved_checkpoint_digest = next;
    changed
}

// --- Shutdown ---

/// Consumes verified venue finality and seals the actual recovered holder cash.
public(package) fun complete_shutdown<Product, Collateral>(
    self: &mut Vault<Product>, withdrawal: TerminalWithdrawal<Collateral>,
) {
    self.assert_collateral_type<_, Collateral>();

    let (recovered, checkpoint, unrecoverable_collateral_raw) = withdrawal.into_recovered_cash();
    let (locked, funder) = self.seed_facts();
    let supply = self.share_supply();
    let eligible = self.state.finalize_shutdown(supply, locked);
    let recovered_amount = recovered.value();
    // With no eligible share left the seed funder takes the cash back directly.
    let cash = if (eligible == 0) {
        transfer::public_transfer(recovered, funder);
        balance::zero()
    } else {
        recovered.into_balance()
    };

    self.venue_account.replace_checkpoint(checkpoint);
    dynamic_field::add(&mut self.id, TerminalCashKey(), cash);

    if (self.note_checkpoint_health(&checkpoint, true)) {
        events::health_synchronized<Product>(self.id.to_inner(), events::diagnostic_cleared_reason(), checkpoint);
    };
    events::shutdown_finalized<Product>(
        self.id.to_inner(), recovered_amount, eligible,
        if (eligible == 0) { option::some(funder) } else { option::none() },
        checkpoint, unrecoverable_collateral_raw,
    );
}

// --- Venue Custody ---

/// Retains an operation's already allocated admin coin without changing venue accounting.
public(package) fun retain_admin_cash<Product, Collateral>(
    self: &mut Vault<Product>,
    cash: Coin<Collateral>,
) {
    self.assert_collateral_type<_, Collateral>();
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
public(package) fun admin_cash_balance<Product, Collateral>(self: &Vault<Product>): u64 {
    self.assert_collateral_type<_, Collateral>();
    if (!dynamic_field::exists(&self.id, AdminCashKey())) { return 0 };
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, AdminCashKey());
    cash.value()
}

/// Checks the immutable activation collateral identity even on local-only paths.
public(package) fun assert_collateral_type<Product, Collateral>(self: &Vault<Product>) {
    assert!(
        self.venue_account.binding().collateral_type() == type_name::with_original_ids<Collateral>(),
        blast_boosts_aftermath::errors::collateral_type_mismatch!(),
    );
}

// --- Reads ---

/// Returns the stable Vault identity used by adapter events.
public(package) fun id<Product>(self: &Vault<Product>): ID {
    self.id.to_inner()
}

/// Returns the authoritative leverage-currency supply from the retained cap.
public(package) fun share_supply<Product>(self: &Vault<Product>): u64 {
    self.treasury_cap().total_supply()
}

/// Returns the exact once-recorded activation ownership for future terminal accounting.
public(package) fun seed_facts<Product>(self: &Vault<Product>): (u64, address) {
    (self.seed_facts.locked_shares, self.seed_facts.funder)
}

/// Rejects an unusable immutable beneficiary before activation touches the venue.
public(package) fun assert_seed_funder(funder: address) {
    assert!(funder != @0x0, blast_boosts_aftermath::errors::invalid_seed_funder!());
}

// === Private Functions ===

/// The caller's risk module is the one the issuance selected.
fun assert_selected_risk_module<RiskModule: drop>(selected: TypeName) {
    assert!(
        valid_risk_module_type<RiskModule>() == selected,
        blast_boosts_aftermath::errors::risk_module_witness_mismatch!(),
    );
}

/// Admits only runtime-constructible witnesses from a separate risk package.
/// The package-origin check excludes this adapter's public Product wrapper
/// from accidentally becoming administrative risk authority.
fun valid_risk_module_type<RiskModule: drop>(): TypeName {
    let witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !witness.is_primitive()
            && type_name::original_id<RiskModule>() != type_name::original_id<BLAST_BOOSTS_AFTERMATH>(),
        blast_boosts_aftermath::errors::invalid_risk_module_witness_type!(),
    );

    witness
}

fun treasury_cap<Product>(self: &Vault<Product>): &TreasuryCap<BlastBoost<Product>> {
    dynamic_object_field::borrow(&self.id, TreasuryKey<Product>())
}

fun treasury_cap_mut<Product>(self: &mut Vault<Product>): &mut TreasuryCap<BlastBoost<Product>> {
    dynamic_object_field::borrow_mut(&mut self.id, TreasuryKey<Product>())
}

// === Test-Only Functions ===

#[test_only]
public fun seed_facts_for_testing(locked_shares: u64, funder: address): SeedFacts {
    SeedFacts { locked_shares, funder }
}

#[test_only]
public fun terminal_cash_for_testing<Product, Collateral>(self: &Vault<Product>): u64 {
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, TerminalCashKey());
    cash.value()
}

#[test_only]
fun metadata_cap<Product>(self: &Vault<Product>): &MetadataCap<BlastBoost<Product>> {
    dynamic_object_field::borrow(&self.id, MetadataKey<Product>())
}

#[test_only]
public fun unresolved_checkpoint_digest_for_testing<Product>(self: &Vault<Product>): Option<vector<u8>> {
    self.unresolved_checkpoint_digest
}

#[test_only]
public fun set_active_for_testing<Product>(self: &mut VaultIssuance<Product>) {
    self.state.set_active_for_testing();
}

#[test_only]
public fun max_order_notional_for_testing<Product>(self: &Vault<Product>): u64 {
    self.state.max_order_notional_for_testing()
}

#[test_only]
public fun vault_policy_for_testing<Product>(self: &Vault<Product>): VaultPolicy {
    self.state.vault_policy_for_testing()
}

#[test_only]
public fun nav_cap_for_testing<Product>(self: &Vault<Product>): u64 {
    self.state.nav_cap()
}

#[test_only]
public fun fee_settings_for_testing<Product>(self: &Vault<Product>): (u64, u64, u64) {
    self.state.fee_settings()
}

#[test_only]
public fun risk_module_witness_for_testing<Product>(
    self: &Vault<Product>,
): TypeName {
    self.risk_module_witness
}

#[test_only]
public fun treasury_cap_id_for_testing<Product>(self: &Vault<Product>): ID {
    object::id(self.treasury_cap())
}

#[test_only]
public fun metadata_cap_id_for_testing<Product>(self: &Vault<Product>): ID {
    object::id(self.metadata_cap())
}

#[test_only]
public fun set_unwinding_for_testing<Product>(self: &mut Vault<Product>) {
    self.state.set_unwinding_for_testing();
}

#[test_only]
/// Issues fixture shares through the same retained native TreasuryCap as production mints.
public fun mint_eligible_shares_for_testing<Product>(
    self: &mut Vault<Product>, amount: u64, ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    coin::mint(self.treasury_cap_mut(), amount, ctx)
}

#[test_only]
public fun is_unwinding_for_testing<Product>(self: &Vault<Product>): bool {
    self.state.is_unwinding_for_testing()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_boosts_aftermath::{
    blast_boost::{Self, BlastBoost},
    blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH,
    constants,
    events,
    protocol::Protocol,
    venue_account::{Binding, Checkpoint, TerminalWithdrawal, VenueAccount},
};

use blast_boosts_core::{
    observation::{Self as observation, PositionObservation, PriceObservation},
    policy::{PositionSide, VaultPolicy},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    lifecycle::ShutdownReason,
    state::{Self, ActivePosition, DonationPlan, MintPlan, RebalancePlan, RedemptionPlan, State},
};

use perpetuals::{account::Account, clearing_house::{ClearingHouse, SessionSummary}, registry::Registry};

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use std::{string::String, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{CoinRegistry, MetadataCap},
    clock::Clock,
    dynamic_field,
    dynamic_object_field,
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
