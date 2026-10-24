// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Atomic Aftermath operations for adapter-owned leverage Vaults.
module blast_boosts_aftermath::operations;

// === Public Functions ===

/// Seeds one issuance and returns its activated Vault and ClearingHouse.
/// The same transaction must share both after composition.
///
/// Direction and size come only from the immutable core policy; the caller
/// chooses no order parameter.
/// Every external value is retained in the Vault, shared, consumed, or returned.
/// Only the issuer's transaction can reach this: the issuance has no abilities,
/// so it cannot be stored, shared, or handed to another signer.
public fun initialize<Product, Collateral>(
    issuance: VaultIssuance<Product, Collateral>,
    protocol: &Protocol,
    currency: &Currency<Collateral>,
    registry: &mut Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    seed: Coin<Collateral>,
    seed_reserve: u64,
    position_imr: u256,
    clock: &Clock,
    ctx: &mut TxContext,
): (Vault<Product, Collateral>, ClearingHouse<Collateral>) {
    protocol.assert_current();
    let terms = issuance.issuance();
    let position_side = terms.seed_side();
    let seed_amount = seed.value();
    assert_initialization_inputs(
        currency.decimals(), clearing_house.market_params().scaling_factor(), seed_amount, seed_reserve,
    );
    assert_position_imr(position_imr);

    let (mut account, share_policy, admin_cap, binding) =
        registry.open_venue_account(&clearing_house, ctx);
    account.fund_venue_account(&admin_cap, registry, &mut clearing_house, seed, position_imr);

    clearing_house = terms.seed_position(
        &mut account, &admin_cap, &binding, registry, clearing_house, base_oracle, collateral_oracle, seed_reserve, clock, ctx,
    );

    clearing_house.settle_position_funding(collateral_oracle, binding.account_number(), clock);
    let (final_observation, checkpoint) = binding.capture(
        &account, registry, &clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();
    clearing_house.assert_position_imr_unchanged(binding.account_number(), position_imr);
    let venue_account = venue_account::new(binding, checkpoint, admin_cap);

    let (vault, seed_nav, seeded) = issuance.activate(
        final_observation, seed_reserve, venue_account, clock.timestamp_ms(), ctx,
    );
    account.consume_policy_and_share_account(share_policy);
    vault.emit_vault_initialized<Product, Collateral>(
        seed_amount, seed_nav, seeded.equity(), seeded.base(), seeded.lot_size(), position_side, position_imr,
    );

    (vault, clearing_house)
}

/// Exchanges exact bound collateral for native leverage shares in one atomic operation.
/// Policy fixes direction and whole-lot size; partial sessions must complete the aggregate.
/// Returns the ClearingHouse for composition; the transaction must share it afterward.
public fun mint<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    cash: Coin<Collateral>,
    minimum_shares: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BlastBoost<Product>>, ClearingHouse<Collateral>) {
    protocol.assert_current();
    vault.state().assert_active();
    let deposit = cash.value();
    assert!(deposit > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_at_ms);

    let (before, before_checkpoint) = vault.synchronize_or_fail(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();

    let plan = vault.state().prepare_mint(before, deposit, vault.total_share_supply(), minimum_shares, clock.timestamp_ms());
    let terms = vault.increasing_terms(plan.mint_position());

    let checkpoint = vault.fund_mint(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        cash, plan.admin_fee(), &before_checkpoint, ctx,
    );

    let binding = vault.venue().binding();
    let clearing_house = vault.fill_orders(
        account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, checkpoint, terms, plan.base_to_buy(), clock, ctx,
    );

    let (after, final_checkpoint) = binding.capture(
        account, registry, &clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();

    let shares = vault.complete_mint<Product, Collateral>(plan, deposit, after, final_checkpoint, clock.timestamp_ms(), ctx);

    (shares, clearing_house)
}

/// Burns native shares only after their proportional close and exact collateral payout.
/// Entry-quote and realized PnL use authenticated post-session state, never an invented formula.
/// Returns the ClearingHouse for composition; the transaction must share it afterward.
public fun redeem<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    shares: Coin<BlastBoost<Product>>,
    minimum_collateral: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Collateral>, ClearingHouse<Collateral>) {
    protocol.assert_current();
    vault.state().assert_active();
    assert!(shares.value() > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_at_ms);

    let (before, checkpoint) = vault.synchronize_or_fail(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();

    let plan = vault.state().prepare_redemption(before, shares.value(), vault.total_share_supply(), minimum_collateral, clock.timestamp_ms());
    let terms = vault.reducing_terms(plan.redemption_position());

    let binding = vault.venue().binding();
    let mut clearing_house = vault.fill_orders(
        account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, checkpoint, terms, plan.base_to_sell(), clock, ctx,
    );

    let (after_sell, after_sell_checkpoint) = binding.capture(
        account, registry, &clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();
    let (net, admin, fee, reserve_fee) = vault.settle_redemption(plan, &shares, after_sell, clock.timestamp_ms());

    let cash = vault.venue().withdraw(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle, net + admin, clock, ctx,
    );
    let final_checkpoint = binding.capture_checkpoint(
        account, registry, &clearing_house, base_oracle, collateral_oracle,
    );
    after_sell_checkpoint.assert_withdrawal_checkpoint(&final_checkpoint, net + admin);

    let cash = vault.complete_redemption(shares, cash, net, admin, fee, reserve_fee, final_checkpoint, ctx);

    (cash, clearing_house)
}

/// Adds `partner` to the Blast partners Boosts accepts, at once. Adding a
/// partner whose removal is pending cancels the removal.
public fun add_partner(
    protocol: &mut Protocol,
    _: &AdminWitness<RiskAdmin>,
    partner: &Partner,
) {
    protocol.assert_current();

    let partner_id = object::id(partner);
    protocol.add_partner(partner_id);

    events::partner_added(partner_id);
}

/// Removes `partner` from the Blast partners Boosts accepts, with the same
/// notice Blast gives for every change to a partner: it stays accepted, and
/// paid, for `blast_partners::delay_ms()`.
public fun remove_partner(
    protocol: &mut Protocol,
    _: &AdminWitness<RiskAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    protocol.assert_current();

    let partner_id = object::id(partner);
    let now_at_ms = clock.timestamp_ms();
    let acceptance_ends_at_ms = now_at_ms + partners::delay_ms();
    protocol.remove_partner(partner_id, now_at_ms, acceptance_ends_at_ms);

    events::partner_removed(partner_id, acceptance_ends_at_ms);
}

/// `mint`, naming a Blast partner Boosts accepts: the partner is paid its share
/// of the admin fee this mint retained. Holders' shares and the reserve are
/// exactly `mint`'s.
public fun mint_with_partner<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    partner: &Partner,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    cash: Coin<Collateral>,
    minimum_shares: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BlastBoost<Product>>, ClearingHouse<Collateral>) {
    protocol.assert_partner(object::id(partner), clock.timestamp_ms());
    let admin_cash_before = vault.admin_cash_balance<_, Collateral>();

    let (shares, clearing_house) = vault.mint(
        protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        cash, minimum_shares, deadline_at_ms, clock, ctx,
    );
    vault.pay_partner(partner, admin_cash_before, clock, ctx);

    (shares, clearing_house)
}

/// `redeem`, naming a Blast partner Boosts accepts: the partner is paid its
/// share of the admin fee this redemption retained. The redeemer's payout is
/// exactly `redeem`'s.
public fun redeem_with_partner<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    partner: &Partner,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    shares: Coin<BlastBoost<Product>>,
    minimum_collateral: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Collateral>, ClearingHouse<Collateral>) {
    protocol.assert_partner(object::id(partner), clock.timestamp_ms());
    let admin_cash_before = vault.admin_cash_balance<_, Collateral>();

    let (cash, clearing_house) = vault.redeem(
        protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        shares, minimum_collateral, deadline_at_ms, clock, ctx,
    );
    vault.pay_partner(partner, admin_cash_before, clock, ctx);

    (cash, clearing_house)
}

/// A keeper's dry run of `rebalance`: whether the live position sits outside the band.
///
/// Reads everything `rebalance` reads and asks the core the same question, so it
/// aborts where `rebalance` would abort before its first order: an interval
/// since the stored checkpoint that the classifier cannot explain, or an
/// observation the price policy refuses. It does not settle funding first, so a
/// due settlement can move the answer by that amount when the real call runs;
/// intended for `dev_inspect`, not for on-chain gating.
public fun needs_rebalance<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): bool {
    protocol.assert_current();
    vault.state().assert_active();

    let binding = vault.venue().binding();
    let (observation, checkpoint) = binding.capture(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();
    assert!(
        vault.venue().checkpoint().classify_preexisting(&checkpoint).is_clean(),
        blast_boosts_aftermath::errors::unresolved_checkpoint!(),
    );

    vault.state().needs_rebalance(observation, clock.timestamp_ms())
}

/// Updates the order cap after checking the live bound market's prices and lot.
/// Risk administration remains available without healthy margin or positive NAV.
public fun set_max_order_notional<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    witness: &AdminWitness<RiskAdmin>,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    max_order_notional: u64,
    clock: &Clock,
) {
    protocol.assert_current();
    let binding = vault.venue().binding();
    vault.state().assert_max_order_notional_update(max_order_notional);
    let (base_price, collateral_price, lot_size) = binding.capture_order_capacity(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    );

    vault.set_max_order_notional(
        protocol, witness, max_order_notional, base_price, collateral_price, lot_size, clock.timestamp_ms(),
    );
}

