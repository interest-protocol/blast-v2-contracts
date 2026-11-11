// The abort lint sees the shared error macros as numeric literals after expansion.
#[allow(lint(abort_without_constant))]
/// Concentrated-liquidity pools with Uniswap-v4-style lifecycle hooks.
///
/// Sui has no dynamic dispatch, so the pool cannot call a hook. The transaction
/// calls it instead, and the pool enforces that it did:
///
/// ```text
/// begin_*   (pool)  locks the pool and returns a request that owns the payment
/// before_*  (hook)  reads state, may take hook fees, then approves
/// execute_* (pool)  requires the bound before-hook's approval, runs the curve and
///                   returns a completion that owns the output
/// after_*   (hook)  may take from or add to the output, then approves
/// finish    (pool)  requires the bound after-hook's approval and the caller's
///                   minimum outputs, unlocks the pool and returns the coins
/// ```
///
/// Requests and completions have no abilities, so a transaction aborts unless
/// it runs every step. Each slot binds at most one hook witness, fixed when the
/// pool is created. An empty slot needs no approval. Every hook implements one
/// fixed public signature per slot, so routers resolve any hooked pool from
/// chain state alone; `example_hook` documents that convention.
///
/// Every call that mutates pool state checks the shared package version. The pause mask
/// gates creation, swaps and liquidity inflows. Removal and completion remain
/// available while paused.
///
/// The pool sets LP fees at creation and prices the payment remaining after
/// the before-swap hook. Dynamic pools use their own time-weighted reference.
///
/// Swaps integrate the LP fee over each active liquidity interval and credit
/// it to the positions in that interval. Fees settle when liquidity is removed.
module blast_fun_dex::pool;

// === Public Types ===

/// Shared pool. Hook bindings, tick spacing and LP fee settings never change after creation.
public struct Pool<phantom Asset, phantom Quote> has key {
    id: UID,
    tick_spacing: u32,
    lp_fee: LpFee,
    sqrt_price_x96: u256,
    price_reference: PriceReference,
    curve: Curve,
    hooks: Hooks,
    asset_reserve: Balance<Asset>,
    quote_reserve: Balance<Quote>,
    asset_fees: Balance<Asset>,
    quote_fees: Balance<Quote>,
    /// Set from `begin_*` to `finish`, so nothing interleaves with a hooked operation.
    is_in_operation: bool,
}

/// The unfinished pool. No abilities: it must be finalized in the same transaction.
/// Only this phase accepts hook registration.
public struct PoolInitializer<phantom Asset, phantom Quote> {
    pool: Pool<Asset, Quote>,
}

/// The witness type bound to each slot, by its defining-ID type name.
/// Routers read these fields to find the hook package and module.
public struct Hooks has copy, drop, store {
    before_add_liquidity: Option<TypeName>,
    after_add_liquidity: Option<TypeName>,
    before_remove_liquidity: Option<TypeName>,
    after_remove_liquidity: Option<TypeName>,
    before_swap: Option<TypeName>,
    after_swap: Option<TypeName>,
    before_donate: Option<TypeName>,
    after_donate: Option<TypeName>,
}

/// Caller-owned liquidity in one tick range of one pool.
public struct Position<phantom Asset, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
    fees: PositionFees,
}

/// The slot's bound hook and whether it has approved this step.
public struct Approval has drop {
    hook: Option<TypeName>,
    is_approved: bool,
}

/// No abilities. Owns the swap payment and any funds joined by the before hook.
/// The input side funds the curve; funds on the other side travel to completion.
public struct SwapRequest<phantom Asset, phantom Quote> {
    pool_id: ID,
    is_asset_input: bool,
    asset_payment: Balance<Asset>,
    quote_payment: Balance<Quote>,
    sqrt_price_limit_x96: u256,
    approval: Approval,
}

/// No abilities. Owns the maximum payment for minting `liquidity` in a position.
public struct AddLiquidityRequest<phantom Asset, phantom Quote> {
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    asset_payment: Balance<Asset>,
    quote_payment: Balance<Quote>,
    approval: Approval,
}

/// No abilities. Burns `liquidity` from a position.
public struct RemoveLiquidityRequest<phantom Asset, phantom Quote> {
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    approval: Approval,
}

/// No abilities. Owns a donation to in-range liquidity providers.
public struct DonateRequest<phantom Asset, phantom Quote> {
    pool_id: ID,
    asset_payment: Balance<Asset>,
    quote_payment: Balance<Quote>,
    approval: Approval,
}

/// No abilities. Owns an executed operation's output, including unspent payment.
/// `Operation` is `Swap`, `AddLiquidity`, `RemoveLiquidity` or `Donate`.
public struct Completion<phantom Asset, phantom Quote, phantom Operation> {
    pool_id: ID,
    asset_output: Balance<Asset>,
    quote_output: Balance<Quote>,
    approval: Approval,
}

/// Completion tags. They prevent passing one operation's completion as another's.
public struct Swap()
public struct AddLiquidity()
public struct RemoveLiquidity()
public struct Donate()

/// Pool-local hook state key, namespaced by the hook's witness type.
public struct HookStateKey<Name: copy + drop + store> has copy, drop, store {
    hook: TypeName,
    name: Name,
}

