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
/// The pool's `LpFee` settings are fixed at creation. Core computes the rate
/// using the payment that remains after any before-swap hook.
///
/// A dynamic-fee pool measures each swap against a smoothed square-root price,
/// which it updates before pricing the swap.
///
/// The curve math is not implemented: `swap_amounts`, `add_liquidity_amounts`,
/// `remove_liquidity_amounts` and `credit_donation` abort. This package must
/// not be published until they are.
module blast_fun_dex::pool;

// === Constants ===

const MAX_TICK_SPACING: u32 = 32_767;
/// Largest tick magnitude, as in Uniswap v4.
const MAX_TICK: u32 = 887_272;
/// Square-root price bounds in Q64.96, as in Uniswap v4. The maximum is exclusive.
const MIN_SQRT_PRICE_X96: u256 = 4_295_128_739;
const MAX_SQRT_PRICE_X96: u256 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

// === Public Types ===

/// Shared pool. Hook bindings, tick spacing and LP fee settings never change after creation.
public struct Pool<phantom Asset, phantom Quote> has key {
    id: UID,
    tick_spacing: u32,
    lp_fee: LpFee,
    sqrt_price_x96: u256,
    /// Smoothed square-root price a dynamic fee measures swaps against.
    /// Starts at the creation price; fixed-fee pools never move it.
    reference_sqrt_price_x96: u256,
    /// When the reference last updated, in Unix epoch milliseconds. Zero until
    /// the first update. Both prices start at the creation price.
    reference_moved_at_ms: u64,
    hooks: Hooks,
    asset_reserve: Balance<Asset>,
    quote_reserve: Balance<Quote>,
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
}

/// The slot's bound hook and whether it has approved this step.
public struct Approval has drop {
    hook: Option<TypeName>,
    is_approved: bool,
}

/// No abilities. Owns the swap payment; the input side is the only nonzero balance.
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

// Events.

public struct PoolCreated has copy, drop {
    pool_id: ID,
    asset: TypeName,
    quote: TypeName,
    tick_spacing: u32,
    lp_fee: LpFee,
    sqrt_price_x96: u256,
    hooks: Hooks,
}

public struct Swapped has copy, drop {
    pool_id: ID,
    sender: address,
    is_asset_input: bool,
    input_spent: u64,
    output_amount: u64,
    /// The LP fee this swap paid.
    lp_fee_ppm: u32,
    sqrt_price_after_x96: u256,
}

public struct LiquidityAdded has copy, drop {
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
}

public struct LiquidityRemoved has copy, drop {
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
}

public struct Donated has copy, drop {
    pool_id: ID,
    asset_amount: u64,
    quote_amount: u64,
}

// === Public Functions ===

// Hook slot flags for `register_hook`. Combine with `|`.

macro public fun before_add_liquidity_flag(): u8 { 0x80 }
macro public fun after_add_liquidity_flag(): u8 { 0x40 }
macro public fun before_remove_liquidity_flag(): u8 { 0x20 }
macro public fun after_remove_liquidity_flag(): u8 { 0x10 }
macro public fun before_swap_flag(): u8 { 0x08 }
macro public fun after_swap_flag(): u8 { 0x04 }
macro public fun before_donate_flag(): u8 { 0x02 }
macro public fun after_donate_flag(): u8 { 0x01 }
macro public fun all_hook_flags(): u8 { 0xff }

// Creation.

/// Starts a pool that charges `lp_fee_ppm`, a protocol fee tier, on every swap.
public fun new_with_fixed_fee<Asset, Quote>(
    tiers: &BlastDexFeeTiers,
    tick_spacing: u32,
    lp_fee_ppm: u32,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    new_initializer(tick_spacing, lp_fee::new_fixed(tiers, lp_fee_ppm), sqrt_price_x96, ctx)
}

