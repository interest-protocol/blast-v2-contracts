// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// One custody and funded-fee ledger shared by bonding-curve and presale launch adapters.
module blast_market_maker::market_maker;

// === Public Types ===

public enum Route has copy, drop, store {
    Curve,
    Presale,
}
public enum Phase has copy, drop, store {
    Funding,
    Curve,
    Presale,
    Pool,
    Refunding,
}

/// Exact atom-unit limits, committed before the vault is shared.
public struct TradingLimits has copy, drop, store {
    max_meme_input: u64,
    max_quote_input: u64,
    lifetime_meme_input: u64,
    lifetime_quote_input: u64,
    idle_quote: u64,
    action_limit: u64,
    meme_bucket_capacity: u64,
    quote_bucket_capacity: u64,
    meme_refill_per_ms: u64,
    quote_refill_per_ms: u64,
    curve_quote_basis_limit: u64,
    pool_quote_input_limit: u64,
}

public struct BlastMarketMakerVault<phantom Meme, phantom Quote> has key {
    id: UID,
    route: Route,
    phase: Phase,
    target: u64,
    new_address_minimum: u64,
    deadline_at_ms: u64,
    external_id: Option<ID>,
    pool_id: Option<ID>,
    policy_id: ID,
    treasury_id: ID,
    raise_bps: u64,
    maximum_lp_bps: u64,
    paused: bool,
    operator_cap_id: ID,
    creator_cap_id: ID,
    signer_pk: vector<u8>,
    signer_epoch: u64,
    nonce: u64,
    limits: Option<TradingLimits>,
    spent_meme: u64,
    spent_quote: u64,
    actions: u64,
    meme_bucket: u64,
    quote_bucket: u64,
    bucket_at_ms: u64,
    curve_quote_basis: u64,
    pool_quote_input: u64,
    funding: Balance<Quote>,
    capital_meme: Balance<Meme>,
    capital_quote: Balance<Quote>,
    meme_fees: FeeLedger<Meme>,
    quote_fees: FeeLedger<Quote>,
    raise_fees: Balance<Quote>,
    backers: Table<address, BackerClaim>,
    total_weight: u64,
}

public struct BackerClaim has store { weight: u64, meme: FeeClaim, quote: FeeClaim }
public struct BlastMarketMakerOperatorCap has key, store { id: UID, vault_id: ID }
/// One transferable authority can manage any number of explicitly bound vaults.
public struct BlastMarketMakerCreatorCap has key, store { id: UID }

// === Public Functions ===

public fun trading_limits(
    max_meme_input: u64,
    max_quote_input: u64,
    lifetime_meme_input: u64,
    lifetime_quote_input: u64,
    idle_quote: u64,
    action_limit: u64,
): TradingLimits {
    assert!(max_meme_input > 0 && max_quote_input > 0, EInvalidTradingLimits);
    assert!(
        max_meme_input <= lifetime_meme_input && max_quote_input <= lifetime_quote_input,
        EInvalidTradingLimits,
    );
    assert!(action_limit > 0 && action_limit <= 1_000_000_000, EInvalidTradingLimits);

    TradingLimits {
        max_meme_input,
        max_quote_input,
        lifetime_meme_input,
        lifetime_quote_input,
        idle_quote,
        action_limit,
        meme_bucket_capacity: lifetime_meme_input,
        quote_bucket_capacity: lifetime_quote_input,
        meme_refill_per_ms: 0,
        quote_refill_per_ms: 0,
        curve_quote_basis_limit: lifetime_quote_input,
        pool_quote_input_limit: lifetime_quote_input,
    }
}

/// Optional stricter rolling and self-fee ceilings, immutable once the market maker is shared.
public fun with_rate_limits(
    mut limits: TradingLimits,
    meme_capacity: u64,
    quote_capacity: u64,
    meme_refill_per_ms: u64,
    quote_refill_per_ms: u64,
    curve_quote_basis_limit: u64,
    pool_quote_input_limit: u64,
): TradingLimits {
    assert!(
        meme_capacity >= limits.max_meme_input && quote_capacity >= limits.max_quote_input,
        EInvalidTradingLimits,
    );
    assert!(curve_quote_basis_limit > 0 && pool_quote_input_limit > 0, EInvalidTradingLimits);
    limits.meme_bucket_capacity = meme_capacity;
    limits.quote_bucket_capacity = quote_capacity;
    limits.meme_refill_per_ms = meme_refill_per_ms;
    limits.quote_refill_per_ms = quote_refill_per_ms;
    limits.curve_quote_basis_limit = curve_quote_basis_limit;
    limits.pool_quote_input_limit = pool_quote_input_limit;

    limits
}

/// Returns the exact BCS payload for the current key epoch/nonce and exact action.
public fun signing_bytes<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    action: Action,
    issued_at_ms: u64,
    expires_at_ms: u64,
): vector<u8> {
    risk::message_bytes<Meme, Quote>(
        self.id.to_inner(),
        *self.external_id.borrow(),
        self.pool_id,
        self.operator_cap_id,
        action,
        self.nonce,
        self.signer_epoch,
        issued_at_ms,
        expires_at_ms,
    )
}

