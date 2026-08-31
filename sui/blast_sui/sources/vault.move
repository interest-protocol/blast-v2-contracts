// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Single-validator custody of the 1:1 funSUI ledger and the blastSUI share ledger.
module blast_sui::vault;

use blast_sui::{
    acl::AdminWitness,
    blast_sui::BLAST_SUI,
    constants,
    custody::{Self, Custody},
    deposit_receipt::{Self, BlastSuiDepositReceipt},
    events,
    fun_sui::FUN_SUI,
    math,
    package_version::PackageVersion,
};
use sui::{coin::{Coin, TreasuryCap}, sui::SUI};
use sui_system::sui_system::SuiSystemState;

use fun exchange_rate_at as SuiSystemState.exchange_rate_at;

// === Public Structs ===

/// Shared owner of both treasury caps and the two native custody ledgers.
///
/// `fun_custody` backs only funSUI plus the protocol-funded rounding reserve,
/// and `blast_custody` backs only blastSUI, including the seed shares locked
/// at `@0x0` by `create`; both delegate only through `pool_id`.
/// `blast_cap.total_supply()` is therefore never zero after creation. `rate_epoch`, `rate_sui`, and `rate_pool_tokens` cache
/// the pool exchange-rate entry last observed for a current epoch; a refresh in
/// an epoch without an entry keeps this conservative rate instead of scanning
/// the table. `unwind_only` records that the validator left the active set.
public struct Vault has key {
    id: UID,
    fun_cap: TreasuryCap<FUN_SUI>,
    blast_cap: TreasuryCap<BLAST_SUI>,
    pool_id: ID,
    fun_custody: Custody,
    blast_custody: Custody,
    rate_epoch: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    redeem_fee_bps: u64,
    unwind_only: bool,
}

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
public fun create(
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    fun_cap: TreasuryCap<FUN_SUI>,
    blast_cap: TreasuryCap<BLAST_SUI>,
    owner_seed: Coin<SUI>,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
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
    let mut self = Vault {
        id: object::new(ctx),
        fun_cap,
        blast_cap,
        pool_id,
        fun_custody: custody::new(),
        blast_custody: custody::new(),
        rate_epoch: epoch,
        rate_sui,
        rate_pool_tokens,
        redeem_fee_bps: constants::default_redeem_fee_bps!(),
        unwind_only: false,
    };
    self.fun_custody.deposit(fun_reserve);
    self.blast_custody.deposit(seed);
    let vault_pool_id = self.pool_id;
    self.blast_custody.stake_idle(system_state, validator, &vault_pool_id, 0, ctx);
    let locked_coin = self.blast_cap.mint(bootstrap_sui, ctx);
    let locked_blast_sui = locked_coin.value();

    events::vault_created(
        self.id.to_inner(),
        validator,
        pool_id,
        fun_reserve_sui,
        bootstrap_sui,
        locked_blast_sui,
        self.redeem_fee_bps,
        self.custody(),
    );
    transfer::public_transfer(locked_coin, @0x0);
    transfer::share_object(self);
}

/// Mints funSUI one-to-one for SUI held in fun custody.
public fun mint_fun_sui(
    self: &mut Vault,
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
): Coin<FUN_SUI> {
    package_version.assert_current();
    let amount = sui_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);
    self.assert_accepts_mints();

    self.fun_custody.deposit(sui_in.into_balance());
    let fun_coin = self.fun_cap.mint(amount, ctx);
    self.assert_fun_backed();
    self.stake_idle(system_state, ctx);

    events::fun_sui_minted(amount, self.custody());
    fun_coin
}

/// Burns funSUI and returns exactly one MIST per unit from fun custody.
public fun redeem_fun_sui(
    self: &mut Vault,
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    fun_in: Coin<FUN_SUI>,
    ctx: &mut TxContext,
): Coin<SUI> {
    package_version.assert_current();
    let amount = fun_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);

    let sui_out = self.fun_custody.withdraw_exact(
        system_state,
        amount,
        self.rate_sui,
        self.rate_pool_tokens,
        ctx,
    );
    self.fun_cap.burn(fun_in);
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
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
): BlastSuiDepositReceipt {
    package_version.assert_current();
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
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    receipt: BlastSuiDepositReceipt,
    min_blast_out: u64,
    ctx: &mut TxContext,
): Coin<BLAST_SUI> {
    package_version.assert_current();
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
        self.blast_cap.total_supply(),
    );
    assert!(blast_out >= min_blast_out, blast_sui::errors::slippage_exceeded!());

    self.blast_custody.join_active_at_rate(
        active_stake,
        self.rate_sui,
        self.rate_pool_tokens,
    );
    let blast_coin = self.blast_cap.mint(blast_out, ctx);
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
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    sui_in: Coin<SUI>,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    let amount = sui_in.value();
    assert!(amount > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);

    self.blast_custody.deposit(sui_in.into_balance());
    self.stake_idle(system_state, ctx);

    events::blast_sui_donated(amount, self.custody());
}

/// Burns blastSUI for its pro-rata share of blast custody less the retained fee.
///
/// Every redemption is partial against the total supply because the locked
/// seed shares can never be presented, so every redemption pays the current
/// `redeem_fee_bps`, which stays in blast custody. The quote uses the cached
/// conservative valuation, so the caller's `min_sui_out` is its protection
/// during a safe-mode epoch.
public fun redeem_blast_sui(
    self: &mut Vault,
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    blast_in: Coin<BLAST_SUI>,
    min_sui_out: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    package_version.assert_current();
    let shares = blast_in.value();
    assert!(shares > 0, blast_sui::errors::zero_amount!());
    self.refresh(system_state, ctx);
    let (gross_sui, fee_sui, net_sui) = math::blast_redemption_quote(
        shares,
        self.blast_custody.assets(),
        self.blast_cap.total_supply(),
        self.redeem_fee_bps,
    );
    assert!(net_sui > 0, blast_sui::errors::zero_sui_after_fee!());
    assert!(net_sui >= min_sui_out, blast_sui::errors::slippage_exceeded!());

    let sui_out = self.blast_custody.withdraw_exact(
        system_state,
        net_sui,
        self.rate_sui,
        self.rate_pool_tokens,
        ctx,
    );
    self.blast_cap.burn(blast_in);
    self.stake_idle(system_state, ctx);

    events::blast_sui_redeemed(shares, gross_sui, fee_sui, net_sui, self.custody());
    sui_out.into_coin(ctx)
}

