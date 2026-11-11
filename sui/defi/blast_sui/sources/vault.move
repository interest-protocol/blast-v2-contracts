// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Single-validator custody of the 1:1 funSUI ledger and the blastSUI share ledger.
module blast_sui::vault;

// === Public Types ===

/// Shared owner of the treasury-cap, metadata-cap and display-cap child objects and the two
/// native custody ledgers.
///
/// `fun_custody` backs only funSUI plus the protocol-funded rounding reserve,
/// and `blast_custody` backs only blastSUI, including the seed shares locked
/// at `@0x0` by `create`; both delegate only through `pool_id`.
/// blastSUI supply is therefore never zero after creation. `rate_epoch`,
/// `rate_sui`, and `rate_pool_tokens` cache the pool exchange-rate entry last
/// observed for a current epoch; a refresh in an epoch without an entry keeps
/// this conservative rate instead of scanning the table. `redeem_fee` is the
/// blastSUI redemption fee; every change waits its applied delay. `unwind_only`
/// records that the validator left the active set.
public struct Vault has key {
    id: UID,
    pool_id: ID,
    fun_custody: Custody,
    blast_custody: Custody,
    rate_epoch: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    redeem_fee: Delayed<RedeemFeeKey, u64>,
    unwind_only: bool,
}

/// Keys the redemption fee's delayed lifecycle.
public struct RedeemFeeKey() has copy, drop, store;

/// Type-derived key for a treasury cap owned as a discoverable child object.
public struct TreasuryKey<phantom CoinType>() has copy, drop, store;

/// Type-derived key for a metadata or display capability sealed as a discoverable child object.
public struct CapabilityKey<phantom Capability>() has copy, drop, store;

// === Public Functions ===

/// Creates and shares the vault from the owner seed, locking every seed share.
///
/// Both treasury caps must be empty. The pool's canonical validator must be
/// active and the pool must have an exchange-rate entry for the current epoch.
/// The seed must cover the fun rounding reserve plus a blast bootstrap of at
/// least the native minimum stake: the reserve enters fun custody as liquid
/// protocol capital that mints nothing, and the remainder enters blast custody,
/// mints one blastSUI share per MIST, and is delegated in this transaction.
/// The complete minted `Coin<BLAST_SUI>` is transferred to `@0x0` here, so
/// blastSUI supply stays permanently positive and the bootstrap backing can
/// never be redeemed. Nothing is returned; the treasury total supply and the
/// `VaultCreated` fact record the locked amount.
///
/// Both metadata caps and the deposit-receipt display cap are sealed as children of
/// the vault with no accessor. The redemption-fee delay starts at zero so the
/// bootstrap transaction can configure it; deposits stay paused until `unpause`,
/// which refuses while that delay is zero.
public fun create(
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    display_registry: &mut DisplayRegistry,
    fun_cap: TreasuryCap<FUN_SUI>,
    blast_cap: TreasuryCap<BLAST_SUI>,
    fun_metadata_cap: MetadataCap<FUN_SUI>,
    blast_metadata_cap: MetadataCap<BLAST_SUI>,
    owner_seed: Coin<SUI>,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    assert!(
        fun_cap.total_supply() == 0 && blast_cap.total_supply() == 0,
        blast_sui::errors::nonzero_initial_supply!(),
    );

    let fun_reserve_sui = constants::fun_rounding_reserve_mist!();
    assert!(
        owner_seed.value() >= constants::native_min_stake_mist!() + fun_reserve_sui,
        blast_sui::errors::bootstrap_below_native_minimum!(),
    );

    let validator = system_state.validator_address_by_pool_id(&pool_id);
    assert!(
        system_state.active_validator_addresses_ref().contains(&validator),
        blast_sui::errors::validator_not_active!(),
    );

    let epoch = ctx.epoch();
    let (is_current, rate_sui, rate_pool_tokens) = system_state.exchange_rate_at(&pool_id, epoch);
    assert!(is_current, blast_sui::errors::stale_exchange_rate!());

    let mut seed = owner_seed.into_balance();
    let fun_reserve = seed.split(fun_reserve_sui);
    let bootstrap_sui = seed.value();
    let id = object::new(ctx);
    let redeem_fee = delayed::new(RedeemFeeKey(), &id, constants::default_redeem_fee_bps!(), 0);
    let mut self = Vault {
        id,
        pool_id,
        fun_custody: custody::new(),
        blast_custody: custody::new(),
        rate_epoch: epoch,
        rate_sui,
        rate_pool_tokens,
        redeem_fee,
        unwind_only: false,
    };

    self.add_treasury_cap(fun_cap);
    self.add_treasury_cap(blast_cap);
    self.add_capability(fun_metadata_cap);
    self.add_capability(blast_metadata_cap);
    self.add_capability(deposit_receipt::create_display(display_registry, ctx));
    self.fun_custody.deposit(fun_reserve);
    self.blast_custody.deposit(seed);
    let vault_pool_id = self.pool_id;
    self.blast_custody.stake_idle(system_state, validator, &vault_pool_id, 0, ctx);
    let locked_coin = self.treasury_cap_mut<BLAST_SUI>().mint(bootstrap_sui, ctx);

    events::vault_created(
        self.id.to_inner(),
        validator,
        pool_id,
        fun_reserve_sui,
        bootstrap_sui,
        locked_coin.value(),
        self.redeem_fee.value(),
        self.custody(),
    );

    transfer::public_transfer(locked_coin, @0x0);
    transfer::share_object(self);
}

