/// Aftermath migration with complete source reconciliation and locked fungible LP.
module blast_fun_migrators::aftermath;

// === Constants ===

/// One half in Aftermath's `1e18` fixed-point weight unit.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;
const FIXED_ONE: u64 = 1_000_000_000_000_000_000;
const MIN_WEIGHT: u64 = 10_000_000_000_000_000;
const FLATNESS: u64 = 0;
/// Aftermath rejects zero; this is its unavoidable 0.01% base-pool minimum.
const BASE_SWAP_IN_FEE: u64 = 100_000_000_000_000;
const DEFAULT_DAO_FEE_BPS: u16 = 200;
const MAX_DAO_FEE_BPS: u16 = 10_000;
const MIN_ILLIQUID_LP: u64 = 1_000;
const REQUIRED_LP_DECIMALS: u8 = 9;
const POOL_NAME: vector<u8> = b"Blast Aftermath Meme Pool";

// === Errors ===

#[error(code = 0)]
const EInvalidCoinOrder: vector<u8> = b"Selected Aftermath route must match canonical coin order.";
#[error(code = 1)]
const ELpTypeAlreadyRegistered: vector<u8> = b"Aftermath LP type must be fresh and unregistered.";
#[error(code = 3)]
const EPoolInvariantMismatch: vector<u8> = b"Aftermath pool state does not match the migration policy.";
#[error(code = 4)]
const EBalanceMismatch: vector<u8> = b"Aftermath pool must contain every source asset unit.";
#[error(code = 5)]
const ELpSupplyMismatch: vector<u8> = b"Aftermath LP supply or decimals do not match the locked-liquidity policy.";
#[error(code = 6)]
const EInvalidWeight: vector<u8> = b"Aftermath weights must each be at least 1% and sum to 100%.";
#[error(code = 7)]
const EUnchangedPolicy: vector<u8> = b"Aftermath policy must differ from its currently effective values.";
#[error(code = 8)]
const EInvalidDaoFee: vector<u8> = b"Aftermath DAO fee must not exceed 10,000 basis points.";
#[error(code = 9)]
const EDaoPoolInvariantMismatch: vector<u8> = b"Aftermath DAO-fee pool does not match the migration policy.";
#[error(code = 10)]
const EUnchangedDaoFee: vector<u8> = b"Aftermath DAO fee must differ from its current value.";
#[error(code = 11)]
const ELpPrincipalChanged: vector<u8> = b"Aftermath DAO fee accrual must not change locked LP principal.";

// === Public Structs ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Aftermath LP coin attached to the common vault.
public struct Venue() has drop;

/// Sealed dynamic-field name for Aftermath's future-migration policy.
public struct PolicyKey() has copy, drop, store;

/// Admin-pinned Aftermath economics applied to future migrations.
public struct AftermathPolicy has copy, drop, store {
    meme_weight: u64,
    quote_weight: u64,
    dao_fee_bps: u16,
}

/// Permanently locked fungible LP principal and DAO-fee policy capability.
public struct AftermathPosition<phantom Lp> has key, store {
    id: UID,
    lp_balance: Balance<Lp>,
    dao_fee_owner_cap: OwnerCap<Lp>,
}

// === Public Functions ===

/// Migrates when Aftermath's canonical order places Meme first.
public fun migrate_meme_first<Lp, Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    migrators_version: &MigratorsVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool_registry: &mut PoolRegistry,
    create_pool_cap: CreatePoolCapV2,
    dao_fee_version: &Version,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert_canonical_order<Meme, Quote>(true);
    assert!(!pool_registry.contains_lp_coin<Lp>(), ELpTypeAlreadyRegistered);
    let policy = effective_policy(venue_config);
    let launch_id = object::id(launch);
    let payload = launch.migrate<_, _, Witness>(package_version, meme_currency, ctx);
    let lp_fee_authority = lp_fee_authority::new(&payload, Witness());
    let (meme, quote) = payload.redeem_migration(Witness());
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (pool, lp_coin) = create_and_reconcile<Lp, Meme, Quote>(
        pool_registry,
        create_pool_cap,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        meme_amount,
        quote_amount,
        policy.meme_weight,
        policy.quote_weight,
        BASE_SWAP_IN_FEE,
        ctx,
    );

    lock_and_share<Lp, Meme, Quote>(
        launch_id,
        lp_fee_authority,
        pool,
        lp_coin,
        meme_amount,
        quote_amount,
        policy,
        dao_fee_version,
        ctx,
    );
}