/// Starts a pool whose LP fee rises from `base_fee_ppm` with the gap between each
/// swap's projected price and the reference price, up to `max_fee_ppm`; see
/// `lp_fee`. The settings never change and need no hook.
public fun new_with_dynamic_fee<Asset, Quote>(
    tiers: &BlastDexFeeTiers,
    tick_spacing: u32,
    base_fee_ppm: u32,
    max_fee_ppm: u32,
    sensitivity_ppm: u32,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    let lp_fee = lp_fee::new_dynamic(tiers, base_fee_ppm, max_fee_ppm, sensitivity_ppm);

    new_initializer(tick_spacing, lp_fee, sqrt_price_x96, ctx)
}

/// Binds `Witness` to every slot in `flags`. Only the hook's package can create
/// its witness, so the hook decides which pools it joins. `_config` proves the
/// hook's configuration exists, so routers can always derive and pass it.
public fun register_hook<Asset, Quote, Witness: drop>(
    self: &mut PoolInitializer<Asset, Quote>,
    _config: &HookConfig<Witness>,
    _witness: Witness,
    flags: u8,
) {
    assert!(flags != 0, EInvalidHookFlags);

    let hook = type_name::with_defining_ids<Witness>();
    let hooks = &mut self.pool.hooks;
    if ((flags & before_add_liquidity_flag!()) != 0) bind(&mut hooks.before_add_liquidity, hook);
    if ((flags & after_add_liquidity_flag!()) != 0) bind(&mut hooks.after_add_liquidity, hook);
    if ((flags & before_remove_liquidity_flag!()) != 0) bind(&mut hooks.before_remove_liquidity, hook);
    if ((flags & after_remove_liquidity_flag!()) != 0) bind(&mut hooks.after_remove_liquidity, hook);
    if ((flags & before_swap_flag!()) != 0) bind(&mut hooks.before_swap, hook);
    if ((flags & after_swap_flag!()) != 0) bind(&mut hooks.after_swap, hook);
    if ((flags & before_donate_flag!()) != 0) bind(&mut hooks.before_donate, hook);
    if ((flags & after_donate_flag!()) != 0) bind(&mut hooks.after_donate, hook);
}

/// Freezes the hook bindings and returns the pool for `share`.
public fun finalize<Asset, Quote>(self: PoolInitializer<Asset, Quote>): Pool<Asset, Quote> {
    let PoolInitializer { pool } = self;

    event::emit(PoolCreated {
        pool_id: pool.id.to_inner(),
        asset: type_name::with_defining_ids<Asset>(),
        quote: type_name::with_defining_ids<Quote>(),
        tick_spacing: pool.tick_spacing,
        lp_fee: pool.lp_fee,
        sqrt_price_x96: pool.sqrt_price_x96,
        hooks: pool.hooks,
    });

    pool
}

/// Defining-module sink for a finalized pool.
public fun share<Asset, Quote>(self: Pool<Asset, Quote>) {
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
    tick_lower: I32,
    tick_upper: I32,
    ctx: &mut TxContext,
): Position<Asset, Quote> {
    assert!(tick_lower.lt(&tick_upper), EInvalidTickRange);
    assert!(
        self.is_usable_tick(&tick_lower) && self.is_usable_tick(&tick_upper),
        EInvalidTickRange,
    );

    Position { id: object::new(ctx), pool_id: self.id.to_inner(), tick_lower, tick_upper, liquidity: 0 }
}

/// Deletes a position that holds no liquidity.
public fun destroy_empty_position<Asset, Quote>(position: Position<Asset, Quote>) {
    let Position { id, pool_id: _, tick_lower: _, tick_upper: _, liquidity } = position;
    assert!(liquidity == 0, EPositionNotEmpty);

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
    payment: Coin<Asset>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    assert!(payment.value() > 0, EZeroAmount);
    assert!(
        sqrt_price_limit_x96 < self.sqrt_price_x96 && sqrt_price_limit_x96 > MIN_SQRT_PRICE_X96,
        EInvalidPriceLimit,
    );

    self.lock();
    self.new_swap_request(true, payment.into_balance(), balance::zero(), sqrt_price_limit_x96)
}

