"""Contracts for owned positions and the swap's local admission boundaries."""

EMPTY_FEES_SPEC = """\
#[mode(spec), ext(spec_only, no_abort)]
public(package) fun empty_position_fees(self: &PositionFees): bool {
    self.checkpoint == zero() && self.owed_x128 == zero()
}

"""

SWAP_SEARCH_TOTAL_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
fun search_domain(start: u256, end: u256, liquidity: u128, up: bool): bool {
    liquidity > 0
        && start >= constants::min_sqrt_price_x96!() && start < constants::max_sqrt_price_x96!()
        && end >= constants::min_sqrt_price_x96!() && end < constants::max_sqrt_price_x96!()
        && (if (up) start <= end else end <= start)
}

// The math and fee lemmas supply this numerical contract. This summary is a
// cut for checking the search controller, separate from trial totality.
#[mode(spec), ext(spec(target = trial))]
fun trial_for_total_search(
    self: &ContinuousPath, start: u256, limit: u256, liquidity: u128, net_budget: u64, up: bool,
): SwapStep {
    prover::prover::requires(self.max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::requires(search_domain(start, limit, liquidity, up));
    prover::prover::asserts(true);
    let step = trial(self, start, limit, liquidity, net_budget, up);
    let complement = PPM - (self.max_fee_ppm as u256);
    prover::prover::ensures(step.net <= net_budget && step.fee <= step.net);
    prover::prover::ensures(search_domain(start, step.price_x96, liquidity, up));
    prover::prover::ensures(if (up) step.price_x96 <= limit else limit <= step.price_x96);
    prover::prover::ensures(step.fee == 0 || ((step.fee as u256) - 1) * complement
        < (step.net as u256) * (self.max_fee_ppm as u256));
    step
}

#[mode(spec), ext(spec(target = sqrt_price_math::output_delta_x64))]
fun output_for_total_search(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    prover::prover::requires(search_domain(start, end, liquidity, up));
    prover::prover::asserts(true);
    sqrt_price_math::output_delta_x64(start, end, liquidity, up)
}

#[mode(spec), ext(spec_only(loop_inv(target = swap_step)), no_abort)]
#[allow(unused_function)]
fun total_search_invariant(
    best: SwapStep, budget: u64, upper: u64, start: u256, liquidity: u128, up: bool,
): bool {
    upper >= 0 && upper <= budget
        && (best.net as u128) + (best.fee as u128) <= (budget as u128)
        && search_domain(start, best.price_x96, liquidity, up)
}

#[mode(spec), ext(spec(prove, target = swap_step, include(
    a = trial_for_total_search, b = output_for_total_search, c = preceding_budget_total_spec,
), boogie_opt = b"vcsSplitOnEveryAssert"))]
fun search_total_spec(
    self: &ContinuousPath, start: u256, limit: u256, liquidity: u128, budget: u64, up: bool,
): (u256, u64, u256, u64) {
    prover::prover::requires(self.max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::requires(search_domain(start, limit, liquidity, up));
    prover::prover::asserts(true);
    let (end, spent, output, fee) = swap_step(self, start, limit, liquidity, budget, up);
    prover::prover::ensures(fee <= spent && spent <= budget);
    (end, spent, output, fee)
}

"""

PROBE_TOTAL_BPL = """\
function $0_sqrt_price_math_probe_next$pure(start: int, stake: int, budget: int, up: bool): int;
function $0_sqrt_price_math_probe_net$pure(start: int, end: int, stake: int, up: bool): int;
procedure {:inline 1} $0_sqrt_price_math_probe_next(start: int, stake: int, budget: int, up: bool)
    returns (result: int) {
    result := $0_sqrt_price_math_probe_next$pure(start, stake, budget, up);
}
procedure {:inline 1} $0_sqrt_price_math_probe_net(start: int, end: int, stake: int, up: bool)
    returns (result: int) {
    result := $0_sqrt_price_math_probe_net$pure(start, end, stake, up);
}
"""

PROBE_MATH_SUMMARIES = """\
#[mode(spec), ext(spec_only, no_abort, pure)]
public(package) native fun probe_next(start: u256, liquidity: u128, net: u64, up: bool): u256;

#[mode(spec), ext(spec_only, no_abort, pure)]
public(package) native fun probe_net(start: u256, end: u256, liquidity: u128, up: bool): u256;

#[mode(spec), ext(spec(target = next_price))]
public(package) fun probe_next_total(start: u256, liquidity: u128, net: u64, up: bool): u256 {
    prover::prover::requires(start >= (1u256 << 32) && start < (1u256 << 160) && liquidity > 0);
    prover::prover::asserts(true);
    let result = next_price(start, liquidity, net, up);
    prover::prover::ensures(result == probe_next(start, liquidity, net, up));
    result
}

#[mode(spec), ext(spec(target = input_delta))]
public(package) fun probe_input_total(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    prover::prover::requires(start >= (1u256 << 32) && start < (1u256 << 160));
    prover::prover::requires(end >= (1u256 << 32) && end < (1u256 << 160));
    prover::prover::requires(if (up) start <= end else end <= start);
    prover::prover::asserts(true);
    let result = input_delta(start, end, liquidity, up);
    prover::prover::ensures(result == probe_net(start, end, liquidity, up));
    result
}

"""

PROBE_TOTAL_SPEC = """\
// The interval certificate supplies width. The exact cap and ceiling
// lemmas supply the arithmetic bounds used by fee_up and the controller.
#[mode(spec), ext(spec(target = quote))]
fun quote_for_total_probe(self: &ContinuousPath, start_x96: u256, end_x96: u256, net_input: u64): FeeQuote {
    prover::prover::requires(self.max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::requires(start_x96 >= constants::min_sqrt_price_x96!()
        && start_x96 < constants::max_sqrt_price_x96!());
    prover::prover::requires(end_x96 >= constants::min_sqrt_price_x96!()
        && end_x96 < constants::max_sqrt_price_x96!());
    prover::prover::requires(net_input == 0 || start_x96 != end_x96);
    prover::prover::asserts(true);
    let fee = quote(self, start_x96, end_x96, net_input);
    let unit = 1u256 << 96;
    let complement = PPM - (self.max_fee_ppm as u256);
    prover::prover::ensures(fee.upper_x96 <= (net_input as u256) * unit);
    prover::prover::ensures(fee.lower_x96 <= fee.upper_x96 && fee.upper_x96 - fee.lower_x96 < unit / 4);
    prover::prover::ensures(fee.upper_x96 == 0 || (fee.upper_x96 - 1) * complement
        < (net_input as u256) * (self.max_fee_ppm as u256) * unit);
    fee
}

#[mode(spec), ext(spec(prove, target = trial, include(
    a = sqrt_price_math::probe_next_total, b = sqrt_price_math::probe_input_total,
    c = quote_for_total_probe, d = fee_up_total_spec,
), extra_bpl = b"probe_total.bpl", boogie_opt = b"vcsSplitOnEveryAssert"))]
fun trial_total_spec(
    self: &ContinuousPath, start: u256, limit: u256, liquidity: u128, net_budget: u64, up: bool,
): SwapStep {
    prover::prover::requires(self.max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::requires(liquidity > 0);
    prover::prover::requires(start >= constants::min_sqrt_price_x96!()
        && start < constants::max_sqrt_price_x96!());
    let next = sqrt_price_math::probe_next(start, liquidity, net_budget, up);
    let end = if (up) next.min(limit) else next.max(limit);
    prover::prover::requires(end >= constants::min_sqrt_price_x96!()
        && end < constants::max_sqrt_price_x96!());
    prover::prover::requires(if (up) start <= end else end <= start);
    let net = sqrt_price_math::probe_net(start, end, liquidity, up);
    prover::prover::requires(net >= 0 && net <= (net_budget as u256) && (net == 0 || start != end));
    prover::prover::asserts(true);
    let step = trial(self, start, limit, liquidity, net_budget, up);
    let complement = PPM - (self.max_fee_ppm as u256);
    prover::prover::ensures(step.price_x96 == end && (step.net as u256) == net);
    prover::prover::ensures(step.net <= net_budget && step.fee <= step.net);
    prover::prover::ensures(step.fee == 0 || ((step.fee as u256) - 1) * complement
        < (step.net as u256) * (self.max_fee_ppm as u256));
    step
}

"""

OWNED_POSITION_SPECS = """\
#[mode(spec), ext(spec(target = sui::object::delete, ignore_abort))]
fun delete_owned_position_uid(id: UID) {
    sui::object::delete(id)
}

#[mode(spec), ext(spec(prove, target = new_position, ignore_abort, include = allocate_output_uid))]
fun new_owned_position_spec<Asset, Quote>(
    self: &Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    lower: I32, upper: I32, ctx: &mut TxContext,
): Position<Asset, Quote> {
    prover::prover::requires(self.tick_spacing > 0);
    let position = new_position(self, package_version, lower, upper, ctx);
    prover::prover::ensures(position.pool_id == self.id.to_inner());
    prover::prover::ensures(position.tick_lower == lower && position.tick_upper == upper);
    prover::prover::ensures(lower.lt(&upper) && self.is_usable_tick(&lower) && self.is_usable_tick(&upper));
    prover::prover::ensures(position.liquidity == 0 && curve::empty_position_fees(&position.fees));
    position
}

#[mode(spec), ext(spec(prove, target = destroy_empty_position, ignore_abort, include = delete_owned_position_uid))]
fun destroy_owned_position_spec<Asset, Quote>(position: Position<Asset, Quote>) {
    let stake = position.liquidity;
    destroy_empty_position(position);
    prover::prover::ensures(stake == 0);
}


#[mode(spec), ext(spec(prove, target = begin_add_liquidity, ignore_abort, include = delete_owned_position_uid))]
fun mint_position_binding_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    position: &Position<Asset, Quote>, liquidity: u128, asset: Coin<Asset>, quote: Coin<Quote>,
): AddLiquidityRequest<Asset, Quote> {
    let request = begin_add_liquidity(self, package_version, position, liquidity, asset, quote);
    prover::prover::ensures(self.is_in_operation && request.pool_id == self.id.to_inner());
    prover::prover::ensures(request.pool_id == position.pool_id && request.position_id == position.id.to_inner());
    request
}