// === Public Functions ===

// Creation.

/// Starts a pool with validated fixed or dynamic LP fee settings.
public fun new<Asset, Quote>(
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    tick_spacing: u32,
    lp_fee: LpFee,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::create_pause_bit!());

    assert!(
        type_name::with_defining_ids<Asset>() != type_name::with_defining_ids<Quote>(),
        blast_fun_dex::errors::identical_tokens!(),
    );
    assert!(tick_spacing > 0 && tick_spacing <= constants::max_tick_spacing!(), blast_fun_dex::errors::invalid_tick_spacing!());
    assert!(
        sqrt_price_x96 >= constants::min_sqrt_price_x96!() && sqrt_price_x96 < constants::max_sqrt_price_x96!(),
        blast_fun_dex::errors::invalid_sqrt_price!(),
    );

    PoolInitializer {
        pool: Pool {
            id: object::new(ctx),
            tick_spacing,
            lp_fee,
            sqrt_price_x96,
            price_reference: price_reference::new(sqrt_price_x96),
            curve: curve::new(sqrt_price_x96, ctx),
            hooks: Hooks {
                before_add_liquidity: option::none(),
                after_add_liquidity: option::none(),
                before_remove_liquidity: option::none(),
                after_remove_liquidity: option::none(),
                before_swap: option::none(),
                after_swap: option::none(),
                before_donate: option::none(),
                after_donate: option::none(),
            },
            asset_reserve: balance::zero(),
            quote_reserve: balance::zero(),
            asset_fees: balance::zero(),
            quote_fees: balance::zero(),
            is_in_operation: false,
        },
    }
}

/// Binds `Witness` to every slot in `flags`. Only the hook's package can create
/// its witness, so the hook decides which pools it joins. `_config` proves the
/// hook's configuration exists, so routers can always derive and pass it.
public fun register_hook<Asset, Quote, Witness: drop>(
    self: &mut PoolInitializer<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _config: &HookConfig<Witness>,
    _witness: Witness,
    flags: u8,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::create_pause_bit!());

    assert!(flags != 0, blast_fun_dex::errors::invalid_hook_flags!());

    let hook = type_name::with_defining_ids<Witness>();
    let hooks = &mut self.pool.hooks;
    if ((flags & constants::before_add_liquidity_flag!()) != 0) hooks.before_add_liquidity.bind(hook);
    if ((flags & constants::after_add_liquidity_flag!()) != 0) hooks.after_add_liquidity.bind(hook);
    if ((flags & constants::before_remove_liquidity_flag!()) != 0) hooks.before_remove_liquidity.bind(hook);
    if ((flags & constants::after_remove_liquidity_flag!()) != 0) hooks.after_remove_liquidity.bind(hook);
    if ((flags & constants::before_swap_flag!()) != 0) hooks.before_swap.bind(hook);
    if ((flags & constants::after_swap_flag!()) != 0) hooks.after_swap.bind(hook);
    if ((flags & constants::before_donate_flag!()) != 0) hooks.before_donate.bind(hook);
    if ((flags & constants::after_donate_flag!()) != 0) hooks.after_donate.bind(hook);
}

/// Freezes the hook bindings and returns the pool for `share`.
public fun finalize<Asset, Quote>(
    self: PoolInitializer<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
): Pool<Asset, Quote> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::create_pause_bit!());

    let PoolInitializer { pool } = self;

    blast_events::pool_created(
        pool.id.to_inner(),
        type_name::with_defining_ids<Asset>(),
        type_name::with_defining_ids<Quote>(),
        pool.tick_spacing,
        pool.lp_fee,
        pool.sqrt_price_x96,
        pool.hooks,
    );

    pool
}

/// Defining-module sink for a finalized pool.
public fun share<Asset, Quote>(
    self: Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::create_pause_bit!());

    transfer::share_object(self);
}

// Pool reads.

public fun sqrt_price_x96<Asset, Quote>(self: &Pool<Asset, Quote>): u256 {
    self.sqrt_price_x96
}

/// The LP fee settings every swap pays under.
public fun lp_fee<Asset, Quote>(self: &Pool<Asset, Quote>): LpFee {
    self.lp_fee
}

// Positions.

/// Creates an empty position. Ticks must be ordered multiples of the tick spacing
/// within ±887,272.
public fun new_position<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    tick_lower: I32,
    tick_upper: I32,
    ctx: &mut TxContext,
): Position<Asset, Quote> {
    package_version.assert_current(constants::version!());

    assert!(tick_lower.lt(&tick_upper), blast_fun_dex::errors::invalid_tick_range!());
    assert!(
        self.is_usable_tick(&tick_lower) && self.is_usable_tick(&tick_upper),
        blast_fun_dex::errors::invalid_tick_range!(),
    );

    Position {
        id: object::new(ctx),
        pool_id: self.id.to_inner(),
        tick_lower,
        tick_upper,
        liquidity: 0,
        fees: curve::new_position_fees(),
    }
}

/// Deletes a position that holds no liquidity.
public fun destroy_empty_position<Asset, Quote>(position: Position<Asset, Quote>) {
    let Position { id, liquidity, .. } = position;
    assert!(liquidity == 0, blast_fun_dex::errors::position_not_empty!());

    id.delete();
}