/// Curve-route funding only. Presale commitments are held exclusively in the upstream presale.
public fun contribute_and_return_change<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    mut payment: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    self.assert_can_contribute(version, clock);
    assert!(self.route == Route::Curve && self.phase == Phase::Funding, EWrongRoute);
    if (!self.backers.contains(ctx.sender()))
        assert!(payment.value() >= self.new_address_minimum, EContributionBelowMinimum);
    let accepted = payment.value().min(self.target - self.total_weight);
    assert!(accepted > 0, EZeroContribution);
    self.assert_backer_capacity(ctx.sender());

    self.record_weight(accepted, ctx.sender());
    self.funding.join(payment.split(accepted, ctx).into_balance());
    sui::event::emit(BlastContributed<Quote> {
        vault_id: self.id.to_inner(),
        accepted,
        total_weight: self.total_weight,
    });

    payment
}

/// A permissionless full-refund transition exists only for the curve-route raise.
public fun begin_refunding<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    clock: &Clock,
) {
    version.assert_current();
    assert!(self.route == Route::Curve && self.phase == Phase::Funding, EWrongPhase);
    assert!(clock.timestamp_ms() >= self.deadline_at_ms, EDeadlineNotReached);

    self.phase = Phase::Refunding;
    sui::event::emit(BlastRefundingStarted { vault_id: self.id.to_inner() });
}

public fun refund<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    ctx: &mut TxContext,
): Coin<Quote> {
    version.assert_current();
    assert!(self.phase == Phase::Refunding && self.route == Route::Curve, EWrongPhase);
    assert!(self.backers.contains(ctx.sender()), ENothingRefundable);
    let BackerClaim { weight, meme: _, quote: _ } = self.backers.remove(ctx.sender());

    self.total_weight = self.total_weight - weight;
    let refund = self.funding.split(weight).into_coin(ctx);
    sui::event::emit(BlastRefunded<Quote> {
        vault_id: self.id.to_inner(),
        amount: weight,
    });

    refund
}

/// Creates an inert authority; using it against a vault always checks the current version.
public fun new_creator_cap(ctx: &mut TxContext): BlastMarketMakerCreatorCap {
    BlastMarketMakerCreatorCap { id: object::new(ctx) }
}

public fun creator_cap_id<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>): ID {
    self.creator_cap_id
}

/// Adds strategy capital without creating fee weight or a redemption claim.
/// Anyone may fund an active vault, including while discretionary trading is paused.
public fun deposit_capital<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
) {
    version.assert_current();
    assert!(self.phase == Phase::Curve || self.phase == Phase::Pool, EWrongPhase);
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyCapitalMovement);

    self.join_capital(meme.into_balance(), quote.into_balance());
    self.emit_capital_deposited(meme_amount, quote_amount);
}

/// The creator may return idle strategy capital to users or compose it in another protocol.
/// This authority is broader than delegated trading limits and remains usable while paused.
/// Funding refunds, fee balances and positions (including the burned base) are never spent.
public fun withdraw_capital<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
    version: &PackageVersion,
    meme_amount: u64,
    quote_amount: u64,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    version.assert_current();
    self.assert_creator(cap);
    assert!(self.phase == Phase::Curve || self.phase == Phase::Pool, EWrongPhase);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyCapitalMovement);
    assert!(
        meme_amount <= self.capital_meme.value() && quote_amount <= self.capital_quote.value(),
        EInsufficientCapital,
    );

    let meme = self.capital_meme.split(meme_amount).into_coin(ctx);
    let quote = self.capital_quote.split(quote_amount).into_coin(ctx);
    sui::event::emit(BlastCapitalWithdrawn<Meme, Quote> {
        vault_id: self.id.to_inner(),
        creator_cap_id: self.creator_cap_id,
        meme_amount,
        quote_amount,
    });
    (meme, quote)
}

/// Returns unallocated Meme/Quote and reserved Meme/Quote balances, in that order.
public fun fee_balances<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
): (u64, u64, u64, u64) {
    (
        self.meme_fees.available(),
        self.quote_fees.available(),
        self.meme_fees.reserved(),
        self.quote_fees.reserved(),
    )
}

/// On-chain fee balances are public; this view reports a backer's funded entitlement.
public fun claimable_fees<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    backer: address,
): (u64, u64) {
    if (!self.backers.contains(backer)) return (0, 0);
    let claim = self.backers.borrow(backer);
    (
        self.meme_fees.claimable(&claim.meme, claim.weight),
        self.quote_fees.claimable(&claim.quote, claim.weight),
    )
}

/// Only received, unallocated fees may be kept, shared or moved into trading capital.
/// Existing backer reserves and principal remain outside this fee-only payout path.
public fun allocate_fees<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
    version: &PackageVersion,
    meme: FeeAllocation,
    quote: FeeAllocation,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    version.assert_current();
    self.assert_creator(cap);
    assert!(self.phase == Phase::Curve || self.phase == Phase::Pool, EWrongPhase);
    assert!(!meme.is_empty() || !quote.is_empty(), EEmptyAllocation);
    let (kept_meme, reinvested_meme) = self.meme_fees.allocate(meme, self.total_weight);
    let (kept_quote, reinvested_quote) = self.quote_fees.allocate(quote, self.total_weight);
    self.capital_meme.join(reinvested_meme);
    self.capital_quote.join(reinvested_quote);
    sui::event::emit(BlastFeesAllocated<Meme, Quote> {
        vault_id: self.id.to_inner(),
        creator_cap_id: self.creator_cap_id,
        meme,
        quote,
        total_weight: self.total_weight,
    });
    (kept_meme.into_coin(ctx), kept_quote.into_coin(ctx))
}

