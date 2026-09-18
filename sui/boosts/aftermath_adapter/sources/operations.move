// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Atomic Aftermath operations for adapter-owned leverage Vaults.
module blast_boosts_aftermath::operations;

// `unwind_base_decoded` takes the position already decoded from IFixed; the
// pinned `ifixed` port aborts under test, so the pure check is exercised
// from fixtures through it.

// === Constants ===

/// Maximum market-order calls permitted in one atomic initialization session.
const MAX_INITIALIZATION_ORDERS: u64 = 16;

/// Hard ceiling on venue market calls in one active atomic operation.
const MAX_ACTIVE_ORDERS: u64 = 16;

// === Public Types ===

/// The sealed terms every order of one operation is placed and proved under.
/// Package-internal; Move has no private structs.
public struct OrderTerms has copy, drop {
    is_ask: bool,
    reduce_only: bool,
    max_order_notional: u64,
    lot_size: u64,
    base_price: u64,
    collateral_price: u64,
}

/// What the venue reported about one whole-lot market order, already checked
/// against the order cap and the lot: the base atoms filled, the raw signed
/// base and quote the session moved, and the execution price to prove against
/// the sealed oracle.
public struct Fill has copy, drop {
    filled: u64,
    filled_base: u256,
    filled_quote: u256,
    executed: u64,
    is_ask: bool,
    reduce_only: bool,
}

