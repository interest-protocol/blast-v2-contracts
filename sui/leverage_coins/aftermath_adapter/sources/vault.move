// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Adapter-owned Vault, leverage currency, and venue storage.
module blast_leverage_aftermath::vault;

use blast_admin::acl::AdminWitness;
use blast_leverage_aftermath::{
    aftermath::AFTERMATH,
    constants,
    events,
    protocol::Protocol,
    venue_account::{Self as venue_account, Binding, Checkpoint, TerminalWithdrawal, VenueAccount},
};
use blast_leverage_core::{
    observation::{Self as observation, PositionObservation, PriceObservation},
    policy::{PositionSide, VaultPolicy},
    blast_leverage_core::{Self as domain, BLAST_LEVERAGE_CORE},
    state::{Self as series_state, DonationPlan, MintPlan, RebalancePlan, RedemptionPlan, State},
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

// === Public Structs ===

/// Shared adapter custody for one Series1 leverage currency and product.
///
/// This adapter defines `Vault<Product>`, so it can issue the corresponding
/// non-OTW currency through Coin Registry. The nested Series1 state has private
/// fields and can change only through Series1 mutation functions.
public struct Vault<phantom Product> has key {
    id: UID,
    series_state: State<Product>,
    risk_module_witness: TypeName,
    venue_account: Option<VenueAccount>,
    unresolved_checkpoint_digest: Option<vector<u8>>,
    seed_facts: Option<SeedFacts>,
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

/// Issues one owned adapter Vault and its unique leverage currency.
///
/// `Product` is the currency's identity: `Vault<Product>` names the coin and
/// Coin Registry admits each type once. Any non-primitive type may serve; the
/// Series1 issuer role is the only authority. The adapter generation and that
/// role are checked before Coin Registry mutation. The returned key-only Vault must pass to `share` in this
/// package. Package custody is not an input: `package_admin` seals a validated
/// Publisher and UpgradeCap that no other object can hold, so re-reading those
/// fields here would prove nothing this package does not already own.
public fun issue<Product: drop, RiskModule: drop>(
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    _risk_module: RiskModule,
    registry: &mut CoinRegistry,
    vault_policy: VaultPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): Vault<Product> {
    protocol.assert_current();
    let series_state = series_state::new<Product>(
        admin_witness,
        vault_policy,
        max_order_notional_minimum,
        max_order_notional_current,
        max_order_notional_maximum,
    );

    assert!(
        !type_name::with_original_ids<Product>().is_primitive(),
        blast_leverage_aftermath::errors::invalid_product_witness_type!(),
    );

    let risk_module_witness = valid_risk_module_type<RiskModule>();

    let (initializer, treasury_cap) = registry.new_currency<Vault<Product>>(
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
    let mut vault = Vault {
        id: object::new(ctx),
        series_state,
        risk_module_witness,
        venue_account: option::none(),
        unresolved_checkpoint_digest: option::none(),
        seed_facts: option::none(),
    };
    let vault_id = vault.id.to_inner();

    vault.add_treasury_cap(treasury_cap);
    vault.add_metadata_cap(metadata_cap);
    events::vault_issued<Product>(
        vault_id,
        treasury_cap_id,
        metadata_cap_id,
        risk_module_witness,
        vault_policy,
        max_order_notional_minimum,
        max_order_notional_current,
        max_order_notional_maximum,
        0,
    );

    vault
}

/// Shares one fully issued adapter Vault.
public fun share<Product>(self: Vault<Product>) {
    transfer::share_object(self);
}

/// Replaces the NAV cap that bounds post-mint shareholder NAV.
/// This local administrative edge requires neither venue objects nor prices.
public fun set_nav_cap<Product>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    nav_cap: u64,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let previous = self.series_state.set_nav_cap(nav_cap);
    events::nav_cap_updated<Product>(self.id.to_inner(), previous, nav_cap);
}

/// Updates only future fee collections under the immutable issuance caps.
/// This local administrative edge requires neither venue objects nor prices.
public fun set_fees<Product>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    mint_bps: u64,
    redeem_bps: u64,
    admin_bps: u64,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let (previous_mint, previous_redeem, previous_admin) =
        self.series_state.set_fees(mint_bps, redeem_bps, admin_bps);

    events::fees_updated<Product>(
        self.id.to_inner(), previous_mint, previous_redeem, previous_admin,
        mint_bps, redeem_bps, admin_bps,
    );
}

/// Returns only earned local admin collateral, including during venue/oracle outages.
public fun withdraw_admin_fees<Product, Collateral>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());
    self.assert_collateral_type<_, Collateral>();
    assert!(amount > 0, blast_leverage_aftermath::errors::zero_amount!());

    let available = self.admin_cash_balance<_, Collateral>();
    assert!(amount <= available, blast_leverage_aftermath::errors::insufficient_admin_cash!());

    let cash = dynamic_field::borrow_mut<_, Balance<Collateral>>(&mut self.id, AdminCashKey());
    let output = coin::from_balance(cash.split(amount), ctx);

    events::admin_fees_withdrawn<Product>(self.id.to_inner(), amount, available - amount);

    output
}