public fun position_pool_id<Asset, Quote>(self: &Position<Asset, Quote>): ID {
    self.pool_id
}

public fun tick_lower<Asset, Quote>(self: &Position<Asset, Quote>): I32 {
    self.tick_lower
}

public fun tick_upper<Asset, Quote>(self: &Position<Asset, Quote>): I32 {
    self.tick_upper
}

public fun position_liquidity<Asset, Quote>(self: &Position<Asset, Quote>): u128 {
    self.liquidity
}

// Swap.

/// Locks the pool and starts selling `payment` for Quote. The price limit must
/// be below the current price.
public fun begin_swap_asset_to_quote<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    payment: Coin<Asset>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    begin_swap!(
        self,
        package_version,
        payment.value(),
        sqrt_price_limit_x96 < self.sqrt_price_x96 && sqrt_price_limit_x96 > constants::min_sqrt_price_x96!(),
    );

    self.new_swap_request(true, payment.into_balance(), balance::zero(), sqrt_price_limit_x96)
}

/// Locks the pool and starts selling `payment` for Asset. The price limit must
/// be above the current price.
public fun begin_swap_quote_to_asset<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    payment: Coin<Quote>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    begin_swap!(
        self,
        package_version,
        payment.value(),
        sqrt_price_limit_x96 > self.sqrt_price_x96 && sqrt_price_limit_x96 < constants::max_sqrt_price_x96!(),
    );

    self.new_swap_request(false, balance::zero(), payment.into_balance(), sqrt_price_limit_x96)
}

/// Before-swap hook: borrows the Asset payment for splitting fees or joining funds.
/// Requires the bound hook and an unapproved request.
public fun swap_asset_payment_mut<Asset, Quote, Witness: drop>(
    self: &mut SwapRequest<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
): &mut Balance<Asset> {
    assert_hook_pool!(self, package_version, pool);
    self.approval.assert_open<Witness>();

    &mut self.asset_payment
}

/// Before-swap hook: borrows the Quote payment for splitting fees or joining funds.
/// Requires the bound hook and an unapproved request.
public fun swap_quote_payment_mut<Asset, Quote, Witness: drop>(
    self: &mut SwapRequest<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
): &mut Balance<Quote> {
    assert_hook_pool!(self, package_version, pool);
    self.approval.assert_open<Witness>();

    &mut self.quote_payment
}

/// Before-swap hook: approves the request. It cannot be changed afterwards.
public fun approve_swap<Asset, Quote, Witness: drop>(
    self: &mut SwapRequest<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert_hook_pool!(self, package_version, pool);
    self.approval.approve<Witness>();
}

public fun swap_is_asset_input<Asset, Quote>(self: &SwapRequest<Asset, Quote>): bool {
    self.is_asset_input
}

/// Remaining payment on the input side.
public fun swap_input_value<Asset, Quote>(self: &SwapRequest<Asset, Quote>): u64 {
    if (self.is_asset_input) self.asset_payment.value() else self.quote_payment.value()
}

public fun swap_sqrt_price_limit_x96<Asset, Quote>(self: &SwapRequest<Asset, Quote>): u256 {
    self.sqrt_price_limit_x96
}

/// Swaps the remaining payment up to the price limit at the pool's LP fee.
/// A dynamic-fee pool observes its reference before the price changes.
/// Unspent payment and the output travel in the completion.
public fun execute_swap<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Completion<Asset, Quote, Swap> {
    self.execute_swap_inner(package_version, request, clock, false, ctx)
}

/// Allows a paid, zero-output partial fill when the traversal limit is reached.
/// Use finish with the desired minimum outputs, including zero to accept it.
public fun execute_swap_partial<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Completion<Asset, Quote, Swap> {
    self.execute_swap_inner(package_version, request, clock, true, ctx)
}

// Add liquidity.

/// Locks the pool and starts minting `liquidity` in `position`. Unused payment
/// is returned.
public fun begin_add_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    position: &Position<Asset, Quote>,
    liquidity: u128,
    asset_payment: Coin<Asset>,
    quote_payment: Coin<Quote>,
): AddLiquidityRequest<Asset, Quote> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::liquidity_in_pause_bit!());

    assert!(position.pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    assert!(liquidity > 0, blast_fun_dex::errors::zero_liquidity!());

    self.lock();
    AddLiquidityRequest {
        pool_id: self.id.to_inner(),
        position_id: position.id.to_inner(),
        liquidity,
        asset_payment: asset_payment.into_balance(),
        quote_payment: quote_payment.into_balance(),
        approval: Approval { hook: self.hooks.before_add_liquidity, is_approved: false },
    }
}

/// Before-add-liquidity hook: approves the request.
public fun approve_add_liquidity<Asset, Quote, Witness: drop>(
    self: &mut AddLiquidityRequest<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert_hook_pool!(self, package_version, pool);
    self.approval.approve<Witness>();
}

public fun add_liquidity_amount<Asset, Quote>(self: &AddLiquidityRequest<Asset, Quote>): u128 {
    self.liquidity
}

