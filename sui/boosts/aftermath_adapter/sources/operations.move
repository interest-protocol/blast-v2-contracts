// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Atomic Aftermath operations for adapter-owned leverage Vaults.
module blast_boosts_aftermath::operations;

// === Public Types ===

/// Linear custody of the redeemed shares until the payout is proved to have left the venue.
public struct RedemptionReceipt<phantom Product> {
    shares: Balance<BlastBoost<Product>>,
    net: u64,
    admin: u64,
    fee: u64,
    reserve_fee: u64,
    after_sell_checkpoint: Checkpoint,
}

// === Public Functions ===

/// Seeds one issuance on the venue and returns its activated Vault, which the
/// same transaction must pass to `vault::share`.
///
/// Direction and size come only from the immutable core policy; the caller
/// chooses no order parameter.
/// Every external value is either retained in the Vault, shared, or consumed.
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
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    seed: Coin<Collateral>,
    seed_reserve: u64,
    position_imr: u256,
    clock: &Clock,
    ctx: &mut TxContext,
): Vault<Product, Collateral> {
    protocol.assert_current();
    let terms = issuance.issuance();
    let position_side = terms.side();
    let seed_amount = seed.value();
    assert_initialization_inputs(currency.decimals(), seed_amount, seed_reserve);
    assert_position_imr(position_imr);

    let (mut account, share_policy, admin_cap, binding) =
        open_venue_account(registry, &clearing_house, base_oracle, collateral_oracle, ctx);
    fund_venue_account(&mut account, &admin_cap, registry, &mut clearing_house, seed, position_imr);

    clearing_house = orders::seed_position(
        terms, &mut account, &admin_cap, &binding, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, seed_reserve, clock, ctx,
    );

    clearing_house.settle_position_funding(collateral_oracle, binding.account_number(), clock);
    let (final_observation, checkpoint) = snapshot::capture(
        &binding, &account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    assert_position_imr_unchanged(&clearing_house, binding.account_number(), position_imr);
    let venue_account = venue_account::new(binding, checkpoint, admin_cap);
    // BLAST_ACTIVATION_BOUNDARY_A1
    let (vault, seed_nav, seeded) = issuance.activate(
        final_observation, seed_reserve, venue_account, clock.timestamp_ms(), ctx,
    );
    // BLAST_ACTIVATION_BOUNDARY_A2
    account.consume_policy_and_share_account(share_policy);
    // BLAST_ACTIVATION_BOUNDARY_A3
    clearing_house.share();
    // BLAST_ACTIVATION_BOUNDARY_A4
    emit_vault_initialized<Product, Collateral>(
        &vault, seed_amount, seed_nav, seeded.equity(), seeded.base(), seeded.lot_size(), position_side, position_imr,
    );
    // BLAST_ACTIVATION_BOUNDARY_A5

    vault
}

/// Exchanges exact bound collateral for native leverage shares in one atomic operation.
/// Policy fixes direction and whole-lot size; partial sessions must complete the aggregate.
public fun mint<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    cash: Coin<Collateral>,
    minimum_shares: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    protocol.assert_current();
    let deposit = cash.value();
    assert!(deposit > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.state().assert_user_fee_limit(true, maximum_fee_bps);

    let (before, before_checkpoint) = synchronize(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&before_checkpoint);

    let plan = vault.state().prepare_mint(before, deposit, vault.total_share_supply(), minimum_shares, clock.timestamp_ms());
    let terms = orders::active_terms(vault, false, plan.mint_position());

    let binding = vault.venue().binding();
    let checkpoint = fund_mint(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        cash, plan.admin_fee(), &before_checkpoint, ctx,
    );

    let (clearing_house, checkpoint) = orders::fill_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, checkpoint, terms, plan.base_to_buy(), clock, ctx,
    );

    let (after, final_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    checkpoint.assert_deposit_checkpoint(&final_checkpoint, 0);
    let shares = complete_mint<Product, Collateral>(vault, plan, deposit, after, final_checkpoint, clock.timestamp_ms(), ctx);
    clearing_house.share();

    shares
}

/// Burns native shares only after their proportional close and exact collateral payout.
/// Entry-quote and realized PnL use authenticated post-session state, never an invented formula.
public fun redeem<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    shares: Coin<BlastBoost<Product>>,
    minimum_collateral: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    protocol.assert_current();
    assert!(shares.value() > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.state().assert_user_fee_limit(false, maximum_fee_bps);

    let (before, checkpoint) = synchronize(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&checkpoint);

    let plan = vault.state().prepare_redemption(before, shares.value(), vault.total_share_supply(), minimum_collateral, clock.timestamp_ms());
    let terms = orders::active_terms(vault, true, plan.redemption_position());

    let binding = vault.venue().binding();
    let (mut clearing_house, checkpoint) = orders::fill_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, checkpoint, terms, plan.base_to_sell(), clock, ctx,
    );

    let (after_sell, after_sell_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    checkpoint.assert_deposit_checkpoint(&after_sell_checkpoint, 0);
    let receipt = seal_redemption_receipt(vault, plan, shares, after_sell, after_sell_checkpoint, clock.timestamp_ms());
    let cash = vault.venue().withdraw(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        receipt.redemption_cash_required(), clock, ctx,
    );
    let final_checkpoint = snapshot::capture_checkpoint(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
    );
    receipt.after_sell_checkpoint.assert_withdrawal_checkpoint(&final_checkpoint, receipt.redemption_cash_required());
    let cash = complete_redemption(vault, receipt, cash, final_checkpoint, ctx);
    clearing_house.share();

    cash
}

/// Permissionless, policy-sized maintenance with no caller reward or trade parameters.
public fun rebalance<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol.assert_current();

    let (before, checkpoint) = synchronize(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&checkpoint);

    let mut plan = vault.state().prepare_rebalance(before, orders::live_venue_fee_bps(&clearing_house), clock.timestamp_ms());
    let terms = orders::active_terms(vault, !vault.state().next_rebalance_order(&plan).is_increase(), plan.rebalance_position());
    let binding = vault.venue().binding();

    let (clearing_house, checkpoint) = orders::rebalance_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, &binding, &terms, &mut plan, checkpoint, clock, ctx,
    );

    complete_rebalance<Product, Collateral>(vault, plan, checkpoint);
    clearing_house.share();
}