/// Deposits configured collateral into the active funding buffer without shares or fees.
public fun donate<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    cash: Coin<Collateral>,
    clock: &Clock,
) {
    protocol.assert_current();
    vault.state().assert_active();
    let amount = cash.value();
    assert!(amount > 0, blast_boosts_aftermath::errors::zero_amount!());

    vault.synchronize_or_fail(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    );

    vault.venue().deposit(account, registry, cash);

    let binding = vault.venue().binding();
    let (after, checkpoint) = binding.capture(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();

    vault.complete_donation(after, checkpoint, amount, clock.timestamp_ms());
}

/// Settles due funding and reconciles the stored checkpoint with the venue,
/// with no priced operation attached and no lifecycle move. Any caller may
/// submit the bound objects; a binding failure aborts. An explainable funding
/// move is booked and emitted, and an interval the classifier cannot explain
/// leaves the accepted checkpoint standing and emits `CheckpointDrifted`.
public fun sync_health<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    protocol.assert_current();

    vault.synchronize(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    );
}

/// Recovers all actual holder collateral only from an exactly settled bound account.
public fun finalize_shutdown<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol.assert_current();
    vault.state().assert_unwinding();

    let binding = vault.venue().binding();
    let before = binding.capture_checkpoint(
        account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    let amount = before.recoverable_terminal_cash();

    let recovered = if (amount == 0) {
        sui::coin::zero(ctx)
    } else {
        vault.venue().withdraw(
            account, registry, clearing_house, base_oracle, collateral_oracle, amount, clock, ctx,
        )
    };

    let after = binding.capture_checkpoint(
        account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    before.assert_terminal_withdrawal_checkpoint(&after, recovered.value());

    vault.complete_finalization(after, recovered);
}

// === Private Functions ===

/// Permissionless, policy-sized maintenance with no caller reward or trade parameters.
///
/// Ordinary maintenance runs at or below the reference gas price. A reduction
/// starting above the hard leverage cap may pay priority gas; holders bear the
/// venue's extra trading fee, and the plan stops once the hard cap is restored.
/// Private entry prevents a preceding venue session from supplying the shared market.
/// Shares the ClearingHouse internally, ending its use in this transaction.
entry fun rebalance<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    ctx: &TxContext,
) {
    protocol.assert_current();
    vault.state().assert_active();

    let (before, checkpoint) = vault.synchronize_or_fail(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle, clock,
    ).into_observation();

    let mut plan = vault.state().prepare_rebalance(before, clearing_house.live_venue_fee_bps(), clock.timestamp_ms());
    plan.assert_gas_price(ctx);
    let position = plan.rebalance_position();
    let terms = if (plan.is_increasing()) { vault.increasing_terms(position) } else { vault.reducing_terms(position) };
    let binding = vault.venue().binding();

    let (clearing_house, checkpoint) = vault.rebalance_orders(
        account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, &terms, &mut plan, checkpoint, clock, ctx,
    );

    vault.complete_rebalance<Product, Collateral>(plan, checkpoint);
    clearing_house.share();
}