/// Mints the liquidity, taking what it requires from the payment.
public fun execute_add_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: AddLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, AddLiquidity> {
    let (liquidity, asset_payment, quote_payment) = self.open_add_liquidity(package_version, request, position);

    let (asset_required, quote_required) = self.position_amounts(position, liquidity, true);
    assert!(
        asset_required <= (asset_payment.value() as u256) && quote_required <= (quote_payment.value() as u256),
        blast_fun_dex::errors::insufficient_payment!(),
    );

    self.settle_add_liquidity(
        position, liquidity, asset_payment, quote_payment, asset_required as u64, quote_required as u64,
    )
}

// Remove liquidity.

/// Locks the pool and starts burning `liquidity` from `position`.
public fun begin_remove_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    position: &Position<Asset, Quote>,
    liquidity: u128,
): RemoveLiquidityRequest<Asset, Quote> {
    package_version.assert_current(constants::version!());

    assert!(position.pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    assert!(liquidity > 0, blast_fun_dex::errors::zero_liquidity!());
    assert!(liquidity <= position.liquidity, blast_fun_dex::errors::insufficient_liquidity!());

    self.lock();
    RemoveLiquidityRequest {
        pool_id: self.id.to_inner(),
        position_id: position.id.to_inner(),
        liquidity,
        approval: Approval { hook: self.hooks.before_remove_liquidity, is_approved: false },
    }
}

/// Before-remove-liquidity hook: approves the request.
public fun approve_remove_liquidity<Asset, Quote, Witness: drop>(
    self: &mut RemoveLiquidityRequest<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert_hook_pool!(self, package_version, pool);
    self.approval.approve<Witness>();
}

public fun remove_liquidity_amount<Asset, Quote>(self: &RemoveLiquidityRequest<Asset, Quote>): u128 {
    self.liquidity
}

/// Burns liquidity and returns its principal and the position's accrued whole-atom fees.
public fun execute_remove_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: RemoveLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, RemoveLiquidity> {
    let liquidity = self.open_remove_liquidity(package_version, request, position);

    let (asset_amount, quote_amount) = self.position_amounts(position, liquidity, false);
    assert!(
        asset_amount <= (self.asset_reserve.value() as u256) && quote_amount <= (self.quote_reserve.value() as u256),
        blast_fun_dex::errors::insufficient_liquidity!(),
    );

    self.settle_remove_liquidity(position, liquidity, asset_amount as u64, quote_amount as u64)
}

// Donate.

/// Locks the pool and starts donating to in-range liquidity providers.
public fun begin_donate<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    asset_payment: Coin<Asset>,
    quote_payment: Coin<Quote>,
): DonateRequest<Asset, Quote> {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::liquidity_in_pause_bit!());

    assert!(asset_payment.value() > 0 || quote_payment.value() > 0, blast_fun_dex::errors::zero_amount!());

    self.lock();
    DonateRequest {
        pool_id: self.id.to_inner(),
        asset_payment: asset_payment.into_balance(),
        quote_payment: quote_payment.into_balance(),
        approval: Approval { hook: self.hooks.before_donate, is_approved: false },
    }
}

/// Before-donate hook: approves the request.
public fun approve_donate<Asset, Quote, Witness: drop>(
    self: &mut DonateRequest<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert_hook_pool!(self, package_version, pool);
    self.approval.approve<Witness>();
}

public fun donate_asset_value<Asset, Quote>(self: &DonateRequest<Asset, Quote>): u64 {
    self.asset_payment.value()
}

public fun donate_quote_value<Asset, Quote>(self: &DonateRequest<Asset, Quote>): u64 {
    self.quote_payment.value()
}

/// Credits the donation to in-range liquidity providers. The completion is empty.
public fun execute_donate<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: DonateRequest<Asset, Quote>,
): Completion<Asset, Quote, Donate> {
    let (asset_payment, quote_payment) = self.open_donate(package_version, request);
    let (asset_amount, quote_amount) = (asset_payment.value(), quote_payment.value());

    self.curve.credit(asset_amount, quote_amount);
    self.asset_fees.join(asset_payment);
    self.quote_fees.join(quote_payment);

    self.settle_donate(asset_amount, quote_amount)
}

// Completion.

/// After hook: borrows the Asset output for splitting fees or joining rebates.
/// Requires the bound hook and an unapproved completion.
public fun asset_output_mut<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
): &mut Balance<Asset> {
    assert_hook_pool!(self, package_version, pool);
    self.approval.assert_open<Witness>();

    &mut self.asset_output
}

/// After hook: borrows the Quote output for splitting fees or joining rebates.
/// Requires the bound hook and an unapproved completion.
public fun quote_output_mut<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
): &mut Balance<Quote> {
    assert_hook_pool!(self, package_version, pool);
    self.approval.assert_open<Witness>();

    &mut self.quote_output
}

/// After hook: approves the completion. It cannot be changed afterwards.
public fun approve_completion<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert_hook_pool!(self, package_version, pool);
    self.approval.approve<Witness>();
}

public fun asset_output_value<Asset, Quote, Operation>(self: &Completion<Asset, Quote, Operation>): u64 {
    self.asset_output.value()
}

public fun quote_output_value<Asset, Quote, Operation>(self: &Completion<Asset, Quote, Operation>): u64 {
    self.quote_output.value()
}

