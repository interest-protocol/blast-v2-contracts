/// Example hook: charges a hook fee on every swap input and counts swaps per
/// pool. Its other slots only approve. The pool alone sets the LP fee.
///
/// # The hook convention
///
/// Routers call any hook without hook-specific code, so every hook exposes
/// exactly these `public` functions for the slots it binds. Sui forbids
/// changing a published `public` signature, so every later version keeps them.
/// The router finds the package from the bound witness type's defining ID
/// (upgraded to its latest version), the module from the witness's module, and
/// the configuration at the address derived from `HookNamespace` and the
/// witness type. It passes empty `hook_data` unless the hook's own service
/// supplies bytes.
///
/// ```text
/// before_swap<A, Q>(pool, package_version, config, request: &mut SwapRequest<A, Q>, hook_data, clock, ctx)
/// after_swap<A, Q>(pool, package_version, config, completion: &mut Completion<A, Q, Swap>, hook_data, clock, ctx)
/// before_add_liquidity<A, Q>(pool, package_version, config, request: &mut AddLiquidityRequest<A, Q>, position, hook_data, clock, ctx)
/// after_add_liquidity<A, Q>(pool, package_version, config, completion: &mut Completion<A, Q, AddLiquidity>, position, hook_data, clock, ctx)
/// before_remove_liquidity<A, Q>(pool, package_version, config, request: &mut RemoveLiquidityRequest<A, Q>, position, hook_data, clock, ctx)
/// after_remove_liquidity<A, Q>(pool, package_version, config, completion: &mut Completion<A, Q, RemoveLiquidity>, position, hook_data, clock, ctx)
/// before_donate<A, Q>(pool, package_version, config, request: &mut DonateRequest<A, Q>, hook_data, clock, ctx)
/// after_donate<A, Q>(pool, package_version, config, completion: &mut Completion<A, Q, Donate>, hook_data, clock, ctx)
/// ```
///
/// `pool` is `&mut Pool<A, Q>`, `package_version` is the shared DEX
/// `&PackageVersion<BLAST_FUN_DEX>`, `config` is `&HookConfig<Witness>`,
/// `position` is `&Position<A, Q>`, `hook_data` is `vector<u8>`, `clock` is `&Clock` and
/// `ctx` is `&mut TxContext`.
///
/// Every function first requires `config.version()` to equal the version
/// compiled into the package, because older versions stay callable. A hook
/// that reads `hook_data` decodes it strictly with `sui::bcs`, rejects
/// trailing bytes, and binds any signed payload to the sender, pool, slot,
/// expiry and a nonce. Hooks that need other objects or per-user arguments add
/// separate typed functions for hook-aware callers; generic routers only call
/// the functions above.
///
/// The convention fixes every slot's parameters, so slots that ignore the
/// `Clock` still take it; the allowed lint would otherwise reject them.
#[allow(lint(unused_object_with_fields))]
module blast_fun_dex_example_hook::fee_hook;

// === Constants ===

/// Version compiled into this package. `migrate` moves the configuration to it.
const VERSION: u64 = 1;
const BPS_DENOMINATOR: u64 = 10_000;
const FEE_CHANGE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;
/// Hook fee ceiling: 10% of the swap input.
const MAX_FEE_BPS: u64 = 1_000;

// === Public Types ===

/// The hook's witness. Only this module can construct it.
public struct FeeHook() has drop;

/// Schedules and cancels fee changes, migrates the configuration and withdraws fees.
public struct FeeHookAdminCap has key, store {
    id: UID,
}

/// Keys the delayed hook fee stored as a dynamic field on its `HookConfig`.
public struct FeeBpsKey() has copy, drop, store;

/// Pool-local hook fees collected in `CoinType`.
public struct CollectedFeesKey<phantom CoinType>() has copy, drop, store;