/// Replaces the risk-module witness accepted by this adapter Vault.
///
/// Rotation is available in every Series1 lifecycle state. It changes no core
/// policy, accounting value, currency capability, or adapter version.
public fun rotate_risk_module<Product, RiskModule: drop>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    _risk_module: RiskModule,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::risk_admin_role());

    let new_witness = valid_risk_module_type<RiskModule>();
    assert!(
        new_witness != self.risk_module_witness,
        blast_leverage_aftermath::errors::risk_module_witness_unchanged!(),
    );

    let previous_witness = self.risk_module_witness;
    self.risk_module_witness = new_witness;
    events::risk_module_witness_rotated<Product>(
        self.id.to_inner(),
        previous_witness,
        new_witness,
    );
}

/// Changes the live per-call maximum order notional within its frozen bounds.
///
/// This value limits the absolute atomic-USDC notional of one Aftermath order.
/// It does not limit a user's deposit or the Vault's total open position.
/// The selected risk module may raise or lower the current value without a
/// cooldown. This transition changes neither the immutable bounds nor live
/// position exposure and therefore remains available in every lifecycle state.
public fun set_max_order_notional<Product, RiskModule: drop>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    _: RiskModule,
    current: u64,
) {
    protocol.assert_current();
    let presented_witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !presented_witness.is_primitive(),
        blast_leverage_aftermath::errors::invalid_risk_module_witness_type!(),
    );
    assert!(
        presented_witness == self.risk_module_witness,
        blast_leverage_aftermath::errors::risk_module_witness_mismatch!(),
    );

    let previous = self.series_state.set_max_order_notional(current);
    events::max_order_notional_updated<Product>(
        self.id.to_inner(),
        previous,
        current,
    );
}

/// Irreversibly stops ordinary operations without requiring venue or oracle availability.
public fun begin_shutdown<Product>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    reason: blast_leverage_core::lifecycle::ShutdownReason,
) {
    protocol.assert_current();
    admin_witness.assert_role(domain::shutdown_admin_role());

    self.series_state.begin_shutdown();
    events::shutdown_begun<Product>(self.id.to_inner(), reason);
}

/// Burns native eligible shares for local terminal collateral; no venue or oracle access.
public fun redeem_shutdown<Product, Collateral>(
    self: &mut Vault<Product>, protocol: &Protocol, shares: Coin<Vault<Product>>,
    minimum_collateral: u64, deadline_ms: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    self.series_state.assert_settled();
    assert!(clock.timestamp_ms() <= deadline_ms, blast_leverage_aftermath::errors::deadline_expired!());
    self.assert_collateral_type<_, Collateral>();

    let (locked, _) = self.seed_facts();
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, TerminalCashKey());
    let output = self.series_state.shutdown_claim_quote(cash.value(), self.share_supply(), locked, shares.value(), minimum_collateral);

    let burned = self.burn_redeemed_shares(shares);
    let cash = dynamic_field::borrow_mut<_, Balance<Collateral>>(&mut self.id, TerminalCashKey());
    let output_coin = coin::from_balance(cash.split(output), ctx);
    let remaining = cash.value();

    events::shutdown_redeemed<Product>(self.id.to_inner(), burned, output, remaining, self.share_supply() - locked);
    output_coin
}

// === Package Functions ===