/// Claims only the sender's reserved, funded fees in both assets.
public fun claim_fees<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    version.assert_current();
    assert!(self.phase == Phase::Curve || self.phase == Phase::Pool, EWrongPhase);
    assert!(self.backers.contains(ctx.sender()), ENoBackerClaim);
    let claim = self.backers.borrow_mut(ctx.sender());
    let meme = self.meme_fees.claim(&mut claim.meme, claim.weight);
    let quote = self.quote_fees.claim(&mut claim.quote, claim.weight);
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    if (meme_amount > 0 || quote_amount > 0)
        sui::event::emit(BlastBackerFeesClaimed<Meme, Quote> {
            vault_id: self.id.to_inner(),
            meme_amount,
            quote_amount,
        });
    (meme.into_coin(ctx), quote.into_coin(ctx))
}

/// Credits only the separately charged curve fundraising fee, never trading revenue.
public fun credit_raise_fees_to_treasury<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    treasury: &mut BlastMarketMakerTreasury,
) {
    version.assert_current();
    self.assert_treasury(treasury);
    assert!(self.raise_fees.value() > 0, ENothingClaimable);
    treasury.credit(version, self.id.to_inner(), self.raise_fees.withdraw_all());
}

public fun set_paused<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
    version: &PackageVersion,
    paused: bool,
) {
    version.assert_current();
    self.assert_creator(cap);
    assert!(self.paused != paused, EValueUnchanged);

    self.paused = paused;
    sui::event::emit(BlastPauseChanged { vault_id: self.id.to_inner(), paused });
}

public fun rotate_operator<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
    version: &PackageVersion,
    recipient: address,
    ctx: &mut TxContext,
) {
    version.assert_current();
    self.assert_creator(cap);
    assert!(recipient != @0x0, EZeroAuthority);
    let previous_cap_id = self.operator_cap_id;
    let successor = BlastMarketMakerOperatorCap {
        id: object::new(ctx),
        vault_id: self.id.to_inner(),
    };

    self.operator_cap_id = object::id(&successor);
    transfer::public_transfer(successor, recipient);
    sui::event::emit(BlastOperatorChanged {
        vault_id: self.id.to_inner(),
        previous_cap_id,
        successor_cap_id: self.operator_cap_id,
        recipient,
    });
}

public fun rotate_signer<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
    version: &PackageVersion,
    signer_pk: vector<u8>,
) {
    version.assert_current();
    self.assert_creator(cap);
    assert!(signer_pk.length() == 32, EInvalidSigner);
    assert!(signer_pk != self.signer_pk, EValueUnchanged);
    let previous_pk = self.signer_pk;

    self.signer_pk = signer_pk;
    self.signer_epoch = self.signer_epoch + 1;
    sui::event::emit(BlastSignerChanged {
        vault_id: self.id.to_inner(),
        previous_pk,
        signer_pk,
        signer_epoch: self.signer_epoch,
    });
}

/// Rebinds one vault without transferring control of other vaults using the same cap.
public fun set_creator_cap<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
    version: &PackageVersion,
    successor: &BlastMarketMakerCreatorCap,
) {
    version.assert_current();
    self.assert_creator(cap);
    let successor_cap_id = object::id(successor);
    assert!(successor_cap_id != self.creator_cap_id, EValueUnchanged);
    let previous_cap_id = self.creator_cap_id;
    self.creator_cap_id = successor_cap_id;
    sui::event::emit(BlastCreatorChanged {
        vault_id: self.id.to_inner(),
        previous_cap_id,
        successor_cap_id,
    });
}

/// Inert caller-owned stale objects can be deleted without any generation-dependent mutation.
public fun destroy_stale_operator_cap<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    cap: BlastMarketMakerOperatorCap,
) {
    assert!(
        cap.vault_id == self.id.to_inner() && object::id(&cap) != self.operator_cap_id,
        ENotStaleCap,
    );
    let BlastMarketMakerOperatorCap { id, vault_id: _ } = cap;
    id.delete();
}

// === Package Functions ===

public(package) fun curve_route(): Route { Route::Curve }

public(package) fun presale_route(): Route { Route::Presale }

public(package) fun new<Meme, Quote>(
    route: Route,
    target: u64,
    deadline_at_ms: u64,
    operator: address,
    creator: &BlastMarketMakerCreatorCap,
    signer_pk: vector<u8>,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &BlastMarketMakerTreasury,
    ctx: &mut TxContext,
): BlastMarketMakerVault<Meme, Quote> {
    version.assert_current();
    policy.assert_canonical(version);
    treasury.assert_canonical(version);
    assert!(
        std::type_name::with_original_ids<Meme>() != std::type_name::with_original_ids<Quote>(),
        EIdenticalAssets,
    );
    assert!(target > 0 && deadline_at_ms > 0, EInvalidDeadline);
    assert!(operator != @0x0, EZeroAuthority);
    assert!(signer_pk.length() == 32, EInvalidSigner);
    if (route == Route::Curve) assert!(target >= 10_000_000, ECurveTargetBelowMinimum);
    let new_address_minimum = if (route == Route::Curve)
        10_000_000u64.max(
            (((target as u128) + (MAX_BACKERS as u128) - 1) / (MAX_BACKERS as u128)) as u64,
        ) else 0;
    let id = object::new(ctx);
    let vault_id = id.to_inner();
    let operator_cap = BlastMarketMakerOperatorCap { id: object::new(ctx), vault_id };
    let operator_cap_id = object::id(&operator_cap);
    let creator_cap_id = object::id(creator);
    let phase = if (route == Route::Curve) Phase::Funding else Phase::Presale;

    transfer::public_transfer(operator_cap, operator);
    BlastMarketMakerVault {
        id,
        route,
        phase,
        target,
        new_address_minimum,
        deadline_at_ms,
        external_id: option::none(),
        pool_id: option::none(),
        policy_id: object::id(policy),
        treasury_id: object::id(treasury),
        raise_bps: if (route == Route::Curve) CURVE_RAISE_BPS else 0,
        maximum_lp_bps: market_maker_fee_policy::maximum(),
        paused: false,
        operator_cap_id,
        creator_cap_id,
        signer_pk,
        signer_epoch: 0,
        nonce: 0,
        limits: option::none(),
        spent_meme: 0,
        spent_quote: 0,
        actions: 0,
        meme_bucket: 0,
        quote_bucket: 0,
        bucket_at_ms: 0,
        curve_quote_basis: 0,
        pool_quote_input: 0,
        funding: balance::zero(),
        capital_meme: balance::zero(),
        capital_quote: balance::zero(),
        meme_fees: fee_ledger::new(),
        quote_fees: fee_ledger::new(),
        raise_fees: balance::zero(),
        backers: table::new(ctx),
        total_weight: 0,
    }
}