/// Locks the pool and starts selling `payment` for Asset. The price limit must
/// be above the current price.
public fun begin_swap_quote_to_asset<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    payment: Coin<Quote>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    assert!(payment.value() > 0, EZeroAmount);
    assert!(
        sqrt_price_limit_x96 > self.sqrt_price_x96 && sqrt_price_limit_x96 < MAX_SQRT_PRICE_X96,
        EInvalidPriceLimit,
    );

    self.lock();
    self.new_swap_request(false, balance::zero(), payment.into_balance(), sqrt_price_limit_x96)
}

/// Before-swap hook: takes Asset from the payment, for example as a hook fee.
public fun take_swap_asset_payment<Asset, Quote, Witness: drop>(
    self: &mut SwapRequest<Asset, Quote>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
    amount: u64,
): Balance<Asset> {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);
    self.approval.assert_open<Witness>();

    self.asset_payment.split(amount)
}

/// Before-swap hook: takes Quote from the payment, for example as a hook fee.
public fun take_swap_quote_payment<Asset, Quote, Witness: drop>(
    self: &mut SwapRequest<Asset, Quote>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
    amount: u64,
): Balance<Quote> {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);
    self.approval.assert_open<Witness>();

    self.quote_payment.split(amount)
}

/// Before-swap hook: approves the request. It cannot be changed afterwards.
public fun approve_swap<Asset, Quote, Witness: drop>(
    self: &mut SwapRequest<Asset, Quote>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);

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
/// A dynamic-fee pool first moves its reference price by the `clock`.
/// Unspent payment and the output travel in the completion.
public fun execute_swap<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: SwapRequest<Asset, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Completion<Asset, Quote, Swap> {
    let (is_asset_input, asset_payment, quote_payment, sqrt_price_limit_x96) = self.open_swap(request);

    let input_value = if (is_asset_input) asset_payment.value() else quote_payment.value();
    let (input_spent, output_amount, sqrt_price_after_x96, lp_fee) = swap_amounts_and_lp_fee!(
        self.lp_fee,
        || self.move_reference_sqrt_price_x96(clock),
        |lp_fee| self.swap_amounts(is_asset_input, input_value, sqrt_price_limit_x96, lp_fee),
    );

    self.settle_swap(
        is_asset_input,
        asset_payment,
        quote_payment,
        lp_fee,
        input_spent,
        output_amount,
        sqrt_price_after_x96,
        ctx,
    )
}

// Add liquidity.

/// Locks the pool and starts minting `liquidity` in `position`. Unused payment
/// is returned.
public fun begin_add_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    position: &Position<Asset, Quote>,
    liquidity: u128,
    asset_payment: Coin<Asset>,
    quote_payment: Coin<Quote>,
): AddLiquidityRequest<Asset, Quote> {
    assert!(position.pool_id == self.id.to_inner(), EWrongPool);
    assert!(liquidity > 0, EZeroLiquidity);

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
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);

    self.approval.approve<Witness>();
}

public fun add_liquidity_amount<Asset, Quote>(self: &AddLiquidityRequest<Asset, Quote>): u128 {
    self.liquidity
}

/// Mints the liquidity, taking what it requires from the payment.
public fun execute_add_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: AddLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, AddLiquidity> {
    let (liquidity, asset_payment, quote_payment) = self.open_add_liquidity(request, position);

    let (asset_required, quote_required) = self.add_liquidity_amounts(position, liquidity);

    self.settle_add_liquidity(position, liquidity, asset_payment, quote_payment, asset_required, quote_required)
}

// Remove liquidity.

/// Locks the pool and starts burning `liquidity` from `position`.
public fun begin_remove_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    position: &Position<Asset, Quote>,
    liquidity: u128,
): RemoveLiquidityRequest<Asset, Quote> {
    assert!(position.pool_id == self.id.to_inner(), EWrongPool);
    assert!(liquidity > 0, EZeroLiquidity);
    assert!(liquidity <= position.liquidity, EInsufficientLiquidity);

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
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);

    self.approval.approve<Witness>();
}

public fun remove_liquidity_amount<Asset, Quote>(self: &RemoveLiquidityRequest<Asset, Quote>): u128 {
    self.liquidity
}