/// Mints funSUI one-to-one for SUI held in fun custody.
public fun mint_fun_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
): Coin<FUN_SUI> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::fun_mint_pause_bit!());

    let amount = sui_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);
    self.assert_accepts_mints();

    self.fun_custody.deposit(sui_in.into_balance());
    let fun_coin = self.treasury_cap_mut<FUN_SUI>().mint(amount, ctx);
    self.assert_fun_backed();
    self.stake_idle(system_state, ctx);

    events::fun_sui_minted(amount, self.custody());

    fun_coin
}

/// Burns funSUI and returns exactly one MIST per unit from fun custody.
public fun redeem_fun_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    fun_in: Coin<FUN_SUI>,
    ctx: &mut TxContext,
): Coin<SUI> {
    package_version.assert_current(constants::version!());

    let amount = fun_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);

    let sui_out = self
        .fun_custody
        .withdraw_exact(
            system_state,
            amount,
            self.rate_sui,
            self.rate_pool_tokens,
            ctx,
        );
    self.treasury_cap_mut<FUN_SUI>().burn(fun_in);
    self.protect_fun_exit_liquidity(system_state, ctx);
    self.stake_idle(system_state, ctx);
    self.assert_fun_backed();

    events::fun_sui_redeemed(amount, self.custody());

    sui_out.into_coin(ctx)
}

/// Delegates SUI into a key-only receipt that remains outside vault custody.
///
/// The receipt is returned for transaction composition. It can be claimed for
/// blastSUI from its activation epoch, cancelled for native SUI at any time, or
/// placed in the caller's account through `deposit_receipt::keep`.
public fun request_blast_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
): BlastSuiDepositReceipt {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::blast_request_pause_bit!());

    let amount = sui_in.value();
    assert!(
        amount >= constants::native_min_stake_mist!(),
        blast_sui::errors::blast_deposit_below_native_minimum!(),
    );
    self.refresh(system_state, ctx);
    self.assert_accepts_mints();

    let validator = system_state.validator_address_by_pool_id(&self.pool_id);
    let staked_sui = system_state.request_add_stake_non_entry(sui_in, validator, ctx);
    assert!(
        staked_sui.pool_id() == self.pool_id,
        blast_sui::errors::wrong_delegation_pool!(),
    );

    let receipt = deposit_receipt::new(self.id.to_inner(), staked_sui, ctx);
    self.stake_idle(system_state, ctx);

    events::blast_sui_deposit_requested(
        receipt.id(),
        self.id.to_inner(),
        receipt.pool_id(),
        receipt.principal_sui(),
        receipt.activation_epoch(),
        self.custody(),
    );

    receipt
}