/// Ends any operation: requires the after hook's approval and the caller's
/// minimum outputs, unlocks the pool and returns both coins, either may be zero.
public fun finish<Asset, Quote, Operation>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    completion: Completion<Asset, Quote, Operation>,
    min_asset_output: u64,
    min_quote_output: u64,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    package_version.assert_current(constants::version!());

    let Completion { pool_id, asset_output, quote_output, approval } = completion;
    assert!(pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    approval.assert_approved();
    assert!(asset_output.value() >= min_asset_output, blast_fun_dex::errors::insufficient_output!());
    assert!(quote_output.value() >= min_quote_output, blast_fun_dex::errors::insufficient_output!());

    self.is_in_operation = false;

    (asset_output.into_coin(ctx), quote_output.into_coin(ctx))
}

// Pool-local hook state. Any hook bound to the pool owns one namespace keyed by
// its witness type; the pool UID itself is never exposed.

public fun add_hook_state<Asset, Quote, Witness: drop, Name: copy + drop + store, State: store>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _witness: &Witness,
    name: Name,
    state: State,
) {
    package_version.assert_current(constants::version!());

    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::add(&mut self.id, key, state);
}

public fun has_hook_state<Asset, Quote, Witness: drop, Name: copy + drop + store>(
    self: &Pool<Asset, Quote>,
    _witness: &Witness,
    name: Name,
): bool {
    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::exists(&self.id, key)
}

public fun hook_state<Asset, Quote, Witness: drop, Name: copy + drop + store, State: store>(
    self: &Pool<Asset, Quote>,
    _witness: &Witness,
    name: Name,
): &State {
    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::borrow(&self.id, key)
}

public fun hook_state_mut<Asset, Quote, Witness: drop, Name: copy + drop + store, State: store>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _witness: &Witness,
    name: Name,
): &mut State {
    package_version.assert_current(constants::version!());

    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::borrow_mut(&mut self.id, key)
}

public fun remove_hook_state<Asset, Quote, Witness: drop, Name: copy + drop + store, State: store>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _witness: &Witness,
    name: Name,
): State {
    package_version.assert_current(constants::version!());

    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::remove(&mut self.id, key)
}

// === Private Functions ===

// Direct calls keep the pool borrow lazy until after payment and price validation.
macro fun begin_swap<$Asset, $Quote>(
    $self: &mut Pool<$Asset, $Quote>,
    $package_version: &PackageVersion<BLAST_FUN_DEX>,
    $payment_value: u64,
    $valid_price_limit: bool,
) {
    let package_version = $package_version;
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::swap_pause_bit!());

    assert!($payment_value > 0, blast_fun_dex::errors::zero_amount!());
    assert!($valid_price_limit, blast_fun_dex::errors::invalid_price_limit!());

    let pool = $self;
    pool.lock();
}

// Requests and completions share these fields; keep their public types distinct.
macro fun assert_hook_pool<$Asset, $Quote>(
    $self: &_,
    $package_version: &PackageVersion<BLAST_FUN_DEX>,
    $pool: &Pool<$Asset, $Quote>,
) {
    let package_version = $package_version;
    package_version.assert_current(constants::version!());

    let request = $self;
    let pool = $pool;
    assert!(request.pool_id == pool.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
}

fun bind(slot: &mut Option<TypeName>, hook: TypeName) {
    assert!(slot.is_none(), blast_fun_dex::errors::hook_slot_taken!());

    slot.fill(hook);
}

fun is_usable_tick<Asset, Quote>(self: &Pool<Asset, Quote>, tick: &I32): bool {
    let magnitude = tick.magnitude();

    magnitude <= constants::max_tick!() && magnitude % self.tick_spacing == 0
}

fun lock<Asset, Quote>(self: &mut Pool<Asset, Quote>) {
    assert!(!self.is_in_operation, blast_fun_dex::errors::pool_in_operation!());

    self.is_in_operation = true;
}

fun new_swap_request<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    is_asset_input: bool,
    asset_payment: Balance<Asset>,
    quote_payment: Balance<Quote>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    SwapRequest {
        pool_id: self.id.to_inner(),
        is_asset_input,
        asset_payment,
        quote_payment,
        sqrt_price_limit_x96,
        approval: Approval { hook: self.hooks.before_swap, is_approved: false },
    }
}

/// Bound to this slot and not yet approved, so the hook may still change the step.
fun assert_open<Witness>(self: &Approval) {
    assert!(
        self.hook == option::some(type_name::with_defining_ids<Witness>()),
        blast_fun_dex::errors::hook_not_bound!(),
    );
    assert!(!self.is_approved, blast_fun_dex::errors::already_approved!());
}

fun approve<Witness>(self: &mut Approval) {
    self.assert_open<Witness>();

    self.is_approved = true;
}

/// An empty slot needs no approval.
fun assert_approved(self: &Approval) {
    assert!(self.hook.is_none() || self.is_approved, blast_fun_dex::errors::missing_approval!());
}

fun approval_for_completion(hook: Option<TypeName>): Approval {
    Approval { hook, is_approved: false }
}