/// Permissionless bounded close-only progress, never caller-sized or dependent
/// on positive NAV. A live market is closed by price-limited orders; a market the
/// venue has paused only by the venue's own settlement, once it has closed the
/// market and enabled settlement prices; a frozen clearing house aborts every
/// venue call on its version check, so it is refused here until unfrozen.
/// Priority gas is allowed so closings can compete during congestion; holders
/// bear the venue's extra trading fee on any priority-priced fills.
/// Private entry prevents a preceding venue session from supplying the shared market.
/// Shares the ClearingHouse internally, ending its use in this transaction.
entry fun unwind<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    ctx: &TxContext,
) {
    protocol.assert_current();
    vault.state().assert_unwinding();
    assert!(!clearing_house.is_frozen(), blast_boosts_aftermath::errors::venue_not_ready!());

    if (clearing_house.is_market_paused()) {
        vault.unwind_settlement(account, registry, &mut clearing_house, base_oracle, collateral_oracle);
    } else {
        clearing_house = vault.unwind_market(
            account, registry, clearing_house, base_oracle, collateral_oracle, clock, ctx,
        );
    };
    clearing_house.share();
}

/// Returns one authenticated product observation without mutating state.
///
/// Private, so no transaction or package can call it: only a simulation with
/// transaction checks skipped (dev-inspect `skip_checks`) reaches it. With checks
/// on, the call is rejected as a non-entry function, and a node may refuse to
/// simulate with checks off.
/// The adapter generation and the complete venue object graph are checked before
/// returning the canonical capture, retained share supply, and clock reading.
/// Its outputs are informational only; every state-changing operation repeats
/// its own checks and capture.
#[allow(unused_function)]
fun observe<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): (CapturedSnapshot, ID, u64, u64) {
    protocol.assert_current();

    let binding = vault.venue().binding();
    let captured = binding.capture(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    );

    (captured, vault.treasury_cap_id(), vault.total_share_supply(), clock.timestamp_ms())
}