/// Burns the liquidity and returns its tokens in the completion.
public fun execute_remove_liquidity<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: RemoveLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
): Completion<Asset, Quote, RemoveLiquidity> {
    let liquidity = self.open_remove_liquidity(request, position);

    let (asset_amount, quote_amount) = self.remove_liquidity_amounts(position, liquidity);

    self.settle_remove_liquidity(position, liquidity, asset_amount, quote_amount)
}

// Donate.

/// Locks the pool and starts donating to in-range liquidity providers.
public fun begin_donate<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    asset_payment: Coin<Asset>,
    quote_payment: Coin<Quote>,
): DonateRequest<Asset, Quote> {
    assert!(asset_payment.value() > 0 || quote_payment.value() > 0, EZeroAmount);

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
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);

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
    request: DonateRequest<Asset, Quote>,
): Completion<Asset, Quote, Donate> {
    let (asset_payment, quote_payment) = self.open_donate(request);
    let (asset_amount, quote_amount) = (asset_payment.value(), quote_payment.value());

    self.credit_donation(asset_payment, quote_payment);

    self.settle_donate(asset_amount, quote_amount)
}

// Completion.

/// After hook: takes Asset from the output, for example as a hook fee.
public fun take_asset_output<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
    amount: u64,
): Balance<Asset> {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);
    self.approval.assert_open<Witness>();

    self.asset_output.split(amount)
}

/// After hook: takes Quote from the output, for example as a hook fee.
public fun take_quote_output<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
    amount: u64,
): Balance<Quote> {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);
    self.approval.assert_open<Witness>();

    self.quote_output.split(amount)
}

/// After hook: adds Asset to the output, for example as a rebate.
public fun join_asset_output<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
    asset: Balance<Asset>,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);
    self.approval.assert_open<Witness>();

    self.asset_output.join(asset);
}

/// After hook: adds Quote to the output, for example as a rebate.
public fun join_quote_output<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
    quote: Balance<Quote>,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);
    self.approval.assert_open<Witness>();

    self.quote_output.join(quote);
}

/// After hook: approves the completion. It cannot be changed afterwards.
public fun approve_completion<Asset, Quote, Operation, Witness: drop>(
    self: &mut Completion<Asset, Quote, Operation>,
    pool: &Pool<Asset, Quote>,
    _witness: Witness,
) {
    assert!(self.pool_id == pool.id.to_inner(), EWrongPool);

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
    completion: Completion<Asset, Quote, Operation>,
    min_asset_output: u64,
    min_quote_output: u64,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let Completion { pool_id, asset_output, quote_output, approval } = completion;
    assert!(pool_id == self.id.to_inner(), EWrongPool);
    approval.assert_approved();
    assert!(asset_output.value() >= min_asset_output, EInsufficientOutput);
    assert!(quote_output.value() >= min_quote_output, EInsufficientOutput);

    self.is_in_operation = false;

    (asset_output.into_coin(ctx), quote_output.into_coin(ctx))
}

// Pool-local hook state. Any hook bound to the pool owns one namespace keyed by
// its witness type; the pool UID itself is never exposed.

public fun add_hook_state<Asset, Quote, Witness: drop, Name: copy + drop + store, State: store>(
    self: &mut Pool<Asset, Quote>,
    _witness: &Witness,
    name: Name,
    state: State,
) {
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
    _witness: &Witness,
    name: Name,
): &mut State {
    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::borrow_mut(&mut self.id, key)
}

public fun remove_hook_state<Asset, Quote, Witness: drop, Name: copy + drop + store, State: store>(
    self: &mut Pool<Asset, Quote>,
    _witness: &Witness,
    name: Name,
): State {
    let key = self.hook_state_key<_, _, Witness, _>(name);

    dynamic_field::remove(&mut self.id, key)
}

// === Private Functions ===