#[mode(spec), ext(spec(prove, target = begin_remove_liquidity, ignore_abort))]
fun burn_position_binding_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    position: &Position<Asset, Quote>, liquidity: u128,
): RemoveLiquidityRequest<Asset, Quote> {
    let request = begin_remove_liquidity(self, package_version, position, liquidity);
    prover::prover::ensures(self.is_in_operation && request.pool_id == self.id.to_inner());
    prover::prover::ensures(request.pool_id == position.pool_id && request.position_id == position.id.to_inner());
    request
}

#[mode(spec), ext(spec(prove, target = open_add_liquidity, ignore_abort))]
fun open_mint_binding_spec<Asset, Quote>(
    self: &Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: AddLiquidityRequest<Asset, Quote>, position: &Position<Asset, Quote>,
): (u128, Balance<Asset>, Balance<Quote>) {
    let pool_id = request.pool_id;
    let position_id = request.position_id;
    let (liquidity, asset, quote) = open_add_liquidity(self, package_version, request, position);
    prover::prover::ensures(pool_id == self.id.to_inner() && position_id == position.id.to_inner());
    (liquidity, asset, quote)
}

#[mode(spec), ext(spec(prove, target = open_remove_liquidity, ignore_abort))]
fun open_burn_binding_spec<Asset, Quote>(
    self: &Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: RemoveLiquidityRequest<Asset, Quote>, position: &Position<Asset, Quote>,
): u128 {
    let pool_id = request.pool_id;
    let position_id = request.position_id;
    let result = open_remove_liquidity(self, package_version, request, position);
    prover::prover::ensures(pool_id == self.id.to_inner() && position_id == position.id.to_inner());
    result
}