// --- Initialization ---

/// The collateral is six-decimal on both sides: the currency the vault issues
/// against and the market's own collateral scale, which the venue multiplies
/// every allocated atom by (`clearing_house::allocate_collateral`).
fun assert_initialization_inputs(
    collateral_decimals: u8,
    market_scaling_factor: u256,
    seed_amount: u64,
    seed_reserve: u64,
) {
    assert!(
        collateral_decimals == constants::collateral_decimals!()
            && market_scaling_factor == constants::collateral_atom_to_ifixed_scale!(),
        blast_boosts_aftermath::errors::invalid_collateral_decimals!(),
    );
    assert!(seed_amount > 0, blast_boosts_aftermath::errors::invalid_seed!());
    assert!(seed_reserve < seed_amount, blast_boosts_aftermath::errors::invalid_seed_reserve!());
}

fun assert_position_imr(position_imr: u256) {
    assert_position_imr_sign(position_imr.is_neg());
}

fun assert_position_imr_sign(is_negative: bool) {
    assert!(!is_negative, blast_boosts_aftermath::errors::initialization_imr_mismatch!());
}

/// Creates the isolated Aftermath account the Vault will own and binds it to
/// the registry and clearing house this activation was called with.
fun open_venue_account<Collateral>(
    registry: &mut Registry,
    clearing_house: &ClearingHouse<Collateral>,
    ctx: &mut TxContext,
): (Account<Collateral>, AccountSharePolicy, AuthorityCap<ACCOUNT, ADMIN>, Binding) {
    let (account, share_policy, admin_cap) = account::create_account<Collateral>(registry, ctx);
    let binding = venue_account::new_binding(
        object::id(&account), account.account_id(), object::id(registry), object::id(clearing_house),
    );

    (account, share_policy, admin_cap, binding)
}

/// Deposits and allocates the whole seed, opens the market position, and sets its margin ratio.
fun fund_venue_account<Collateral>(
    account: &mut Account<Collateral>,
    admin_cap: &AuthorityCap<ACCOUNT, ADMIN>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    seed: Coin<Collateral>,
    position_imr: u256,
) {
    let seed_amount = seed.value();
    account.deposit_collateral(admin_cap, registry, seed);
    clearing_house.create_market_position(admin_cap, account);
    clearing_house.allocate_collateral(admin_cap, account, seed_amount);
    clearing_house.set_position_initial_margin_ratio(admin_cap, account, position_imr);
}

/// The margin ratio set before the seed orders must survive them unchanged.
fun assert_position_imr_unchanged<Collateral>(
    clearing_house: &ClearingHouse<Collateral>,
    account_number: u64,
    position_imr: u256,
) {
    let final_imr = clearing_house.position(account_number).initial_margin_ratio();
    assert_position_imr_unchanged_decoded(final_imr.is_neg(), final_imr, position_imr);
}

fun assert_position_imr_unchanged_decoded(
    final_is_negative: bool,
    final_imr: u256,
    position_imr: u256,
) {
    assert!(
        !final_is_negative && final_imr == position_imr,
        blast_boosts_aftermath::errors::initialization_imr_mismatch!(),
    );
}

/// Emits activation facts read back from the resulting real Vault state.
fun emit_vault_initialized<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    seed_amount: u64,
    seed_shareholder_nav: u64,
    seed_venue_equity: u64,
    position_base: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
) {
    events::vault_initialized<Product>(
        vault.id(),
        vault.venue().binding(),
        seed_amount,
        seed_venue_equity,
        vault.state().maintenance_reserve(),
        seed_shareholder_nav,
        vault.locked_shares(),
        position_base,
        lot_size,
        position_side,
        position_imr,
        *vault.venue().checkpoint(),
    );
}

// --- Mint And Redeem ---

fun assert_deadline(now_at_ms: u64, deadline_at_ms: u64) {
    assert!(now_at_ms <= deadline_at_ms, blast_boosts_aftermath::errors::deadline_expired!());
}