/// Consumes an activated receipt and mints blastSUI at the current fair rate.
///
/// The receipt's native stake is external to blast custody until this call.
/// Existing holders therefore keep every reward earned before its activation.
public fun claim_blast_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    receipt: BlastSuiDepositReceipt,
    min_blast_out: u64,
    ctx: &mut TxContext,
): Coin<BLAST_SUI> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::blast_claim_pause_bit!());

    receipt.assert_binding(self.id.to_inner(), self.pool_id);
    assert!(
        receipt.activation_epoch() <= ctx.epoch(),
        blast_sui::errors::blast_deposit_not_active!(),
    );

    self.refresh(system_state, ctx);
    self.assert_accepts_mints();
    assert!(self.rate_epoch == ctx.epoch(), blast_sui::errors::stale_exchange_rate!());

    let (receipt_id, principal_sui) = (receipt.id(), receipt.principal_sui());
    let active_stake = system_state.convert_to_fungible_staked_sui(
        receipt.destroy(),
        ctx,
    );

    let pool_tokens = active_stake.value();
    let contributed_sui = math::sui_at_rate_down(
        pool_tokens,
        self.rate_sui,
        self.rate_pool_tokens,
    );
    let blast_out = math::blast_shares_out_down(
        contributed_sui,
        self.blast_custody.assets(),
        self.treasury_cap<BLAST_SUI>().total_supply(),
    );
    assert!(blast_out >= min_blast_out, blast_sui::errors::slippage_exceeded!());

    self
        .blast_custody
        .join_active_at_rate(
            active_stake,
            self.rate_sui,
            self.rate_pool_tokens,
        );
    let blast_coin = self.treasury_cap_mut<BLAST_SUI>().mint(blast_out, ctx);
    self.stake_idle(system_state, ctx);

    events::blast_sui_deposit_claimed(
        receipt_id,
        self.id.to_inner(),
        principal_sui,
        contributed_sui,
        pool_tokens,
        blast_out,
        self.custody(),
    );

    blast_coin
}

/// Adds external SUI rewards to blast custody without minting blastSUI.
///
/// The donation increases assets per existing share, including the permanently
/// locked bootstrap shares. Anyone may donate; the caller receives no receipt,
/// shares, or withdrawal authority. Idle donations are delegated when a current
/// rate proves the pool is active and remain liquid otherwise.
public fun donate_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    let amount = sui_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);

    self.blast_custody.deposit(sui_in.into_balance());
    self.stake_idle(system_state, ctx);

    events::blast_sui_donated(amount, self.custody());
}

/// Adds SUI to fun custody without refreshing, minting, or delegating.
///
/// This is the recovery path for `fun_backing_below_supply`: every other entry point
/// refreshes first and aborts while fun custody is below the funSUI supply, so a top-up
/// that must not depend on that check restores 1:1 backing for every later call. Anyone
/// may contribute; the caller receives nothing, and any amount above the supply plus the
/// rounding reserve is swept to blast custody by the next refresh.
public fun top_up_fun_reserve(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    sui_in: Coin<SUI>,
) {
    package_version.assert_current(constants::version!());

    let amount = sui_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());

    self.fun_custody.deposit(sui_in.into_balance());

    events::fun_reserve_topped_up(amount, self.custody());
}