fun is_bound(self: &Hooks, hook: TypeName): bool {
    let candidate = option::some(hook);

    self.before_add_liquidity == candidate
        || self.after_add_liquidity == candidate
        || self.before_remove_liquidity == candidate
        || self.after_remove_liquidity == candidate
        || self.before_swap == candidate
        || self.after_swap == candidate
        || self.before_donate == candidate
        || self.after_donate == candidate
}

fun hook_state_key<Asset, Quote, Witness, Name: copy + drop + store>(
    self: &Pool<Asset, Quote>,
    name: Name,
): HookStateKey<Name> {
    let hook = type_name::with_defining_ids<Witness>();
    assert!(self.hooks.is_bound(hook), blast_fun_dex::errors::hook_not_bound!());

    HookStateKey { hook, name }
}

// Validation shared by execution and its test seam.

fun open_swap<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
): (bool, Balance<Asset>, Balance<Quote>, u256) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::swap_pause_bit!());

    let SwapRequest { pool_id, is_asset_input, asset_payment, quote_payment, sqrt_price_limit_x96, approval } = request;
    assert!(pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    approval.assert_approved();

    (is_asset_input, asset_payment, quote_payment, sqrt_price_limit_x96)
}

/// Freezes the pool's fee schedule before walking the curve.
fun swap_fee_path<Asset, Quote>(self: &mut Pool<Asset, Quote>, clock: &Clock): ContinuousPath {
    let reference_x96 = if (self.lp_fee.is_dynamic()) {
        self.price_reference.observe(self.sqrt_price_x96, clock.timestamp_ms())
    } else {
        self.sqrt_price_x96
    };

    continuous_fee::new(self.lp_fee, reference_x96)
}

fun open_add_liquidity<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: AddLiquidityRequest<Asset, Quote>,
    position: &Position<Asset, Quote>,
): (u128, Balance<Asset>, Balance<Quote>) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::liquidity_in_pause_bit!());

    let AddLiquidityRequest {
        pool_id,
        position_id,
        liquidity,
        asset_payment,
        quote_payment,
        approval,
    } = request;
    assert!(pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    assert!(position_id == position.id.to_inner(), blast_fun_dex::errors::wrong_position!());
    approval.assert_approved();

    (liquidity, asset_payment, quote_payment)
}

fun open_remove_liquidity<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: RemoveLiquidityRequest<Asset, Quote>,
    position: &Position<Asset, Quote>,
): u128 {
    package_version.assert_current(constants::version!());

    let RemoveLiquidityRequest { pool_id, position_id, liquidity, approval } = request;
    assert!(pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    assert!(position_id == position.id.to_inner(), blast_fun_dex::errors::wrong_position!());
    approval.assert_approved();

    liquidity
}

fun open_donate<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: DonateRequest<Asset, Quote>,
): (Balance<Asset>, Balance<Quote>) {
    package_version.assert_current(constants::version!());
    package_version.assert_not_paused(constants::liquidity_in_pause_bit!());

    let DonateRequest { pool_id, asset_payment, quote_payment, approval } = request;
    assert!(pool_id == self.id.to_inner(), blast_fun_dex::errors::wrong_pool!());
    approval.assert_approved();

    (asset_payment, quote_payment)
}

// Custody and events after the curve has priced the operation.

fun settle_swap<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    mut asset_payment: Balance<Asset>,
    mut quote_payment: Balance<Quote>,
    lp_fee_amount: u64,
    input_spent: u64,
    output_amount: u64,
    sqrt_price_after_x96: u256,
    ctx: &TxContext,
): Completion<Asset, Quote, Swap> {
    if (is_asset_input) {
        self.asset_fees.join(asset_payment.split(lp_fee_amount));
        self.asset_reserve.join(asset_payment.split(input_spent - lp_fee_amount));
        quote_payment.join(self.quote_reserve.split(output_amount));
    } else {
        self.quote_fees.join(quote_payment.split(lp_fee_amount));
        self.quote_reserve.join(quote_payment.split(input_spent - lp_fee_amount));
        asset_payment.join(self.asset_reserve.split(output_amount));
    };
    self.sqrt_price_x96 = sqrt_price_after_x96;

    blast_events::swapped(
        self.id.to_inner(),
        ctx.sender(),
        is_asset_input,
        input_spent,
        output_amount,
        lp_fee_amount,
        sqrt_price_after_x96,
    );

    Completion {
        pool_id: self.id.to_inner(),
        asset_output: asset_payment,
        quote_output: quote_payment,
        approval: approval_for_completion(self.hooks.after_swap),
    }
}

fun settle_add_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    liquidity: u128,
    mut asset_payment: Balance<Asset>,
    mut quote_payment: Balance<Quote>,
    asset_required: u64,
    quote_required: u64,
): Completion<Asset, Quote, AddLiquidity> {
    assert!(asset_payment.value() >= asset_required, blast_fun_dex::errors::insufficient_payment!());
    assert!(quote_payment.value() >= quote_required, blast_fun_dex::errors::insufficient_payment!());

    let (lower, upper) = position.indexes();
    self.curve.change_liquidity(&mut position.fees, lower, upper, position.liquidity, liquidity, true);
    self.asset_reserve.join(asset_payment.split(asset_required));
    self.quote_reserve.join(quote_payment.split(quote_required));
    position.liquidity = position.liquidity + liquidity;

    blast_events::liquidity_added(
        self.id.to_inner(),
        position.id.to_inner(),
        position.tick_lower,
        position.tick_upper,
        liquidity,
        asset_required,
        quote_required,
    );

    Completion {
        pool_id: self.id.to_inner(),
        asset_output: asset_payment,
        quote_output: quote_payment,
        approval: approval_for_completion(self.hooks.after_add_liquidity),
    }
}