"""

SWAP_BOUNDARY_SPECS = """\
// This summary is for the VM's native object allocation.
#[mode(spec), ext(spec(target = sui::object::new))]
fun allocate_output_uid(ctx: &mut TxContext): UID {
    prover::prover::asserts(true);
    sui::object::new(ctx)
}

#[mode(spec), ext(spec(prove, target = open_swap))]
fun open_swap_total_spec<Asset, Quote>(
    self: &Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
): (bool, Balance<Asset>, Balance<Quote>, u256) {
    prover::prover::requires(package_version.version() == constants::version!());
    prover::prover::requires(!package_version.is_paused(constants::swap_pause_bit!()));
    prover::prover::requires(request.pool_id == self.id.to_inner());
    prover::prover::requires(request.approval.hook.is_none() || request.approval.is_approved);
    prover::prover::asserts(true);
    open_swap(self, package_version, request)
}

#[mode(spec), ext(spec(prove, target = finish, include = allocate_output_uid))]
fun finish_swap_total_spec<Asset, Quote, Operation>(
    self: &mut Pool<Asset, Quote>, package_version: &PackageVersion<BLAST_FUN_DEX>,
    completion: Completion<Asset, Quote, Operation>, min_asset: u64, min_quote: u64, ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    prover::prover::requires(package_version.version() == constants::version!());
    prover::prover::requires(completion.pool_id == self.id.to_inner());
    prover::prover::requires(completion.approval.hook.is_none() || completion.approval.is_approved);
    prover::prover::requires(completion.asset_output.value() >= min_asset);
    prover::prover::requires(completion.quote_output.value() >= min_quote);
    prover::prover::asserts(true);
    let (asset, quote) = finish(self, package_version, completion, min_asset, min_quote, ctx);
    prover::prover::ensures(!self.is_in_operation);
    (asset, quote)
}