/// Burns blastSUI for its pro-rata share of blast custody less the retained fee.
///
/// Every redemption is partial against the total supply because the locked
/// seed shares can never be presented, so every redemption pays the applied
/// redemption fee, which stays in blast custody. Redemptions never pause. The
/// quote uses the cached conservative valuation, so the caller's `min_sui_out`
/// is its protection during a safe-mode epoch.
public fun redeem_blast_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    blast_in: Coin<BLAST_SUI>,
    min_sui_out: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    package_version.assert_current(constants::version!());

    let shares = blast_in.value();
    assert!(shares > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);

    let (gross_sui, fee_sui, net_sui) = math::blast_redemption_quote(
        shares,
        self.blast_custody.assets(),
        self.treasury_cap<BLAST_SUI>().total_supply(),
        self.redeem_fee.value(),
    );
    assert!(net_sui > 0, blast_sui::errors::zero_sui_after_fee!());
    assert!(net_sui >= min_sui_out, blast_sui::errors::slippage_exceeded!());

    let sui_out = self
        .blast_custody
        .withdraw_exact(
            system_state,
            net_sui,
            self.rate_sui,
            self.rate_pool_tokens,
            ctx,
        );
    self.treasury_cap_mut<BLAST_SUI>().burn(blast_in);
    self.stake_idle(system_state, ctx);

    events::blast_sui_redeemed(shares, gross_sui, fee_sui, net_sui, self.custody());

    sui_out.into_coin(ctx)
}

/// Schedules a redemption fee of at most `max_redeem_fee_bps` and the delay in force once it
/// applies, ready after the applied delay. A pending change is replaced and its wait restarts.
public fun schedule_redeem_fee(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<FeeAdmin>,
    redeem_fee_bps: u64,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(
        redeem_fee_bps <= constants::max_redeem_fee_bps!(),
        blast_sui::errors::redeem_fee_above_maximum!(),
    );

    self.redeem_fee.schedule(redeem_fee_bps, delay_ms, clock);
}

/// Applies the scheduled redemption fee permissionlessly once ready.
public fun apply_redeem_fee(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.redeem_fee.apply(clock);
}

/// Cancels a pending redemption-fee change, including after its delay has elapsed.
public fun cancel_redeem_fee(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.redeem_fee.cancel();
}

/// Releases deposit pause `bits` once every delay is guarded. Exits have no pause bit, so
/// this never gates them.
public fun unpause(
    self: &Vault,
    package_version: &mut PackageVersion<BLAST_SUI_PACKAGE>,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_SUI_PACKAGE>>,
    package_admin: &PackageAdmin<BLAST_SUI_PACKAGE>,
    bits: u8,
) {
    package_version.assert_current(constants::version!());

    assert!(self.redeem_fee.is_guarded(), blast_sui::errors::unguarded_delay!());

    package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits);
}

/// Permissionless refresh: unwinds an inactive validator, converts activated
/// stake, revalues both ledgers, sweeps fun yield, and delegates idle SUI.
public fun sync(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    self.refresh(system_state, ctx);
    self.stake_idle(system_state, ctx);

    events::vault_synced(self.custody());
}

// === Private Functions ===

fun add_treasury_cap<CoinType>(
    self: &mut Vault,
    treasury_cap: TreasuryCap<CoinType>,
) {
    self.id.add_dynamic_object_field(TreasuryKey<CoinType>(), treasury_cap);
}

/// Seals one package capability; nothing reads it on chain, so it has no accessor.
fun add_capability<Capability: key + store>(self: &mut Vault, capability: Capability) {
    self.id.add_dynamic_object_field(CapabilityKey<Capability>(), capability);
}

fun treasury_cap<CoinType>(self: &Vault): &TreasuryCap<CoinType> {
    self.id.dynamic_object_field(TreasuryKey<CoinType>())
}

fun treasury_cap_mut<CoinType>(self: &mut Vault): &mut TreasuryCap<CoinType> {
    self.id.dynamic_object_field_mut(TreasuryKey<CoinType>())
}