fun settle_remove_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
): Completion<Asset, Quote, RemoveLiquidity> {
    let (lower, upper) = position.indexes();
    self.curve.change_liquidity(&mut position.fees, lower, upper, position.liquidity, liquidity, false);
    position.liquidity = position.liquidity - liquidity;
    let (asset_fee, quote_fee) = position.fees.take_fees(position.liquidity == 0);
    let mut asset_output = self.asset_reserve.split(asset_amount);
    let mut quote_output = self.quote_reserve.split(quote_amount);
    asset_output.join(self.asset_fees.split(asset_fee));
    quote_output.join(self.quote_fees.split(quote_fee));

    blast_events::liquidity_removed(
        self.id.to_inner(),
        position.id.to_inner(),
        position.tick_lower,
        position.tick_upper,
        liquidity,
        asset_amount,
        quote_amount,
        asset_fee,
        quote_fee,
    );

    Completion {
        pool_id: self.id.to_inner(),
        asset_output,
        quote_output,
        approval: approval_for_completion(self.hooks.after_remove_liquidity),
    }
}

fun settle_donate<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    asset_amount: u64,
    quote_amount: u64,
): Completion<Asset, Quote, Donate> {
    blast_events::donated(self.id.to_inner(), asset_amount, quote_amount);

    Completion {
        pool_id: self.id.to_inner(),
        asset_output: balance::zero(),
        quote_output: balance::zero(),
        approval: approval_for_completion(self.hooks.after_donate),
    }
}

fun execute_swap_inner<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
    clock: &Clock,
    allow_zero_partial: bool,
    ctx: &TxContext,
): Completion<Asset, Quote, Swap> {
    let (is_asset_input, asset_payment, quote_payment, sqrt_price_limit_x96) = self.open_swap(package_version, request);

    let input_value = if (is_asset_input) asset_payment.value() else quote_payment.value();
    let fee_path = self.swap_fee_path(clock);
    let (input_spent, output_amount, sqrt_price_after_x96, lp_fee_amount) =
        self.swap_amounts(is_asset_input, input_value, sqrt_price_limit_x96, fee_path, allow_zero_partial);

    self.settle_swap(
        is_asset_input,
        asset_payment,
        quote_payment,
        lp_fee_amount,
        input_spent,
        output_amount,
        sqrt_price_after_x96,
        ctx,
    )
}

/// Integrate one fee per initialized liquidity interval, crediting the old
/// range before crossing its tick. The unspent budget returns in completion.
fun swap_amounts<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    input_value: u64,
    sqrt_price_limit_x96: u256,
    fee_path: ContinuousPath,
    allow_zero_partial: bool,
): (u64, u64, u256, u64) {
    let up = !is_asset_input;
    let mut remaining = input_value;
    let mut output_x64 = 0u256;
    let mut total_fee = 0;
    let mut spot = self.sqrt_price_x96;
    let mut steps = 0;
    while (remaining > 0 && spot != sqrt_price_limit_x96 && steps < constants::max_swap_steps!()) {
        steps = steps + 1;
        let tick = self.curve.next_tick(up);
        let tick_price = if (tick.is_some()) self.curve.tick_price(*tick.borrow()) else sqrt_price_limit_x96;
        let target = if (up) tick_price.min(sqrt_price_limit_x96) else tick_price.max(sqrt_price_limit_x96);
        let liquidity = self.curve.liquidity();

        if (liquidity > 0 && spot != target) {
            let (end, spent, step_output_x64, fee) = fee_path.swap_step(spot, target, liquidity, remaining, up);
            if (end == spot) break;
            spot = end;
            remaining = remaining - spent;
            output_x64 = output_x64 + step_output_x64;
            total_fee = total_fee + fee;
            if (is_asset_input) self.curve.credit(fee, 0)
            else self.curve.credit(0, fee);
        } else if (tick.is_some() && target == tick_price) {
            // A gap can reach the next initialized range without spending input.
            spot = target;
        } else {
            break
        };

        if (tick.is_some() && spot == tick_price) {
            self.curve.cross(tick.destroy_some(), up);
        } else {
            self.curve.move_inside(spot, tick, up);
            break
        };
    };

    let output = output_x64 >> 64;
    let paid_partial = allow_zero_partial && steps == constants::max_swap_steps!()
        && spot != sqrt_price_limit_x96 && remaining < input_value;
    assert!(output > 0 || paid_partial, blast_fun_dex::errors::insufficient_output!());
    let reserve = if (is_asset_input) self.quote_reserve.value() else self.asset_reserve.value();
    assert!(output <= (reserve as u256), blast_fun_dex::errors::insufficient_liquidity!());
    (input_value - remaining, output as u64, spot, total_fee)
}