/// Presales cannot guarantee retained Quote before the actual upstream handoff.
/// V1 admits only a zero idle floor, preserving discretionary trading even with tiny retention.
public(package) fun assert_presale_limits(limits: &TradingLimits) {
    assert!(limits.idle_quote == 0, EInvalidTradingLimits);
}

public(package) fun set_trading_limits<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    limits: TradingLimits,
) {
    assert!(self.limits.is_none(), ELimitsAlreadyConfigured);
    if (self.route == Route::Presale) limits.assert_presale_limits();
    self.meme_bucket = limits.meme_bucket_capacity;
    self.quote_bucket = limits.quote_bucket_capacity;
    self.limits = option::some(limits);
}

public(package) fun share<Meme, Quote>(self: BlastMarketMakerVault<Meme, Quote>) {
    assert!(self.limits.is_some(), EInvalidTradingLimits);
    sui::event::emit(BlastMarketMakerCreated<Meme, Quote> {
        vault_id: self.id.to_inner(),
        route: self.route,
        target: self.target,
        new_address_minimum: self.new_address_minimum,
        deadline_at_ms: self.deadline_at_ms,
        external_id: self.external_id,
        policy_id: self.policy_id,
        treasury_id: self.treasury_id,
        raise_bps: self.raise_bps,
        maximum_lp_bps: self.maximum_lp_bps,
        signer_pk: self.signer_pk,
        signer_epoch: self.signer_epoch,
        operator_cap_id: self.operator_cap_id,
        creator_cap_id: self.creator_cap_id,
        limits: *self.limits.borrow(),
    });
    transfer::share_object(self);
}

public(package) fun bind_external<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    external_id: ID,
) {
    assert!(self.external_id.is_none(), EExternalAlreadyBound);
    self.external_id = option::some(external_id);
    sui::event::emit(BlastExternalBound { vault_id: self.id.to_inner(), external_id });
}

public(package) fun assert_external<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    external_id: ID,
) {
    assert!(self.external_id.contains(&external_id), EWrongExternalObject);
}

public(package) fun assert_presale_route<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>) {
    assert!(self.route == Route::Presale, EWrongRoute);
}

public(package) fun assert_can_contribute<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    clock: &Clock,
) {
    version.assert_current();
    assert!(!self.paused, EPaused);
    assert!(self.phase == Phase::Funding || self.phase == Phase::Presale, EWrongPhase);
    assert!(clock.timestamp_ms() < self.deadline_at_ms, EDeadlineReached);
}

public(package) fun record_presale_contribution<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    accepted: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    self.assert_can_contribute(version, clock);
    self.assert_presale_route();
    assert!(accepted > 0, EZeroContribution);
    assert!(accepted <= self.target - self.total_weight, EFundingAboveTarget);
    self.assert_backer_capacity(ctx.sender());

    self.record_weight(accepted, ctx.sender());
    sui::event::emit(BlastContributed<Quote> {
        vault_id: self.id.to_inner(),
        accepted,
        total_weight: self.total_weight,
    });
}

public(package) fun charge_raise_fee_and_enter_curve<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    clock: &Clock,
): Balance<Quote> {
    self.assert_can_contribute(version, clock);
    assert!(self.route == Route::Curve && self.phase == Phase::Funding, EWrongRoute);
    assert!(self.total_weight == self.target, ETargetNotFilled);
    let fee = market_maker_math::apply_down(self.target, self.raise_bps);

    let gross = self.funding.value();
    self.raise_fees.join(self.funding.split(fee));
    let net = self.funding.value();
    self.phase = Phase::Curve;
    sui::event::emit(BlastCurveFundingActivated<Quote> {
        vault_id: self.id.to_inner(),
        gross,
        raise_fee: fee,
        net,
    });
    self.funding.withdraw_all()
}

public(package) fun activate_pool<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    pool_id: ID,
) {
    assert!(self.phase == Phase::Curve || self.phase == Phase::Presale, EWrongPhase);
    assert!(self.pool_id.is_none(), EPoolAlreadyBound);

    self.pool_id = option::some(pool_id);
    self.phase = Phase::Pool;
    sui::event::emit(BlastPoolActivated {
        vault_id: self.id.to_inner(),
        pool_id,
        total_weight: self.total_weight,
    });
}

public(package) fun assert_pool<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    pool_id: ID,
) {
    assert!(self.phase == Phase::Pool && self.pool_id.contains(&pool_id), EWrongPool);
}

public(package) fun join_capital<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.capital_meme.join(meme);
    self.capital_quote.join(quote);
}