/// Consumes verified venue finality and seals the actual recovered holder cash.
public(package) fun complete_shutdown<Product, Collateral>(
    self: &mut Vault<Product>, withdrawal: TerminalWithdrawal<Collateral>,
) {
    self.series_state.assert_unwinding();
    self.assert_collateral_type<_, Collateral>();
    let (recovered, checkpoint, unrecoverable_collateral_raw) = withdrawal.into_recovered_cash();

    let (locked, funder) = self.seed_facts();
    let supply = self.share_supply();

    let eligible = self.series_state.finalize_shutdown(supply, locked);
    self.replace_venue_checkpoint(checkpoint);
    let recovered_amount = recovered.value();
    let cash = if (eligible == 0) {
        transfer::public_transfer(recovered, funder);
        balance::zero()
    } else {
        recovered.into_balance()
    };
    dynamic_field::add(&mut self.id, TerminalCashKey(), cash);
    if (self.note_checkpoint_health(&checkpoint, true)) {
        events::health_synchronized<Product>(self.id.to_inner(), events::checkpoint_reconciled_reason(), checkpoint);
    };
    events::shutdown_finalized<Product>(self.id.to_inner(), recovered_amount, eligible,
        if (eligible == 0) { option::some(funder) } else { option::none() }, checkpoint, unrecoverable_collateral_raw);
}

/// Checks the caller's rate ceiling without treating share atoms as collateral.
public(package) fun assert_user_fee_limit<Product>(self: &Vault<Product>, mint: bool, maximum: u64) {
    self.series_state.assert_user_fee_limit(mint, maximum);
}

/// Returns actual collateral through retained custody; no caller receives venue authority.
public(package) fun withdraw_collateral<Product, Collateral>(
    self: &Vault<Product>, account: &mut Account<Collateral>, registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>, base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage, amount: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    self.venue_account.borrow().withdraw(account, registry, clearing_house, base_oracle, collateral_oracle, amount, clock, ctx)
}

/// Seals redemption terms against the actual native input and authoritative supply.
public(package) fun prepare_redemption<Product>(
    self: &Vault<Product>, observation: PositionObservation, shares: &Coin<Vault<Product>>,
    minimum_output: u64, maximum_fee_bps: u64, now: u64,
): RedemptionPlan<Product> {
    self.series_state.prepare_redemption(observation, shares.value(), self.share_supply(), minimum_output, maximum_fee_bps, now)
}

/// Prices only the attributable completed unwind, before any withdrawal or burn.
public(package) fun price_redemption<Product>(
    self: &mut Vault<Product>, plan: RedemptionPlan<Product>, observation: PositionObservation, now: u64,
): (u64, u64, u64, u64, u64) {
    self.series_state.complete_redemption(plan, observation, now)
}

/// Consumes the final cash/margin proof before native shares leave the supply.
public(package) fun assert_redemption_cash_out<Product>(
    self: &Vault<Product>, observation: PositionObservation, equity: u64, base: u64,
    base_price: u64, collateral_price: u64, now: u64,
) {
    self.series_state.assert_redemption_cash_out(observation, equity, base, base_price, collateral_price, now);
}

/// Burns only through this Vault's retained native TreasuryCap.
public(package) fun burn_redeemed_shares<Product>(self: &mut Vault<Product>, shares: Coin<Vault<Product>>): u64 {
    let treasury_cap = dynamic_object_field::borrow_mut(&mut self.id, TreasuryKey<Product>());
    coin::burn(treasury_cap, shares)
}

/// Allocates only the bound account's deposited cash into its retained market.
public(package) fun allocate_collateral<Product, Collateral>(
    self: &Vault<Product>, account: &mut Account<Collateral>, clearing_house: &mut ClearingHouse<Collateral>, amount: u64,
) {
    self.venue_account.borrow().allocate(account, clearing_house, amount);
}

/// Keeps all authority inside custody while executing one adapter-derived order.
public(package) fun execute_order<Product, Collateral>(
    self: &Vault<Product>, account: &mut Account<Collateral>, clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    is_ask: bool, base: u64, reduce_only: bool, clock: &Clock, ctx: &TxContext,
): (ClearingHouse<Collateral>, SessionSummary) {
    self.venue_account.borrow().execute_order(
        account, clearing_house, base_oracle, collateral_oracle, is_ask, base, reduce_only, clock, ctx,
    )
}