fun position_amounts<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    position: &Position<Asset, Quote>,
    liquidity: u128,
    round_up: bool,
): (u256, u256) {
    let (lower, upper) = position.indexes();
    curve::position_amounts(self.sqrt_price_x96, lower, upper, liquidity, round_up)
}

fun indexes<Asset, Quote>(self: &Position<Asset, Quote>): (u32, u32) {
    (tick_math::index(self.tick_lower), tick_math::index(self.tick_upper))
}

// === Test-Only Functions ===

/// Settles fixture-supplied curve results while exercising the reference update.
#[test_only]
public fun execute_swap_with_amounts_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
    input_spent: u64,
    output_amount: u64,
    sqrt_price_after_x96: u256,
    lp_fee_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Completion<Asset, Quote, Swap> {
    let (is_asset_input, asset_payment, quote_payment, _) = self.open_swap(package_version, request);
    self.swap_fee_path(clock);

    self.settle_swap(
        is_asset_input,
        asset_payment,
        quote_payment,
        lp_fee_amount,
        input_spent,
        output_amount,
        sqrt_price_after_x96,
        ctx,
    )
}

/// `execute_add_liquidity` with the curve's results supplied by the test.
#[test_only]
public fun execute_add_liquidity_with_amounts_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: AddLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    asset_required: u64,
    quote_required: u64,
): Completion<Asset, Quote, AddLiquidity> {
    let (liquidity, asset_payment, quote_payment) = self.open_add_liquidity(package_version, request, position);

    self.settle_add_liquidity(position, liquidity, asset_payment, quote_payment, asset_required, quote_required)
}

/// `execute_remove_liquidity` with the curve's results supplied by the test.
#[test_only]
public fun execute_remove_liquidity_with_amounts_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: RemoveLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    asset_amount: u64,
    quote_amount: u64,
): Completion<Asset, Quote, RemoveLiquidity> {
    let liquidity = self.open_remove_liquidity(package_version, request, position);

    self.settle_remove_liquidity(position, liquidity, asset_amount, quote_amount)
}

/// `execute_donate` with the donation joined to reserves instead of fee growth.
#[test_only]
public fun execute_donate_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: DonateRequest<Asset, Quote>,
): Completion<Asset, Quote, Donate> {
    let (asset_payment, quote_payment) = self.open_donate(package_version, request);
    let (asset_amount, quote_amount) = (asset_payment.value(), quote_payment.value());
    self.asset_reserve.join(asset_payment);
    self.quote_reserve.join(quote_payment);

    self.settle_donate(asset_amount, quote_amount)
}

#[test_only]
public fun join_reserves_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    asset: Balance<Asset>,
    quote: Balance<Quote>,
) {
    self.asset_reserve.join(asset);
    self.quote_reserve.join(quote);
}

#[test_only]
public fun reserves_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): (u64, u64) {
    (self.asset_reserve.value() + self.asset_fees.value(), self.quote_reserve.value() + self.quote_fees.value())
}

#[test_only]
public fun is_in_operation_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): bool {
    self.is_in_operation
}

#[test_only]
public fun hooks_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): Hooks {
    self.hooks
}

#[test_only]
public fun before_swap_hook_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): Option<TypeName> {
    self.hooks.before_swap
}

#[test_only]
public fun after_donate_hook_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): Option<TypeName> {
    self.hooks.after_donate
}

/// The reference square-root price and when it last moved.
#[test_only]
public fun reference_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): (u256, u64) {
    self.price_reference.observation_for_testing()
}

// === Imports ===

use blast_admin::package_version::PackageVersion;
use blast_fun_dex::{
    blast_events,
    blast_fun_dex::BLAST_FUN_DEX,
    constants,
    hook_config::HookConfig,
    i32::I32,
    lp_fee::LpFee,
    continuous_fee::{Self, ContinuousPath},
    curve::{Self, Curve, PositionFees},
    tick_math,
    price_reference::{Self, PriceReference},
};
use std::type_name::{Self, TypeName};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_field};

use fun bind as Option.bind;

public use fun swap_asset_payment_mut as SwapRequest.asset_payment_mut;
public use fun swap_quote_payment_mut as SwapRequest.quote_payment_mut;
public use fun approve_swap as SwapRequest.approve;
public use fun swap_is_asset_input as SwapRequest.is_asset_input;
public use fun swap_input_value as SwapRequest.input_value;
public use fun swap_sqrt_price_limit_x96 as SwapRequest.sqrt_price_limit_x96;
public use fun approve_add_liquidity as AddLiquidityRequest.approve;
public use fun add_liquidity_amount as AddLiquidityRequest.liquidity;
public use fun approve_remove_liquidity as RemoveLiquidityRequest.approve;
public use fun remove_liquidity_amount as RemoveLiquidityRequest.liquidity;
public use fun approve_donate as DonateRequest.approve;
public use fun donate_asset_value as DonateRequest.asset_value;
public use fun donate_quote_value as DonateRequest.quote_value;
public use fun approve_completion as Completion.approve;
public use fun destroy_empty_position as Position.destroy_empty;
public use fun position_pool_id as Position.pool_id;
public use fun position_liquidity as Position.liquidity;
