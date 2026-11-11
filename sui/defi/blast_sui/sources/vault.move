// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Custody of the 1:1 funSUI ledger and the blastSUI share ledger across user-picked validators.
module blast_sui::vault;

// === Public Types ===

/// Shared owner of the treasury-cap, metadata-cap and display-cap child objects and the two
/// native custody ledgers.
///
/// `fun_custody` backs only funSUI plus the protocol-funded rounding reserve, and
/// `blast_custody` backs only blastSUI, including the seed shares locked at `@0x0` by `create`;
/// blastSUI supply is therefore never zero after creation. `validators` lists the staking pools
/// users may pick: admission waits its delay and removal is immediate. `pool_rates` caches each
/// admitted pool's last usable exchange-rate entry; its keys always equal the admitted members,
/// and a refresh in an epoch without a usable entry keeps the conservative cached rate.
/// `redeem_fee` is the blastSUI redemption fee; every change waits its applied delay.
public struct Vault has key {
    id: UID,
    validators: DelayedSet<ValidatorKey, ID>,
    pool_rates: VecMap<ID, PoolRate>,
    fun_custody: Custody,
    blast_custody: Custody,
    redeem_fee: Delayed<RedeemFeeKey, u64>,
}

/// Keys the validator admissions' delayed lifecycle.
public struct ValidatorKey() has copy, drop, store;

/// Keys the redemption fee's delayed lifecycle.
public struct RedeemFeeKey() has copy, drop, store;

/// Type-derived key for a treasury cap owned as a discoverable child object.
public struct TreasuryKey<phantom CoinType>() has copy, drop, store;

/// Type-derived key for a metadata or display capability sealed as a discoverable child object.
public struct CapabilityKey<phantom Capability>() has copy, drop, store;

// === Public Functions ===

/// Creates and shares the vault from the owner seed, locking every seed share.
///
/// Both treasury caps must be empty. The first validator is admitted here, at the zero
/// notice: its pool's validator must be active and the pool must have a usable exchange-rate
/// entry for the current epoch.
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
/// the vault with no accessor. The default redemption fee applies immediately, and changes
/// to the fee or its delay initially wait 48 hours. The validator delay starts at zero so the
/// bootstrap can list validators; deposits stay paused until `unpause`, which refuses while
/// it is zero.
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
    clock: &Clock,
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

    let mut seed = owner_seed.into_balance();
    let fun_reserve = seed.split(fun_reserve_sui);
    let bootstrap_sui = seed.value();
    let id = object::new(ctx);
    let redeem_fee = delayed::new(
        RedeemFeeKey(),
        &id,
        constants::default_redeem_fee_bps!(),
        constants::initial_redeem_fee_delay_ms!(),
    );
    let validators = delayed_set::new(ValidatorKey(), &id, 0);
    let mut self = Vault {
        id,
        validators,
        pool_rates: vec_map::empty(),
        fun_custody: custody::new(),
        blast_custody: custody::new(),
        redeem_fee,
    };

    self.validators.schedule_add(pool_id, clock);
    self.admit_pool(system_state, pool_id, clock, ctx);
    self.add_treasury_cap(fun_cap);
    self.add_treasury_cap(blast_cap);
    self.add_capability(fun_metadata_cap);
    self.add_capability(blast_metadata_cap);
    self.add_capability(deposit_receipt::create_display(display_registry, ctx));
    self.fun_custody.deposit(fun_reserve);
    self.blast_custody.deposit(seed);
    self.stake_idle(system_state, ctx);
    let locked_coin = self.treasury_cap_mut<BLAST_SUI>().mint(bootstrap_sui, ctx);

    events::vault_created(
        self.id.to_inner(),
        system_state.validator_address_by_pool_id(&pool_id),
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

/// Mints funSUI one-to-one for SUI held in fun custody, delegating it to the picked pool.
///
/// The pick directs only this deposit: up to `sui_in`, keeping the reserve liquid, is staked
/// to `pool_id` when it reaches the native minimum, the pool has a current rate and a free
/// pending slot. Otherwise it stays liquid for the idle rule. Exits follow the vault's order.
public fun mint_fun_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
): Coin<FUN_SUI> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::fun_mint_pause_bit!());

    let amount = sui_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);
    self.assert_accepted(&pool_id);

    self.fun_custody.deposit(sui_in.into_balance());
    let fun_coin = self.treasury_cap_mut<FUN_SUI>().mint(amount, ctx);
    self.assert_fun_backed();
    let delegated_sui = self
        .fun_custody
        .stake_pick(
            system_state,
            &pool_id,
            self.pool_rates[&pool_id],
            amount,
            constants::fun_rounding_reserve_mist!(),
            ctx,
        );
    self.stake_idle(system_state, ctx);

    events::fun_sui_minted(pool_id, amount, delegated_sui, self.custody());

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
        .withdraw_exact(system_state, amount, &self.pool_rates, ctx);
    self.treasury_cap_mut<FUN_SUI>().burn(fun_in);
    self.protect_fun_exit_liquidity(system_state, ctx);
    self.stake_idle(system_state, ctx);
    self.assert_fun_backed();

    events::fun_sui_redeemed(amount, self.custody());

    sui_out.into_coin(ctx)
}