/// Supplies only policy-derived active execution constraints to the adapter.
public(package) fun active_constraints<Product>(self: &Vault<Product>): (PositionSide, u64) {
    self.series_state.active_constraints()
}

/// Validates each ordinary active fill against the sealed reference price.
public(package) fun assert_active_execution<Product>(self: &Vault<Product>, reference: u64, executed: u64) {
    self.series_state.assert_active_execution(reference, executed);
}

/// Validates intermediate margin and prices without persisting an economic checkpoint.
public(package) fun assert_active_observation<Product>(
    self: &Vault<Product>, observation: PositionObservation, base_price: u64, collateral_price: u64, now: u64,
) {
    self.series_state.assert_active_observation(observation, base_price, collateral_price, now);
}

/// Seals maintenance terms against this Vault's immutable policy and current buffer.
public(package) fun prepare_rebalance<Product>(
    self: &Vault<Product>, observation: PositionObservation, venue_fee_bps: u64, now: u64,
): RebalancePlan<Product> {
    self.series_state.prepare_rebalance(observation, venue_fee_bps, now)
}

/// Derives the next bounded order without accepting any caller trading parameter.
public(package) fun rebalance_order<Product>(self: &Vault<Product>, plan: &RebalancePlan<Product>): (u64, bool, bool) {
    self.series_state.rebalance_order(plan)
}

/// Uses the core's current threshold to validate this session's actual execution.
public(package) fun assert_rebalance_execution<Product>(self: &Vault<Product>, plan: &RebalancePlan<Product>, reference: u64, executed: u64) {
    self.series_state.assert_rebalance_execution(plan, reference, executed);
}

/// Advances sealed intent only after the adapter has proved the venue mutation.
public(package) fun accept_rebalance_fill<Product>(
    self: &Vault<Product>, plan: &mut RebalancePlan<Product>, observation: PositionObservation, filled: u64, now: u64,
) {
    self.series_state.accept_rebalance_fill(plan, observation, filled, now);
}

/// Completes core maintenance; no native shares or admin assets move.
public(package) fun complete_rebalance<Product>(self: &Vault<Product>, plan: RebalancePlan<Product>): (u64, u64, u64, u64, bool) {
    self.series_state.complete_rebalance(plan)
}

/// Seals mint terms against this Vault's sole native share-supply authority.
public(package) fun prepare_mint<Product>(
    self: &Vault<Product>,
    observation: PositionObservation,
    deposit: u64,
    minimum_shares: u64,
    maximum_fee_bps: u64,
    now: u64,
): MintPlan<Product> {
    self.series_state.prepare_mint(
        observation, deposit, self.share_supply(), minimum_shares, maximum_fee_bps, now,
    )
}

/// Mints only the shares priced by the completed Series1 transition.
public(package) fun complete_mint<Product>(
    self: &mut Vault<Product>,
    plan: MintPlan<Product>,
    after: PositionObservation,
    now: u64,
    ctx: &mut TxContext,
): (Coin<Vault<Product>>, u64, u64, u64, u64, u64, u64) {
    let (amount, contribution, fee, admin, buffer, rate, admin_rate) = self.series_state.complete_mint(plan, after, now);
    let treasury_cap = dynamic_object_field::borrow_mut(&mut self.id, TreasuryKey<Product>());
    (coin::mint(treasury_cap, amount, ctx), contribution, fee, admin, buffer, rate, admin_rate)
}

/// Cheap active lifecycle guard shared by public financial operations.
public(package) fun assert_active<Product>(self: &Vault<Product>) {
    self.series_state.assert_active();
}

/// Synchronization can reconcile only an active or unwinding venue account.
public(package) fun assert_can_sync<Product>(self: &Vault<Product>) {
    self.series_state.assert_can_sync();
}

/// Stops every terminal venue call outside the irreversible unwind phase.
public(package) fun assert_unwinding<Product>(self: &Vault<Product>) {
    self.series_state.assert_unwinding();
}

/// Consumes authenticated oracle facts through the terminal Series1 policy.
public(package) fun unwind_constraints<Product>(
    self: &Vault<Product>, base: PriceObservation, collateral: PriceObservation, now: u64,
): (PositionSide, u64, u64, u64) {
    self.series_state.unwind_constraints(base, collateral, now)
}