/// Sets the blastSUI redemption fee for every later redemption.
public fun set_redeem_fee(
    self: &mut Vault,
    package_version: &PackageVersion,
    _: &AdminWitness,
    redeem_fee_bps: u64,
) {
    package_version.assert_current();
    assert!(
        redeem_fee_bps <= constants::max_redeem_fee_bps!(),
        blast_sui::errors::redeem_fee_above_maximum!(),
    );
    let old_redeem_fee_bps = self.redeem_fee_bps;
    assert!(
        redeem_fee_bps != old_redeem_fee_bps,
        blast_sui::errors::redeem_fee_unchanged!(),
    );

    self.redeem_fee_bps = redeem_fee_bps;

    events::redeem_fee_changed(old_redeem_fee_bps, redeem_fee_bps);
}

/// Permissionless refresh: unwinds an inactive validator, converts activated
/// stake, revalues both ledgers, sweeps fun yield, and delegates idle SUI.
public fun sync(
    self: &mut Vault,
    package_version: &PackageVersion,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    self.refresh(system_state, ctx);
    self.stake_idle(system_state, ctx);

    events::vault_synced(self.custody());
}

// === Private Functions ===

/// Brings both ledgers to the current epoch with exactly one exchange-rate table lookup.
///
/// A current-epoch entry replaces the cache; a missing entry (safe mode) keeps
/// the cached rate, which never exceeds the live rate because pool rates only
/// grow. Both ledgers are revalued at the applied rate before the sweep.
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
        self.fun_custody.unwind(system_state, ctx);
        self.blast_custody.unwind(system_state, ctx);
        self.unwind_only = true;

        events::native_stake_unwound(self.custody());
    } else {
        let epoch = ctx.epoch();
        let (is_current, rate_sui, rate_pool_tokens) =
            system_state.exchange_rate_at(&self.pool_id, epoch);
        if (is_current) {
            self.rate_epoch = epoch;
            self.rate_sui = rate_sui;
            self.rate_pool_tokens = rate_pool_tokens;
        };

        // After the active-address check above, a current entry proves that the
        // immutable pool itself is active. Address membership alone is not
        // enough because an address can return with a different pool.
        if (is_current) self.blast_custody.activate_pending(system_state, ctx);
        self.fun_custody.revalue(self.rate_sui, self.rate_pool_tokens);
        self.blast_custody.revalue(self.rate_sui, self.rate_pool_tokens);

        // Resolve arrived fun receipts oldest-first, rechecking the buffer per
        // receipt: convert one only while its floor loss preserves the exit
        // buffer; otherwise keep it through activation and safe mode, then
        // realize it in a normal later epoch so recovery cannot forfeit
        // current or deferred rewards. The loop is bounded by the pending
        // ledger cap and stops at the first receipt it must retain, since
        // later receipts activate no earlier.
        if (is_current) {
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
                    // Withdrawing during the activation epoch forfeits that
                    // epoch's reward. Withdrawing during safe mode can also
                    // forfeit deferred rewards. Recover only after a full
                    // epoch with a current rate.
                    self.fun_custody.realize_oldest_pending(system_state, ctx);
                } else break;
            };
        };
    };
}

/// Returns whether the pool has an exchange-rate entry for `epoch` and, if so, its primitives.
fun exchange_rate_at(
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    epoch: u64,
): (bool, u64, u64) {
    let rates = system_state.pool_exchange_rates(pool_id);
    if (!rates.contains(epoch)) return (false, 0, 0);

    let rate = &rates[epoch];
    (true, rate.sui_amount(), rate.pool_token_amount())
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
    let retained = self.fun_cap.total_supply() + reserve;
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
        self.fun_custody.transfer_active_tokens(
            &mut self.blast_custody,
            pool_tokens,
            self.rate_sui,
            self.rate_pool_tokens,
            ctx,
        );
    };
    let swept_sui = liquid_sui + math::sui_at_rate_down(
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
    self.fun_custody.stake_idle(
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
    let fun_supply = self.fun_cap.total_supply();
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
        self.fun_custody.assets() >= self.fun_cap.total_supply(),
        blast_sui::errors::fun_backing_below_supply!(),
    );
}

fun fun_backing_buffer(self: &Vault): u64 {
    self.fun_custody
        .assets()
        .saturating_sub(self.fun_cap.total_supply())
}

fun custody(self: &Vault): events::VaultCustody {
    events::vault_custody(
        self.fun_custody.pool_custody(),
        self.blast_custody.pool_custody(),
        events::exchange_rate(self.rate_epoch, self.rate_sui, self.rate_pool_tokens),
        self.fun_cap.total_supply(),
        self.blast_cap.total_supply(),
    )
}

// === Test-Only Functions ===

#[test_only]
public fun fun_supply_for_testing(self: &Vault): u64 {
    self.fun_cap.total_supply()
}

#[test_only]
public fun blast_supply_for_testing(self: &Vault): u64 {
    self.blast_cap.total_supply()
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
    self.redeem_fee_bps
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