/// Delegates SUI to the picked pool in a key-only receipt that remains outside vault custody.
///
/// The receipt is returned for transaction composition. It can be claimed for
/// blastSUI from its activation epoch, cancelled for native SUI at any time, or
/// placed in the caller's account through `deposit_receipt::keep`.
public fun request_blast_sui(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    pool_id: ID,
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
    self.assert_accepted(&pool_id);

    let validator = system_state.validator_address_by_pool_id(&pool_id);
    let staked_sui = system_state.request_add_stake_non_entry(sui_in, validator, ctx);
    assert!(staked_sui.pool_id() == pool_id, blast_sui::errors::wrong_delegation_pool!());

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
/// Existing holders therefore keep every reward earned before its activation. Every admitted
/// pool must have a current rate: a stale one understates blast assets and would over-mint.
/// A removed pool's receipt cannot be claimed; `deposit_receipt::cancel` stays open.
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

    receipt.assert_vault(self.id.to_inner());
    assert!(
        receipt.activation_epoch() <= ctx.epoch(),
        blast_sui::errors::blast_deposit_not_active!(),
    );

    self.refresh(system_state, ctx);
    let pool_id = receipt.pool_id();
    self.assert_accepted(&pool_id);
    assert!(self.has_every_rate_at(ctx.epoch()), blast_sui::errors::stale_exchange_rate!());

    let (receipt_id, principal_sui) = (receipt.id(), receipt.principal_sui());
    let active_stake = system_state.convert_to_fungible_staked_sui(
        receipt.destroy(),
        ctx,
    );

    let rate = self.pool_rates[&pool_id];
    let pool_tokens = active_stake.value();
    let contributed_sui = math::sui_at_rate_down(pool_tokens, rate.sui(), rate.pool_tokens());
    let blast_out = math::blast_shares_out_down(
        contributed_sui,
        self.blast_custody.assets(),
        self.treasury_cap<BLAST_SUI>().total_supply(),
    );
    assert!(blast_out >= min_blast_out, blast_sui::errors::slippage_exceeded!());

    self.blast_custody.join_active_at_rate(&pool_id, active_stake, rate);
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
/// shares, or withdrawal authority. Idle donations are delegated to pools with a
/// current rate and remain liquid otherwise.
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
/// that must not depend on that check restores 1:1 backing for every later call. While fun
/// custody holds active stake, the top-up must exceed the gap by more than
/// `fun_exit_low_water_mist`, so the next refresh skips the protective
/// unwind, whose rounding could drop custody below the supply again. A smaller top-up loses
/// nothing, and a larger one still recovers. Anyone may contribute; the caller receives
/// nothing, and any amount above the supply plus the rounding reserve is swept to blast
/// custody by the next refresh.
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
        .withdraw_exact(system_state, net_sui, &self.pool_rates, ctx);
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

/// Schedules a validator's admission after the applied delay. Rescheduling a pending
/// admission restarts its delay and takes no new slot.
public fun schedule_validator(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<ValidatorAdmin>,
    pool_id: ID,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(
        self.validators.is_pending(&pool_id)
            || self.validators.contains(&pool_id)
            || self.validators.length() + self.validators.pending_count()
                < constants::max_validators!(),
        blast_sui::errors::max_validators_reached!(),
    );

    self.validators.schedule_add(pool_id, clock);
}

/// Admits a scheduled validator permissionlessly once ready, while its pool is active with a
/// usable rate for this epoch.
public fun apply_validator(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    self.admit_pool(system_state, pool_id, clock, ctx);

    events::vault_synced(self.custody());
}

/// Cancels a pending validator admission, including after its delay has elapsed.
public fun cancel_validator(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<CancelAdmin>,
    pool_id: ID,
) {
    package_version.assert_current(constants::version!());

    self.validators.cancel_add(pool_id);
}

/// Removes a validator immediately, because reducing risk is never delayed.
///
/// A member's positions unwind in this call and its SUI re-delegates to the remaining members;
/// a pending admission is discarded. Removal during safe mode can forfeit deferred rewards.
/// A member that the refresh itself finds departed is already gone, and the call succeeds.
public fun remove_validator(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<ValidatorAdmin>,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    let is_pending = self.validators.is_pending(&pool_id);
    assert!(
        is_pending || self.validators.contains(&pool_id),
        blast_sui::errors::validator_not_accepted!(),
    );
    self.refresh(system_state, ctx);

    if (is_pending) {
        self.validators.remove(pool_id);
    } else if (self.validators.contains(&pool_id)) {
        self.retire_pool(system_state, pool_id, ctx);
        self.protect_fun_exit_liquidity(system_state, ctx);
        self.assert_fun_backed();
    };
    self.stake_idle(system_state, ctx);

    events::vault_synced(self.custody());
}

/// Schedules the delay for later validator admissions, ready after the applied one.
public fun schedule_validator_delay(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<ValidatorAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.validators.schedule_delay(delay_ms, clock);
}

/// Applies the scheduled validator delay permissionlessly once ready.
public fun apply_validator_delay(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.validators.apply_delay(clock);
}

/// Cancels a pending validator-delay change, including after its delay has elapsed.
public fun cancel_validator_delay(
    self: &mut Vault,
    package_version: &PackageVersion<BLAST_SUI_PACKAGE>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.validators.cancel_delay();
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

    assert!(
        self.redeem_fee.is_guarded() && self.validators.is_guarded(),
        blast_sui::errors::unguarded_delay!(),
    );

    package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits);
}