/// Enforces the immutable emergency bound on an actual venue fill price.
public(package) fun assert_unwind_execution<Product>(self: &Vault<Product>, reference: u64, executed: u64) {
    self.series_state.assert_unwind_execution(reference, executed);
}

/// Validates pre-donation pricing before any asset-bearing venue interaction.
public(package) fun prepare_donation<Product>(
    self: &Vault<Product>, observation: PositionObservation, amount: u64, now: u64,
): DonationPlan<Product> {
    self.series_state.prepare_donation(observation, amount, now)
}

/// Applies only the completed donation's buffer allocation.
public(package) fun complete_donation<Product>(
    self: &mut Vault<Product>, plan: DonationPlan<Product>, after: PositionObservation, now: u64,
) {
    self.series_state.complete_donation(plan, after, now);
}

/// Relabels authenticated buffer after live risk-administrator authorization.
public(package) fun release_buffer<Product>(
    self: &mut Vault<Product>,
    admin_witness: &AdminWitness<BLAST_LEVERAGE_CORE>,
    observation: PositionObservation,
    amount: u64,
    now: u64,
) {
    admin_witness.assert_role(domain::risk_admin_role());
    self.series_state.release_buffer(observation, amount, now);
}

/// Uses retained venue authority without exposing a cap or custody reference.
public(package) fun deposit_collateral<Product, Collateral>(
    self: &Vault<Product>, account: &mut Account<Collateral>, registry: &Registry, cash: Coin<Collateral>,
) {
    assert_venue_account_installed(self.venue_account.is_some());
    self.venue_account.borrow().deposit(account, registry, cash);
}

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
        self.venue_binding().collateral_type() == type_name::with_original_ids<Collateral>(),
        blast_leverage_aftermath::errors::collateral_type_mismatch!(),
    );
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

/// Installs the one venue account after atomic initialization succeeds.
public(package) fun install_venue_account<Product>(
    self: &mut Vault<Product>,
    venue_account: VenueAccount,
) {
    assert_venue_account_installable(self.venue_account.is_some());
    self.venue_account.fill(venue_account);
}

/// Authenticates the selected risk module and returns the seed-side constraints.
public(package) fun initialization_constraints<Product, RiskModule: drop>(
    self: &Vault<Product>,
    _: &RiskModule,
): (PositionSide, u64) {
    self.assert_selected_risk_module<_, RiskModule>();
    assert_venue_account_installable(self.venue_account.is_some());
    self.series_state.initialization_constraints()
}

/// Consumes a strict flat-position observation and returns authenticated sizing inputs.
public(package) fun prepare_initialization<Product>(
    self: &Vault<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): (u64, u64, u64, u64) {
    self.series_state.prepare_initialization(
        observation,
        seed_reserve,
        reference_time_ms,
    )
}

/// Applies the immutable strict execution tolerance before activation.
public(package) fun assert_initialization_execution<Product>(
    self: &Vault<Product>,
    reference_price: u64,
    execution_price: u64,
) {
    self.series_state.assert_initialization_execution(
        reference_price,
        execution_price,
    );
}

/// Applies the live Series1 order-notional cap to one planned seed order.
public(package) fun assert_order_notional_allowed<Product>(
    self: &Vault<Product>,
    order_notional: u64,
) {
    self.series_state.assert_order_notional_allowed(order_notional);
}

/// Activates Series1 after the adapter proves the complete final observation.
public(package) fun initialize_series<Product>(
    self: &mut Vault<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    collateral_decimals: u8,
    reference_time_ms: u64,
): u64 {
    self.series_state.initialize(
        observation,
        seed_reserve,
        constants::base_decimals!(),
        collateral_decimals,
        reference_time_ms,
    )
}

/// Returns the authoritative leverage-currency supply from the retained cap.
public(package) fun share_supply<Product>(self: &Vault<Product>): u64 {
    self.treasury_cap().total_supply()
}

/// Returns the authoritative funding-only reserve for state-derived events.
public(package) fun maintenance_reserve<Product>(self: &Vault<Product>): u64 {
    self.series_state.maintenance_reserve()
}

/// Rejects an unusable immutable beneficiary before activation touches the venue.
public(package) fun assert_seed_funder(funder: address) {
    assert!(funder != @0x0, blast_leverage_aftermath::errors::invalid_seed_funder!());
}