/// Brings both ledgers to the current epoch with exactly one exchange-rate table lookup.
///
/// A usable current-epoch entry replaces the cache; a missing or empty entry
/// keeps the cached rate, which never exceeds the live rate because pool rates
/// only grow. Both ledgers are revalued at the applied rate before the sweep.
fun refresh(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    if (!self.unwind_only) self.refresh_native(system_state, ctx);

    self.sweep_fun_yield(ctx);
    self.protect_fun_exit_liquidity(system_state, ctx);
    self.assert_fun_backed();
}

/// Unwinds an inactive validator or applies one current rate without scanning backward.
fun refresh_native(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    let validator = system_state.validator_address_by_pool_id(&self.pool_id);
    if (!system_state.active_validator_addresses_ref().contains(&validator)) {
        self.unwind_native(system_state, ctx);
    } else {
        self.refresh_active_native(system_state, ctx);
    };
}

fun unwind_native(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    self.fun_custody.unwind(system_state, ctx);
    self.blast_custody.unwind(system_state, ctx);
    self.unwind_only = true;

    events::native_stake_unwound(self.custody());
}

fun refresh_active_native(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    let epoch = ctx.epoch();
    let (is_current, rate_sui, rate_pool_tokens) =
        system_state.exchange_rate_at(
        &self.pool_id,
        epoch
    );
    if (is_current) {
        self.rate_epoch = epoch;
        self.rate_sui = rate_sui;
        self.rate_pool_tokens = rate_pool_tokens;
    };

    // After the active-address check in `refresh_native`, a current entry proves
    // that the immutable pool itself is active. Address membership alone is not
    // enough because an address can return with a different pool.
    if (is_current) self.blast_custody.activate_pending(system_state, ctx);
    self.fun_custody.revalue(self.rate_sui, self.rate_pool_tokens);
    self.blast_custody.revalue(self.rate_sui, self.rate_pool_tokens);

    if (is_current) self.resolve_fun_receipts(system_state, epoch, ctx);
}

/// Resolves arrived fun receipts oldest-first while preserving the exit buffer.
///
/// The pending-ledger cap bounds the loop. It stops at the first retained
/// receipt because later receipts activate no earlier.
fun resolve_fun_receipts(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    epoch: u64,
    ctx: &mut TxContext,
) {
    let loss_bound = math::fun_conversion_loss_bound_up(
        self.rate_sui,
        self.rate_pool_tokens,
    );

    loop {
        let fun_activation_epoch = self.fun_custody.oldest_pending_activation_epoch();
        if (fun_activation_epoch.is_none() || *fun_activation_epoch.borrow() > epoch) {
            break
        };
        let activation_epoch = *fun_activation_epoch.borrow();
        let buffer = self.fun_backing_buffer();
        if (
            buffer >= loss_bound
                && buffer - loss_bound > constants::fun_exit_low_water_mist!()
        ) {
            self.fun_custody.activate_oldest_pending(system_state, ctx);
            self.fun_custody.revalue(self.rate_sui, self.rate_pool_tokens);
        } else if (activation_epoch < epoch) {
            // Withdrawing during the activation epoch forfeits that epoch's
            // reward. Withdrawing during safe mode can also forfeit deferred
            // rewards. Recover only after a full epoch with a current rate.
            self.fun_custody.realize_oldest_pending(system_state, ctx);
        } else break;
    };
}

/// Returns whether the pool has a usable exchange-rate entry for `epoch`, and its primitives.
///
/// An entry with a zero component counts as missing, exactly like a safe-mode epoch: the
/// vault keeps its cached rate rather than valuing stake at one MIST per pool token.
fun exchange_rate_at(
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    epoch: u64,
): (bool, u64, u64) {
    let rates = system_state.pool_exchange_rates(pool_id);
    if (!rates.contains(epoch)) return (false, 0, 0);

    let rate = &rates[epoch];
    let (rate_sui, rate_pool_tokens) = (rate.sui_amount(), rate.pool_token_amount());

    (math::is_usable_rate(rate_sui, rate_pool_tokens), rate_sui, rate_pool_tokens)
}