fun new_initializer<Asset, Quote>(
    tick_spacing: u32,
    lp_fee: LpFee,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    assert!(
        type_name::with_defining_ids<Asset>() != type_name::with_defining_ids<Quote>(),
        EIdenticalTokens,
    );
    assert!(tick_spacing > 0 && tick_spacing <= MAX_TICK_SPACING, EInvalidTickSpacing);
    assert!(
        sqrt_price_x96 >= MIN_SQRT_PRICE_X96 && sqrt_price_x96 < MAX_SQRT_PRICE_X96,
        EInvalidSqrtPrice,
    );

    PoolInitializer {
        pool: Pool {
            id: object::new(ctx),
            tick_spacing,
            lp_fee,
            sqrt_price_x96,
            reference_sqrt_price_x96: sqrt_price_x96,
            reference_moved_at_ms: 0,
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
            is_in_operation: false,
        },
    }
}

fun bind(slot: &mut Option<TypeName>, hook: TypeName) {
    assert!(slot.is_none(), EHookSlotTaken);

    slot.fill(hook);
}

fun is_usable_tick<Asset, Quote>(self: &Pool<Asset, Quote>, tick: &I32): bool {
    let magnitude = tick.magnitude();

    magnitude <= MAX_TICK && magnitude % self.tick_spacing == 0
}

fun lock<Asset, Quote>(self: &mut Pool<Asset, Quote>) {
    assert!(!self.is_in_operation, EPoolInOperation);

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
        EHookNotBound,
    );
    assert!(!self.is_approved, EAlreadyApproved);
}

fun approve<Witness>(self: &mut Approval) {
    self.assert_open<Witness>();

    self.is_approved = true;
}

/// An empty slot needs no approval.
fun assert_approved(self: &Approval) {
    assert!(self.hook.is_none() || self.is_approved, EMissingApproval);
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
    assert!(self.hooks.is_bound(hook), EHookNotBound);

    HookStateKey { hook, name }
}

// Validation shared by execution and its test seam.

fun open_swap<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    request: SwapRequest<Asset, Quote>,
): (bool, Balance<Asset>, Balance<Quote>, u256) {
    let SwapRequest { pool_id, is_asset_input, asset_payment, quote_payment, sqrt_price_limit_x96, approval } = request;
    assert!(pool_id == self.id.to_inner(), EWrongPool);
    approval.assert_approved();

    (is_asset_input, asset_payment, quote_payment, sqrt_price_limit_x96)
}

// The swap's LP fee, shared by execution and its test seam.

/// Prices a swap and returns the input spent (including the LP fee), the
/// output, the price after the swap and the LP fee charged. `$swap_amounts`
/// prices the swap at a given LP fee, and `$move_reference_sqrt_price_x96`
/// moves the pool's reference price and returns it. A fixed-fee pool prices
/// once at its fee and never moves its reference. A dynamic-fee pool moves its
/// reference, previews the swap at its base fee, takes the fee for the
/// previewed price against the reference, then prices the swap again at that
/// fee. The trader's price limit is neither price.
macro fun swap_amounts_and_lp_fee(
    $lp_fee: LpFee,
    $move_reference_sqrt_price_x96: || -> u256,
    $swap_amounts: |Ppm| -> (u64, u64, u256),
): (u64, u64, u256, Ppm) {
    let lp_fee = $lp_fee;
    let base_fee = lp_fee.base_fee();
    let applied_fee = if (lp_fee.is_dynamic()) {
        let reference_sqrt_price_x96 = $move_reference_sqrt_price_x96();
        let (_, _, projected_sqrt_price_x96) = $swap_amounts(base_fee);
        lp_fee.fee_at_price(reference_sqrt_price_x96, projected_sqrt_price_x96)
    } else {
        base_fee
    };

    let (input_spent, output_amount, sqrt_price_after_x96) = $swap_amounts(applied_fee);
    (input_spent, output_amount, sqrt_price_after_x96, applied_fee)
}