/// A keeper's dry run of `rebalance`: whether the live position sits outside the band.
///
/// Reads everything `rebalance` reads and asks the core the same question, so it
/// aborts where `rebalance` would abort before its first order: unresolved venue
/// drift, or an observation the price policy refuses. It does not settle funding
/// first, so a due settlement can move the answer by that amount when the real
/// call runs; intended for `dev_inspect`, not for on-chain gating.
public fun needs_rebalance<Product, Collateral>(
    vault: &Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
): bool {
    protocol.assert_current();

    let (observation, checkpoint) = snapshot::capture(
        &vault.venue().binding(), account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&checkpoint);

    vault.state().needs_rebalance(observation, clock.timestamp_ms())
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
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    cash: Coin<Collateral>,
    clock: &Clock,
) {
    protocol.assert_current();
    let amount = cash.value();
    assert!(amount > 0, blast_boosts_aftermath::errors::zero_amount!());

    let before_checkpoint = synchronize(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_checkpoint();
    vault.venue().checkpoint().assert_unchanged(&before_checkpoint);

    vault.venue().deposit(account, registry, cash);
    let (after, checkpoint) = snapshot::capture(
        &vault.venue().binding(), account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    complete_donation(vault, after, checkpoint, amount, clock.timestamp_ms());
}

/// Reconciles one bound Aftermath checkpoint and persists objective health.
///
/// Any caller may submit the immutable bound objects and exact Pyth updates.
/// Source or identity authentication failures abort. Authenticated economic
/// faults preserve lifecycle; unresolved external changes preserve the accepted
/// economic checkpoint and emit only a novel diagnostic observation.
public fun sync_health<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
) {
    protocol.assert_current();

    let _ = synchronize(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_checkpoint();
}

/// Permissionless bounded close-only progress, never caller-sized or dependent on positive NAV.
public fun unwind<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol.assert_current();

    if (clearing_house.is_frozen()) {
        unwind_frozen(vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle);
    } else {
        clearing_house = unwind_market(
            vault, account, registry, clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock, ctx,
        );
    };
    clearing_house.share();
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

    let binding = vault.venue().binding();
    let before = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    let amount = before.recoverable_terminal_cash();
    let recovered = if (amount == 0) {
        sui::coin::zero(ctx)
    } else {
        vault.venue().withdraw(
            account, registry, clearing_house, base_oracle, collateral_oracle, amount, clock, ctx,
        )
    };
    let after = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );

    complete_finalization(vault, before.terminal_withdrawal(after, recovered));
}

// === Private Functions ===

// --- Initialization ---