/// Pool-local number of swaps this hook has finished.
public struct SwapCountKey() has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(FeeHookAdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Public Functions ===

// Administration.

/// Creates and shares the hook's configuration. Callable once.
public fun create_config(
    namespace: &mut HookNamespace,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _admin: &FeeHookAdminCap,
    fee_bps: u64,
) {
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);

    let mut config = hook_config::new(package_version, namespace, FeeHook(), VERSION);
    let policy = delayed::new(FeeBpsKey(), config.uid(), fee_bps, FEE_CHANGE_DELAY_MS);
    config.uid_mut(package_version, &FeeHook()).add_dynamic_field(FeeBpsKey(), policy);
    config.share(package_version);
}

/// Proposes a fee up to 1,000 bps, ready after the fixed 48-hour delay.
public fun schedule_fee_bps(
    config: &mut HookConfig<FeeHook>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _admin: &FeeHookAdminCap,
    fee_bps: u64,
    clock: &Clock,
): u64 {
    let policy = fee_policy_mut(config, package_version);
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);

    policy.schedule_value(fee_bps, clock)
}

/// Permissionlessly applies the scheduled hook fee once ready.
public fun apply_fee_bps(
    config: &mut HookConfig<FeeHook>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    clock: &Clock,
) {
    fee_policy_mut(config, package_version).apply(clock);
}

/// Discards the pending hook fee, including once it is ready.
public fun cancel_fee_bps(
    config: &mut HookConfig<FeeHook>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _admin: &FeeHookAdminCap,
) {
    fee_policy_mut(config, package_version).cancel();
}

/// After an upgrade, accepts this version and stops all older ones.
public fun migrate(
    config: &mut HookConfig<FeeHook>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _admin: &FeeHookAdminCap,
) {
    config.set_version(package_version, FeeHook(), VERSION);
}

/// Withdraws the hook fees a pool has collected in `CoinType`.
public fun withdraw_fees<Asset, Quote, CoinType>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    _admin: &FeeHookAdminCap,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert_current_version(config);
    assert!(
        pool.has_hook_state(&FeeHook(), CollectedFeesKey<CoinType>()),
        ENoFeesCollected,
    );

    let collected: &mut Balance<CoinType> = pool.hook_state_mut(package_version, &FeeHook(), CollectedFeesKey<CoinType>());
    collected.withdraw_all().into_coin(ctx)
}

/// Binds this hook to every slot of a new pool. Accepts any pair and fee mode.
public fun register<Asset, Quote>(
    initializer: &mut PoolInitializer<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
) {
    assert_current_version(config);

    initializer.register_hook(package_version, config, FeeHook(), pool::all_hook_flags!());
}

// Swap slots.

/// Takes the hook fee from the input and approves.
public fun before_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    request: &mut SwapRequest<Asset, Quote>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    let policy: &Delayed<FeeBpsKey, u64> = config.uid().dynamic_field(FeeBpsKey());
    let fee = request.input_value().mul_div_ceil(policy.value(), BPS_DENOMINATOR);
    if (request.is_asset_input()) {
        let fee_payment = request.take_asset_payment(package_version, pool, FeeHook(), fee);
        pool.collect_fee(package_version, fee_payment);
    } else {
        let fee_payment = request.take_quote_payment(package_version, pool, FeeHook(), fee);
        pool.collect_fee(package_version, fee_payment);
    };

    request.approve(package_version, pool, FeeHook());
}

/// Counts the swap and approves its output unchanged.
public fun after_swap<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    completion: &mut Completion<Asset, Quote, Swap>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    if (!pool.has_hook_state(&FeeHook(), SwapCountKey())) pool.add_hook_state(package_version, &FeeHook(), SwapCountKey(), 0u64);
    let swap_count: &mut u64 = pool.hook_state_mut(package_version, &FeeHook(), SwapCountKey());
    *swap_count = *swap_count + 1;

    completion.approve(package_version, pool, FeeHook());
}

// Liquidity and donation slots.

public fun before_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    request: &mut AddLiquidityRequest<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    request.approve(package_version, pool, FeeHook());
}