/// Permissionless refresh: retires departed pools, converts activated stake,
/// revalues both ledgers, sweeps fun yield, and delegates idle SUI.
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

/// Proves a scheduled pool active and current, then admits it with an empty position per
/// ledger. The only place, with `retire_pool`, that changes the set of tracked pools.
fun admit_pool(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    clock: &Clock,
    ctx: &TxContext,
) {
    self.validators.apply_add(pool_id, clock);

    let validator = system_state.validator_address_by_pool_id(&pool_id);
    assert!(
        system_state.active_validator_addresses_ref().contains(&validator),
        blast_sui::errors::validator_not_active!(),
    );

    let entry = system_state.exchange_rate_at(&pool_id, ctx.epoch());
    assert!(is_usable_entry(&entry), blast_sui::errors::stale_exchange_rate!());

    self.pool_rates.insert(pool_id, entry.destroy_some());
    self.fun_custody.add_position(pool_id);
    self.blast_custody.add_position(pool_id);
}

/// Unwinds a pool's positions into ledger liquid and stops tracking it, in one step: a pool
/// is either a member with positions or gone.
fun retire_pool(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    self.fun_custody.retire_position(system_state, &pool_id, ctx);
    self.blast_custody.retire_position(system_state, &pool_id, ctx);
    self.validators.remove(pool_id);
    self.pool_rates.remove(&pool_id);

    events::pool_unwound(pool_id, self.custody());
}