/// Moves fun assets above the funSUI supply plus the rounding reserve into blast custody.
///
/// Liquid SUI above the reserve moves first, so the reserve stays liquid. The
/// remainder moves as active pool tokens worth at most the remaining surplus at
/// the cached rate, so fun custody keeps at least the supply plus reserve at its
/// conservative valuation: retained yield is what replenishes the reserve. Fun
/// principal never moves.
fun sweep_fun_yield(self: &mut Vault, ctx: &mut TxContext) {
    let reserve = constants::fun_rounding_reserve_mist!();
    let retained = self.treasury_cap<FUN_SUI>().total_supply() + reserve;
    let assets = self.fun_custody.assets();
    if (assets <= retained) return;

    let surplus = assets - retained;
    let liquid_sui = surplus.min(self.fun_custody.liquid_sui().saturating_sub(reserve));
    if (liquid_sui > 0) {
        self.fun_custody.transfer_liquid(&mut self.blast_custody, liquid_sui);
    };

    let pool_tokens = math::pool_tokens_at_rate_down(
        surplus - liquid_sui,
        self.rate_sui,
        self.rate_pool_tokens,
    ).min(self.fun_custody.active_pool_tokens());
    if (pool_tokens > 0) {
        self
            .fun_custody
            .transfer_active_tokens(
                &mut self.blast_custody,
                pool_tokens,
                self.rate_sui,
                self.rate_pool_tokens,
                ctx,
            );
    };

    let swept_sui =
        liquid_sui + math::sui_at_rate_down(
        pool_tokens,
        self.rate_sui,
        self.rate_pool_tokens,
    );
    if (swept_sui > 0) {
        events::fun_yield_swept(liquid_sui, pool_tokens, swept_sui, self.custody());
    };
}

/// Delegates both ledgers' idle SUI only with current immutable-pool proof.
///
/// Fun custody keeps the rounding reserve liquid; blast custody stakes
/// everything. Safe mode can temporarily leave new SUI liquid; the next normal
/// sync delegates it.
fun stake_idle(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    // Together with refresh's active-address check, a current exchange-rate
    // entry proves that `pool_id`, not merely its old validator address, is
    // active. Safe mode defers delegation until the next normal sync.
    if (self.unwind_only || self.rate_epoch != ctx.epoch()) return;

    let pool_id = self.pool_id;
    let validator = system_state.validator_address_by_pool_id(&pool_id);
    self
        .fun_custody
        .stake_idle(
            system_state,
            validator,
            &pool_id,
            constants::fun_rounding_reserve_mist!(),
            ctx,
        );
    self.blast_custody.stake_idle(system_state, validator, &pool_id, 0, ctx);
}

/// Unwinds fun stake before another native rounding loss could consume its 1:1 backing.
fun protect_fun_exit_liquidity(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    let fun_supply = self.treasury_cap<FUN_SUI>().total_supply();
    if (fun_supply == 0 || self.fun_custody.active_pool_tokens() == 0) return;
    if (self.fun_backing_buffer() > constants::fun_exit_low_water_mist!()) return;

    self.fun_custody.unwind(system_state, ctx);
}

fun assert_accepts_mints(self: &Vault) {
    assert!(!self.unwind_only, blast_sui::errors::unwind_only!());
}

/// Fun custody's conservative assets must cover the exact 1:1 funSUI claim.
fun assert_fun_backed(self: &Vault) {
    assert!(
        self.fun_custody.assets() >= self.treasury_cap<FUN_SUI>().total_supply(),
        blast_sui::errors::fun_backing_below_supply!(),
    );
}

fun fun_backing_buffer(self: &Vault): u64 {
    self.fun_custody
        .assets()
        .saturating_sub(self.treasury_cap<FUN_SUI>().total_supply())
}