public fun after_add_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    completion: &mut Completion<Asset, Quote, AddLiquidity>,
    _position: &Position<Asset, Quote>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    completion.approve(package_version, pool, FeeHook());
}

public fun before_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    request: &mut RemoveLiquidityRequest<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    request.approve(package_version, pool, FeeHook());
}

public fun after_remove_liquidity<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    completion: &mut Completion<Asset, Quote, RemoveLiquidity>,
    _position: &Position<Asset, Quote>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    completion.approve(package_version, pool, FeeHook());
}

public fun before_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    request: &mut DonateRequest<Asset, Quote>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    request.approve(package_version, pool, FeeHook());
}

public fun after_donate<Asset, Quote>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    config: &HookConfig<FeeHook>,
    completion: &mut Completion<Asset, Quote, Donate>,
    _hook_data: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_current_version(config);

    completion.approve(package_version, pool, FeeHook());
}

// Reads.

/// Swaps this hook has finished on the pool.
public fun swap_count<Asset, Quote>(pool: &Pool<Asset, Quote>): u64 {
    if (!pool.has_hook_state(&FeeHook(), SwapCountKey())) return 0;

    *pool.hook_state(&FeeHook(), SwapCountKey())
}

/// Hook fees the pool holds in `CoinType`.
public fun collected_fees<Asset, Quote, CoinType>(pool: &Pool<Asset, Quote>): u64 {
    if (!pool.has_hook_state(&FeeHook(), CollectedFeesKey<CoinType>())) return 0;

    let collected: &Balance<CoinType> = pool.hook_state(&FeeHook(), CollectedFeesKey<CoinType>());
    collected.value()
}

// === Private Functions ===

fun assert_current_version(config: &HookConfig<FeeHook>) {
    assert!(config.version() == VERSION, EWrongVersion);
}

fun fee_policy_mut(
    config: &mut HookConfig<FeeHook>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
): &mut Delayed<FeeBpsKey, u64> {
    assert_current_version(config);

    config.uid_mut(package_version, &FeeHook()).dynamic_field_mut(FeeBpsKey())
}

fun collect_fee<Asset, Quote, CoinType>(
    pool: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    fee: Balance<CoinType>,
) {
    if (!pool.has_hook_state(&FeeHook(), CollectedFeesKey<CoinType>())) {
        pool.add_hook_state(package_version, &FeeHook(), CollectedFeesKey<CoinType>(), fee);
        return
    };

    let collected: &mut Balance<CoinType> = pool.hook_state_mut(package_version, &FeeHook(), CollectedFeesKey<CoinType>());
    collected.join(fee);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Moves the configuration past this package's version, as a newer package would.
#[test_only]
public fun set_version_for_testing(
    config: &mut HookConfig<FeeHook>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    version: u64,
) {
    config.set_version(package_version, FeeHook(), version);
}

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Hook configuration is not at this package's version.";
#[error(code = 1)]
const EFeeTooHigh: vector<u8> = b"Hook fee must not exceed 1,000 bps.";
#[error(code = 2)]
const ENoFeesCollected: vector<u8> = b"Pool has collected no hook fees in this coin.";

// === Imports ===

use blast_admin::{delayed::{Self, Delayed}, package_version::PackageVersion};
use blast_fun_dex::{
    blast_fun_dex::BLAST_FUN_DEX,
    hook_config::{Self, HookConfig, HookNamespace},
    pool::{
        Self,
        AddLiquidity,
        AddLiquidityRequest,
        Completion,
        Donate,
        DonateRequest,
        Pool,
        PoolInitializer,
        Position,
        RemoveLiquidity,
        RemoveLiquidityRequest,
        Swap,
        SwapRequest,
    },
};
use sui::{balance::Balance, clock::Clock, coin::Coin, dynamic_field};

use fun collect_fee as Pool.collect_fee;
use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow as UID.dynamic_field;
use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;