/// Migrates when Aftermath's canonical order places Meme second.
public fun migrate_meme_second<Lp, Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    migrators_version: &MigratorsVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool_registry: &mut PoolRegistry,
    create_pool_cap: CreatePoolCapV2,
    dao_fee_version: &Version,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert_canonical_order<Meme, Quote>(false);
    assert!(!pool_registry.contains_lp_coin<Lp>(), ELpTypeAlreadyRegistered);
    let policy = effective_policy(venue_config);
    let launch_id = object::id(launch);
    let payload = launch.migrate<_, _, Witness>(package_version, meme_currency, ctx);
    let lp_fee_authority = lp_fee_authority::new(&payload, Witness());
    let (meme, quote) = payload.redeem_migration(Witness());
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (pool, lp_coin) = create_and_reconcile<Lp, Quote, Meme>(
        pool_registry,
        create_pool_cap,
        quote.into_coin(ctx),
        meme.into_coin(ctx),
        quote_amount,
        meme_amount,
        policy.quote_weight,
        policy.meme_weight,
        BASE_SWAP_IN_FEE,
        ctx,
    );

    lock_and_share<Lp, Meme, Quote>(
        launch_id,
        lp_fee_authority,
        pool,
        lp_coin,
        meme_amount,
        quote_amount,
        policy,
        dao_fee_version,
        ctx,
    );
}

/// Pins Aftermath's role-based weights and DAO fee for future migrations.
public fun set_policy(
    venue_config: &mut VenueConfig,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    meme_weight: u64,
    quote_weight: u64,
    dao_fee_bps: u16,
) {
    migrators_version.assert_current();
    let new_policy = AftermathPolicy {
        meme_weight,
        quote_weight,
        dao_fee_bps,
    };
    new_policy.assert_valid();

    let old_policy = if (venue_config.has_policy(PolicyKey())) {
        let policy_mut = venue_config.policy_mut<_, AftermathPolicy>(PolicyKey());
        let old_policy = *policy_mut;
        old_policy.assert_changed(&new_policy);
        *policy_mut = new_policy;
        old_policy
    } else {
        let old_policy = default_policy();
        old_policy.assert_changed(&new_policy);
        venue_config.add_policy(PolicyKey(), new_policy);
        old_policy
    };

    events::aftermath_policy_updated(
        old_policy.meme_weight,
        old_policy.quote_weight,
        old_policy.dao_fee_bps,
        new_policy.meme_weight,
        new_policy.quote_weight,
        new_policy.dao_fee_bps,
    );
}

/// Updates one migrated pool's DAO fee while retaining its cap and vault recipient.
public fun update_dao_fee<Lp, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    dao_fee_pool: &mut DaoFeePool<Lp>,
    dao_fee_version: &Version,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    dao_fee_bps: u16,
) {
    migrators_version.assert_current();
    assert_valid_dao_fee(dao_fee_bps);
    let dao_fee_pool_id = object::id(dao_fee_pool);
    assert!(self.pool_id() == dao_fee_pool_id, EDaoPoolInvariantMismatch);
    assert!(
        dao_fee_pool.fee_recipient() == object::id(self).to_address(),
        EDaoPoolInvariantMismatch,
    );
    let old_dao_fee_bps = dao_fee_pool.fee_bps();
    assert!(old_dao_fee_bps != dao_fee_bps, EUnchangedDaoFee);

    let position = self.position_mut<_, _, _, AftermathPosition<Lp>>(&Venue());
    position.dao_fee_owner_cap.set_fee_bps(
        dao_fee_pool,
        dao_fee_version,
        dao_fee_bps,
    );
    assert!(
        dao_fee_pool.fee_bps() == dao_fee_bps,
        EDaoPoolInvariantMismatch,
    );
    assert!(
        dao_fee_pool.fee_recipient() == object::id(self).to_address(),
        EDaoPoolInvariantMismatch,
    );
    events::aftermath_dao_fee_updated(
        object::id(self),
        dao_fee_pool_id,
        old_dao_fee_bps,
        dao_fee_bps,
    );
}

// === Private Functions ===

fun default_policy(): AftermathPolicy {
    AftermathPolicy {
        meme_weight: HALF_WEIGHT,
        quote_weight: HALF_WEIGHT,
        dao_fee_bps: DEFAULT_DAO_FEE_BPS,
    }
}

fun effective_policy(venue_config: &VenueConfig): AftermathPolicy {
    let policy = if (venue_config.has_policy(PolicyKey())) {
        let policy_override = venue_config.policy<_, AftermathPolicy>(PolicyKey());
        *policy_override
    } else {
        default_policy()
    };
    policy.assert_valid();
    policy
}