fun custody(self: &Vault): events::VaultCustody {
    events::vault_custody(
        self.fun_custody.pool_custody(),
        self.blast_custody.pool_custody(),
        events::exchange_rate(self.rate_epoch, self.rate_sui, self.rate_pool_tokens),
        self.treasury_cap<FUN_SUI>().total_supply(),
        self.treasury_cap<BLAST_SUI>().total_supply(),
    )
}

// === Test-Only Functions ===

#[test_only]
public fun fun_supply_for_testing(self: &Vault): u64 {
    self.treasury_cap<FUN_SUI>().total_supply()
}

#[test_only]
public fun blast_supply_for_testing(self: &Vault): u64 {
    self.treasury_cap<BLAST_SUI>().total_supply()
}

#[test_only]
public fun fun_custody_for_testing(self: &Vault): events::PoolCustody {
    self.fun_custody.pool_custody()
}

#[test_only]
public fun blast_custody_for_testing(self: &Vault): events::PoolCustody {
    self.blast_custody.pool_custody()
}

#[test_only]
public fun pool_id_for_testing(self: &Vault): ID {
    self.pool_id
}

#[test_only]
public fun exchange_rate_for_testing(self: &Vault): events::ExchangeRate {
    events::exchange_rate(self.rate_epoch, self.rate_sui, self.rate_pool_tokens)
}

#[test_only]
public fun redeem_fee_bps_for_testing(self: &Vault): u64 {
    self.redeem_fee.value()
}

#[test_only]
public fun redeem_fee_delay_ms_for_testing(self: &Vault): u64 {
    self.redeem_fee.delay_ms()
}

#[test_only]
public fun has_capability_for_testing<Capability: key + store>(self: &Vault): bool {
    self.id.has_dynamic_object_field_with_type<_, Capability>(CapabilityKey<Capability>())
}

#[test_only]
public fun is_unwind_only_for_testing(self: &Vault): bool {
    self.unwind_only
}

#[test_only]
/// Simulates a native loss beyond every buffer to prove the vault fails closed.
public fun simulate_native_loss_for_testing(self: &mut Vault, amount: u64) {
    self.fun_custody.transfer_liquid(&mut self.blast_custody, amount);
}

#[test_only]
/// Simulates cumulative native rounding loss without thousands of test transactions.
public fun consume_fun_buffer_for_testing(self: &mut Vault, amount: u64) {
    assert!(amount <= self.fun_backing_buffer());
    self.fun_custody.transfer_liquid(&mut self.blast_custody, amount);
    self.assert_fun_backed();
}

#[test_only]
/// Simulates swept blast yield split across a new pending stake and liquid residue.
public fun add_blast_layers_for_testing(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    pending_in: Coin<SUI>,
    liquid_in: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let pool_id = self.pool_id;
    let validator = system_state.validator_address_by_pool_id(&pool_id);
    self.blast_custody.deposit(pending_in.into_balance());
    self.blast_custody.stake_idle(system_state, validator, &pool_id, 0, ctx);
    self.blast_custody.deposit(liquid_in.into_balance());
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Delayed},
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::PackageVersion,
};

use blast_sui::{
    blast_sui::BLAST_SUI,
    blast_sui_domain::{CancelAdmin, FeeAdmin},
    blast_sui_package::{BLAST_SUI_PACKAGE, package_witness},
    constants,
    custody::{Self, Custody},
    deposit_receipt::{Self, BlastSuiDepositReceipt},
    events,
    fun_sui::FUN_SUI,
    math,
};

use sui::{
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::MetadataCap,
    display_registry::DisplayRegistry,
    dynamic_object_field,
    sui::SUI,
};

use sui_system::sui_system::SuiSystemState;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;

#[test_only]
use fun dynamic_object_field::exists_with_type as UID.has_dynamic_object_field_with_type;

use fun exchange_rate_at as SuiSystemState.exchange_rate_at;