fun assert_initialization_inputs(collateral_decimals: u8, seed_amount: u64, seed_reserve: u64) {
    assert!(
        collateral_decimals == constants::collateral_decimals!(),
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
/// the exact venue objects this activation was called with.
fun open_venue_account<Collateral>(
    registry: &mut Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    ctx: &mut TxContext,
): (Account<Collateral>, AccountSharePolicy, AuthorityCap<ACCOUNT, ADMIN>, Binding) {
    let (account, share_policy, admin_cap) = account::create_account<Collateral>(registry, ctx);
    let binding = venue_account::new_binding(
        object::id(&account),
        account.account_id(),
        object::id(registry),
        object::id(clearing_house),
        object::id(base_oracle),
        object::id(collateral_oracle),
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
    clearing_house.allocate_collateral(admin_cap, account, seed_amount);
    clearing_house.create_market_position(admin_cap, account);
    clearing_house.set_position_initial_margin_ratio(admin_cap, account, position_imr);
}

/// The margin ratio set before the seed orders must survive them unchanged.
fun assert_position_imr_unchanged<Collateral>(
    clearing_house: &ClearingHouse<Collateral>,
    account_number: u64,
    position_imr: u256,
) {
    let final_imr = clearing_house.position(account_number).initial_margin_ratio();
    assert!(
        !final_imr.is_neg() && final_imr == position_imr,
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

fun assert_deadline(now_ms: u64, deadline: u64) {
    assert!(now_ms <= deadline, blast_boosts_aftermath::errors::deadline_expired!());
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
    vault.retain_admin_cash(cash.split(admin_fee, ctx));
    let venue_deposit = cash.value();
    vault.venue().deposit(account, registry, cash);
    vault.venue().allocate(account, clearing_house, venue_deposit);

    let funded = snapshot::capture_checkpoint(
        &vault.venue().binding(), account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    before.assert_allocated_deposit_checkpoint(&funded, venue_deposit);

    funded
}

// --- Completion ---

/// Commits native mint effects only after the orchestration proved its venue checkpoint.
fun complete_mint<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: MintPlan<Product>,
    deposit: u64,
    after: PositionObservation,
    checkpoint: Checkpoint,
    now_ms: u64,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    let (amount, contribution, fee, admin, reserve_fee) = vault.state_mut().complete_mint(plan, after, now_ms);

    let shares = vault.mint_shares(amount, ctx);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::minted<Product>(
        vault.id(), deposit, shares.value(), contribution, fee, admin, reserve_fee,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(),
        vault.total_share_supply(), checkpoint,
    );

    shares
}

/// Holds the actual input coin across payout instead of accepting a numerical burn promise.
fun seal_redemption_receipt<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RedemptionPlan<Product>,
    shares: Coin<BlastBoost<Product>>,
    after_sell: PositionObservation,
    after_sell_checkpoint: Checkpoint,
    now_ms: u64,
): RedemptionReceipt<Product> {
    assert!(
        shares.value() == plan.redemption_shares(),
        blast_boosts_aftermath::errors::redemption_share_mismatch!(),
    );

    let (net, admin, fee, reserve_fee) = vault.state_mut().complete_redemption(plan, after_sell, now_ms);

    RedemptionReceipt { shares: shares.into_balance(), net, admin, fee, reserve_fee, after_sell_checkpoint }
}

/// Returns only the exact total collateral that must leave the venue before completion.
fun redemption_cash_required<Product>(self: &RedemptionReceipt<Product>): u64 {
    self.net + self.admin
}

/// Completes custody after the public operation proves the withdrawal on the checkpoint:
/// retains the earned admin cash, burns the held shares, and accepts the checkpoint.
fun complete_redemption<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    receipt: RedemptionReceipt<Product>,
    mut cash: Coin<Collateral>,
    checkpoint: Checkpoint,
    ctx: &mut TxContext,
): Coin<Collateral> {
    let RedemptionReceipt { shares, net, admin, fee, reserve_fee, after_sell_checkpoint: _ } = receipt;
    assert!(cash.value() == net + admin, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());

    vault.retain_admin_cash(cash.split(admin, ctx));
    let burned = vault.burn_redeemed_shares(shares.into_coin(ctx));
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::redeemed<Product>(
        vault.id(), burned, net, fee, admin, reserve_fee,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.total_share_supply(), checkpoint,
    );

    cash
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
    now_ms: u64,
) {
    vault.venue().checkpoint().assert_deposit_checkpoint(&checkpoint, amount);

    vault.state_mut().donate(after, amount, now_ms);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::donated<Product>(vault.id(), amount, vault.state().maintenance_reserve(), checkpoint);
}

// --- Funding ---

/// Applies the complete Blast-owned post-capture synchronization phase.
fun apply_post_capture<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    preexisting_change: CheckpointChange,
    local_change: CheckpointChange,
) {
    let stored_checkpoint = *vault.venue().checkpoint();
    let net = preexisting_change.net_funding(local_change);
    let checkpoint_clean = net.is_clean();
    let (absorbed, uncovered, restored) = settle_net_funding(vault, &net);
    let reserve_after = vault.state().maintenance_reserve();

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
/// build on it without reading the venue again.
fun synchronize<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
): CapturedSnapshot {
    vault.state().assert_can_sync();

    let binding = vault.venue().binding();
    let stored_checkpoint = *vault.venue().checkpoint();
    binding.update_funding_when_due(clearing_house, base_oracle, clock);
    let (pre_checkpoint, collateral_price) = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).funding_probe();
    let funding_candidate = venue_account::funding_candidate(clearing_house, account);

    clearing_house.settle_position_funding(collateral_oracle, account.account_id(), clock);

    let post_capture = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let (preexisting_change, local_change) = stored_checkpoint.classify_sync_changes(
        &pre_checkpoint, &post_capture.checkpoint(), funding_candidate, collateral_price,
    );
    apply_post_capture(vault, post_capture.checkpoint(), preexisting_change, local_change);

    post_capture
}


// --- Shutdown ---

/// The venue's direct frozen settlement is not a market order or a stale-price fallback.
fun unwind_frozen<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
) {
    let binding = vault.venue().binding();
    let before = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    before.assert_no_orders();
    let (enabled, base_price, collateral_price) = clearing_house.settlement_valuation_prices();
    assert!(
        enabled && base_price != 0 && collateral_price != 0
            && !base_price.is_neg() && !collateral_price.is_neg(),
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );

    clearing_house.close_position_at_settlement_prices(account, &vector[]);
    let after = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );

    complete_unwind(vault, before, option::none(), after, 0, option::none());
}