/// Keeps the admin's fee slice as vault cash and puts the rest of the deposit
/// to work on the venue, proving the checkpoint moved by exactly that amount.
/// Returns the funded checkpoint the orders start from.
fun fund_mint<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    mut cash: Coin<Collateral>,
    admin_fee: u64,
    before: &Checkpoint,
    ctx: &mut TxContext,
): Checkpoint {
    vault.retain_admin_cash(cash.split(admin_fee, ctx).into_balance());
    let venue_deposit = cash.value();
    vault.venue().deposit(account, registry, cash);
    vault.venue().allocate(account, clearing_house, venue_deposit);

    let binding = vault.venue().binding();
    let funded = binding.capture_checkpoint(
        account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    before.assert_allocated_deposit_checkpoint(&funded, venue_deposit);

    funded
}

// --- Permissionless Trades ---

/// Only a plan that started above the hard cap may pass the venue's priority
/// trading fee to holders. The core fixes that decision before any fill.
fun assert_rebalance_gas_price<Product>(plan: &RebalancePlan<Product>, ctx: &TxContext) {
    assert!(
        plan.is_emergency_rebalance() || ctx.gas_price() <= ctx.reference_gas_price(),
        blast_boosts_aftermath::errors::priority_gas_price!(),
    );
}

// --- Completion ---

/// Commits native mint effects only after the orchestration proved its venue checkpoint.
fun complete_mint<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: MintPlan<Product>,
    deposit: u64,
    after: PositionObservation,
    checkpoint: Checkpoint,
    now_at_ms: u64,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    let (amount, contribution, fee, admin, reserve_fee) = vault.state_mut().complete_mint(plan, after, now_at_ms);

    let shares = vault.mint_shares(amount, ctx);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::minted<Product>(
        vault.id(), deposit, shares.value(), contribution, fee, admin, reserve_fee,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(),
        vault.total_share_supply(), checkpoint,
    );

    shares
}

/// Prices the payout on the position the sell left. The share coin is held,
/// unburned, until the payout is proved to have left the venue.
/// Returns the user's net, the admin cash, the fee, and the fee's reserve share.
fun settle_redemption<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RedemptionPlan<Product>,
    shares: &Coin<BlastBoost<Product>>,
    after_sell: PositionObservation,
    now_at_ms: u64,
): (u64, u64, u64, u64) {
    assert!(
        shares.value() == plan.redemption_shares(),
        blast_boosts_aftermath::errors::redemption_share_mismatch!(),
    );

    vault.state_mut().complete_redemption(plan, after_sell, now_at_ms)
}

/// Completes custody after the public operation proves the withdrawal on the checkpoint:
/// retains the earned admin cash, burns the held shares, and accepts the checkpoint.
fun complete_redemption<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    shares: Coin<BlastBoost<Product>>,
    mut cash: Coin<Collateral>,
    net: u64,
    admin: u64,
    fee: u64,
    reserve_fee: u64,
    checkpoint: Checkpoint,
    ctx: &mut TxContext,
): Coin<Collateral> {
    assert!(cash.value() == net + admin, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());

    vault.retain_admin_cash(cash.split(admin, ctx).into_balance());
    let burned = vault.burn_redeemed_shares(shares);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::redeemed<Product>(
        vault.id(), burned, net, fee, admin, reserve_fee,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.total_share_supply(), checkpoint,
    );

    cash
}

/// Pays `partner` its share of the admin fee one mint or redeem just retained,
/// the admin cash added since `admin_cash_before`, keeps the rest as Blast's
/// admin cash, and records the payment against the vault. The reserve fee is
/// never part of it.
fun pay_partner<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    partner: &Partner,
    admin_cash_before: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let admin_fee = vault.admin_cash_balance<_, Collateral>() - admin_cash_before;

    let mut fee = vault.take_admin_cash(admin_fee);
    let partner_fee = partner.pay(&mut fee, clock, ctx);
    vault.retain_admin_cash(fee);

    events::partner_fee_paid<Product>(vault.id(), object::id(partner), admin_fee, partner_fee);
}

/// Advances the sole economic checkpoint only after sealed maintenance has succeeded.
fun complete_rebalance<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RebalancePlan<Product>,
    checkpoint: Checkpoint,
) {
    let (before_equity, after_equity, before_base, after_base, increase) = vault.state().complete_rebalance(plan);

    vault.venue_mut().replace_checkpoint(checkpoint);

    events::rebalanced<Product>(
        vault.id(), before_equity, after_equity, before_base, after_base, increase,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.total_share_supply(), checkpoint,
    );
}

/// Credits a donation the venue has taken: the raw checkpoint proves the exact
/// deposit, the core prices the position it left.
fun complete_donation<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    after: PositionObservation,
    checkpoint: Checkpoint,
    amount: u64,
    now_at_ms: u64,
) {
    vault.venue().checkpoint().assert_deposit_checkpoint(&checkpoint, amount);

    vault.state_mut().donate(after, amount, now_at_ms);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::donated<Product>(vault.id(), amount, vault.state().maintenance_reserve(), checkpoint);
}

// --- Funding ---