/// Updates the reference toward the pre-swap price using the time since the
/// last update. Swaps at the same Clock timestamp share the reference set by
/// the first swap at that timestamp. The final spot at that timestamp can
/// influence the reference at the next timestamp.
fun move_reference_sqrt_price_x96<Asset, Quote>(self: &mut Pool<Asset, Quote>, clock: &Clock): u256 {
    let now_ms = clock.timestamp_ms();
    if (now_ms > self.reference_moved_at_ms) {
        let elapsed_ms = now_ms - self.reference_moved_at_ms;
        self.reference_sqrt_price_x96 =
            lp_fee::moved_reference_sqrt_price_x96(self.reference_sqrt_price_x96, self.sqrt_price_x96, elapsed_ms);
        self.reference_moved_at_ms = now_ms;
    };

    self.reference_sqrt_price_x96
}

fun open_add_liquidity<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    request: AddLiquidityRequest<Asset, Quote>,
    position: &Position<Asset, Quote>,
): (u128, Balance<Asset>, Balance<Quote>) {
    let AddLiquidityRequest {
        pool_id,
        position_id,
        liquidity,
        asset_payment,
        quote_payment,
        approval,
    } = request;
    assert!(pool_id == self.id.to_inner(), EWrongPool);
    assert!(position_id == position.id.to_inner(), EWrongPosition);
    approval.assert_approved();

    (liquidity, asset_payment, quote_payment)
}

fun open_remove_liquidity<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    request: RemoveLiquidityRequest<Asset, Quote>,
    position: &Position<Asset, Quote>,
): u128 {
    let RemoveLiquidityRequest { pool_id, position_id, liquidity, approval } = request;
    assert!(pool_id == self.id.to_inner(), EWrongPool);
    assert!(position_id == position.id.to_inner(), EWrongPosition);
    approval.assert_approved();

    liquidity
}

fun open_donate<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    request: DonateRequest<Asset, Quote>,
): (Balance<Asset>, Balance<Quote>) {
    let DonateRequest { pool_id, asset_payment, quote_payment, approval } = request;
    assert!(pool_id == self.id.to_inner(), EWrongPool);
    approval.assert_approved();

    (asset_payment, quote_payment)
}

// Custody and events after the curve has priced the operation.

fun settle_swap<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    mut asset_payment: Balance<Asset>,
    mut quote_payment: Balance<Quote>,
    lp_fee: Ppm,
    input_spent: u64,
    output_amount: u64,
    sqrt_price_after_x96: u256,
    ctx: &TxContext,
): Completion<Asset, Quote, Swap> {
    if (is_asset_input) {
        self.asset_reserve.join(asset_payment.split(input_spent));
        quote_payment.join(self.quote_reserve.split(output_amount));
    } else {
        self.quote_reserve.join(quote_payment.split(input_spent));
        asset_payment.join(self.asset_reserve.split(output_amount));
    };
    self.sqrt_price_x96 = sqrt_price_after_x96;

    event::emit(Swapped {
        pool_id: self.id.to_inner(),
        sender: ctx.sender(),
        is_asset_input,
        input_spent,
        output_amount,
        lp_fee_ppm: lp_fee.value(),
        sqrt_price_after_x96,
    });

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
    assert!(asset_payment.value() >= asset_required, EInsufficientPayment);
    assert!(quote_payment.value() >= quote_required, EInsufficientPayment);

    self.asset_reserve.join(asset_payment.split(asset_required));
    self.quote_reserve.join(quote_payment.split(quote_required));
    position.liquidity = position.liquidity + liquidity;

    event::emit(LiquidityAdded {
        pool_id: self.id.to_inner(),
        position_id: position.id.to_inner(),
        liquidity,
        asset_amount: asset_required,
        quote_amount: quote_required,
    });

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
    position.liquidity = position.liquidity - liquidity;
    let asset_output = self.asset_reserve.split(asset_amount);
    let quote_output = self.quote_reserve.split(quote_amount);

    event::emit(LiquidityRemoved {
        pool_id: self.id.to_inner(),
        position_id: position.id.to_inner(),
        liquidity,
        asset_amount,
        quote_amount,
    });

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
    event::emit(Donated { pool_id: self.id.to_inner(), asset_amount, quote_amount });

    Completion {
        pool_id: self.id.to_inner(),
        asset_output: balance::zero(),
        quote_output: balance::zero(),
        approval: approval_for_completion(self.hooks.after_donate),
    }
}