/// One bounded unwind step on a live market: settle funding, then place up to
/// `max_active_orders` close-only orders under the emergency bound, proving
/// each fill against the checkpoint before the next.
fun unwind_market<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<Collateral> {
    let binding = vault.venue().binding();
    binding.update_funding_when_due(&mut clearing_house, base_oracle, clock);
    let capture = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let collateral_fixed = capture.collateral_fixed();
    let (terms, remaining, before) = orders::unwind_terms(vault, capture, clock.timestamp_ms());

    let funded = settle_funding_for_unwind(
        &binding, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        &before, collateral_fixed, clock,
    );

    let (clearing_house, after, order_count, filled_quote) = orders::close_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, &terms, funded, remaining, clock, ctx,
    );

    complete_unwind(vault, before, option::some(funded), after, order_count, option::some(filled_quote));

    clearing_house
}

/// Settles the account's funding on the venue and proves the checkpoint moved
/// only by the funding the venue's own formula predicted. Returns the settled checkpoint.
fun settle_funding_for_unwind<Collateral>(
    binding: &Binding,
    account: &Account<Collateral>,
    registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    before: &Checkpoint,
    collateral_fixed: u256,
    clock: &Clock,
): Checkpoint {
    let candidate = venue_account::funding_candidate(clearing_house, account);
    clearing_house.settle_position_funding(collateral_oracle, account.account_id(), clock);

    let funded = snapshot::capture_checkpoint(binding, account, registry, clearing_house, base_oracle, collateral_oracle);
    before.classify_change(&funded, candidate, collateral_fixed).assert_expected();

    funded
}

/// Advances terminal checkpoint/event state only after an attributable close has completed.
fun complete_unwind<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    before: Checkpoint,
    funded: Option<Checkpoint>,
    after: Checkpoint,
    order_count: u64,
    filled_quote: Option<u256>,
) {
    vault.state().assert_unwinding();
    after.assert_no_orders();
    if (filled_quote.is_none()) {
        assert!(funded.is_none() && order_count == 0, blast_boosts_aftermath::errors::terminal_venue_unsettled!());
        before.assert_direct_settlement_checkpoint(&after);
    } else {
        assert!(
            funded.is_some() && order_count > 0 && order_count <= constants::max_active_orders!(),
            blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
        );
    };

    vault.venue_mut().replace_checkpoint(after);

    events::unwind_progress<Product>(vault.id(), before, funded, after, order_count, filled_quote);
}