fun assert_valid(self: &AftermathPolicy) {
    assert!(
        self.meme_weight >= MIN_WEIGHT
            && self.quote_weight >= MIN_WEIGHT
            && self.meme_weight <= FIXED_ONE
            && self.quote_weight <= FIXED_ONE
            && self.meme_weight + self.quote_weight == FIXED_ONE,
        EInvalidWeight,
    );
    assert_valid_dao_fee(self.dao_fee_bps);
}

fun assert_valid_dao_fee(dao_fee_bps: u16) {
    assert!(dao_fee_bps <= MAX_DAO_FEE_BPS, EInvalidDaoFee);
}

fun assert_changed(self: &AftermathPolicy, new_policy: &AftermathPolicy) {
    assert!(
        self.meme_weight != new_policy.meme_weight
            || self.quote_weight != new_policy.quote_weight
            || self.dao_fee_bps != new_policy.dao_fee_bps,
        EUnchangedPolicy,
    );
}

fun assert_canonical_order<Meme, Quote>(meme_is_first: bool) {
    let meme_first = is_type_name_less<Meme, Quote>();
    let meme_second = is_type_name_less<Quote, Meme>();
    assert!(meme_first != meme_second, EInvalidCoinOrder);
    assert!(meme_first == meme_is_first, EInvalidCoinOrder);
}

/// Mirrors Aftermath's defining-ID lexicographic type sorter.
fun is_type_name_less<A, B>(): bool {
    let a_name = type_name::with_defining_ids<A>().into_string();
    let b_name = type_name::with_defining_ids<B>().into_string();
    let a_bytes = a_name.as_bytes();
    let b_bytes = b_name.as_bytes();
    let a_length = a_bytes.length();
    let b_length = b_bytes.length();
    let limit = if (a_length < b_length) a_length else b_length;
    let mut index = 0;
    while (index < limit) {
        let a_byte = a_bytes[index];
        let b_byte = b_bytes[index];
        if (a_byte < b_byte) return true;
        if (a_byte > b_byte) return false;
        index = index + 1;
    };
    a_length < b_length
}

fun create_and_reconcile<Lp, C1, C2>(
    pool_registry: &mut PoolRegistry,
    create_pool_cap: CreatePoolCapV2,
    coin_1: Coin<C1>,
    coin_2: Coin<C2>,
    amount_1: u64,
    amount_2: u64,
    weight_1: u64,
    weight_2: u64,
    fee_rate: u64,
    ctx: &mut TxContext,
): (Pool<Lp>, Coin<Lp>) {
    let (pool, lp_coin) = pool_factory::create_pool_2_coins_v2<Lp, C1, C2>(
        create_pool_cap,
        pool_registry,
        POOL_NAME,
        vector[weight_1, weight_2],
        FLATNESS,
        vector[fee_rate, fee_rate],
        vector[0, 0],
        vector[0, 0],
        vector[0, 0],
        coin_1,
        coin_2,
        option::none(),
        false,
        ctx,
    );

    assert!(pool.size() == 2, EPoolInvariantMismatch);
    assert!(
        pool_registry.lp_type_to_pool_id<Lp>() == object::id(&pool),
        EPoolInvariantMismatch,
    );
    assert!(pool.balance_of<Lp, C1>() == amount_1, EBalanceMismatch);
    assert!(pool.balance_of<Lp, C2>() == amount_2, EBalanceMismatch);
    assert!(pool.weight_of<Lp, C1>() == weight_1, EPoolInvariantMismatch);
    assert!(pool.weight_of<Lp, C2>() == weight_2, EPoolInvariantMismatch);
    assert!(pool.flatness() == FLATNESS, EPoolInvariantMismatch);
    assert!(pool.fees_swap_in_for<Lp, C1>() == fee_rate, EPoolInvariantMismatch);
    assert!(pool.fees_swap_in_for<Lp, C2>() == fee_rate, EPoolInvariantMismatch);
    assert!(pool.fees_swap_out_for<Lp, C1>() == 0, EPoolInvariantMismatch);
    assert!(pool.fees_swap_out_for<Lp, C2>() == 0, EPoolInvariantMismatch);
    assert!(pool.fees_deposit_for<Lp, C1>() == 0, EPoolInvariantMismatch);
    assert!(pool.fees_deposit_for<Lp, C2>() == 0, EPoolInvariantMismatch);
    assert!(pool.fees_withdraw_for<Lp, C1>() == 0, EPoolInvariantMismatch);
    assert!(pool.fees_withdraw_for<Lp, C2>() == 0, EPoolInvariantMismatch);

    let locked_lp_amount = lp_coin.value();
    let lp_supply = pool.lp_supply_value();
    assert!(pool.lp_decimals() == REQUIRED_LP_DECIMALS, ELpSupplyMismatch);
    assert!(locked_lp_amount > 0, ELpSupplyMismatch);
    assert!(lp_supply > locked_lp_amount, ELpSupplyMismatch);
    assert!(lp_supply - locked_lp_amount == MIN_ILLIQUID_LP, ELpSupplyMismatch);

    (pool, lp_coin)
}