// Curve math seam. Each function aborts until concentrated-liquidity math lands.

/// Returns the input spent (including the LP fee), the output and the new price.
fun swap_amounts<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _is_asset_input: bool,
    _input_value: u64,
    _sqrt_price_limit_x96: u256,
    _lp_fee: Ppm,
): (u64, u64, u256) {
    abort ECurveMathUnavailable
}

/// Returns the Asset and Quote that minting `liquidity` in the position requires,
/// rounded up.
fun add_liquidity_amounts<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _liquidity: u128,
): (u64, u64) {
    abort ECurveMathUnavailable
}

/// Returns the Asset and Quote that burning `liquidity` releases, rounded down.
fun remove_liquidity_amounts<Asset, Quote>(
    _self: &Pool<Asset, Quote>,
    _position: &Position<Asset, Quote>,
    _liquidity: u128,
): (u64, u64) {
    abort ECurveMathUnavailable
}

/// Credits a donation to in-range liquidity providers' fee growth.
fun credit_donation<Asset, Quote>(
    _self: &mut Pool<Asset, Quote>,
    _asset_payment: Balance<Asset>,
    _quote_payment: Balance<Quote>,
) {
    abort ECurveMathUnavailable
}

// === Test-Only Functions ===

/// `execute_swap` with the curve's results supplied by the test, the same at
/// every LP fee.
#[test_only]
public fun execute_swap_with_amounts_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: SwapRequest<Asset, Quote>,
    input_spent: u64,
    output_amount: u64,
    sqrt_price_after_x96: u256,
    clock: &Clock,
    ctx: &mut TxContext,
): Completion<Asset, Quote, Swap> {
    let (completion, _) = self.execute_swap_with_preview_for_testing(
        request,
        sqrt_price_after_x96,
        input_spent,
        output_amount,
        sqrt_price_after_x96,
        clock,
        ctx,
    );

    completion
}

/// `execute_swap` with the curve's results supplied by the test. The curve's
/// preview ends at `preview_sqrt_price_x96` and the settlement pass at
/// `sqrt_price_after_x96`, with the same amounts. Also returns the LP fees the
/// curve priced at, in order.
#[test_only]
public fun execute_swap_with_preview_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: SwapRequest<Asset, Quote>,
    preview_sqrt_price_x96: u256,
    input_spent: u64,
    output_amount: u64,
    sqrt_price_after_x96: u256,
    clock: &Clock,
    ctx: &mut TxContext,
): (Completion<Asset, Quote, Swap>, vector<u32>) {
    let (is_asset_input, asset_payment, quote_payment, _) = self.open_swap(request);
    let is_dynamic = self.lp_fee.is_dynamic();
    let mut priced_lp_fees_ppm = vector[];

    let (input_spent, output_amount, sqrt_price_after_x96, lp_fee) = swap_amounts_and_lp_fee!(
        self.lp_fee,
        || self.move_reference_sqrt_price_x96(clock),
        |lp_fee| {
            let is_preview = is_dynamic && priced_lp_fees_ppm.is_empty();
            priced_lp_fees_ppm.push_back(lp_fee.value());
            (input_spent, output_amount, if (is_preview) preview_sqrt_price_x96 else sqrt_price_after_x96)
        },
    );
    let completion = self.settle_swap(
        is_asset_input,
        asset_payment,
        quote_payment,
        lp_fee,
        input_spent,
        output_amount,
        sqrt_price_after_x96,
        ctx,
    );

    (completion, priced_lp_fees_ppm)
}

/// `execute_add_liquidity` with the curve's results supplied by the test.
#[test_only]
public fun execute_add_liquidity_with_amounts_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: AddLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    asset_required: u64,
    quote_required: u64,
): Completion<Asset, Quote, AddLiquidity> {
    let (liquidity, asset_payment, quote_payment) = self.open_add_liquidity(request, position);

    self.settle_add_liquidity(position, liquidity, asset_payment, quote_payment, asset_required, quote_required)
}