/// Settles the core on the proven withdrawal, then seals the recovered coin as
/// holder cash under the final checkpoint.
fun complete_finalization<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    withdrawal: TerminalWithdrawal<Collateral>,
) {
    let recovered_amount = withdrawal.recovered_amount();
    let (total_share_supply, locked_shares) = (vault.total_share_supply(), vault.locked_shares());
    let eligible = vault.state_mut().finalize_shutdown(total_share_supply, locked_shares);

    let (checkpoint, unrecoverable_collateral_raw) = vault.seal_terminal_cash(withdrawal, eligible);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::shutdown_finalized<Product>(
        vault.id(), recovered_amount, eligible, checkpoint, unrecoverable_collateral_raw,
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
    emit_vault_initialized(
        vault, seed_amount, seed_shareholder_nav, seed_venue_equity, position_base, lot_size, position_side, position_imr,
    );
}

#[test_only]
public fun complete_mint_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: MintPlan<Product>,
    deposit: u64,
    after: PositionObservation,
    checkpoint: Checkpoint,
    now_ms: u64,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    complete_mint(vault, plan, deposit, after, checkpoint, now_ms, ctx)
}

#[test_only]
public fun seal_redemption_receipt_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RedemptionPlan<Product>,
    shares: Coin<BlastBoost<Product>>,
    after_sell: PositionObservation,
    after_sell_checkpoint: Checkpoint,
    now_ms: u64,
): RedemptionReceipt<Product> {
    seal_redemption_receipt(vault, plan, shares, after_sell, after_sell_checkpoint, now_ms)
}

#[test_only]
public fun redemption_cash_required_for_testing<Product>(self: &RedemptionReceipt<Product>): u64 {
    self.redemption_cash_required()
}

#[test_only]
public fun complete_redemption_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    receipt: RedemptionReceipt<Product>,
    cash: Coin<Collateral>,
    checkpoint: Checkpoint,
    ctx: &mut TxContext,
): Coin<Collateral> {
    complete_redemption(vault, receipt, cash, checkpoint, ctx)
}

#[test_only]
public fun complete_rebalance_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    plan: RebalancePlan<Product>,
    checkpoint: Checkpoint,
) {
    complete_rebalance(vault, plan, checkpoint);
}

#[test_only]
public fun complete_donation_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    after: PositionObservation,
    checkpoint: Checkpoint,
    amount: u64,
    now_ms: u64,
) {
    complete_donation(vault, after, checkpoint, amount, now_ms);
}

#[test_only]
public fun assert_initialization_inputs_for_testing(collateral_decimals: u8, seed_amount: u64, seed_reserve: u64) {
    assert_initialization_inputs(collateral_decimals, seed_amount, seed_reserve);
}

#[test_only]
public fun assert_position_imr_for_testing(is_negative: bool) {
    assert_position_imr_sign(is_negative);
}

#[test_only]
public fun assert_deadline_for_testing(now_ms: u64, deadline: u64) { assert_deadline(now_ms, deadline); }

#[test_only]
public fun apply_post_capture_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    change: CheckpointChange,
) {
    apply_post_capture(vault, checkpoint, checkpoint::unchanged_change(), change);
}

#[test_only]
public fun apply_post_captures_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    checkpoint: Checkpoint,
    preexisting_change: CheckpointChange,
    local_change: CheckpointChange,
) {
    apply_post_capture(vault, checkpoint, preexisting_change, local_change);
}

#[test_only]
public fun complete_unwind_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    before: Checkpoint,
    funded: Option<Checkpoint>,
    after: Checkpoint,
    order_count: u64,
    filled_quote: Option<u256>,
) {
    complete_unwind(vault, before, funded, after, order_count, filled_quote);
}

#[test_only]
public fun complete_finalization_for_testing<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    withdrawal: TerminalWithdrawal<Collateral>,
) {
    complete_finalization(vault, withdrawal);
}

// === Imports ===

use authority_cap::authority::{ADMIN, AuthorityCap};

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    checkpoint::{Self, Checkpoint, CheckpointChange, TerminalWithdrawal},
    constants,
    events,
    orders,
    protocol::Protocol,
    snapshot::{Self, CapturedSnapshot},
    vault::{Vault, VaultIssuance},
    venue_account::{Self, Binding},
};

use blast_boosts_core::{
    observation::{Self, PositionObservation},
    policy::{Self, PositionSide},
    state::{ActivePosition, Issuance, MintPlan, RebalancePlan, RedemptionPlan},
};

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

use pyth::price_info::PriceInfoObject;

use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency};
