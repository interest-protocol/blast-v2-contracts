// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Atomic Aftermath operations for adapter-owned leverage Vaults.
module blast_boosts_aftermath::operations;

// === Constants ===

/// Converts six-decimal collateral atoms to nine-decimal base atoms.
const COLLATERAL_TO_BASE_SCALE: u256 = 1_000;

/// Raw IFixed units represented by one nine-decimal base atom.
const BASE_ATOM_TO_IFIXED_SCALE: u256 = 1_000_000_000;

/// Converts six-decimal seed NAV atoms to nine-decimal share atoms.
const SEED_SHARE_SCALE: u64 = 1_000;

/// Maximum market-order calls permitted in one atomic initialization session.
const MAX_INITIALIZATION_ORDERS: u64 = 16;

/// Hard ceiling on venue market calls in one active atomic operation.
const MAX_ACTIVE_ORDERS: u64 = 16;

// === Public Types ===

/// Linear custody of priced shares until exact collateral and final margin are proved.
public struct RedemptionReceipt<phantom Product> {
    shares: Balance<BlastBoost<Product>>,
    net: u64,
    admin: u64,
    fee: u64,
    reserve_fee: u64,
    fee_bps: u64,
    admin_share_bps: u64,
    final_equity: u64,
    final_base: u64,
    base_price: u64,
    collateral_price: u64,
    unwound_checkpoint: venue_account::Checkpoint,
}

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

// === Public Functions ===