/// `execute_remove_liquidity` with the curve's results supplied by the test.
#[test_only]
public fun execute_remove_liquidity_with_amounts_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: RemoveLiquidityRequest<Asset, Quote>,
    position: &mut Position<Asset, Quote>,
    asset_amount: u64,
    quote_amount: u64,
): Completion<Asset, Quote, RemoveLiquidity> {
    let liquidity = self.open_remove_liquidity(request, position);

    self.settle_remove_liquidity(position, liquidity, asset_amount, quote_amount)
}

/// `execute_donate` with the donation joined to reserves instead of fee growth.
#[test_only]
public fun execute_donate_for_testing<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    request: DonateRequest<Asset, Quote>,
): Completion<Asset, Quote, Donate> {
    let (asset_payment, quote_payment) = self.open_donate(request);
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
    (self.asset_reserve.value(), self.quote_reserve.value())
}

#[test_only]
public fun is_in_operation_for_testing<Asset, Quote>(self: &Pool<Asset, Quote>): bool {
    self.is_in_operation
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
    (self.reference_sqrt_price_x96, self.reference_moved_at_ms)
}

#[test_only]
public fun pool_created_lp_fee_for_testing(event: &PoolCreated): LpFee {
    event.lp_fee
}

#[test_only]
public fun swapped_lp_fee_ppm_for_testing(event: &Swapped): u32 {
    event.lp_fee_ppm
}

// === Errors ===

#[error(code = 0)]
const EIdenticalTokens: vector<u8> = b"Pool tokens must be different types.";
#[error(code = 1)]
const EInvalidTickSpacing: vector<u8> = b"Tick spacing must be between 1 and 32,767.";
#[error(code = 2)]
const EInvalidSqrtPrice: vector<u8> = b"Square-root price is outside the supported range.";
#[error(code = 3)]
const EInvalidHookFlags: vector<u8> = b"Hook registration must select at least one slot.";
#[error(code = 4)]
const EHookSlotTaken: vector<u8> = b"Another hook is already bound to this slot.";
#[error(code = 5)]
const EInvalidTickRange: vector<u8> = b"Ticks must be ordered, in range and multiples of the tick spacing.";
#[error(code = 6)]
const EPositionNotEmpty: vector<u8> = b"Position still holds liquidity.";
#[error(code = 7)]
const EPoolInOperation: vector<u8> = b"Pool is already running an operation in this transaction.";
#[error(code = 8)]
const EWrongPool: vector<u8> = b"Value belongs to a different pool.";
#[error(code = 9)]
const EWrongPosition: vector<u8> = b"Position does not match the request.";
#[error(code = 10)]
const EZeroAmount: vector<u8> = b"Payment must not be zero.";
#[error(code = 11)]
const EInvalidPriceLimit: vector<u8> = b"Price limit is on the wrong side of the current price or out of range.";
#[error(code = 12)]
const EZeroLiquidity: vector<u8> = b"Liquidity must not be zero.";
#[error(code = 13)]
const EInsufficientLiquidity: vector<u8> = b"Position holds less liquidity than requested.";
#[error(code = 14)]
const EHookNotBound: vector<u8> = b"Witness is not the hook bound to this slot.";
#[error(code = 15)]
const EAlreadyApproved: vector<u8> = b"Hook has already approved this step.";
#[error(code = 16)]
const EMissingApproval: vector<u8> = b"The bound hook has not approved this step.";
#[error(code = 17)]
const EInsufficientPayment: vector<u8> = b"Payment is less than the liquidity requires.";
#[error(code = 18)]
const EInsufficientOutput: vector<u8> = b"Output is below the caller's minimum.";
#[error(code = 19)]
const ECurveMathUnavailable: vector<u8> = b"Curve math is not implemented; do not publish this package.";

// === Imports ===

use blast_fun_dex::{hook_config::HookConfig, i32::I32, lp_fee::{Self, BlastDexFeeTiers, LpFee}, ppm::Ppm};
use std::type_name::{Self, TypeName};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_field, event};

public use fun take_swap_asset_payment as SwapRequest.take_asset_payment;
public use fun take_swap_quote_payment as SwapRequest.take_quote_payment;
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