/// Brings both ledgers to the current epoch, then settles fun yield and exit liquidity.
fun refresh(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    self.refresh_pools(system_state, ctx);
    self.resolve_all_fun_receipts(system_state, ctx);

    self.sweep_fun_yield(ctx);
    self.protect_fun_exit_liquidity(system_state, ctx);
    self.assert_fun_backed();
}

/// Retires every departed pool and applies each remaining pool's current rate.
///
/// A pool has departed when its validator address left the active set, or when it has no raw
/// entry this epoch while some tracked pool has one: only safe mode leaves every pool without
/// an entry, so a lone gap means the address now belongs to a different pool. A zero entry is
/// present but unusable, so it is not departure.
fun refresh_pools(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    let epoch = ctx.epoch();
    let active = system_state.active_validator_addresses_ref();
    let pools = self.pool_rates.keys();
    let mut entries = pools.map_ref!(|pool_id| system_state.exchange_rate_at(pool_id, epoch));
    let has_some_entry = entries.any!(|entry| entry.is_some());

    pools.do!(|pool_id| {
        let entry = entries.remove(0);
        let validator = system_state.validator_address_by_pool_id(&pool_id);
        if (!active.contains(&validator) || (entry.is_none() && has_some_entry)) {
            self.retire_pool(system_state, pool_id, ctx);
        } else {
            self.refresh_pool(system_state, pool_id, entry, ctx);
        };
    });
}

/// Applies a usable entry, activates arrived blast receipts, and revalues both positions.
///
/// A missing or empty entry keeps the cached rate, which never exceeds the live rate because
/// pool rates only grow.
fun refresh_pool(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    entry: Option<PoolRate>,
    ctx: &mut TxContext,
) {
    if (is_usable_entry(&entry)) {
        *&mut self.pool_rates[&pool_id] = entry.destroy_some();
        self.blast_custody.activate_pending(system_state, &pool_id, ctx);
    };

    let rate = self.pool_rates[&pool_id];
    self.fun_custody.revalue(&pool_id, rate);
    self.blast_custody.revalue(&pool_id, rate);
}

/// Resolves arrived fun receipts of every pool with a current rate.
fun resolve_all_fun_receipts(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    self.pool_rates.keys().do!(|pool_id| {
        if (self.pool_rates[&pool_id].epoch() == ctx.epoch()) {
            self.resolve_fun_receipts(system_state, pool_id, ctx);
        };
    });
}

/// Resolves a pool's arrived fun receipts oldest-first while preserving the exit buffer.
///
/// The pending-position cap bounds the loop. It stops at the first retained
/// receipt because later receipts activate no earlier.
fun resolve_fun_receipts(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    let epoch = ctx.epoch();
    let rate = self.pool_rates[&pool_id];
    let loss_bound = math::fun_conversion_loss_bound_up(rate.sui(), rate.pool_tokens());

    loop {
        let fun_activation_epoch = self.fun_custody.oldest_pending_activation_epoch(&pool_id);
        if (fun_activation_epoch.is_none() || *fun_activation_epoch.borrow() > epoch) {
            break
        };
        let activation_epoch = *fun_activation_epoch.borrow();
        let buffer = self.fun_backing_buffer();
        if (
            buffer >= loss_bound
                && buffer - loss_bound > constants::fun_exit_low_water_mist!()
        ) {
            self.fun_custody.activate_oldest_pending(system_state, &pool_id, ctx);
            self.fun_custody.revalue(&pool_id, rate);
        } else if (activation_epoch < epoch) {
            // Withdrawing during the activation epoch forfeits that epoch's
            // reward. Withdrawing during safe mode can also forfeit deferred
            // rewards. Recover only after a full epoch with a current rate.
            self.fun_custody.realize_oldest_pending(system_state, &pool_id, ctx);
        } else break;
    };
}