/// Linear custody of the redeemed shares until the payout is proved to have left the venue.
public struct RedemptionReceipt<phantom Product> {
    shares: Balance<BlastBoost<Product>>,
    net: u64,
    admin: u64,
    fee: u64,
    reserve_fee: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    unwound_checkpoint: Checkpoint,
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
    issuance: VaultIssuance<Product>,
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
): Vault<Product> {
    protocol.assert_current();
    let terms = issuance.issuance();
    let (position_side, max_order_notional) = (terms.side(), terms.max_order_notional());
    let seed_amount = seed.value();
    assert_initialization_inputs(currency.decimals(), seed_amount, seed_reserve);
    assert_position_imr(position_imr);

    let (mut account, share_policy, admin_cap, binding) =
        open_venue_account(registry, &clearing_house, base_oracle, collateral_oracle, ctx);
    fund_venue_account(&mut account, &admin_cap, registry, &mut clearing_house, seed, position_imr);

    update_funding_when_due(&binding, &mut clearing_house, base_oracle, clock);
    let (pre_observation, _) = snapshot::capture(
        &binding, &account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    let (target_notional, reference_base_price, collateral_price, lot_size) =
        terms.seed_terms(pre_observation, seed_reserve, clock.timestamp_ms());
    let orders = order_sizes(target_notional, max_order_notional, reference_base_price, collateral_price, lot_size);
    orders.do_ref!(|order| {
        terms.assert_order_notional_allowed(notional_for_base_up(*order, reference_base_price, collateral_price));
    });
    clearing_house = open_seed_position(
        terms, &mut account, &admin_cap, clearing_house, base_oracle, collateral_oracle,
        orders, position_side, reference_base_price, collateral_price, clock, ctx,
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
        final_observation, seed_reserve, currency.decimals(), venue_account, clock.timestamp_ms(), ctx,
    );
    // BLAST_ACTIVATION_BOUNDARY_A2
    account.consume_policy_and_share_account(share_policy);
    // BLAST_ACTIVATION_BOUNDARY_A3
    clearing_house.share();
    // BLAST_ACTIVATION_BOUNDARY_A4
    emit_vault_initialized<Product>(
        &vault, seed_amount, seed_nav, seeded.equity(), seeded.base(), seeded.lot_size(), position_side, position_imr,
    );
    // BLAST_ACTIVATION_BOUNDARY_A5

    vault
}

/// Exchanges exact bound collateral for native leverage shares in one atomic operation.
/// Policy fixes direction and whole-lot size; partial sessions must complete the aggregate.
public fun mint<Product, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    mut cash: Coin<Collateral>,
    minimum_shares: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    protocol.assert_current();
    vault.assert_collateral_type<_, Collateral>();
    let deposit = cash.value();
    assert!(deposit > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.state().assert_user_fee_limit(true, maximum_fee_bps);

    let (before, before_checkpoint) = synchronize(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&before_checkpoint);

    let plan = vault.state().prepare_mint(before, deposit, vault.share_supply(), minimum_shares, clock.timestamp_ms());
    let terms = active_terms(vault, false, plan.mint_position());

    vault.retain_admin_cash(cash.split(plan.admin_fee(), ctx));
    let venue_deposit = cash.value();
    vault.venue().deposit(account, registry, cash);
    vault.venue().allocate(account, &mut clearing_house, venue_deposit);
    let binding = vault.venue().binding();
    let checkpoint = snapshot::capture_checkpoint(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
    );
    before_checkpoint.assert_allocated_deposit_checkpoint(&checkpoint, venue_deposit);

    let (clearing_house, checkpoint) = fill_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, checkpoint, terms, plan.base_to_buy(), clock, ctx,
    );

    let (after, final_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    checkpoint.assert_deposit_checkpoint(&final_checkpoint, 0);
    let shares = complete_mint<Product, Collateral>(vault, plan, after, final_checkpoint, clock.timestamp_ms(), ctx);
    clearing_house.share();

    shares
}

/// Burns native shares only after their proportional close and exact collateral payout.
/// Entry-quote and realized PnL use authenticated post-session state, never an invented formula.
public fun redeem<Product, Collateral>(
    vault: &mut Vault<Product>,
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
    vault.assert_collateral_type<_, Collateral>();
    assert!(shares.value() > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.state().assert_user_fee_limit(false, maximum_fee_bps);

    let (before, checkpoint) = synchronize(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&checkpoint);

    let plan = vault.state().prepare_redemption(before, shares.value(), vault.share_supply(), minimum_collateral, clock.timestamp_ms());
    let terms = active_terms(vault, true, plan.redemption_position());

    let binding = vault.venue().binding();
    let (mut clearing_house, checkpoint) = fill_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        &binding, checkpoint, terms, plan.base_to_sell(), clock, ctx,
    );

    let (unwound, unwound_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    checkpoint.assert_deposit_checkpoint(&unwound_checkpoint, 0);
    let receipt = seal_redemption_receipt(vault, plan, shares, unwound, unwound_checkpoint, clock.timestamp_ms());
    let cash = vault.venue().withdraw(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        receipt.redemption_cash_required(), clock, ctx,
    );
    let final_checkpoint = snapshot::capture_checkpoint(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
    );
    receipt.unwound_checkpoint.assert_withdrawal_checkpoint(&final_checkpoint, receipt.redemption_cash_required());
    let cash = complete_redemption(vault, receipt, cash, final_checkpoint, ctx);
    clearing_house.share();

    cash
}

/// Permissionless, policy-sized maintenance with no caller reward or trade parameters.
public fun rebalance<Product, Collateral>(
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject, collateral_price_info: &PriceInfoObject,
    clock: &Clock, ctx: &mut TxContext,
) {
    protocol.assert_current();
    vault.assert_collateral_type<_, Collateral>();

    let (before, mut checkpoint) = synchronize(
        vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&checkpoint);

    let mut plan = vault.state().prepare_rebalance(before, live_venue_fee_bps(&clearing_house), clock.timestamp_ms());
    let terms = active_terms(vault, !vault.state().next_rebalance_order(&plan).is_increase(), plan.rebalance_position());
    let binding = vault.venue().binding();

    let mut index = 0;
    while (index < MAX_ACTIVE_ORDERS) {
        let order = vault.state().next_rebalance_order(&plan);
        if (order.order_base() == 0) break;

        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, &terms, order.order_base(), clock, ctx,
        );
        clearing_house = next_market;
        vault.state().assert_execution(order.is_wide(), terms.base_price, fill.executed);

        let (after, after_checkpoint) = snapshot::capture(
            &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock,
        ).into_observation();
        fill.assert_checkpoint(&checkpoint, &after_checkpoint);
        vault.state().accept_rebalance_fill(&mut plan, order, after, fill.filled, clock.timestamp_ms());

        checkpoint = after_checkpoint;
        index = index + 1;
    };

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
    vault: &Vault<Product>, protocol: &Protocol, account: &Account<Collateral>, registry: &Registry,
    clearing_house: &ClearingHouse<Collateral>, base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage, base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject, clock: &Clock,
): bool {
    protocol.assert_current();
    vault.assert_collateral_type<_, Collateral>();

    let (observation, checkpoint) = snapshot::capture(
        &vault.venue().binding(), account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).into_observation();
    vault.venue().checkpoint().assert_unchanged(&checkpoint);

    vault.state().needs_rebalance(observation, clock.timestamp_ms())
}

/// Deposits configured collateral into the active funding buffer without shares or fees.
public fun donate<Product, Collateral>(
    vault: &mut Vault<Product>,
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
    vault.assert_collateral_type<_, Collateral>();
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
    vault: &mut Vault<Product>,
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
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject, collateral_price_info: &PriceInfoObject,
    clock: &Clock, ctx: &mut TxContext,
) {
    protocol.assert_current();
    vault.assert_collateral_type<_, Collateral>();

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
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    clock: &Clock, ctx: &mut TxContext,
) {
    protocol.assert_current();
    vault.assert_collateral_type<_, Collateral>();

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

    complete_finalization(vault, recovered, before, after);
}

// === Package Functions ===

/// Emits activation facts read back from the resulting real Vault state.
public(package) fun emit_vault_initialized<Product>(
    vault: &Vault<Product>,
    seed_amount: u64,
    seed_shareholder_nav: u64,
    seed_venue_equity: u64,
    position_base: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
) {
    let binding = vault.venue().binding();

    events::vault_initialized<Product>(
        vault.id(),
        binding.account_object_id(),
        binding.account_number(),
        binding.registry_id(),
        binding.clearing_house_id(),
        binding.base_oracle_id(),
        binding.collateral_oracle_id(),
        binding.collateral_type(),
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

/// Commits native mint effects only after the orchestration proved its venue checkpoint.
public(package) fun complete_mint<Product, Collateral>(
    vault: &mut Vault<Product>, plan: MintPlan<Product>, after: PositionObservation,
    checkpoint: Checkpoint, now_ms: u64, ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    let deposit = plan.mint_deposit();
    let (shares, contribution, fee, admin, reserve_fee, fee_bps, admin_share_bps) =
        vault.complete_mint(plan, after, now_ms, ctx);

    vault.venue_mut().replace_checkpoint(checkpoint);

    events::minted<Product>(
        vault.id(), deposit, shares.value(), contribution, fee, admin, reserve_fee, fee_bps, admin_share_bps,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(),
        vault.share_supply(), checkpoint,
    );

    shares
}

/// Holds the actual input coin across payout instead of accepting a numerical burn promise.
public(package) fun seal_redemption_receipt<Product>(
    vault: &mut Vault<Product>, plan: RedemptionPlan<Product>, shares: Coin<BlastBoost<Product>>,
    unwound: PositionObservation, unwound_checkpoint: Checkpoint, now_ms: u64,
): RedemptionReceipt<Product> {
    assert!(
        shares.value() == plan.redemption_shares(),
        blast_boosts_aftermath::errors::redemption_share_mismatch!(),
    );

    let (fee_bps, admin_share_bps) = (plan.redemption_fee_bps(), plan.redemption_admin_share_bps());
    let (net, admin, fee, reserve_fee) = vault.state_mut().complete_redemption(plan, unwound, now_ms);

    RedemptionReceipt { shares: shares.into_balance(), net, admin, fee, reserve_fee, fee_bps, admin_share_bps, unwound_checkpoint }
}

/// Returns only the exact total collateral that must leave the venue before completion.
public(package) fun redemption_cash_required<Product>(self: &RedemptionReceipt<Product>): u64 {
    self.net + self.admin
}

/// Completes custody after the public operation proves the withdrawal on the checkpoint:
/// retains the earned admin cash, burns the held shares, and accepts the checkpoint.
public(package) fun complete_redemption<Product, Collateral>(
    vault: &mut Vault<Product>, receipt: RedemptionReceipt<Product>, mut cash: Coin<Collateral>,
    checkpoint: Checkpoint, ctx: &mut TxContext,
): Coin<Collateral> {
    let RedemptionReceipt {
        shares, net, admin, fee, reserve_fee, fee_bps, admin_share_bps, unwound_checkpoint: _,
    } = receipt;
    vault.assert_collateral_type<_, Collateral>();
    assert!(cash.value() == net + admin, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());

    vault.retain_admin_cash(cash.split(admin, ctx));
    let burned = vault.burn_redeemed_shares(shares.into_coin(ctx));
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::redeemed<Product>(
        vault.id(), burned, net, fee, admin, reserve_fee, fee_bps, admin_share_bps,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.share_supply(), checkpoint,
    );

    cash
}

/// Advances the sole economic checkpoint only after sealed maintenance has succeeded.
public(package) fun complete_rebalance<Product, Collateral>(
    vault: &mut Vault<Product>, plan: RebalancePlan<Product>, checkpoint: Checkpoint,
) {
    let (before_equity, after_equity, before_base, after_base, increase) = vault.state().complete_rebalance(plan);

    vault.venue_mut().replace_checkpoint(checkpoint);

    events::rebalanced<Product>(
        vault.id(), before_equity, after_equity, before_base, after_base, increase,
        vault.state().maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.share_supply(), checkpoint,
    );
}

/// Credits a donation the venue has taken: the raw checkpoint proves the exact
/// deposit, the core prices the position it left.
public(package) fun complete_donation<Product>(
    vault: &mut Vault<Product>, after: PositionObservation, checkpoint: Checkpoint, amount: u64, now_ms: u64,
) {
    vault.venue().checkpoint().assert_deposit_checkpoint(&checkpoint, amount);

    vault.state_mut().donate(after, amount, now_ms);
    vault.venue_mut().replace_checkpoint(checkpoint);

    events::donated<Product>(vault.id(), amount, vault.state().maintenance_reserve(), checkpoint);
}

/// Applies the complete Blast-owned post-capture synchronization phase.
public(package) fun apply_post_capture<Product>(
    vault: &mut Vault<Product>,
    checkpoint: Checkpoint,
    preexisting_change: CheckpointChange,
    local_change: CheckpointChange,
) {
    let stored_checkpoint = *vault.venue().checkpoint();
    let net = preexisting_change.net_funding(local_change);
    let checkpoint_clean = net.is_clean();
    let (absorbed, uncovered, restored, reserve_after) = if (net.has_funding()) {
        vault.settle_funding(net.is_cost(), net.amount())
    } else {
        (0, 0, 0, vault.state().maintenance_reserve())
    };

    if (checkpoint_clean) {
        vault.venue_mut().replace_checkpoint(checkpoint);
    } else {
        events::checkpoint_drifted<Product>(vault.id(), checkpoint);
    };

    // A zero-net interval still advances authenticated source identity and
    // needs a reducer-visible completed fact; identical retries remain quiet.
    if (checkpoint_clean && !snapshot::checkpoint_unchanged(&stored_checkpoint, &checkpoint)) {
        events::funding_settled<Product>(
            vault.id(), net.is_cost(), net.raw_amount(), net.amount(), absorbed, uncovered, restored,
            reserve_after, stored_checkpoint, checkpoint,
        );
    };
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

fun assert_position_imr_sign(negative: bool) {
    assert!(!negative, blast_boosts_aftermath::errors::initialization_imr_mismatch!());
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
        type_name::with_original_ids<Collateral>(),
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

/// Opens the seed position one policy-sized market order at a time.
///
/// Every session must fill its whole order at the sealed oracle price within
/// the ordinary slippage bound, post nothing, and touch no liquidation; each
/// actual fill is capped separately so admitted slippage cannot carry one
/// order past the live cap.
fun open_seed_position<Product, Collateral>(
    issuance: &Issuance<Product>,
    account: &mut Account<Collateral>,
    admin_cap: &AuthorityCap<ACCOUNT, ADMIN>,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    mut orders: vector<u64>,
    position_side: PositionSide,
    reference_base_price: u64,
    collateral_price: u64,
    clock: &Clock,
    ctx: &TxContext,
): ClearingHouse<Collateral> {
    let is_long = position_side == policy::long();
    let aftermath_order_side = opens_with_ask(position_side);

    while (!orders.is_empty()) {
        let order_base = orders.pop_back();
        let mut session = clearing_house.start_session(
            admin_cap, account, base_oracle, collateral_oracle, option::none(), clock, ctx,
        );
        session.place_market_order(aftermath_order_side, order_base, false);
        let (next_clearing_house, summary) = session.end_session(admin_cap, account, false, false);
        clearing_house = next_clearing_house;

        assert_session_result(
            is_long, order_base,
            summary.base_filled_bid(), summary.base_filled_ask(),
            summary.posted_orders(), summary.liquidated_size(),
            summary.liquidation_bad_debt(),
        );
        let executed = execution_price(summary.execution_price(aftermath_order_side), is_long);
        issuance.assert_execution(reference_base_price, executed);
        let (_, filled_quote) = summary.filled_base_and_quote(aftermath_order_side);
        issuance.assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));
    };

    clearing_house
}

/// The margin ratio set before the seed orders must survive them unchanged.
fun assert_position_imr_unchanged<Collateral>(
    clearing_house: &ClearingHouse<Collateral>, account_number: u64, position_imr: u256,
) {
    let final_imr = clearing_house.position(account_number).initial_margin_ratio();
    assert!(
        !final_imr.is_neg() && final_imr == position_imr,
        blast_boosts_aftermath::errors::initialization_imr_mismatch!(),
    );
}

fun assert_session_result(
    is_long: bool,
    expected_base: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
) {
    assert!(posted_orders == 0, blast_boosts_aftermath::errors::initialization_orders_posted!());
    assert!(liquidated_size == 0 && bad_debt == 0, blast_boosts_aftermath::errors::initialization_liquidation!());

    let expected_raw_base = (expected_base as u256) * constants::base_atom_to_ifixed_scale!();
    let fill_matches = if (is_long) {
        filled_bid == expected_raw_base && filled_ask == 0
    } else {
        filled_ask == expected_raw_base && filled_bid == 0
    };
    assert!(fill_matches, blast_boosts_aftermath::errors::initialization_fill_mismatch!());
}

fun initialization_order_count(target_base: u64, max_order_base: u64): u64 {
    assert!(max_order_base > 0, blast_boosts_aftermath::errors::invalid_initialization_order_size!());

    let count = target_base.div_ceil(max_order_base);
    assert!(
        count <= MAX_INITIALIZATION_ORDERS,
        blast_boosts_aftermath::errors::initialization_order_count_exceeded!(),
    );

    count
}

// --- Orders ---

fun assert_deadline(now_ms: u64, deadline: u64) {
    assert!(now_ms <= deadline, blast_boosts_aftermath::errors::deadline_expired!());
}

/// The terms of an active operation: direction from policy, the live cap, and the plan's sealed prices.
fun active_terms<Product>(vault: &Vault<Product>, reduce_only: bool, position: ActivePosition): OrderTerms {
    let (side, max_order_notional) = (vault.state().side(), vault.state().max_order_notional());
    let is_ask = if (reduce_only) { !opens_with_ask(side) } else { opens_with_ask(side) };

    OrderTerms {
        is_ask, reduce_only, max_order_notional,
        lot_size: position.lot_size(), base_price: position.base_price(), collateral_price: position.collateral_price(),
    }
}

/// Reads the market's taker fee and priority surcharge as one basis-point bound.
fun live_venue_fee_bps<Collateral>(clearing_house: &ClearingHouse<Collateral>): u64 {
    let params = clearing_house.market_params();

    venue_fee_bound(
        nonnegative_rate(params.taker_fee()),
        nonnegative_rate(market::resolve_priority_taker_fee(params.priority_taker_fee())),
    )
}

/// Aftermath's priority rate is an additional surcharge, not an alternative fee.
/// Negative rebates are ignored conservatively; callers provide no fee input.
fun venue_fee_bound(ordinary: u256, priority: u256): u64 {
    let one = constants::ifixed_one!();
    assert!(
        ordinary <= one && priority <= one && ordinary <= one - priority,
        blast_boosts_aftermath::errors::venue_fee_unusable!(),
    );

    ((ordinary + priority).div_ceil(constants::ifixed_per_basis_point!())) as u64
}

/// A venue rebate reads as a zero fee; the bound never credits execution.
fun nonnegative_rate(rate: u256): u256 {
    if (rate.is_neg()) { 0 } else { rate.abs() }
}

/// Whether opening this side is an ask on the Aftermath port: shorts sell to open, longs buy.
fun opens_with_ask(position_side: PositionSide): bool {
    position_side == policy::short()
}

fun order_sizes(
    target_notional: u64,
    max_order_notional: u64,
    base_price: u64,
    collateral_price: u64,
    lot_size: u64,
): vector<u64> {
    assert!(
        target_notional > 0 && max_order_notional > 0,
        blast_boosts_aftermath::errors::invalid_initialization_order_size!(),
    );

    let target_base = base_for_notional_down(target_notional, base_price, collateral_price, lot_size);
    let max_order_base = base_for_notional_down(max_order_notional, base_price, collateral_price, lot_size);
    assert!(
        target_base > 0 && max_order_base > 0,
        blast_boosts_aftermath::errors::invalid_initialization_order_size!(),
    );
    let order_count = initialization_order_count(target_base, max_order_base);

    let mut remaining = target_base;
    let mut orders = vector[];
    while (orders.length() < order_count) {
        let order_base = remaining.min(max_order_base);
        assert!(
            notional_for_base_up(order_base, base_price, collateral_price) <= max_order_notional,
            blast_boosts_aftermath::errors::normalization_overflow!(),
        );
        orders.push_back(order_base);
        remaining = remaining - order_base;
    };
    assert!(remaining == 0, blast_boosts_aftermath::errors::normalization_overflow!());

    orders
}

/// Bounds each next whole-lot request without re-rounding the sealed aggregate.
fun active_order_size(
    remaining: u64, max_order_notional: u64, base_price: u64, collateral_price: u64, lot_size: u64, index: u64,
): u64 {
    assert!(index < MAX_ACTIVE_ORDERS, blast_boosts_aftermath::errors::active_order_count_exceeded!());

    let maximum = base_for_notional_down(max_order_notional, base_price, collateral_price, lot_size);
    assert!(
        maximum > 0 && remaining > 0 && remaining % lot_size == 0,
        blast_boosts_aftermath::errors::active_fill_mismatch!(),
    );

    remaining.min(maximum)
}

/// The next whole-lot request: what remains, capped by the live order notional.
fun next_order_size(self: &OrderTerms, remaining: u64, index: u64): u64 {
    active_order_size(remaining, self.max_order_notional, self.base_price, self.collateral_price, self.lot_size, index)
}

/// Whole-lot base atoms worth at most `notional` at the oracle pair, rounding down.
fun base_for_notional_down(notional: u64, base_price: u64, collateral_price: u64, lot_size: u64): u64 {
    assert!(
        notional > 0 && base_price > 0 && collateral_price > 0 && lot_size > 0,
        blast_boosts_aftermath::errors::normalization_overflow!(),
    );

    let numerator = (notional as u256)
        .checked_mul(collateral_price as u256)
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!())
        .checked_mul(constants::collateral_to_base_scale!())
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let base = numerator / (base_price as u256);
    assert!(base <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    (base as u64) / lot_size * lot_size
}

/// Collateral atoms `base` is worth at the oracle pair, rounding up.
fun notional_for_base_up(base: u64, base_price: u64, collateral_price: u64): u64 {
    let numerator = (base as u256)
        .checked_mul(base_price as u256)
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let denominator = (collateral_price as u256)
        .checked_mul(constants::collateral_to_base_scale!())
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let notional = numerator.div_ceil(denominator);
    assert!(notional <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    notional as u64
}

/// Places every order of one active mint or redemption, proving each fill
/// against the sealed oracle and the checkpoint before the next.
///
/// Returns the market and the checkpoint the last fill left behind.
fun fill_orders<Product, Collateral>(
    vault: &Vault<Product>, account: &mut Account<Collateral>, registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    binding: &Binding, mut checkpoint: Checkpoint,
    terms: OrderTerms, mut remaining: u64, clock: &Clock, ctx: &TxContext,
): (ClearingHouse<Collateral>, Checkpoint) {
    let mut index = 0;
    while (remaining > 0) {
        let requested = terms.next_order_size(remaining, index);
        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, &terms, requested, clock, ctx,
        );
        clearing_house = next_market;
        vault.state().assert_execution(false, terms.base_price, fill.executed);

        let after_checkpoint = snapshot::capture_checkpoint(
            binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        );
        fill.assert_checkpoint(&checkpoint, &after_checkpoint);

        checkpoint = after_checkpoint;
        remaining = remaining - fill.filled;
        index = index + 1;
    };

    (clearing_house, checkpoint)
}

/// Places one whole-lot market order and verifies the venue's report of it.
///
/// The request is checked against the per-order cap before the call and the
/// actual fill after it, so admitted slippage cannot carry one order past the
/// live cap. Every operation loop places its orders through this step; only
/// the slippage bound it then proves against differs.
fun place_order<Product, Collateral>(
    vault: &Vault<Product>, account: &mut Account<Collateral>, clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    terms: &OrderTerms, requested: u64, clock: &Clock, ctx: &TxContext,
): (ClearingHouse<Collateral>, Fill) {
    let OrderTerms { is_ask, reduce_only, lot_size, base_price, collateral_price, .. } = *terms;
    vault.state().assert_order_notional_allowed(notional_for_base_up(requested, base_price, collateral_price));

    let (clearing_house, summary) = vault.venue().execute_order(
        account, clearing_house, base_oracle, collateral_oracle, is_ask, requested, reduce_only, clock, ctx,
    );
    let filled = active_fill(
        !is_ask, requested, lot_size,
        summary.base_filled_bid(), summary.base_filled_ask(),
        summary.posted_orders(), summary.liquidated_size(),
        summary.liquidation_bad_debt(),
    );
    let (filled_base, filled_quote) = summary.filled_base_and_quote(is_ask);
    let executed = execution_price(summary.execution_price(is_ask), !is_ask);
    vault.state().assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));

    (clearing_house, Fill { filled, filled_base, filled_quote, executed, is_ask, reduce_only })
}

/// Proves the checkpoint moved exactly as this fill did: an opening trade moves
/// base and quote, a reduction only base.
fun assert_checkpoint(self: &Fill, before: &Checkpoint, after: &Checkpoint) {
    let base = self.base_after(before.signed_base());

    if (self.reduce_only) {
        before.assert_reduction_checkpoint(after, base)
    } else {
        before.assert_trade_checkpoint(after, base, self.quote_after(before.signed_quote_notional()))
    }
}

/// The signed base the checkpoint must show after this fill.
fun base_after(self: &Fill, previous: u256): u256 {
    if (self.is_ask) { ifixed::sub(previous, self.filled_base) } else { ifixed::add(previous, self.filled_base) }
}

/// The signed quote notional the checkpoint must show after this fill.
fun quote_after(self: &Fill, previous: u256): u256 {
    if (self.is_ask) { ifixed::add(previous, self.filled_quote) } else { ifixed::sub(previous, self.filled_quote) }
}

/// Accepts a positive whole-lot fill toward a bounded atomic aggregate.
fun active_fill(
    is_bid: bool,
    requested_base: u64,
    lot_size: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
): u64 {
    assert!(posted_orders == 0, blast_boosts_aftermath::errors::active_orders_posted!());
    assert!(liquidated_size == 0 && bad_debt == 0, blast_boosts_aftermath::errors::active_liquidation!());

    let (filled, opposite) = if (is_bid) { (filled_bid, filled_ask) } else { (filled_ask, filled_bid) };
    assert!(
        opposite == 0 && filled > 0 && filled <= (requested_base as u256) * constants::base_atom_to_ifixed_scale!()
            && lot_size > 0 && filled % ((lot_size as u256) * constants::base_atom_to_ifixed_scale!()) == 0,
        blast_boosts_aftermath::errors::active_fill_mismatch!(),
    );

    (filled / constants::base_atom_to_ifixed_scale!()) as u64
}

/// Converts one session's actual filled quote into atomic collateral notional.
///
/// The fill is checked separately for every order so allowed execution
/// slippage cannot make an individual order exceed the live core cap.
fun actual_fill_notional(filled_quote: u256, collateral_price: u64): u64 {
    assert!(collateral_price > 0, blast_boosts_aftermath::errors::normalization_overflow!());

    let denominator = (collateral_price as u256)
        .checked_mul(constants::collateral_to_base_scale!())
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let notional = filled_quote.div_ceil(denominator);
    assert!(notional <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    notional as u64
}

fun execution_price(raw_price: u256, round_up: bool): u64 {
    normalize_execution_price(raw_price, round_up, raw_price.is_neg())
}

fun normalize_execution_price(raw_price: u256, round_up: bool, negative: bool): u64 {
    assert!(!negative, blast_boosts_aftermath::errors::normalization_overflow!());

    let down = raw_price / constants::base_atom_to_ifixed_scale!();
    let normalized = if (round_up && raw_price % constants::base_atom_to_ifixed_scale!() != 0) { down + 1 } else { down };
    assert!(normalized <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    normalized as u64
}

// --- Funding ---

/// Refreshes the venue's lazily updated cumulative funding rates when they are
/// due, immediately before a settlement the vault accepts.
///
/// Aftermath advances cumulative funding only when someone trades or calls
/// its permissionless `update_funding`; an idle market would otherwise leave
/// accrued funding out of the candidate, the settlement, and both captured
/// checkpoints. The guard reads the bound market's `funding_last_upd_ms` and
/// the frequency, the first element of `funding_params`, and makes no venue
/// call when the update is not due. The bound market and base oracle are
/// checked against the binding first, so the venue mutation never touches an
/// unbound object. `update_funding` reads the base price-feed
/// storage: the deployed bytecode routes it through
/// `market::try_update_funding`, which prices the premium against the base
/// index through `base_oracle_price_and_twap_price` and aborts on any other
/// storage. The classifier already treats stored-to-pre market-rate
/// advancement as the expected precursor of a local settlement, so the
/// aggregate net-funding rule and the funding event are unchanged.
fun update_funding_when_due<Collateral>(
    binding: &Binding,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    binding.assert_funding_update_inputs(object::id(clearing_house), object::id(base_oracle));

    let (funding_frequency_ms, _) = clearing_house.market_params().funding_params();
    let funding_last_upd_ms = clearing_house.market_state().funding_last_upd_ms();

    if (is_time_to_update_funding(clock.timestamp_ms(), funding_last_upd_ms, funding_frequency_ms)) {
        clearing_house.update_funding(base_oracle, clock);
    };
}

/// Returns whether the venue's cumulative funding is due for an update at `now_ms`.
///
/// Mirrors the pinned `market::is_time_to_update` bytecode exactly:
/// `now_ms >= next_funding_update_time_ms(funding_last_upd_ms, funding_frequency_ms)`.
/// The venue's own `try_update_fundings` repeats this check, so the guard only
/// decides whether the adapter spends a venue call; it never changes what the
/// venue would settle. A zero frequency is never due: the venue formula would
/// divide by it, and a market without a funding cadence has nothing to
/// refresh.
fun is_time_to_update_funding(now_ms: u64, funding_last_upd_ms: u64, funding_frequency_ms: u64): bool {
    funding_frequency_ms > 0
        && now_ms >= next_funding_update_time_ms(funding_last_upd_ms, funding_frequency_ms)
}

/// Returns the venue's next funding update instant: the start of the period
/// after the one containing `funding_last_upd_ms`, exactly as the pinned
/// `market::next_funding_update_time` computes it.
fun next_funding_update_time_ms(funding_last_upd_ms: u64, funding_frequency_ms: u64): u64 {
    funding_last_upd_ms - funding_last_upd_ms % funding_frequency_ms + funding_frequency_ms
}

/// The funding the venue would settle for this account at its current cumulative rates.
fun funding_candidate<Collateral>(clearing_house: &ClearingHouse<Collateral>, account: &Account<Collateral>): u256 {
    let (long_rate, short_rate) = clearing_house.market_state().cum_funding_rates();

    clearing_house.position(account.account_id()).calculate_position_funding_internal(long_rate, short_rate)
}

/// Settles due funding on the venue and reconciles the stored checkpoint with
/// what the venue shows now; returns that capture so a priced operation can
/// build on it without reading the venue again.
fun synchronize<Product, Collateral>(
    vault: &mut Vault<Product>, account: &Account<Collateral>, registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>, base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage, base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject, clock: &Clock,
): CapturedSnapshot {
    vault.state().assert_can_sync();

    let binding = vault.venue().binding();
    let stored_checkpoint = *vault.venue().checkpoint();
    update_funding_when_due(&binding, clearing_house, base_oracle, clock);
    let (pre_checkpoint, collateral_price) = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    ).funding_probe();
    let funding_candidate = funding_candidate(clearing_house, account);

    clearing_house.settle_position_funding(collateral_oracle, account.account_id(), clock);

    let post_capture = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let (preexisting_change, local_change) = classify_sync_changes(
        &stored_checkpoint, &pre_checkpoint, &post_capture.checkpoint(), funding_candidate, collateral_price,
    );
    apply_post_capture(vault, post_capture.checkpoint(), preexisting_change, local_change);

    post_capture
}

fun classify_sync_changes(
    stored: &Checkpoint,
    before: &Checkpoint,
    after: &Checkpoint,
    funding_candidate: u256,
    collateral_price: u256,
): (CheckpointChange, CheckpointChange) {
    let preexisting_change = if (snapshot::checkpoint_ready_for_settlement(stored, before)) {
        snapshot::unchanged_change()
    } else {
        snapshot::classify_preexisting_funding(stored, before)
    };
    let local_change = snapshot::classify_change(before, after, funding_candidate, collateral_price);

    (preexisting_change, local_change)
}

// --- Shutdown ---

/// The venue's direct frozen settlement is not a market order or a stale-price fallback.
fun unwind_frozen<Product, Collateral>(
    vault: &mut Vault<Product>, account: &mut Account<Collateral>, registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
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

/// Authenticates prices and isolates actual funding before up to sixteen policy-sized market closes.
fun unwind_market<Product, Collateral>(
    vault: &mut Vault<Product>, account: &mut Account<Collateral>, registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject, collateral_price_info: &PriceInfoObject,
    clock: &Clock, ctx: &TxContext,
): ClearingHouse<Collateral> {
    let binding = vault.venue().binding();
    update_funding_when_due(&binding, &mut clearing_house, base_oracle, clock);
    let capture = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let collateral_fixed = capture.collateral_fixed();
    let (side, max_order_notional, base_price, collateral_price) = vault.state().unwind_constraints(
        capture.base_price_observation(), capture.collateral_price_observation(), clock.timestamp_ms(),
    );
    let before = capture.into_checkpoint();
    before.assert_no_orders();
    let mut remaining = unwind_base(&before, side);

    let candidate = funding_candidate(&clearing_house, account);
    clearing_house.settle_position_funding(
        collateral_oracle, account.account_id(), clock,
    );
    let funded = snapshot::capture_checkpoint(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
    );
    snapshot::classify_change(&before, &funded, candidate, collateral_fixed).assert_expected();

    let terms = OrderTerms {
        is_ask: !opens_with_ask(side), reduce_only: true, max_order_notional,
        lot_size: funded.lot_size(), base_price, collateral_price,
    };
    let mut checkpoint = funded;
    let mut orders = 0;
    let mut filled_quote_total: u256 = 0;
    while (orders < MAX_ACTIVE_ORDERS && remaining > 0) {
        let requested = terms.next_order_size(remaining, orders);
        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, &terms, requested, clock, ctx,
        );
        clearing_house = next_market;
        vault.state().assert_execution(true, base_price, fill.executed);

        let after = snapshot::capture_checkpoint(
            &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        );
        fill.assert_checkpoint(&checkpoint, &after);
        after.assert_no_orders();

        remaining = remaining - fill.filled;
        checkpoint = after;
        filled_quote_total = filled_quote_total.checked_add(fill.filled_quote)
            .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
        orders = orders + 1;
    };

    complete_unwind(vault, before, option::some(funded), checkpoint, orders, option::some(filled_quote_total));

    clearing_house
}

/// Named IFixed decoding precedes exact base-atom and lot validation.
fun unwind_base(checkpoint: &Checkpoint, side: PositionSide): u64 {
    let base = checkpoint.signed_base();

    unwind_base_decoded(base.abs(), !base.is_neg(), checkpoint.lot_size(), side)
}

fun unwind_base_decoded(magnitude: u256, is_long: bool, lot_size: u64, side: PositionSide): u64 {
    assert!(
        lot_size > 0 && magnitude > 0
            && magnitude <= (std::u64::max_value!() as u256) * constants::base_atom_to_ifixed_scale!()
            && magnitude % ((lot_size as u256) * constants::base_atom_to_ifixed_scale!()) == 0
            && is_long == (side == policy::long()),
        blast_boosts_aftermath::errors::invalid_unwind_exposure!(),
    );

    (magnitude / constants::base_atom_to_ifixed_scale!()) as u64
}

/// Advances terminal checkpoint/event state only after an attributable close has completed.
fun complete_unwind<Product>(
    vault: &mut Vault<Product>, before: Checkpoint, funded: Option<Checkpoint>,
    after: Checkpoint, orders: u64, filled_quote: Option<u256>,
) {
    vault.state().assert_unwinding();
    after.assert_no_orders();
    if (filled_quote.is_none()) {
        assert!(funded.is_none() && orders == 0, blast_boosts_aftermath::errors::terminal_venue_unsettled!());
        before.assert_direct_settlement_checkpoint(&after);
    } else {
        assert!(
            funded.is_some() && orders > 0 && orders <= MAX_ACTIVE_ORDERS,
            blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
        );
    };

    vault.venue_mut().replace_checkpoint(after);

    events::unwind_progress<Product>(vault.id(), before, funded, after, orders, filled_quote);
}

/// Verifies actual withdrawal effects before sealing custody and native claim rules.
fun complete_finalization<Product, Collateral>(
    vault: &mut Vault<Product>, recovered: Coin<Collateral>,
    before: Checkpoint, after: Checkpoint,
) {
    vault.complete_shutdown(before.terminal_withdrawal(after, recovered));
}

// === Test-Only Functions ===

#[test_only]
public fun assert_initialization_inputs_for_testing(collateral_decimals: u8, seed_amount: u64, seed_reserve: u64) {
    assert_initialization_inputs(collateral_decimals, seed_amount, seed_reserve);
}

#[test_only]
public fun assert_position_imr_for_testing(negative: bool) {
    assert_position_imr_sign(negative);
}

#[test_only]
public fun assert_session_result_for_testing(
    is_long: bool,
    expected_base: u64,
    filled_bid: u256,
    filled_ask: u256,
    posted_orders: u64,
    liquidated_size: u64,
    bad_debt: u256,
) {
    assert_session_result(
        is_long,
        expected_base,
        filled_bid,
        filled_ask,
        posted_orders,
        liquidated_size,
        bad_debt,
    );
}

#[test_only]
public fun max_initialization_orders_for_testing(): u64 {
    MAX_INITIALIZATION_ORDERS
}

#[test_only]
public fun order_count_for_testing(
    target_base: u64,
    max_order_base: u64,
): u64 {
    initialization_order_count(target_base, max_order_base)
}

#[test_only]
public fun assert_deadline_for_testing(now_ms: u64, deadline: u64) { assert_deadline(now_ms, deadline); }

#[test_only]
public fun venue_fee_bound_for_testing(ordinary: u256, priority: u256): u64 { venue_fee_bound(ordinary, priority) }

#[test_only]
public fun opens_with_ask_for_testing(position_side: PositionSide): bool {
    opens_with_ask(position_side)
}

#[test_only]
public fun order_sizes_for_testing(
    target_notional: u64,
    max_order_notional: u64,
    base_price: u64,
    collateral_price: u64,
    lot_size: u64,
): vector<u64> {
    order_sizes(
        target_notional,
        max_order_notional,
        base_price,
        collateral_price,
        lot_size,
    )
}

#[test_only]
public fun active_order_size_for_testing(
    remaining: u64, max_order_notional: u64, base_price: u64, collateral_price: u64, lot_size: u64, index: u64,
): u64 {
    active_order_size(remaining, max_order_notional, base_price, collateral_price, lot_size, index)
}

#[test_only]
public fun active_fill_for_testing(
    is_bid: bool, requested_base: u64, lot_size: u64, filled_bid: u256, filled_ask: u256,
    posted_orders: u64, liquidated_size: u64, bad_debt: u256,
): u64 {
    active_fill(is_bid, requested_base, lot_size, filled_bid, filled_ask, posted_orders, liquidated_size, bad_debt)
}

#[test_only]
public fun actual_fill_notional_for_testing(
    filled_quote: u256,
    collateral_price: u64,
): u64 {
    actual_fill_notional(filled_quote, collateral_price)
}

#[test_only]
public fun execution_price_for_testing(
    raw_price: u256,
    round_up: bool,
    negative: bool,
): u64 {
    normalize_execution_price(raw_price, round_up, negative)
}

#[test_only]
public fun is_time_to_update_funding_for_testing(
    now_ms: u64, funding_last_upd_ms: u64, funding_frequency_ms: u64,
): bool {
    is_time_to_update_funding(now_ms, funding_last_upd_ms, funding_frequency_ms)
}

#[test_only]
public fun next_funding_update_time_ms_for_testing(funding_last_upd_ms: u64, funding_frequency_ms: u64): u64 {
    next_funding_update_time_ms(funding_last_upd_ms, funding_frequency_ms)
}

#[test_only]
public fun classify_sync_change_for_testing(
    stored: &Checkpoint,
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
): CheckpointChange {
    let (preexisting_change, local_change) =
        classify_sync_changes_for_testing(
            stored,
            before,
            after,
            candidate_negative,
            candidate_collateral_magnitude,
        );
    preexisting_change.net_funding(local_change)
}

#[test_only]
public fun classify_sync_changes_for_testing(
    stored: &Checkpoint,
    before: &Checkpoint,
    after: &Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
): (CheckpointChange, CheckpointChange) {
    let preexisting_change = if (
        snapshot::checkpoint_ready_for_settlement(stored, before)
    ) {
        snapshot::unchanged_change()
    } else {
        snapshot::classify_preexisting_funding_for_testing(stored, before)
    };
    let local_change = snapshot::classify_change_with_candidate_for_testing(
        before,
        after,
        candidate_negative,
        candidate_collateral_magnitude,
    );
    (preexisting_change, local_change)
}

#[test_only]
public fun apply_post_capture_for_testing<Product>(
    vault: &mut Vault<Product>, checkpoint: Checkpoint, change: CheckpointChange,
) {
    apply_post_capture(vault, checkpoint, snapshot::unchanged_change(), change);
}

#[test_only]
public fun apply_post_captures_for_testing<Product>(
    vault: &mut Vault<Product>, checkpoint: Checkpoint,
    preexisting_change: CheckpointChange, local_change: CheckpointChange,
) {
    apply_post_capture(vault, checkpoint, preexisting_change, local_change);
}

#[test_only]
public fun unwind_base_for_testing(magnitude: u256, is_long: bool, lot_size: u64, side: PositionSide): u64 {
    unwind_base_decoded(magnitude, is_long, lot_size, side)
}

#[test_only]
public(package) fun complete_unwind_for_testing<Product>(
    vault: &mut Vault<Product>, before: Checkpoint, funded: Option<Checkpoint>,
    after: Checkpoint, orders: u64, filled_quote: Option<u256>,
) {
    complete_unwind(vault, before, funded, after, orders, filled_quote);
}

#[test_only]
public(package) fun complete_finalization_for_testing<Product, Collateral>(
    vault: &mut Vault<Product>, recovered: Coin<Collateral>,
    before: Checkpoint, after: Checkpoint,
) {
    complete_finalization(vault, recovered, before, after);
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN, AuthorityCap};

use blast_admin::acl::AdminWitness;

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    constants,
    events,
    protocol::Protocol,
    snapshot::{Self, CapturedSnapshot, CheckpointChange},
    vault::{Self as vault, Vault, VaultIssuance},
    venue_account::{Self, Binding, Checkpoint},
};

use blast_boosts_core::{
    issuance::Issuance,
    observation::PositionObservation,
    policy::{Self, PositionSide},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    state::{ActivePosition, MintPlan, RebalancePlan, RedemptionPlan},
};

use ifixed::ifixed;

// An IFixed value is a u256 carrier; only its sign and magnitude read as methods.
use fun ifixed::abs as u256.abs;
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

use std::type_name;

use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency};