/// Atomically seeds and activates one issued Aftermath leverage Vault.
///
/// Direction and size come only from the immutable core policy. The selected
/// risk module authenticates the edge but cannot choose an order parameter.
/// Every external value is either retained in the Vault, shared, or consumed.
public fun initialize<Product, RiskModule: drop, Collateral>(
    vault: &mut Vault<Product>,
    protocol: &Protocol,
    risk_module: RiskModule,
    currency: &Currency<Collateral>,
    registry: &mut Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject,
    collateral_price_info: &PriceInfoObject,
    seed: Coin<Collateral>,
    seed_reserve: u64,
    seed_funder: address,
    position_imr: u256,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    protocol.assert_current();
    let (position_side, max_order_notional) = vault.initialization_constraints(&risk_module);
    let seed_amount = seed.value();
    vault::assert_seed_funder(seed_funder);
    assert_initialization_inputs(currency.decimals(), seed_amount, seed_reserve, vault.share_supply());
    assert_position_imr(position_imr);

    let (mut account, share_policy, admin_cap, binding) =
        open_venue_account(registry, &clearing_house, base_oracle, collateral_oracle, ctx);
    fund_venue_account(&mut account, &admin_cap, registry, &mut clearing_house, seed, position_imr);

    update_funding_when_due(&binding, &mut clearing_house, base_oracle, clock);
    let (pre_observation, _, _) = snapshot::capture_initialization(
        &binding, &account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let (target_notional, reference_base_price, collateral_price, lot_size) =
        vault.prepare_initialization(pre_observation, seed_reserve, clock.timestamp_ms());
    let orders = order_sizes(target_notional, max_order_notional, reference_base_price, collateral_price, lot_size);
    orders.do_ref!(|order| {
        vault.assert_order_notional_allowed(notional_for_base_up(*order, reference_base_price, collateral_price));
    });
    clearing_house = open_seed_position(
        vault, &mut account, &admin_cap, clearing_house, base_oracle, collateral_oracle,
        orders, position_side, reference_base_price, collateral_price, clock, ctx,
    );

    clearing_house::settle_position_funding(&mut clearing_house, collateral_oracle, binding.account_number(), clock);
    let (final_observation, checkpoint, facts) = snapshot::capture_initialization(
        &binding, &account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    assert_position_imr_unchanged(&clearing_house, binding.account_number(), position_imr);
    let seed_shareholder_nav = vault.initialize(
        final_observation, seed_reserve, currency.decimals(), clock.timestamp_ms(),
    );
    // BLAST_ACTIVATION_BOUNDARY_A1
    let locked_shares = locked_shares(seed_shareholder_nav);
    vault.mint_locked_shares(locked_shares, seed_funder, ctx);
    // BLAST_ACTIVATION_BOUNDARY_A2

    let venue_account = venue_account::new(admin_cap, binding, checkpoint);
    // BLAST_ACTIVATION_BOUNDARY_A3
    account::consume_policy_and_share_account(account, share_policy);
    // BLAST_ACTIVATION_BOUNDARY_A4
    vault.install_venue_account(venue_account);
    // BLAST_ACTIVATION_BOUNDARY_A5
    clearing_house::share(clearing_house);
    // BLAST_ACTIVATION_BOUNDARY_A6
    emit_vault_initialized<Product>(
        vault, seed_amount, facts.venue_equity(), facts.position_base(), facts.position_collateral(),
        facts.lot_size(), facts.side(), position_imr,
    );
    // BLAST_ACTIVATION_BOUNDARY_A7
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
    vault.assert_active();
    vault.assert_collateral_type<_, Collateral>();
    let deposit = cash.value();
    assert!(deposit > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.assert_user_fee_limit(true, maximum_fee_bps);

    sync_health(
        vault, protocol, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, before_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    vault.venue_checkpoint().assert_accepted_checkpoint(&before_checkpoint);

    let plan = vault.prepare_mint(before, deposit, minimum_shares, clock.timestamp_ms());
    let terms = active_terms(vault, false, plan.mint_lot_size(), plan.mint_base_price(), plan.mint_collateral_price());

    vault.retain_admin_cash(cash.split(plan.admin_fee(), ctx));
    let venue_deposit = cash.value();
    vault.deposit_collateral(account, registry, cash);
    vault.allocate_collateral(account, &mut clearing_house, venue_deposit);
    let (allocated, checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    before_checkpoint.assert_allocated_deposit_checkpoint(&checkpoint, venue_deposit);
    vault.assert_active_observation(allocated, terms.base_price, terms.collateral_price, clock.timestamp_ms());

    let (clearing_house, checkpoint) = fill_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, &binding, checkpoint, terms, plan.base_to_buy(), clock, ctx,
    );

    let (after, final_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    checkpoint.assert_deposit_checkpoint(&final_checkpoint, 0);
    let shares = complete_mint<Product, Collateral>(vault, plan, after, final_checkpoint, clock.timestamp_ms(), ctx);
    clearing_house::share(clearing_house);

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
    vault.assert_active();
    vault.assert_collateral_type<_, Collateral>();
    assert!(shares.value() > 0, blast_boosts_aftermath::errors::zero_amount!());
    assert_deadline(clock.timestamp_ms(), deadline_ms);
    vault.assert_user_fee_limit(false, maximum_fee_bps);

    sync_health(
        vault, protocol, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    vault.venue_checkpoint().assert_accepted_checkpoint(&checkpoint);

    let plan = vault.prepare_redemption(before, &shares, minimum_collateral, clock.timestamp_ms());
    let terms = active_terms(
        vault, true, plan.redemption_lot_size(), plan.redemption_base_price(), plan.redemption_collateral_price(),
    );

    let (mut clearing_house, checkpoint) = fill_orders(
        vault, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, &binding, checkpoint, terms, plan.base_to_sell(), clock, ctx,
    );

    let (unwound, unwound_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    checkpoint.assert_deposit_checkpoint(&unwound_checkpoint, 0);
    let receipt = seal_redemption_receipt(vault, plan, shares, unwound, unwound_checkpoint, clock.timestamp_ms());
    let cash = vault.withdraw_collateral(
        account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        receipt.redemption_cash_required(), clock, ctx,
    );
    let (after, final_checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    receipt.unwound_checkpoint.assert_withdrawal_checkpoint(&final_checkpoint, receipt.redemption_cash_required());
    let cash = complete_redemption(vault, receipt, cash, after, final_checkpoint, clock.timestamp_ms(), ctx);
    clearing_house::share(clearing_house);

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
    vault.assert_active();
    vault.assert_collateral_type<_, Collateral>();

    sync_health(
        vault, protocol, account, registry, &mut clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, mut checkpoint) = snapshot::capture(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    vault.venue_checkpoint().assert_accepted_checkpoint(&checkpoint);

    let mut plan = vault.prepare_rebalance(before, live_venue_fee_bps(&clearing_house), clock.timestamp_ms());
    let (_, increasing, _) = vault.rebalance_order(&plan);
    let terms = active_terms(vault, !increasing, plan.lot_size(), plan.base_price(), plan.collateral_price());

    let mut index = 0;
    while (index < MAX_ACTIVE_ORDERS) {
        let (requested, _, _) = vault.rebalance_order(&plan);
        if (requested == 0) break;

        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, &terms, requested, clock, ctx,
        );
        clearing_house = next_market;
        vault.assert_rebalance_execution(&plan, terms.base_price, fill.executed);

        let (after, after_checkpoint) = snapshot::capture(
            &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock,
        );
        fill.assert_checkpoint(&checkpoint, &after_checkpoint);
        vault.accept_rebalance_fill(&mut plan, after, fill.filled, clock.timestamp_ms());

        checkpoint = after_checkpoint;
        index = index + 1;
    };

    complete_rebalance<Product, Collateral>(vault, plan, checkpoint);
    clearing_house::share(clearing_house);
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
    vault.assert_active();
    vault.assert_collateral_type<_, Collateral>();
    let amount = cash.value();
    assert!(amount > 0, blast_boosts_aftermath::errors::zero_amount!());

    sync_health(
        vault, protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let binding = vault.venue_binding();
    let (before, before_checkpoint) = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    vault.venue_checkpoint().assert_accepted_checkpoint(&before_checkpoint);

    let plan = vault.prepare_donation(before, amount, clock.timestamp_ms());
    vault.deposit_collateral(account, registry, cash);
    let (after, checkpoint) = snapshot::capture(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    complete_donation(vault, plan, after, checkpoint, amount, clock.timestamp_ms());
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
    vault.assert_can_sync();
    vault.assert_venue_custody_binding();

    let binding = vault.venue_binding();
    let stored_checkpoint = *vault.venue_checkpoint();
    update_funding_when_due(&binding, clearing_house, base_oracle, clock);
    let pre_capture = snapshot::capture_health(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let (pre_checkpoint, collateral_price) = pre_capture.into_funding_probe();
    let funding_candidate = funding_candidate(clearing_house, account);

    clearing_house::settle_position_funding(clearing_house, collateral_oracle, account::account_id(account), clock);

    let post_capture = snapshot::capture_health(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let (preexisting_change, local_change) = classify_sync_changes(
        &stored_checkpoint, &pre_checkpoint, &post_capture.checkpoint(), funding_candidate, collateral_price,
    );
    apply_post_capture(vault, post_capture, preexisting_change, local_change);
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
    vault.assert_unwinding();
    vault.assert_collateral_type<_, Collateral>();

    if (clearing_house.is_frozen()) {
        unwind_frozen(vault, account, registry, &mut clearing_house, base_oracle, collateral_oracle);
    } else {
        clearing_house = unwind_market(
            vault, account, registry, clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock, ctx,
        );
    };
    clearing_house::share(clearing_house);
}

/// Recovers all actual holder collateral only from an exactly settled bound account.
public fun finalize_shutdown<Product, Collateral>(
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    clock: &Clock, ctx: &mut TxContext,
) {
    protocol.assert_current();
    vault.assert_unwinding();
    vault.assert_collateral_type<_, Collateral>();

    let binding = vault.venue_binding();
    let before = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    let amount = before.recoverable_terminal_cash();
    let recovered = if (amount == 0) {
        sui::coin::zero(ctx)
    } else {
        vault.withdraw_collateral(
            account, registry, clearing_house, base_oracle, collateral_oracle, amount, clock, ctx,
        )
    };
    let after = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );

    complete_finalization(vault, recovered, before, after);
}

// === Package Functions ===

/// Advances the sole economic checkpoint only after sealed maintenance has succeeded.
public(package) fun complete_rebalance<Product, Collateral>(
    vault: &mut Vault<Product>, plan: RebalancePlan<Product>, checkpoint: venue_account::Checkpoint,
) {
    let (before_equity, after_equity, before_base, after_base, increase) = vault.complete_rebalance(plan);

    vault.replace_venue_checkpoint(checkpoint);

    events::rebalanced<Product>(
        object::id(vault), before_equity, after_equity, before_base, after_base, increase,
        vault.maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.share_supply(), checkpoint,
    );
}

/// Holds the actual input coin across payout instead of accepting a numerical burn promise.
public(package) fun seal_redemption_receipt<Product>(
    vault: &mut Vault<Product>, plan: RedemptionPlan<Product>, shares: Coin<BlastBoost<Product>>,
    unwound: PositionObservation, unwound_checkpoint: venue_account::Checkpoint, now_ms: u64,
): RedemptionReceipt<Product> {
    assert!(
        shares.value() == plan.redemption_shares(),
        blast_boosts_aftermath::errors::redemption_share_mismatch!(),
    );

    let (final_base, base_price, collateral_price, fee_bps, admin_share_bps) = (
        plan.base_after_sell(),
        plan.redemption_base_price(),
        plan.redemption_collateral_price(),
        plan.redemption_fee_bps(),
        plan.redemption_admin_share_bps(),
    );
    let (net, admin, final_equity, fee, reserve_fee) = vault.complete_redemption(plan, unwound, now_ms);

    RedemptionReceipt {
        shares: shares.into_balance(), net, admin, fee, reserve_fee, fee_bps, admin_share_bps,
        final_equity, final_base, base_price, collateral_price, unwound_checkpoint,
    }
}

/// Returns only the exact total collateral that must leave the venue before completion.
public(package) fun redemption_cash_required<Product>(self: &RedemptionReceipt<Product>): u64 {
    self.net + self.admin
}

/// Completes custody after the public operation proves the signed withdrawal checkpoint.
/// Validates final cash and margin, retains earned admin cash, then burns the held shares.
public(package) fun complete_redemption<Product, Collateral>(
    vault: &mut Vault<Product>, receipt: RedemptionReceipt<Product>, mut cash: Coin<Collateral>,
    after: PositionObservation, checkpoint: venue_account::Checkpoint, now_ms: u64, ctx: &mut TxContext,
): Coin<Collateral> {
    let RedemptionReceipt {
        shares, net, admin, fee, reserve_fee, fee_bps, admin_share_bps, final_equity, final_base,
        base_price, collateral_price, unwound_checkpoint: _,
    } = receipt;
    vault.assert_collateral_type<_, Collateral>();
    assert!(cash.value() == net + admin, blast_boosts_aftermath::errors::cash_checkpoint_mismatch!());
    vault.assert_redemption_cash_out(after, final_equity, final_base, base_price, collateral_price, now_ms);

    vault.retain_admin_cash(cash.split(admin, ctx));
    let burned = vault.burn_redeemed_shares(shares.into_coin(ctx));
    vault.replace_venue_checkpoint(checkpoint);

    events::redeemed<Product>(
        vault.id(), burned, net, fee, admin, reserve_fee, fee_bps, admin_share_bps,
        vault.maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(), vault.share_supply(), checkpoint,
    );

    cash
}

/// Commits native mint effects only after the orchestration proved its venue checkpoint.
public(package) fun complete_mint<Product, Collateral>(
    vault: &mut Vault<Product>, plan: MintPlan<Product>, after: PositionObservation,
    checkpoint: venue_account::Checkpoint, now_ms: u64, ctx: &mut TxContext,
): Coin<BlastBoost<Product>> {
    let deposit = plan.mint_deposit();
    let (shares, contribution, fee, admin, reserve_fee, fee_bps, admin_share_bps) =
        vault.complete_mint(plan, after, now_ms, ctx);

    vault.replace_venue_checkpoint(checkpoint);

    events::minted<Product>(
        vault.id(), deposit, shares.value(), contribution, fee, admin, reserve_fee, fee_bps, admin_share_bps,
        vault.maintenance_reserve(), vault.admin_cash_balance<_, Collateral>(),
        vault.share_supply(), checkpoint,
    );

    shares
}

/// Shared production completion phase, after the real venue deposit has returned.
public(package) fun complete_donation<Product>(
    vault: &mut Vault<Product>,
    plan: DonationPlan<Product>,
    after: PositionObservation,
    checkpoint: venue_account::Checkpoint,
    amount: u64,
    now_ms: u64,
) {
    vault.venue_checkpoint().assert_deposit_checkpoint(&checkpoint, amount);

    vault.complete_donation(plan, after, now_ms);
    vault.replace_venue_checkpoint(checkpoint);

    events::donated<Product>(vault.id(), amount, vault.maintenance_reserve(), checkpoint);
}

/// Applies the complete Blast-owned post-capture synchronization phase.
public(package) fun apply_post_capture<Product>(
    vault: &mut Vault<Product>,
    post_capture: snapshot::CapturedSnapshot,
    preexisting_change: snapshot::Change,
    local_change: snapshot::Change,
) {
    let stored_checkpoint = *vault.venue_checkpoint();
    let net = preexisting_change.net_funding(local_change);
    let checkpoint_clean = net.is_clean();
    let (absorbed, uncovered, restored, reserve_after) = if (net.has_funding()) {
        vault.settle_funding(net.is_cost(), net.amount())
    } else {
        (0, 0, 0, vault.maintenance_reserve())
    };

    let checkpoint = post_capture.finish_health();
    let diagnostic_changed = vault.note_checkpoint_health(&checkpoint, checkpoint_clean);
    if (checkpoint_clean) {
        vault.replace_venue_checkpoint(checkpoint);
    };

    // A zero-net interval still advances authenticated source identity and
    // needs a reducer-visible completed fact; identical retries remain quiet.
    if (checkpoint_clean && !snapshot::checkpoint_unchanged(&stored_checkpoint, &checkpoint)) {
        events::funding_settled<Product>(
            vault.id(), net.is_cost(), net.raw_amount(), net.amount(), absorbed, uncovered, restored,
            reserve_after, stored_checkpoint, checkpoint,
        );
    };
    if (diagnostic_changed) {
        let reason = if (checkpoint_clean) {
            events::diagnostic_cleared_reason()
        } else {
            events::diagnostic_raised_reason()
        };
        events::health_synchronized<Product>(vault.id(), reason, checkpoint);
    };
}

/// Emits activation facts read back from the resulting real Vault state.
public(package) fun emit_vault_initialized<Product>(
    vault: &Vault<Product>,
    seed_amount: u64,
    seed_venue_equity: u64,
    position_base: u64,
    position_collateral: u64,
    lot_size: u64,
    position_side: PositionSide,
    position_imr: u256,
) {
    let binding = vault.venue_binding();
    let (locked_shares, seed_funder) = vault.seed_facts();

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
        vault.maintenance_reserve(),
        locked_shares / SEED_SHARE_SCALE,
        locked_shares,
        seed_funder,
        position_base,
        position_collateral,
        lot_size,
        position_side,
        position_imr,
        *vault.venue_checkpoint(),
    );
}

// === Private Functions ===

/// Creates the isolated Aftermath account the Vault will own and binds it to
/// the exact venue objects this activation was called with.
fun open_venue_account<Collateral>(
    registry: &mut Registry,
    clearing_house: &ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    ctx: &mut TxContext,
): (Account<Collateral>, AccountSharePolicy, AuthorityCap<ACCOUNT, ADMIN>, venue_account::Binding) {
    let (account, share_policy, admin_cap) = account::create_account<Collateral>(registry, ctx);
    let account_object_id = object::id(&account);
    let binding = venue_account::new_binding(
        account_object_id,
        account::account_id(&account),
        object::id(registry),
        object::id(clearing_house),
        object::id(base_oracle),
        object::id(collateral_oracle),
        type_name::with_original_ids<Collateral>(),
    );
    venue_account::assert_admin_cap_binding(authority::`for`(&admin_cap), account_object_id);

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
    account::deposit_collateral(account, admin_cap, registry, seed);
    clearing_house::allocate_collateral(clearing_house, admin_cap, account, seed_amount);
    clearing_house::create_market_position(clearing_house, admin_cap, account);
    clearing_house::set_position_initial_margin_ratio(clearing_house, admin_cap, account, position_imr);
}

/// Opens the seed position one policy-sized market order at a time.
///
/// Every session must fill its whole order at the sealed oracle price within
/// the ordinary slippage bound, post nothing, and touch no liquidation; each
/// actual fill is capped separately so admitted slippage cannot carry one
/// order past the live cap.
fun open_seed_position<Product, Collateral>(
    vault: &Vault<Product>,
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
        let mut session = clearing_house::start_session(
            clearing_house, admin_cap, account, base_oracle, collateral_oracle, option::none(), clock, ctx,
        );
        clearing_house::place_market_order(&mut session, aftermath_order_side, order_base, false);
        let (next_clearing_house, summary) = clearing_house::end_session(session, admin_cap, account, false, false);
        clearing_house = next_clearing_house;

        assert_session_result(
            is_long, order_base,
            clearing_house::base_filled_bid(&summary), clearing_house::base_filled_ask(&summary),
            clearing_house::posted_orders(&summary), clearing_house::liquidated_size(&summary),
            clearing_house::liquidation_bad_debt(&summary),
        );
        let executed = execution_price(clearing_house::execution_price(&summary, aftermath_order_side), is_long);
        vault.assert_initialization_execution(reference_base_price, executed);
        let (_, filled_quote) = clearing_house::filled_base_and_quote(&summary, aftermath_order_side);
        vault.assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));
    };

    clearing_house
}

/// The margin ratio set before the seed orders must survive them unchanged.
fun assert_position_imr_unchanged<Collateral>(
    clearing_house: &ClearingHouse<Collateral>, account_number: u64, position_imr: u256,
) {
    let final_imr = position::initial_margin_ratio(clearing_house::position(clearing_house, account_number));
    assert!(
        !ifixed::is_neg(final_imr) && final_imr == position_imr,
        blast_boosts_aftermath::errors::initialization_imr_mismatch!(),
    );
}

/// The funding the venue would settle for this account at its current cumulative rates.
fun funding_candidate<Collateral>(clearing_house: &ClearingHouse<Collateral>, account: &Account<Collateral>): u256 {
    let (long_rate, short_rate) = market::cum_funding_rates(clearing_house.market_state());

    position::calculate_position_funding_internal(
        clearing_house.position(account::account_id(account)), long_rate, short_rate,
    )
}

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
    binding: &venue_account::Binding,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    clock: &Clock,
) {
    binding.assert_funding_update_inputs(object::id(clearing_house), object::id(base_oracle));

    let (funding_frequency_ms, _) = market::funding_params(clearing_house.market_params());
    let funding_last_upd_ms = market::funding_last_upd_ms(clearing_house.market_state());

    if (is_time_to_update_funding(clock.timestamp_ms(), funding_last_upd_ms, funding_frequency_ms)) {
        clearing_house::update_funding(clearing_house, base_oracle, clock);
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

/// Advances terminal checkpoint/event state only after an attributable close has completed.
fun complete_unwind<Product>(
    vault: &mut Vault<Product>, before: venue_account::Checkpoint, funded: Option<venue_account::Checkpoint>,
    after: venue_account::Checkpoint, orders: u64, filled_quote: Option<u256>,
) {
    vault.assert_unwinding();
    after.assert_no_orders();
    if (filled_quote.is_none()) {
        assert!(funded.is_none() && orders == 0, blast_boosts_aftermath::errors::terminal_venue_unsettled!());
        before.assert_direct_settlement_close(&after);
    } else {
        assert!(
            funded.is_some() && orders > 0 && orders <= MAX_ACTIVE_ORDERS,
            blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
        );
    };

    vault.replace_venue_checkpoint(after);

    events::unwind_progress<Product>(vault.id(), before, funded, after, orders, filled_quote);
}

/// Verifies actual withdrawal effects before sealing custody and native claim rules.
fun complete_finalization<Product, Collateral>(
    vault: &mut Vault<Product>, recovered: Coin<Collateral>,
    before: venue_account::Checkpoint, after: venue_account::Checkpoint,
) {
    vault.complete_shutdown(before.terminal_withdrawal(after, recovered));
}

/// The venue's direct frozen settlement is not a market order or a stale-price fallback.
fun unwind_frozen<Product, Collateral>(
    vault: &mut Vault<Product>, account: &mut Account<Collateral>, registry: &Registry,
    clearing_house: &mut ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
) {
    let binding = vault.venue_binding();
    let before = snapshot::capture_checkpoint(
        &binding, account, registry, clearing_house, base_oracle, collateral_oracle,
    );
    before.assert_no_orders();
    let (enabled, base_price, collateral_price) = clearing_house.settlement_valuation_prices();
    assert!(
        enabled && base_price != 0 && collateral_price != 0
            && !ifixed::is_neg(base_price) && !ifixed::is_neg(collateral_price),
        blast_boosts_aftermath::errors::terminal_venue_unsettled!(),
    );

    clearing_house::close_position_at_settlement_prices(clearing_house, account, &vector[]);
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
    let binding = vault.venue_binding();
    update_funding_when_due(&binding, &mut clearing_house, base_oracle, clock);
    let capture = snapshot::capture_health(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
        base_price_info, collateral_price_info, clock,
    );
    let collateral_fixed = capture.collateral_fixed();
    let (side, cap, base_price, collateral_price) = vault.unwind_constraints(
        capture.base_price_observation(), capture.collateral_price_observation(), clock.timestamp_ms(),
    );
    let before = capture.finish_health();
    before.assert_no_orders();
    let mut remaining = unwind_base(&before, side);

    let candidate = funding_candidate(&clearing_house, account);
    clearing_house::settle_position_funding(
        &mut clearing_house, collateral_oracle, account::account_id(account), clock,
    );
    let funded = snapshot::capture_checkpoint(
        &binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
    );
    snapshot::classify_change(&before, &funded, candidate, collateral_fixed).assert_clean_funding();

    let terms = OrderTerms {
        is_ask: !opens_with_ask(side), reduce_only: true, max_order_notional: cap,
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
        vault.assert_unwind_execution(base_price, fill.executed);

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
fun unwind_base(checkpoint: &venue_account::Checkpoint, side: PositionSide): u64 {
    let base = checkpoint.signed_base();

    unwind_base_from_parts(ifixed::abs(base), !ifixed::is_neg(base), checkpoint.lot_size(), side)
}

fun unwind_base_from_parts(magnitude: u256, is_long: bool, lot: u64, side: PositionSide): u64 {
    assert!(
        lot > 0 && magnitude > 0
            && magnitude <= (std::u64::max_value!() as u256) * BASE_ATOM_TO_IFIXED_SCALE
            && magnitude % ((lot as u256) * BASE_ATOM_TO_IFIXED_SCALE) == 0
            && is_long == (side == policy::long()),
        blast_boosts_aftermath::errors::invalid_unwind_exposure!(),
    );

    (magnitude / BASE_ATOM_TO_IFIXED_SCALE) as u64
}

/// Reads the market's taker fee and priority surcharge as one basis-point bound.
fun live_venue_fee_bps<Collateral>(clearing_house: &ClearingHouse<Collateral>): u64 {
    let params = clearing_house.market_params();

    venue_fee_bound(
        nonnegative_rate(market::taker_fee(params)),
        nonnegative_rate(market::resolve_priority_taker_fee(market::priority_taker_fee(params))),
    )
}

/// A venue rebate reads as a zero fee; the bound never credits execution.
fun nonnegative_rate(rate: u256): u256 {
    if (ifixed::is_neg(rate)) { 0 } else { ifixed::abs(rate) }
}

/// Aftermath's priority rate is an additional surcharge, not an alternative fee.
/// Negative rebates are ignored conservatively; callers provide no fee input.
fun venue_fee_bound(ordinary: u256, priority: u256): u64 {
    let one = 1_000_000_000_000_000_000u256;
    assert!(
        ordinary <= one && priority <= one && ordinary <= one - priority,
        blast_boosts_aftermath::errors::venue_fee_unusable!(),
    );

    ((ordinary + priority).div_ceil(100_000_000_000_000)) as u64
}

fun classify_sync_changes(
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
    funding_candidate: u256,
    collateral_price: u256,
): (snapshot::Change, snapshot::Change) {
    let preexisting_change = if (snapshot::checkpoint_ready_for_settlement(stored, before)) {
        snapshot::unchanged_change()
    } else {
        snapshot::classify_preexisting_funding(stored, before)
    };
    let local_change = snapshot::classify_change(before, after, funding_candidate, collateral_price);

    (preexisting_change, local_change)
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
    vault.assert_order_notional_allowed(notional_for_base_up(requested, base_price, collateral_price));

    let (clearing_house, summary) = vault.execute_order(
        account, clearing_house, base_oracle, collateral_oracle, is_ask, requested, reduce_only, clock, ctx,
    );
    let filled = active_fill(
        !is_ask, requested, lot_size,
        clearing_house::base_filled_bid(&summary), clearing_house::base_filled_ask(&summary),
        clearing_house::posted_orders(&summary), clearing_house::liquidated_size(&summary),
        clearing_house::liquidation_bad_debt(&summary),
    );
    let (filled_base, filled_quote) = clearing_house::filled_base_and_quote(&summary, is_ask);
    let executed = execution_price(clearing_house::execution_price(&summary, is_ask), !is_ask);
    vault.assert_order_notional_allowed(actual_fill_notional(filled_quote, collateral_price));

    (clearing_house, Fill { filled, filled_base, filled_quote, executed, is_ask, reduce_only })
}

/// Places every order of one active mint or redemption, proving each fill
/// against the sealed oracle and the checkpoint before the next.
///
/// Returns the market and the checkpoint the last fill left behind.
fun fill_orders<Product, Collateral>(
    vault: &Vault<Product>, account: &mut Account<Collateral>, registry: &Registry,
    mut clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price_info: &PriceInfoObject, collateral_price_info: &PriceInfoObject,
    binding: &venue_account::Binding, mut checkpoint: venue_account::Checkpoint,
    terms: OrderTerms, mut remaining: u64, clock: &Clock, ctx: &TxContext,
): (ClearingHouse<Collateral>, venue_account::Checkpoint) {
    let mut index = 0;
    while (remaining > 0) {
        let requested = terms.next_order_size(remaining, index);
        let (next_market, fill) = place_order(
            vault, account, clearing_house, base_oracle, collateral_oracle, &terms, requested, clock, ctx,
        );
        clearing_house = next_market;
        vault.assert_active_execution(terms.base_price, fill.executed);

        let (intermediate, after_checkpoint) = snapshot::capture(
            binding, account, registry, &clearing_house, base_oracle, collateral_oracle,
            base_price_info, collateral_price_info, clock,
        );
        fill.assert_checkpoint(&checkpoint, &after_checkpoint);
        vault.assert_active_observation(intermediate, terms.base_price, terms.collateral_price, clock.timestamp_ms());

        checkpoint = after_checkpoint;
        remaining = remaining - fill.filled;
        index = index + 1;
    };

    (clearing_house, checkpoint)
}

/// The terms of an active operation: direction from policy, the live cap, and the plan's sealed prices.
fun active_terms<Product>(
    vault: &Vault<Product>, reduce_only: bool, lot_size: u64, base_price: u64, collateral_price: u64,
): OrderTerms {
    let (side, max_order_notional) = vault.active_constraints();
    let is_ask = if (reduce_only) { !opens_with_ask(side) } else { opens_with_ask(side) };

    OrderTerms { is_ask, reduce_only, max_order_notional, lot_size, base_price, collateral_price }
}

/// The next whole-lot request: what remains, capped by the live order notional.
fun next_order_size(self: &OrderTerms, remaining: u64, index: u64): u64 {
    active_order_size(remaining, self.max_order_notional, self.base_price, self.collateral_price, self.lot_size, index)
}

/// Proves the checkpoint moved exactly as this fill did: an opening trade moves
/// base and quote, a reduction only base.
fun assert_checkpoint(self: &Fill, before: &venue_account::Checkpoint, after: &venue_account::Checkpoint) {
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

/// Bounds each next whole-lot request without re-rounding the sealed aggregate.
fun active_order_size(
    remaining: u64, cap: u64, base_price: u64, collateral_price: u64, lot: u64, index: u64,
): u64 {
    assert!(index < MAX_ACTIVE_ORDERS, blast_boosts_aftermath::errors::active_order_count_exceeded!());

    let maximum = base_for_notional_down(cap, base_price, collateral_price, lot);
    assert!(
        maximum > 0 && remaining > 0 && remaining % lot == 0,
        blast_boosts_aftermath::errors::active_fill_mismatch!(),
    );

    remaining.min(maximum)
}

fun assert_deadline(now_ms: u64, deadline: u64) {
    assert!(now_ms <= deadline, blast_boosts_aftermath::errors::deadline_expired!());
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

fun initialization_order_count(target_base: u64, max_order_base: u64): u64 {
    assert!(max_order_base > 0, blast_boosts_aftermath::errors::invalid_initialization_order_size!());

    let count = target_base.div_ceil(max_order_base);
    assert!(
        count <= MAX_INITIALIZATION_ORDERS,
        blast_boosts_aftermath::errors::initialization_order_count_exceeded!(),
    );

    count
}

/// Whether opening this side is an ask on the Aftermath port: shorts sell to open, longs buy.
fun opens_with_ask(position_side: PositionSide): bool {
    position_side == policy::short()
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
        .checked_mul(COLLATERAL_TO_BASE_SCALE)
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
        .checked_mul(COLLATERAL_TO_BASE_SCALE)
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let notional = numerator.div_ceil(denominator);
    assert!(notional <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    notional as u64
}

/// Converts one session's actual filled quote into atomic collateral notional.
///
/// The fill is checked separately for every order so allowed execution
/// slippage cannot make an individual order exceed the live core cap.
fun actual_fill_notional(filled_quote: u256, collateral_price: u64): u64 {
    assert!(collateral_price > 0, blast_boosts_aftermath::errors::normalization_overflow!());

    let denominator = (collateral_price as u256)
        .checked_mul(COLLATERAL_TO_BASE_SCALE)
        .destroy_or!(abort blast_boosts_aftermath::errors::normalization_overflow!());
    let notional = filled_quote.div_ceil(denominator);
    assert!(notional <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    notional as u64
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
        opposite == 0 && filled > 0 && filled <= (requested_base as u256) * BASE_ATOM_TO_IFIXED_SCALE
            && lot_size > 0 && filled % ((lot_size as u256) * BASE_ATOM_TO_IFIXED_SCALE) == 0,
        blast_boosts_aftermath::errors::active_fill_mismatch!(),
    );

    (filled / BASE_ATOM_TO_IFIXED_SCALE) as u64
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

    let expected_raw_base = (expected_base as u256) * BASE_ATOM_TO_IFIXED_SCALE;
    let fill_matches = if (is_long) {
        filled_bid == expected_raw_base && filled_ask == 0
    } else {
        filled_ask == expected_raw_base && filled_bid == 0
    };
    assert!(fill_matches, blast_boosts_aftermath::errors::initialization_fill_mismatch!());
}

fun assert_initialization_inputs(
    collateral_decimals: u8,
    seed_amount: u64,
    seed_reserve: u64,
    share_supply: u64,
) {
    assert!(collateral_decimals == 6, blast_boosts_aftermath::errors::invalid_collateral_decimals!());
    assert!(seed_amount > 0, blast_boosts_aftermath::errors::invalid_seed!());
    assert!(seed_reserve < seed_amount, blast_boosts_aftermath::errors::invalid_seed_reserve!());
    assert!(share_supply == 0, blast_boosts_aftermath::errors::share_supply_not_zero!());
}

fun locked_shares(seed_nav: u64): u64 {
    seed_nav
        .checked_mul(SEED_SHARE_SCALE)
        .destroy_or!(abort blast_boosts_aftermath::errors::locked_shares_overflow!())
}

fun execution_price(raw_price: u256, round_up: bool): u64 {
    normalize_execution_price(raw_price, round_up, ifixed::is_neg(raw_price))
}

fun normalize_execution_price(raw_price: u256, round_up: bool, negative: bool): u64 {
    assert!(!negative, blast_boosts_aftermath::errors::normalization_overflow!());

    let down = raw_price / BASE_ATOM_TO_IFIXED_SCALE;
    let normalized = if (round_up && raw_price % BASE_ATOM_TO_IFIXED_SCALE != 0) { down + 1 } else { down };
    assert!(normalized <= std::u64::max_value!() as u256, blast_boosts_aftermath::errors::normalization_overflow!());

    normalized as u64
}

fun assert_position_imr(position_imr: u256) {
    assert_position_imr_sign(ifixed::is_neg(position_imr));
}

fun assert_position_imr_sign(negative: bool) {
    assert!(!negative, blast_boosts_aftermath::errors::initialization_imr_mismatch!());
}

// === Test-Only Functions ===

#[test_only]
public(package) fun complete_unwind_for_testing<Product>(
    vault: &mut Vault<Product>, before: venue_account::Checkpoint, funded: Option<venue_account::Checkpoint>,
    after: venue_account::Checkpoint, orders: u64, filled_quote: Option<u256>,
) {
    complete_unwind(vault, before, funded, after, orders, filled_quote);
}

#[test_only]
public(package) fun complete_finalization_for_testing<Product, Collateral>(
    vault: &mut Vault<Product>, recovered: Coin<Collateral>,
    before: venue_account::Checkpoint, after: venue_account::Checkpoint,
) {
    complete_finalization(vault, recovered, before, after);
}

#[test_only]
public fun unwind_base_for_testing(magnitude: u256, is_long: bool, lot: u64, side: PositionSide): u64 {
    unwind_base_from_parts(magnitude, is_long, lot, side)
}

#[test_only]
public fun venue_fee_bound_for_testing(ordinary: u256, priority: u256): u64 { venue_fee_bound(ordinary, priority) }

#[test_only]
public fun active_order_size_for_testing(
    remaining: u64, cap: u64, base_price: u64, collateral_price: u64, lot: u64, index: u64,
): u64 {
    active_order_size(remaining, cap, base_price, collateral_price, lot, index)
}

#[test_only]
public fun assert_deadline_for_testing(now_ms: u64, deadline: u64) { assert_deadline(now_ms, deadline); }

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
public fun active_fill_for_testing(
    is_bid: bool, requested_base: u64, lot_size: u64, filled_bid: u256, filled_ask: u256,
    posted_orders: u64, liquidated_size: u64, bad_debt: u256,
): u64 {
    active_fill(is_bid, requested_base, lot_size, filled_bid, filled_ask, posted_orders, liquidated_size, bad_debt)
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
public fun opens_with_ask_for_testing(position_side: PositionSide): bool {
    opens_with_ask(position_side)
}

#[test_only]
public fun assert_initialization_inputs_for_testing(
    already_initialized: bool,
    collateral_decimals: u8,
    seed_amount: u64,
    seed_reserve: u64,
    share_supply: u64,
) {
    if (already_initialized) {
        blast_boosts_aftermath::vault::assert_venue_account_installable_for_testing(true);
    };
    assert_initialization_inputs(
        collateral_decimals,
        seed_amount,
        seed_reserve,
        share_supply,
    );
}

#[test_only]
public fun locked_shares_for_testing(seed_nav: u64): u64 {
    locked_shares(seed_nav)
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
public fun actual_fill_notional_for_testing(
    filled_quote: u256,
    collateral_price: u64,
): u64 {
    actual_fill_notional(filled_quote, collateral_price)
}

#[test_only]
public fun assert_position_imr_for_testing(negative: bool) {
    assert_position_imr_sign(negative);
}

#[test_only]
public fun classify_sync_change_for_testing(
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
): snapshot::Change {
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
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
    candidate_negative: bool,
    candidate_collateral_magnitude: u256,
): (snapshot::Change, snapshot::Change) {
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
    vault: &mut Vault<Product>,
    post_capture: snapshot::CapturedSnapshot,
    change: snapshot::Change,
) {
    apply_post_capture(
        vault,
        post_capture,
        snapshot::unchanged_change(),
        change,
    );
}

#[test_only]
public fun apply_post_captures_for_testing<Product>(
    vault: &mut Vault<Product>,
    post_capture: snapshot::CapturedSnapshot,
    preexisting_change: snapshot::Change,
    local_change: snapshot::Change,
) {
    apply_post_capture(
        vault,
        post_capture,
        preexisting_change,
        local_change,
    );
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN, AuthorityCap};

use blast_admin::acl::AdminWitness;

use blast_boosts_aftermath::{
    blast_boost::BlastBoost,
    events,
    protocol::Protocol,
    snapshot,
    vault::{Self as vault, Vault},
    venue_account,
};

use blast_boosts_core::{
    observation::PositionObservation,
    policy::{Self, PositionSide},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
    state::{DonationPlan, MintPlan, RebalancePlan, RedemptionPlan},
};

use ifixed::ifixed;

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{
    account::{Self as account, Account, AccountSharePolicy},
    authority::ACCOUNT,
    clearing_house::{Self, ClearingHouse},
    market,
    registry::Registry,
};

use position::position;

use pyth::price_info::PriceInfoObject;

use std::type_name;

use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency};