/// Returns the pool's raw exchange-rate entry for `epoch`, if the table has one.
fun exchange_rate_at(
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    epoch: u64,
): Option<PoolRate> {
    let rates = system_state.pool_exchange_rates(pool_id);
    if (!rates.contains(epoch)) return option::none();

    let rate = &rates[epoch];

    option::some(custody::new_rate(epoch, rate.sui_amount(), rate.pool_token_amount()))
}

/// Whether an entry can value stake. An entry with a zero component counts as missing for
/// pricing, exactly like a safe-mode epoch: the vault keeps its cached rate rather than
/// valuing stake at one MIST per pool token.
fun is_usable_entry(entry: &Option<PoolRate>): bool {
    entry.is_some_and!(|rate| math::is_usable_rate(rate.sui(), rate.pool_tokens()))
}

/// Moves fun assets above the funSUI supply plus the rounding reserve into blast custody.
///
/// Liquid SUI above the reserve moves first, so the reserve stays liquid. The remainder moves
/// as active pool tokens, position by position in list order, each worth at most the surplus
/// at that pool's cached rate. The surplus is recomputed after every move: flooring can only
/// leave fun custody at or above the supply plus reserve, whereas decrementing by the moved
/// value could over-sweep. Retained yield is what replenishes the reserve; fun principal never
/// moves.
fun sweep_fun_yield(self: &mut Vault, ctx: &mut TxContext) {
    let reserve = constants::fun_rounding_reserve_mist!();
    let retained = self.treasury_cap<FUN_SUI>().total_supply() + reserve;
    let assets = self.fun_custody.assets();
    if (assets <= retained) return;

    let liquid_sui = (assets - retained).min(
        self.fun_custody.liquid_sui().saturating_sub(reserve),
    );
    if (liquid_sui > 0) {
        self.fun_custody.transfer_liquid(&mut self.blast_custody, liquid_sui);
    };

    let mut active_sui = 0;
    self.pool_rates.keys().do!(|pool_id| {
        active_sui = active_sui + self.sweep_pool_yield(pool_id, retained, ctx);
    });

    if (liquid_sui + active_sui > 0) {
        events::fun_yield_swept(liquid_sui, active_sui, liquid_sui + active_sui, self.custody());
    };
}

/// Moves one pool's active tokens worth at most the live surplus; returns their value.
fun sweep_pool_yield(self: &mut Vault, pool_id: ID, retained: u64, ctx: &mut TxContext): u64 {
    let rate = self.pool_rates[&pool_id];
    let pool_tokens = math::pool_tokens_at_rate_down(
        self.fun_custody.assets().saturating_sub(retained),
        rate.sui(),
        rate.pool_tokens(),
    ).min(self.fun_custody.active_pool_tokens(&pool_id));
    if (pool_tokens == 0) return 0;

    self
        .fun_custody
        .transfer_active_tokens(&mut self.blast_custody, &pool_id, pool_tokens, rate, ctx);

    math::sui_at_rate_down(pool_tokens, rate.sui(), rate.pool_tokens())
}

/// Delegates both ledgers' idle SUI across the pools with a current rate.
///
/// Fun custody keeps the rounding reserve liquid; blast custody stakes
/// everything. Safe mode can temporarily leave new SUI liquid; the next normal
/// sync delegates it.
fun stake_idle(self: &mut Vault, system_state: &mut SuiSystemState, ctx: &mut TxContext) {
    self
        .fun_custody
        .stake_idle(
            system_state,
            &self.pool_rates,
            constants::fun_rounding_reserve_mist!(),
            ctx,
        );
    self.blast_custody.stake_idle(system_state, &self.pool_rates, 0, ctx);
}