public(package) fun credit_lp_fees<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &mut BlastMarketMakerTreasury,
    mut meme: Balance<Meme>,
    mut quote: Balance<Quote>,
) {
    version.assert_current();
    assert!(object::id(policy) == self.policy_id, EWrongFeePolicy);
    self.assert_treasury(treasury);
    let (meme_bps, quote_bps) = policy.capped_rates(version, self.maximum_lp_bps);
    let gross_meme = meme.value();
    let gross_quote = quote.value();
    let protocol_meme = market_maker_math::apply_up(gross_meme, meme_bps);
    let protocol_quote = market_maker_math::apply_up(gross_quote, quote_bps);

    treasury.credit(version, self.id.to_inner(), meme.split(protocol_meme));
    treasury.credit(version, self.id.to_inner(), quote.split(protocol_quote));
    sui::event::emit(BlastLpFeesCollected<Meme, Quote> {
        vault_id: self.id.to_inner(),
        gross_meme,
        gross_quote,
        protocol_meme,
        protocol_quote,
        meme_bps,
        quote_bps,
    });
    self.credit_received_fees(meme, quote);
}

public(package) fun credit_curve_fees<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.credit_received_fees(meme, quote);
}

public(package) fun add_adapter_state<Meme, Quote, Key: copy + drop + store, Value: store>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    key: Key,
    value: Value,
) {
    self.id.add_dynamic_field(key, value);
}

public(package) fun has_adapter_state<Meme, Quote, Key: copy + drop + store>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): bool { dynamic_field::exists(&self.id, key) }

public(package) fun adapter_state<Meme, Quote, Key: copy + drop + store, Value: store>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): &Value {
    self.id.borrow_dynamic_field(key)
}

public(package) fun adapter_state_mut<Meme, Quote, Key: copy + drop + store, Value: store>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): &mut Value {
    self.id.borrow_dynamic_field_mut(key)
}

public(package) fun escrow_child<Meme, Quote, Key: copy + drop + store, Child: key + store>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    key: Key,
    child: Child,
) {
    sui::dynamic_object_field::add(&mut self.id, key, child);
}

public(package) fun escrowed_child<Meme, Quote, Key: copy + drop + store, Child: key + store>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): &Child {
    sui::dynamic_object_field::borrow(&self.id, key)
}

public(package) fun escrowed_child_mut<Meme, Quote, Key: copy + drop + store, Child: key + store>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): &mut Child {
    sui::dynamic_object_field::borrow_mut(&mut self.id, key)
}

public(package) fun take_escrowed_child<Meme, Quote, Key: copy + drop + store, Child: key + store>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): Child {
    sui::dynamic_object_field::remove(&mut self.id, key)
}

public(package) fun restore_escrowed_child<
    Meme,
    Quote,
    Key: copy + drop + store,
    Child: key + store,
>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    key: Key,
    child: Child,
) {
    sui::dynamic_object_field::add(&mut self.id, key, child);
}

/// All locally available authority/economic checks precede signature work and venue calls.
public(package) fun authorize_action<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    version: &PackageVersion,
    cap: Option<ID>,
    action: Action,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: &vector<u8>,
    clock: &Clock,
) {
    version.assert_current();
    let unwind = action.is_unwind();
    assert!(unwind || !self.paused, EPaused);
    assert!(
        if (action.is_curve()) self.phase == Phase::Curve else self.phase == Phase::Pool,
        EWrongPhase,
    );
    if (!unwind) {
        assert!(cap.is_some(), EWrongOperator);
        let cap = cap.destroy_some();
        assert!(cap == self.operator_cap_id, EWrongOperator);
        assert!(self.actions < self.limits.borrow().action_limit, EActionLimit);
    } else {
        assert!(cap.is_none(), EWrongOperator);
    };
    let (meme, quote) = action.inputs();
    let limits = self.limits.borrow();
    assert!(meme <= limits.max_meme_input && quote <= limits.max_quote_input, ETradingInputLimit);
    assert!(
        (self.spent_meme as u128) + (meme as u128) <= (limits.lifetime_meme_input as u128),
        ETradingInputLimit,
    );
    assert!(
        (self.spent_quote as u128) + (quote as u128) <= (limits.lifetime_quote_input as u128),
        ETradingInputLimit,
    );
    let (meme_available, quote_available) = self.refilled_buckets(clock);
    assert!(meme <= meme_available && quote <= quote_available, ERateLimit);
    assert!(
        meme <= self.capital_meme.value() && quote <= self.capital_quote.value(),
        EInsufficientCapital,
    );
    assert!(quote == 0 || self.capital_quote.value() - quote >= limits.idle_quote, EIdleQuoteFloor);
    let message = self.signing_bytes(action, issued_at_ms, expires_at_ms);

    risk::verify(&self.signer_pk, signature, &message, issued_at_ms, expires_at_ms, clock);
}