/// Reconciles the stored checkpoint with one the venue just showed, given the
/// net funding classified between them. A clean interval books the funding,
/// adopts the checkpoint and emits the settlement; anything else emits the
/// drift and leaves the accepted checkpoint standing. Every synchronization
/// and every unwind step passes through here.
fun apply_post_capture<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    net: CheckpointChange,
) {
    let checkpoint_clean = net.is_clean();
    let (absorbed, uncovered, restored) = vault.settle_net_funding(&net);
    let reserve_after = vault.state().maintenance_reserve();
    let stored_checkpoint = *vault.venue().checkpoint();

    if (checkpoint_clean) {
        vault.venue_mut().replace_checkpoint(checkpoint);
    } else {
        events::checkpoint_drifted<Product>(vault.id(), checkpoint);
    };

    // A zero-net interval still advances authenticated source identity and
    // needs a reducer-visible completed fact; identical retries remain quiet.
    if (checkpoint_clean && stored_checkpoint != checkpoint) {
        events::funding_settled<Product>(
            vault.id(), net.is_cost(), net.raw_amount(), net.amount(), absorbed, uncovered, restored,
            reserve_after, stored_checkpoint, checkpoint,
        );
    };
}

/// Applies a net funding move to the reserve; a clean interval settles nothing.
/// Returns `(absorbed_by_reserve, uncovered_cost, restored_to_holders)`.
fun settle_net_funding<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    net: &CheckpointChange,
): (u64, u64, u64) {
    if (!net.has_funding()) return (0, 0, 0);

    let settlement = if (net.is_cost()) {
        observation::funding_cost(net.amount())
    } else {
        observation::funding_credit(net.amount())
    };

    vault.state_mut().settle_funding(settlement)
}

/// Settles due funding on the venue and reconciles the stored checkpoint with
/// what the venue shows now; returns that capture so a priced operation can
/// build on it without reading the venue again. Drift is reported here, never
/// an abort: `sync_health` and `unwind` carry on from it, and a priced
/// operation goes through `synchronize_or_fail`.
fun synchronize<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): CapturedSnapshot {
    vault.state().assert_can_sync();

    let binding = vault.venue().binding();
    binding.update_funding_when_due(clearing_house, base_oracle, clock);
    let pre_capture = binding.capture(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    );
    let (pre_checkpoint, collateral_price) = (pre_capture.checkpoint(), pre_capture.collateral_fixed());

    clearing_house.settle_position_funding(collateral_oracle, account.account_id(), clock);

    let post_capture = binding.capture(
        account, registry, clearing_house, base_oracle, collateral_oracle, clock,
    );
    let (preexisting_change, local_change) = vault.venue().checkpoint().classify_sync_changes(
        &pre_checkpoint, &post_capture.checkpoint(), collateral_price,
    );

    vault.apply_post_capture(post_capture.checkpoint(), preexisting_change.net_funding(local_change));

    post_capture
}

/// `synchronize` for a priced operation, which builds on the checkpoint and so
/// must not run on a venue the vault refused to adopt: an interval the
/// classifier could not explain aborts here instead of being reported.
fun synchronize_or_fail<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
): CapturedSnapshot {
    let capture = vault.synchronize(account, registry, clearing_house, base_oracle, collateral_oracle, clock);
    vault.venue().checkpoint().assert_unchanged(&capture.checkpoint());

    capture
}

// --- Shutdown ---

/// The venue's settlement of a closed market is not a venue order or a
/// stale-price fallback. A paused market admits no funding update or
/// settlement, so the stored checkpoint is reconciled with the one read here
/// without a venue call, and the venue's settlement prices, which its admin
/// enables only after closing the market, price the close.
fun unwind_settlement<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
) {
    let binding = vault.venue().binding();
    let before = binding.capture_checkpoint(
        account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    before.assert_no_orders();
    let (enabled, base_price, collateral_price) = clearing_house.settlement_valuation_prices();
    assert_settlement_valuation(
        enabled, base_price, base_price.is_neg(), collateral_price, collateral_price.is_neg(),
    );

    let preexisting_change = vault.venue().checkpoint().classify_preexisting(&before);
    vault.apply_post_capture(before, preexisting_change);

    clearing_house.close_position_at_settlement_prices(account, &vector[]);
    let after = binding.capture_checkpoint(
        account, registry, clearing_house, base_oracle, collateral_oracle,
    );

    vault.complete_unwind(before, after, 0, option::none());
}

/// One bounded unwind step on a live market: synchronize funding and the
/// checkpoint exactly as every priced operation does, then place up to
/// `max_active_orders` close-only orders under the bound the time since
/// shutdown began admits, proving each fill against the checkpoint before the
/// next. A venue the stored
/// checkpoint cannot explain is reported as drift and adopted: shutdown closes
/// what the venue holds, whatever moved it there.
fun unwind_market<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<Collateral> {
    let capture = vault.synchronize(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle, clock,
    );
    let (terms, remaining, before) = vault.unwind_terms(&capture, clock.timestamp_ms());

    let binding = vault.venue().binding();
    let (clearing_house, after, order_count, filled_quote) = vault.close_orders(
        account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, &terms, before, remaining, clock, ctx,
    );

    vault.complete_unwind(before, after, order_count, option::some(filled_quote));

    clearing_house
}

/// The venue must have enabled settlement with two positive, nonzero prices.
fun assert_settlement_valuation(
    enabled: bool,
    base_price: u256,
    base_negative: bool,
    collateral_price: u256,
    collateral_negative: bool,
) {
    assert!(
        enabled && base_price != 0 && collateral_price != 0 && !base_negative && !collateral_negative,
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );
}

/// Advances terminal checkpoint/event state only after an attributable close has completed.
fun complete_unwind<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    before: Checkpoint,
    after: Checkpoint,
    order_count: u64,
    filled_quote: Option<u256>,
) {
    vault.state().assert_unwinding();
    if (filled_quote.is_none()) {
        assert!(order_count == 0, blast_boosts_aftermath::errors::terminal_venue_unsettled!());
        before.assert_direct_settlement_checkpoint(&after);
    } else {
        assert!(
            order_count > 0 && order_count <= constants::max_active_orders!(),
            blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
        );
    };

    vault.venue_mut().replace_checkpoint(after);

    events::unwind_progress<Product>(vault.id(), before, after, order_count, filled_quote);
}