// The wrapper is returned directly by `dao_fee_pool::new` in this transaction.
#[allow(lint(share_owned))]
fun lock_and_share<Lp, Meme, Quote>(
    launch_id: ID,
    lp_fee_authority: LpFeeAuthority<Meme>,
    pool: Pool<Lp>,
    lp_coin: Coin<Lp>,
    meme_amount: u64,
    quote_amount: u64,
    policy: AftermathPolicy,
    dao_fee_version: &Version,
    ctx: &mut TxContext,
) {
    let inner_pool_id = object::id(&pool);
    let locked_lp_amount = lp_coin.value();
    let pending_vault = vault::prepare<Meme, Quote>(
        lp_fee_authority,
        balance::zero(),
        balance::zero(),
        ctx,
    );
    let vault_id = pending_vault.pending_id();
    let vault_address = vault_id.to_address();
    let (dao_fee_pool, dao_fee_owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        policy.dao_fee_bps,
        vault_address,
        ctx,
    );
    assert!(
        dao_fee_pool.fee_bps() == policy.dao_fee_bps,
        EDaoPoolInvariantMismatch,
    );
    assert!(
        dao_fee_pool.fee_recipient() == vault_address,
        EDaoPoolInvariantMismatch,
    );
    let dao_fee_pool_id = object::id(&dao_fee_pool);
    let position = AftermathPosition {
        id: object::new(ctx),
        lp_balance: lp_coin.into_balance(),
        dao_fee_owner_cap,
    };
    let finished_vault_id =
        pending_vault.finish(Venue(), dao_fee_pool_id, position);
    assert!(finished_vault_id == vault_id, EDaoPoolInvariantMismatch);
    events::aftermath_migration_completed<Lp, Meme, Quote, Venue>(
        launch_id,
        vault_id,
        inner_pool_id,
        dao_fee_pool_id,
        meme_amount,
        quote_amount,
        locked_lp_amount,
        policy.meme_weight,
        policy.quote_weight,
        FLATNESS,
        BASE_SWAP_IN_FEE,
        policy.dao_fee_bps,
    );
    transfer::public_share_object(dao_fee_pool);
}

/// Receives and allocates one bounded batch of Meme and Quote DAO-fee coins.
public fun accrue_dao_fees<Lp, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    lp_fee_policy: &LpFeePolicy,
    meme_receivings: vector<Receiving<Coin<Meme>>>,
    quote_receivings: vector<Receiving<Coin<Quote>>>,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, locked_lp_amount_before) = {
        let position = self.position_mut<_, _, _, AftermathPosition<Lp>>(&Venue());
        (position.id.to_inner(), position.lp_balance.value() as u128)
    };
    let (meme_fee, quote_fee) = self.receive_coins(
        &Venue(),
        meme_receivings,
        quote_receivings,
    );
    let locked_lp_amount_after = {
        let position = self.position_mut<_, _, _, AftermathPosition<Lp>>(&Venue());
        position.lp_balance.value() as u128
    };
    assert!(
        locked_lp_amount_before == locked_lp_amount_after,
        ELpPrincipalChanged,
    );
    self.accrue_fees(
        &Venue(),
        position_id,
        meme_fee,
        quote_fee,
        locked_lp_amount_after,
        lp_fee_policy,
        ctx,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun effective_policy_for_testing(
    venue_config: &VenueConfig,
): (u64, u64, u16) {
    let policy = effective_policy(venue_config);
    (
        policy.meme_weight,
        policy.quote_weight,
        policy.dao_fee_bps,
    )
}

#[test_only]
public fun is_type_name_less_for_testing<A, B>(): bool {
    is_type_name_less<A, B>()
}

// === Imports ===

use amm::{
    pool::{Self, CreatePoolCapV2, Pool},
    pool_factory,
    pool_registry::{Self, PoolRegistry},
};

use blast_admin::acl::AdminWitness;

use blast_fun::{
    launch::Launch,
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version::PackageVersion,
};

use blast_fun_migrators::{
    events,
    lp_fee_authority::{Self, LpFeeAuthority},
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
    venue_config::VenueConfig,
};

use dao_fee_amm::{
    pool::{Self as dao_fee_pool, DaoFeePool, OwnerCap},
    version::Version,
};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    coin::Coin,
    coin_registry::Currency,
    transfer::Receiving,
};

use fun dao_fee_amm::pool::update_fee_bps as OwnerCap.set_fee_bps;