/// Charge actual asset inputs after successful venue results. Any budget refusal rolls back all effects.
public(package) fun finish_action<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    action: Action,
    meme: u64,
    quote: u64,
    curve_basis: u64,
    pool_quote: u64,
    clock: &Clock,
) {
    let limits = *self.limits.borrow();
    let next_curve = (self.curve_quote_basis as u128) + (curve_basis as u128);
    let next_pool = (self.pool_quote_input as u128) + (pool_quote as u128);
    assert!(
        next_curve <= (limits.curve_quote_basis_limit as u128) && next_pool <= (limits.pool_quote_input_limit as u128),
        ESelfFeeLimit,
    );
    let (approved_meme, approved_quote) = action.inputs();
    assert!(meme <= approved_meme && quote <= approved_quote, ETradingInputLimit);
    let (meme_available, quote_available) = self.refilled_buckets(clock);
    let nonce = self.nonce.checked_add(1).destroy_or!(abort ENonceOverflow);
    let actions = if (action.is_unwind()) self.actions
    else self.actions.checked_add(1).destroy_or!(abort EActionLimit);
    assert!(actions <= limits.action_limit, EActionLimit);
    assert!(
        action.is_unwind() || self.capital_quote.value() >= limits.idle_quote,
        EIdleQuoteFloor,
    );

    self.spent_meme = self.spent_meme + meme;
    self.spent_quote = self.spent_quote + quote;
    self.curve_quote_basis = next_curve as u64;
    self.pool_quote_input = next_pool as u64;
    self.meme_bucket = meme_available - meme;
    self.quote_bucket = quote_available - quote;
    self.bucket_at_ms = clock.timestamp_ms();
    self.actions = actions;
    self.nonce = nonce;
    sui::event::emit(BlastActionExecuted {
        vault_id: self.id.to_inner(),
        action,
        nonce: nonce - 1,
        actions,
        meme_input: meme,
        quote_input: quote,
        curve_quote_basis: self.curve_quote_basis,
        pool_quote_input: self.pool_quote_input,
        capital_meme: self.capital_meme.value(),
        capital_quote: self.capital_quote.value(),
    });
}

public(package) fun check_initial_budget<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    initial_budget: u64,
    idle_floor: u64,
) {
    let net = self.target - market_maker_math::apply_down(self.target, self.raise_bps);
    assert!(
        initial_budget > 0 && initial_budget <= net && net - initial_budget >= idle_floor,
        EInvalidTradingLimits,
    );
    assert!(
        initial_budget <= self.limits.borrow().curve_quote_basis_limit && idle_floor >= self.limits.borrow().idle_quote,
        ESelfFeeLimit,
    );
}

public(package) fun record_initial_buy<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    spent: u64,
    floor: u64,
) {
    assert!(spent <= self.limits.borrow().curve_quote_basis_limit, ESelfFeeLimit);
    assert!(self.capital_quote.value() >= floor, EIdleQuoteFloor);
    self.curve_quote_basis = spent;
    sui::event::emit(BlastInitialBuyCompleted {
        vault_id: self.id.to_inner(),
        spent,
        capital_meme: self.capital_meme.value(),
        capital_quote: self.capital_quote.value(),
    });
}

public(package) fun take_capital_meme<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    amount: u64,
): Balance<Meme> {
    assert!(amount <= self.capital_meme.value(), EInsufficientCapital);
    self.capital_meme.split(amount)
}

public(package) fun take_capital_quote<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    amount: u64,
): Balance<Quote> {
    assert!(amount <= self.capital_quote.value(), EInsufficientCapital);
    self.capital_quote.split(amount)
}

public(package) fun receive_curve_cap<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    cap: sui::transfer::Receiving<blast_fun::creator_authority::CurveFeeCap<Meme>>,
): blast_fun::creator_authority::CurveFeeCap<Meme> {
    transfer::public_receive(&mut self.id, cap)
}

/// Receives pair assets sent to this vault's address. Native Receiving proves ownership,
/// not sender provenance; these receipts create capital only, never fee rights.
public(package) fun receive_capital_meme<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    coin: sui::transfer::Receiving<Coin<Meme>>,
) {
    assert!(self.phase == Phase::Curve || self.phase == Phase::Pool, EWrongPhase);
    let meme = transfer::public_receive(&mut self.id, coin);
    let amount = meme.value();

    self.capital_meme.join(meme.into_balance());
    if (amount > 0) self.emit_capital_deposited(amount, 0);
}

public(package) fun receive_capital_quote<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    coin: sui::transfer::Receiving<Coin<Quote>>,
) {
    assert!(self.phase == Phase::Curve || self.phase == Phase::Pool, EWrongPhase);
    let quote = transfer::public_receive(&mut self.id, coin);
    let amount = quote.value();

    self.capital_quote.join(quote.into_balance());
    if (amount > 0) self.emit_capital_deposited(0, amount);
}

public(package) fun has_escrowed_child<Meme, Quote, Key: copy + drop + store>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    key: Key,
): bool {
    sui::dynamic_object_field::exists(&self.id, key)
}

public(package) fun assert_curve<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>) {
    assert!(self.phase == Phase::Curve, EWrongPhase);
}

public(package) fun assert_refunding<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>) {
    assert!(self.phase == Phase::Refunding, EWrongPhase);
}

/// Existing contributors may top up even when every distinct-address slot is occupied.
public(package) fun assert_backer_slot(existing: bool, count: u64) {
    assert!(existing || count < MAX_BACKERS, EBackerCapacity);
}

// === Private Functions ===

fun refilled_buckets<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    clock: &Clock,
): (u64, u64) {
    assert!(clock.timestamp_ms() >= self.bucket_at_ms, EClockRegression);
    let elapsed = (clock.timestamp_ms() - self.bucket_at_ms) as u256;
    let limits = self.limits.borrow();
    let meme = ((self.meme_bucket as u256) + elapsed * (limits.meme_refill_per_ms as u256)).min(
        limits.meme_bucket_capacity as u256,
    );
    let quote = ((self.quote_bucket as u256) + elapsed * (limits.quote_refill_per_ms as u256)).min(
        limits.quote_bucket_capacity as u256,
    );

    (meme as u64, quote as u64)
}

fun assert_backer_capacity<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    backer: address,
) {
    assert_backer_slot(self.backers.contains(backer), self.backers.length());
}