/// Settles the core on the proven withdrawal, then seals the recovered coin as
/// holder cash under the final checkpoint, whose allocated collateral is the
/// raw sub-atomic remainder the venue could not release.
fun complete_finalization<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    recovered: Coin<Collateral>,
) {
    let (total_share_supply, locked_shares) = (vault.total_share_supply(), vault.locked_shares());
    let eligible = vault.state_mut().finalize_shutdown(total_share_supply, locked_shares);

    let recovered_amount = recovered.value();
    vault.seal_terminal_cash(recovered, eligible);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::shutdown_finalized<Product>(
        vault.id(), recovered_amount, eligible, checkpoint, checkpoint.allocated_collateral(),
    );
}

// === Test-Only Functions ===

#[test_only]
public fun emit_vault_initialized_for_testing<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    seed_amount: u64,
    seed_shareholder_nav: u64,
    seed_venue_equity: u64,
    position_base: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
) {
    vault.emit_vault_initialized(
        seed_amount, seed_shareholder_nav, seed_venue_equity, position_base, lot_size, position_side, position_imr,
    );
}

#[test_only]
public fun complete_mint_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: MintPlan<Product>,
    deposit: u64,
    after: PositionObservation,
    checkpoint: Checkpoint,
    now_at_ms: u64,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    vault.complete_mint(plan, deposit, after, checkpoint, now_at_ms, ctx)
}

#[test_only]
public fun settle_redemption_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RedemptionPlan<Product>,
    shares: &Coin<BlastBoost<Product>>,
    after_sell: PositionObservation,
    now_at_ms: u64,
): (u64, u64, u64, u64) {
    vault.settle_redemption(plan, shares, after_sell, now_at_ms)
}

#[test_only]
public fun complete_redemption_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    shares: Coin<BlastBoost<Product>>,
    cash: Coin<Collateral>,
    net: u64,
    admin: u64,
    fee: u64,
    reserve_fee: u64,
    checkpoint: Checkpoint,
    ctx: &mut TxContext,
): Coin<Collateral> {
    vault.complete_redemption(shares, cash, net, admin, fee, reserve_fee, checkpoint, ctx)
}

#[test_only]
public fun pay_partner_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    partner: &Partner,
    admin_cash_before: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    vault.pay_partner(partner, admin_cash_before, clock, ctx);
}

#[test_only]
public fun complete_rebalance_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RebalancePlan<Product>,
    checkpoint: Checkpoint,
) {
    vault.complete_rebalance(plan, checkpoint);
}

#[test_only]
public fun complete_donation_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    after: PositionObservation,
    checkpoint: Checkpoint,
    amount: u64,
    now_at_ms: u64,
) {
    vault.complete_donation(after, checkpoint, amount, now_at_ms);
}

#[test_only]
public fun assert_initialization_inputs_for_testing(
    collateral_decimals: u8,
    market_scaling_factor: u256,
    seed_amount: u64,
    seed_reserve: u64,
) {
    assert_initialization_inputs(collateral_decimals, market_scaling_factor, seed_amount, seed_reserve);
}

#[test_only]
public fun assert_position_imr_for_testing(is_negative: bool) {
    assert_position_imr_sign(is_negative);
}

#[test_only]
public fun assert_position_imr_unchanged_for_testing(
    final_is_negative: bool,
    final_imr: u256,
    position_imr: u256,
) {
    assert_position_imr_unchanged_decoded(final_is_negative, final_imr, position_imr);
}