/// Mints the one locked seed position and makes it permanently inaccessible.
public(package) fun mint_locked_shares<Product>(
    self: &mut Vault<Product>,
    amount: u64,
    funder: address,
    ctx: &mut TxContext,
) {
    assert!(self.seed_facts.is_none() && self.share_supply() == 0,
        blast_leverage_aftermath::errors::seed_already_recorded!());
    assert_seed_funder(funder);
    assert!(amount > 0, blast_leverage_aftermath::errors::zero_amount!());
    let treasury_cap = dynamic_object_field::borrow_mut(
        &mut self.id,
        TreasuryKey<Product>(),
    );
    let locked_shares: Coin<Vault<Product>> = coin::mint(treasury_cap, amount, ctx);
    self.seed_facts.fill(SeedFacts { locked_shares: amount, funder });
    transfer::public_transfer(locked_shares, @0x0);
}

/// Returns the exact once-recorded activation ownership for future terminal accounting.
public(package) fun seed_facts<Product>(self: &Vault<Product>): (u64, address) {
    let seed = self.seed_facts.borrow();
    (seed.locked_shares, seed.funder)
}

/// Returns the stable Vault identity used by adapter events.
public(package) fun id<Product>(self: &Vault<Product>): ID {
    self.id.to_inner()
}

/// Copies the immutable venue binding without exposing its custody value.
public(package) fun venue_binding<Product>(self: &Vault<Product>): Binding {
    assert_venue_account_installed(self.venue_account.is_some());
    self.venue_account.borrow().binding()
}

/// Borrows the latest raw venue checkpoint immutably.
public(package) fun venue_checkpoint<Product>(
    self: &Vault<Product>,
): &Checkpoint {
    assert_venue_account_installed(self.venue_account.is_some());
    self.venue_account.borrow().checkpoint()
}

/// Revalidates retained Aftermath authority without exposing the cap.
public(package) fun assert_venue_custody_binding<Product>(
    self: &Vault<Product>,
) {
    assert_venue_account_installed(self.venue_account.is_some());
    self.venue_account.borrow().assert_custody_binding();
}

/// Applies one authenticated nonzero funding classification to Series1.
public(package) fun settle_funding<Product>(
    self: &mut Vault<Product>,
    is_cost: bool,
    amount: u64,
): (u64, u64, u64, u64) {
    let (absorbed, uncovered, restored) = self.series_state.settle_funding(if (is_cost) {
        observation::funding_cost(amount)
    } else {
        observation::funding_credit(amount)
    });

    (absorbed, uncovered, restored, self.series_state.maintenance_reserve())
}

/// Replaces the raw venue checkpoint after authenticated reconciliation.
public(package) fun replace_venue_checkpoint<Product>(
    self: &mut Vault<Product>,
    checkpoint: Checkpoint,
) {
    assert_venue_account_installed(self.venue_account.is_some());
    self.venue_account.borrow_mut().replace_checkpoint(checkpoint);
}

// === Private Functions ===

fun assert_venue_account_installable(is_installed: bool) {
    assert!(
        !is_installed,
        blast_leverage_aftermath::errors::venue_account_already_installed!(),
    );
}

fun assert_venue_account_installed(is_installed: bool) {
    assert!(
        is_installed,
        blast_leverage_aftermath::errors::venue_account_not_installed!(),
    );
}

fun assert_selected_risk_module<Product, RiskModule: drop>(
    self: &Vault<Product>,
) {
    let presented_witness = valid_risk_module_type<RiskModule>();
    assert!(
        presented_witness == self.risk_module_witness,
        blast_leverage_aftermath::errors::risk_module_witness_mismatch!(),
    );
}

/// Admits only runtime-constructible witnesses from a separate risk package.
/// The package-origin check excludes this adapter's public Product wrapper
/// from accidentally becoming administrative risk authority.
fun valid_risk_module_type<RiskModule: drop>(): TypeName {
    let witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !witness.is_primitive()
            && type_name::original_id<RiskModule>()
                != type_name::original_id<AFTERMATH>(),
        blast_leverage_aftermath::errors::invalid_risk_module_witness_type!(),
    );
    witness
}

fun add_treasury_cap<Product>(
    self: &mut Vault<Product>,
    treasury_cap: TreasuryCap<Vault<Product>>,
) {
    self.id.add_dynamic_object_field(TreasuryKey<Product>(), treasury_cap);
}