"""

CREDIT_TOTAL_SPEC = """\
#[mode(spec), ext(spec(prove, target = credit))]
fun credit_total_spec(self: &mut Curve, asset: u64, quote: u64) {
    prover::prover::requires(self.liquidity > 0);
    prover::prover::asserts(true);
    credit(self, asset, quote);
}

"""

REFERENCE_TOTAL_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
fun reference_valid(self: &PriceReference): bool {
    let start = self.window_start_ms as u256;
    let observed = self.observed_at_ms as u256;
    let window = constants::reference_window_ms!() as u256;
    if (observed < start || observed >= start + window) return false;
    let elapsed = observed - start;
    let minimum = constants::min_sqrt_price_x96!();
    let maximum = constants::max_sqrt_price_x96!() - 1;
    minimum * window <= self.previous_total && self.previous_total <= maximum * window
        && minimum * elapsed <= self.current_total && self.current_total <= maximum * elapsed
}

#[mode(spec), ext(spec(prove, target = new))]
fun reference_new_total_spec(price: u256): PriceReference {
    prover::prover::requires(price >= constants::min_sqrt_price_x96!() && price < constants::max_sqrt_price_x96!());
    prover::prover::asserts(true);
    let result = new(price);
    prover::prover::ensures(reference_valid(&result));
    result
}

#[mode(spec), ext(spec(prove, target = observe, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun reference_observe_total_spec(self: &mut PriceReference, spot: u256, now_ms: u64): u256 {
    prover::prover::requires(reference_valid(self));
    prover::prover::requires(spot >= constants::min_sqrt_price_x96!() && spot < constants::max_sqrt_price_x96!());
    prover::prover::asserts(true);
    let result = observe(self, spot, now_ms);
    prover::prover::ensures(reference_valid(self));
    prover::prover::ensures(result >= constants::min_sqrt_price_x96!() && result < constants::max_sqrt_price_x96!());
    result
}

"""