/// Unwinds fun stake before another native rounding loss could consume its 1:1 backing.
fun protect_fun_exit_liquidity(
    self: &mut Vault,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    let fun_supply = self.treasury_cap<FUN_SUI>().total_supply();
    if (fun_supply == 0 || !self.fun_custody.has_active_stake()) return;
    if (self.fun_backing_buffer() > constants::fun_exit_low_water_mist!()) return;

    self.fun_custody.unwind(system_state, ctx);
}

fun assert_accepted(self: &Vault, pool_id: &ID) {
    assert!(self.validators.contains(pool_id), blast_sui::errors::validator_not_accepted!());
}

/// Whether every admitted pool's rate was read at `epoch`.
fun has_every_rate_at(self: &Vault, epoch: u64): bool {
    self.pool_rates.keys().all!(|pool_id| self.pool_rates[pool_id].epoch() == epoch)
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
    let pools = self.pool_rates.keys().map!(|pool_id| {
        let rate = self.pool_rates[&pool_id];

        events::pool_snapshot(
            pool_id,
            events::exchange_rate(rate.epoch(), rate.sui(), rate.pool_tokens()),
            self.fun_custody.position_custody(&pool_id),
            self.blast_custody.position_custody(&pool_id),
        )
    });

    events::vault_custody(
        self.fun_custody.liquid_sui(),
        self.blast_custody.liquid_sui(),
        pools,
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
public fun custody_for_testing(self: &Vault): events::VaultCustody {
    self.custody()
}

#[test_only]
public fun fun_assets_for_testing(self: &Vault): u64 {
    self.fun_custody.assets()
}

#[test_only]
public fun blast_assets_for_testing(self: &Vault): u64 {
    self.blast_custody.assets()
}

#[test_only]
public fun fun_custody_for_testing(self: &Vault): events::LedgerTotals {
    self.custody().fun_totals()
}

#[test_only]
public fun blast_custody_for_testing(self: &Vault): events::LedgerTotals {
    self.custody().blast_totals()
}

#[test_only]
/// The first admitted pool.
public fun pool_id_for_testing(self: &Vault): ID {
    self.pool_rates.keys()[0]
}

#[test_only]
/// The first admitted pool's applied rate, or zero with no pool.
public fun exchange_rate_for_testing(self: &Vault): events::ExchangeRate {
    let (_, _, rate, _, _) = self.custody().vault_custody_fields();

    rate
}

#[test_only]
public fun pools_for_testing(self: &Vault): vector<ID> {
    self.pool_rates.keys()
}

#[test_only]
public fun validators_for_testing(self: &Vault): &DelayedSet<ValidatorKey, ID> {
    &self.validators
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
    self.blast_custody.deposit(pending_in.into_balance());
    self.blast_custody.stake_idle(system_state, &self.pool_rates, 0, ctx);
    self.blast_custody.deposit(liquid_in.into_balance());
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Delayed},
    delayed_set::{Self, DelayedSet},
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::PackageVersion,
};

use blast_sui::{
    blast_sui::BLAST_SUI,
    blast_sui_domain::{CancelAdmin, FeeAdmin, ValidatorAdmin},
    blast_sui_package::{BLAST_SUI_PACKAGE, package_witness},
    constants,
    custody::{Self, Custody, PoolRate},
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
    vec_map::{Self, VecMap},
};

use sui_system::sui_system::SuiSystemState;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;

#[test_only]
use fun dynamic_object_field::exists_with_type as UID.has_dynamic_object_field_with_type;

use fun exchange_rate_at as SuiSystemState.exchange_rate_at;