fun add_metadata_cap<Product>(
    self: &mut Vault<Product>,
    metadata_cap: MetadataCap<Vault<Product>>,
) {
    self.id.add_dynamic_object_field(MetadataKey<Product>(), metadata_cap);
}

fun treasury_cap<Product>(self: &Vault<Product>): &TreasuryCap<Vault<Product>> {
    dynamic_object_field::borrow(&self.id, TreasuryKey<Product>())
}

// === Test-Only Functions ===

#[test_only]
public fun terminal_cash_for_testing<Product, Collateral>(self: &Vault<Product>): u64 {
    let cash = dynamic_field::borrow<_, Balance<Collateral>>(&self.id, TerminalCashKey());
    cash.value()
}

#[test_only]
fun metadata_cap<Product>(self: &Vault<Product>): &MetadataCap<Vault<Product>> {
    dynamic_object_field::borrow(&self.id, MetadataKey<Product>())
}

#[test_only]
public fun id_for_testing<Product>(self: &Vault<Product>): ID {
    self.id.to_inner()
}

#[test_only]
public fun unresolved_checkpoint_digest_for_testing<Product>(self: &Vault<Product>): Option<vector<u8>> {
    self.unresolved_checkpoint_digest
}

#[test_only]
public fun is_uninitialized_for_testing<Product>(self: &Vault<Product>): bool {
    self.series_state.is_uninitialized_for_testing()
}

#[test_only]
public fun has_venue_account_for_testing<Product>(self: &Vault<Product>): bool {
    self.venue_account.is_some()
}

#[test_only]
public fun assert_venue_account_installable_for_testing(is_installed: bool) {
    assert_venue_account_installable(is_installed);
}

#[test_only]
public fun assert_venue_account_installed_for_testing(is_installed: bool) {
    assert_venue_account_installed(is_installed);
}

#[test_only]
public fun set_active_for_testing<Product>(self: &mut Vault<Product>) {
    self.series_state.set_active_for_testing();
}

#[test_only]
public fun maintenance_reserve_for_testing<Product>(self: &Vault<Product>): u64 {
    self.series_state.maintenance_reserve_for_testing()
}

#[test_only]
public fun max_order_notional_for_testing<Product>(
    self: &Vault<Product>,
): (u64, u64, u64) {
    self.series_state.max_order_notional_for_testing()
}

#[test_only]
public fun vault_policy_for_testing<Product>(self: &Vault<Product>): VaultPolicy {
    self.series_state.vault_policy_for_testing()
}

#[test_only]
public fun nav_cap_for_testing<Product>(self: &Vault<Product>): u64 {
    self.series_state.nav_cap()
}

#[test_only]
public fun fee_settings_for_testing<Product>(self: &Vault<Product>): (u64, u64, u64) {
    self.series_state.fee_settings()
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
public fun share_supply_for_testing<Product>(self: &Vault<Product>): u64 {
    self.treasury_cap().total_supply()
}

#[test_only]
public fun set_unwinding_for_testing<Product>(self: &mut Vault<Product>) {
    self.series_state.set_unwinding_for_testing();
}

#[test_only]
public fun initialization_constraints_for_testing<Product, RiskModule: drop>(
    self: &Vault<Product>,
    risk_module: &RiskModule,
): (PositionSide, u64) {
    self.initialization_constraints(risk_module)
}

#[test_only]
public fun mint_locked_shares_for_testing<Product>(
    self: &mut Vault<Product>,
    amount: u64,
    funder: address,
    ctx: &mut TxContext,
) {
    self.mint_locked_shares(amount, funder, ctx);
}

#[test_only]
/// Issues fixture shares through the same retained native TreasuryCap as production mints.
public fun mint_eligible_shares_for_testing<Product>(
    self: &mut Vault<Product>, amount: u64, ctx: &mut TxContext,
): Coin<Vault<Product>> {
    let treasury_cap = dynamic_object_field::borrow_mut(&mut self.id, TreasuryKey<Product>());
    coin::mint(treasury_cap, amount, ctx)
}

#[test_only]
public fun is_unwinding_for_testing<Product>(self: &Vault<Product>): bool {
    self.series_state.is_unwinding_for_testing()
}