fun record_weight<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    accepted: u64,
    backer: address,
) {
    if (self.backers.contains(backer)) {
        let claim = self.backers.borrow_mut(backer);
        claim.weight = claim.weight + accepted;
    } else {
        self
            .backers
            .add(
                backer,
                BackerClaim {
                    weight: accepted,
                    meme: fee_ledger::new_claim(),
                    quote: fee_ledger::new_claim(),
                },
            );
    };
    self.total_weight = self.total_weight + accepted;
}

fun assert_treasury<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    treasury: &BlastMarketMakerTreasury,
) {
    assert!(object::id(treasury) == self.treasury_id, EWrongTreasury);
}

fun assert_creator<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    cap: &BlastMarketMakerCreatorCap,
) {
    assert!(object::id(cap) == self.creator_cap_id, EWrongCreator);
}

fun credit_received_fees<Meme, Quote>(
    self: &mut BlastMarketMakerVault<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    let meme_received = meme.value();
    let quote_received = quote.value();
    self.meme_fees.credit(meme);
    self.quote_fees.credit(quote);
    if (meme_received > 0 || quote_received > 0)
        sui::event::emit(BlastFeesCredited<Meme, Quote> {
            vault_id: self.id.to_inner(),
            meme_received,
            quote_received,
        });
}

fun emit_capital_deposited<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(BlastCapitalDeposited<Meme, Quote> {
        vault_id: self.id.to_inner(),
        meme_amount,
        quote_amount,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun weight_for_testing<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
    backer: address,
): u64 {
    if (self.backers.contains(backer)) self.backers.borrow(backer).weight else 0
}

#[test_only]
public fun total_weight_for_testing<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>): u64 {
    self.total_weight
}

#[test_only]
public fun capital_for_testing<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>): (u64, u64) {
    (self.capital_meme.value(), self.capital_quote.value())
}

#[test_only]
public fun is_pool_for_testing<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>): bool {
    self.phase == Phase::Pool
}

#[test_only]
public fun phase_for_testing<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>): Phase {
    self.phase
}

#[test_only]
public fun external_for_testing<Meme, Quote>(
    self: &BlastMarketMakerVault<Meme, Quote>,
): Option<ID> {
    self.external_id
}

#[test_only]
public fun raise_fees_for_testing<Meme, Quote>(self: &BlastMarketMakerVault<Meme, Quote>): u64 {
    self.raise_fees.value()
}

// === Events ===

public struct BlastMarketMakerCreated<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    route: Route,
    target: u64,
    new_address_minimum: u64,
    deadline_at_ms: u64,
    external_id: Option<ID>,
    policy_id: ID,
    treasury_id: ID,
    raise_bps: u64,
    maximum_lp_bps: u64,
    signer_pk: vector<u8>,
    signer_epoch: u64,
    operator_cap_id: ID,
    creator_cap_id: ID,
    limits: TradingLimits,
}
public struct BlastExternalBound has copy, drop { vault_id: ID, external_id: ID }
/// Completed curve fundraising transition; gross equals raise_fee plus net deployed capital.
public struct BlastCurveFundingActivated<phantom Quote> has copy, drop {
    vault_id: ID,
    gross: u64,
    raise_fee: u64,
    net: u64,
}

public struct BlastContributed<phantom Quote> has copy, drop {
    vault_id: ID,
    accepted: u64,
    total_weight: u64,
}
public struct BlastRefundingStarted has copy, drop { vault_id: ID }
public struct BlastRefunded<phantom Quote> has copy, drop { vault_id: ID, amount: u64 }
public struct BlastBackerFeesClaimed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}
public struct BlastPauseChanged has copy, drop { vault_id: ID, paused: bool }
public struct BlastOperatorChanged has copy, drop {
    vault_id: ID,
    previous_cap_id: ID,
    successor_cap_id: ID,
    recipient: address,
}
public struct BlastSignerChanged has copy, drop {
    vault_id: ID,
    previous_pk: vector<u8>,
    signer_pk: vector<u8>,
    signer_epoch: u64,
}
public struct BlastCreatorChanged has copy, drop {
    vault_id: ID,
    previous_cap_id: ID,
    successor_cap_id: ID,
}
public struct BlastPoolActivated has copy, drop { vault_id: ID, pool_id: ID, total_weight: u64 }
public struct BlastLpFeesCollected<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    gross_meme: u64,
    gross_quote: u64,
    protocol_meme: u64,
    protocol_quote: u64,
    meme_bps: u64,
    quote_bps: u64,
}
public struct BlastFeesCredited<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme_received: u64,
    quote_received: u64,
}
public struct BlastFeesAllocated<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    creator_cap_id: ID,
    meme: FeeAllocation,
    quote: FeeAllocation,
    total_weight: u64,
}

public struct BlastCapitalDeposited<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}
public struct BlastCapitalWithdrawn<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    creator_cap_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

public struct BlastActionExecuted has copy, drop {
    vault_id: ID,
    action: Action,
    nonce: u64,
    actions: u64,
    meme_input: u64,
    quote_input: u64,
    curve_quote_basis: u64,
    pool_quote_input: u64,
    capital_meme: u64,
    capital_quote: u64,
}
public struct BlastInitialBuyCompleted has copy, drop {
    vault_id: ID,
    spent: u64,
    capital_meme: u64,
    capital_quote: u64,
}

// === Constants ===

const MAX_BACKERS: u64 = 10_000;
const CURVE_RAISE_BPS: u64 = 500;

// === Errors ===