#[test_only]
public fun assert_deadline_for_testing(now_at_ms: u64, deadline_at_ms: u64) { assert_deadline(now_at_ms, deadline_at_ms); }

#[test_only]
#[allow(lint(prefer_mut_tx_context))]
public fun assert_rebalance_gas_price_for_testing<Product>(plan: &RebalancePlan<Product>, ctx: &TxContext) {
    plan.assert_gas_price(ctx);
}

#[test_only]
public fun assert_settlement_valuation_for_testing(
    enabled: bool,
    base_price: u256,
    base_negative: bool,
    collateral_price: u256,
    collateral_negative: bool,
) {
    assert_settlement_valuation(enabled, base_price, base_negative, collateral_price, collateral_negative);
}

#[test_only]
public fun apply_post_capture_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    change: CheckpointChange,
) {
    vault.apply_post_capture(checkpoint, change);
}

#[test_only]
public fun apply_post_captures_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    preexisting_change: CheckpointChange,
    local_change: CheckpointChange,
) {
    vault.apply_post_capture(checkpoint, preexisting_change.net_funding(local_change));
}

#[test_only]
public fun complete_unwind_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    before: Checkpoint,
    after: Checkpoint,
    order_count: u64,
    filled_quote: Option<u256>,
) {
    vault.complete_unwind(before, after, order_count, filled_quote);
}

#[test_only]
public fun complete_finalization_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    recovered: Coin<Collateral>,
) {
    vault.complete_finalization(checkpoint, recovered);
}

// === Imports ===

use authority_cap::authority::{ADMIN, AuthorityCap};

use blast_admin::blast_acl::AdminWitness;

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    checkpoint::{Checkpoint, CheckpointChange},
    constants,
    events,
    orders,
    blast_boosts_aftermath::Protocol,
    snapshot::{Self, CapturedSnapshot},
    vault::{Vault, VaultIssuance},
    venue_account::{Self, Binding},
};

// The order and snapshot operations take the vault, its binding, the issuance
// or the market first and read as their methods here; their modules sit above
// the types' own, so the aliases stay local to the driver.
use fun orders::close_orders as Vault.close_orders;

use fun orders::fill_orders as Vault.fill_orders;

use fun orders::increasing_terms as Vault.increasing_terms;

use fun orders::live_venue_fee_bps as ClearingHouse.live_venue_fee_bps;

use fun orders::rebalance_orders as Vault.rebalance_orders;

use fun orders::reducing_terms as Vault.reducing_terms;

use fun orders::seed_position as Issuance.seed_position;

use fun orders::unwind_terms as Vault.unwind_terms;

use fun snapshot::capture as Binding.capture;

use fun snapshot::capture_checkpoint as Binding.capture_checkpoint;

use blast_boosts_core::{
    blast_boosts_core::RiskAdmin,
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide},
    state::{ActivePosition, Issuance, MintPlan, RebalancePlan, RedemptionPlan},
};

use blast_partners::blast_partners::{Self as partners, Partner};

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign reads as a method here.
use fun ifixed::is_neg as u256.is_neg;

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{
    account::{Self as account, Account, AccountSharePolicy},
    authority::ACCOUNT,
    clearing_house::ClearingHouse,
    market,
    registry::Registry,
};

use sui::{clock::Clock, coin::Coin, coin_registry::Currency};

use fun apply_post_capture as Vault.apply_post_capture;

use fun assert_position_imr_unchanged as ClearingHouse.assert_position_imr_unchanged;

use fun complete_donation as Vault.complete_donation;

use fun complete_finalization as Vault.complete_finalization;

use fun complete_mint as Vault.complete_mint;

use fun assert_rebalance_gas_price as RebalancePlan.assert_gas_price;

use fun complete_rebalance as Vault.complete_rebalance;

use fun complete_redemption as Vault.complete_redemption;

use fun complete_unwind as Vault.complete_unwind;

use fun emit_vault_initialized as Vault.emit_vault_initialized;

use fun fund_mint as Vault.fund_mint;

use fun fund_venue_account as Account.fund_venue_account;

use fun mint as Vault.mint;

use fun open_venue_account as Registry.open_venue_account;

use fun pay_partner as Vault.pay_partner;

use fun redeem as Vault.redeem;

use fun settle_net_funding as Vault.settle_net_funding;

use fun settle_redemption as Vault.settle_redemption;

use fun synchronize as Vault.synchronize;

use fun synchronize_or_fail as Vault.synchronize_or_fail;

use fun unwind_market as Vault.unwind_market;

use fun unwind_settlement as Vault.unwind_settlement;

use fun snapshot::capture_order_capacity as Binding.capture_order_capacity;