#[error(code = 0)]
const EInvalidTradingLimits: vector<u8> =
    b"Trading limits must be positive, bounded and internally consistent.";
#[error(code = 1)]
const EWrongRoute: vector<u8> = b"The market maker belongs to the other launch route.";
#[error(code = 2)]
const EZeroContribution: vector<u8> = b"The accepted contribution must be positive.";
#[error(code = 3)]
const EWrongPhase: vector<u8> = b"The market maker lifecycle does not permit this action.";
#[error(code = 4)]
const EDeadlineNotReached: vector<u8> = b"The curve funding deadline has not been reached.";
#[error(code = 5)]
const ENothingRefundable: vector<u8> = b"The sender has no refundable curve contribution.";
#[error(code = 6)]
const ENoBackerClaim: vector<u8> = b"The sender has no market maker fee rights.";
#[error(code = 7)]
const ENothingClaimable: vector<u8> = b"The segregated protocol balance is empty.";
#[error(code = 8)]
const EValueUnchanged: vector<u8> = b"The proposed authority value must change.";
#[error(code = 9)]
const EZeroAuthority: vector<u8> = b"An authority address must be nonzero.";
#[error(code = 10)]
const EInvalidSigner: vector<u8> = b"An Ed25519 public key must contain exactly 32 bytes.";
#[error(code = 11)]
const EInvalidDeadline: vector<u8> = b"The target and deadline must be positive and fit u64.";
#[error(code = 12)]
const ENotStaleCap: vector<u8> = b"Only an owned stale cap for this market maker may be retired.";
#[error(code = 13)]
const EIdenticalAssets: vector<u8> = b"The Meme and Quote assets must differ.";
#[error(code = 14)]
const ELimitsAlreadyConfigured: vector<u8> =
    b"Trading limits are committed exactly once before sharing.";
#[error(code = 15)]
const EExternalAlreadyBound: vector<u8> =
    b"The market maker's external launch identity is immutable.";
#[error(code = 16)]
const EWrongExternalObject: vector<u8> =
    b"The supplied launch or presale belongs to another market maker.";
#[error(code = 17)]
const EPaused: vector<u8> = b"The market maker is paused for discretionary actions.";
#[error(code = 18)]
const EDeadlineReached: vector<u8> = b"The exclusive contribution deadline has been reached.";
#[error(code = 19)]
const EFundingAboveTarget: vector<u8> =
    b"Wrapper contributions cannot exceed the committed target.";
#[error(code = 20)]
const ETargetNotFilled: vector<u8> = b"The curve fundraising target must be filled exactly.";
#[error(code = 21)]
const EPoolAlreadyBound: vector<u8> = b"The market maker already has its immutable pool binding.";
#[error(code = 22)]
const EWrongPool: vector<u8> = b"The pool is not this market maker's active pool.";
#[error(code = 23)]
const EWrongFeePolicy: vector<u8> = b"The LP policy is not the one committed by this market maker.";
#[error(code = 24)]
const EBackerCapacity: vector<u8> = b"The maximum number of distinct fee backers has been reached.";
#[error(code = 25)]
const EWrongTreasury: vector<u8> =
    b"Only the market maker's canonical protocol treasury may receive protocol assets.";
#[error(code = 26)]
const EWrongCreator: vector<u8> = b"The creator cap is not bound to this market maker.";

#[error(code = 27)]
const EContributionBelowMinimum: vector<u8> =
    b"A new curve backer must offer the committed minimum payment.";
#[error(code = 28)]
const ECurveTargetBelowMinimum: vector<u8> = b"The curve funding target must be at least 0.01 SUI.";

#[error(code = 29)]
const EWrongOperator: vector<u8> = b"The operator cap is stale or belongs to another market maker.";
#[error(code = 30)]
const EActionLimit: vector<u8> = b"The immutable discretionary action limit is exhausted.";
#[error(code = 31)]
const ETradingInputLimit: vector<u8> =
    b"The action exceeds its per-action or lifetime gross input ceiling.";
#[error(code = 32)]
const ERateLimit: vector<u8> = b"The immutable token bucket cannot cover this gross input.";
#[error(code = 33)]
const EInsufficientCapital: vector<u8> =
    b"The action cannot spend fee liabilities or more than retained capital.";
#[error(code = 34)]
const EIdleQuoteFloor: vector<u8> = b"The action must preserve the committed idle Quote floor.";
#[error(code = 35)]
const ESelfFeeLimit: vector<u8> = b"The immutable self-fee conversion basis is exhausted.";
#[error(code = 36)]
const ENonceOverflow: vector<u8> = b"The next authorization nonce must fit u64.";
#[error(code = 37)]
const EClockRegression: vector<u8> =
    b"The canonical Clock cannot precede the previous token-bucket update.";

#[error(code = 38)]
const EEmptyAllocation: vector<u8> = b"Allocate a positive amount of received fees.";
#[error(code = 39)]
const EEmptyCapitalMovement: vector<u8> = b"Move a positive amount of market-making capital.";

// === Imports ===

use blast_market_maker::{
    market_maker_fee_policy::{Self, BlastMarketMakerFeePolicy},
    market_maker_math,
    fee_ledger::{Self, FeeLedger, FeeClaim, FeeAllocation},
    package_version::BlastMarketMakerVersion as PackageVersion,
    protocol_treasury::BlastMarketMakerTreasury,
    risk::{Self, Action},
};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_field, table::{Self, Table}};

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow as UID.borrow_dynamic_field;
use fun dynamic_field::borrow_mut as UID.borrow_dynamic_field_mut;
