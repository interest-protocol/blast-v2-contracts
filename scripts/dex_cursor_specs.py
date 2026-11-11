"""Prove the compiled tick search against the pinned ordered price grid."""

GRID_BPL = """\
function $DexGridPrice(index: int): int;
function {:inline} $0_tick_math_grid_price$pure(index: int): int { $DexGridPrice(index) }
function {:inline} $0_tick_math_grid_successor_price$pure(index: int): int { $DexGridPrice(index + 1) }
procedure {:inline 1} $0_tick_math_grid_price(index: int) returns (result: int) {
    result := $DexGridPrice(index);
}
procedure {:inline 1} $0_tick_math_grid_successor_price(index: int) returns (result: int) {
    result := $DexGridPrice(index + 1);
}
procedure {:inline 1} $0_tick_math_grid_predecessor_price(index: int) returns (result: int) {
    result := $DexGridPrice(index - 1);
}
"""

TICK_GRID_SPECS = """\
#[mode(spec), ext(spec_only, no_abort, pure)]
public(package) native fun grid_price(index: u32): u256;

#[mode(spec), ext(spec_only, no_abort, pure)]
public(package) native fun grid_successor_price(index: u32): u256;

#[mode(spec), ext(spec_only, no_abort)]
public(package) native fun grid_predecessor_price(index: u32): u256;

// The exhaustive compiled grid evaluator instantiates this function.
#[mode(spec), ext(spec(target = sqrt_price_x96))]
fun tick_price_on_grid(index: u32): u256 {
    prover::prover::requires(index <= 2 * blast_fun_dex::constants::max_tick!());
    prover::prover::asserts(true);
    let result = sqrt_price_x96(index);
    prover::prover::ensures(result == grid_price(index));
    result
}

#[mode(spec), ext(spec_only(loop_inv(target = floor_index)), no_abort)]
#[allow(unused_function)]
fun floor_grid_invariant(
    price_x96: u256, lower: u32, upper: u32, floor: u32, ceiling: u32,
): bool {
    0 <= floor && floor <= lower && lower <= upper && upper <= ceiling && ceiling <= 2 * blast_fun_dex::constants::max_tick!()
        && grid_price(lower) <= price_x96
        && (upper == ceiling || grid_successor_price(upper) > price_x96)
}

#[mode(spec), ext(spec(prove, target = floor_index,
    include = tick_price_on_grid, extra_bpl = b"grid_price.bpl"))]
fun floor_grid_spec(price_x96: u256, lower: u32, upper: u32): u32 {
    prover::prover::requires(lower >= 0 && lower <= upper && upper <= 2 * blast_fun_dex::constants::max_tick!());
    prover::prover::requires(grid_price(lower) <= price_x96);
    prover::prover::asserts(true);
    let index = floor_index(price_x96, lower, upper);
    prover::prover::ensures(lower <= index && index <= upper);
    prover::prover::ensures(grid_price(index) <= price_x96);
    prover::prover::ensures(index == upper || grid_successor_price(index) > price_x96);
    index
}

"""

CURSOR_GRID_SPEC = """\
#[mode(spec), ext(spec(prove, target = move_inside,
    include = tick_math::floor_grid_spec, extra_bpl = b"grid_price.bpl"))]
fun move_inside_grid_spec(self: &mut Curve, price_x96: u256, neighbor: Option<u32>, up: bool) {
    let index = self.index;
    let liquidity = self.liquidity;
    let total = self.total_liquidity;
    let growth = self.growth;
    let group_index = self.group_index;
    let (lower, upper) = if (up) {
        (index, neighbor.destroy_or!(2 * constants::max_tick!()))
    } else {
        (neighbor.destroy_or!(0), index)
    };
    prover::prover::requires(lower >= 0 && lower <= upper && upper <= 2 * constants::max_tick!());
    prover::prover::requires(tick_math::grid_price(lower) <= price_x96);
    prover::prover::asserts(true);
    move_inside(self, price_x96, neighbor, up);
    prover::prover::ensures(lower <= self.index && self.index <= upper);
    prover::prover::ensures(tick_math::grid_price(self.index) <= price_x96);
    prover::prover::ensures(self.index == upper || tick_math::grid_successor_price(self.index) > price_x96);
    prover::prover::ensures(self.liquidity == liquidity && self.total_liquidity == total);
    prover::prover::ensures(self.growth == growth && self.group_index == group_index);
}

"""


def observe_floor_ceiling(source):
    marker = "    while (lower < upper) {"
    if source.count(marker) != 1:
        raise SystemExit("Could not locate the tick floor loop.")
    # Identity assignments retain the original endpoints as loop snapshots.
    return source.replace(
        marker,
        "    let floor = lower;\n    let ceiling = upper;\n    lower = floor;\n    upper = ceiling;\n" + marker,
        1,
    )


SWAP_GRID_CURVE_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
public(package) fun spot_bracket(self: &Curve, spot: u256): bool {
    self.index >= 0 && self.index < 2 * constants::max_tick!()
        && tick_math::grid_price(self.index) <= spot
        && spot <= tick_math::grid_successor_price(self.index)
}

// Instantiated by the reachable bitmap and tick-price storage arguments.
#[mode(spec), ext(spec(target = next_tick, ignore_abort))]
fun next_tick_for_grid_swap(self: &Curve, up: bool): Option<u32> {
    let tick = next_tick(self, up);
    let index = *tick.borrow_with_default(&0);
    prover::prover::ensures(!tick.is_some() || (index >= 0 && index <= 2 * constants::max_tick!()
        && (if (up) self.index < index else index <= self.index)));
    let price = tick_math::grid_price(index);
    if (tick.is_some()) {
        prover::prover::ensures(if (up) {
            tick_math::grid_successor_price(self.index) <= price
                && price <= tick_math::grid_successor_price(index)
        } else {
            price <= tick_math::grid_price(self.index)
                && tick_math::grid_predecessor_price(index) <= price
        });
    };
    tick
}

#[mode(spec), ext(spec(target = tick_price, ignore_abort))]
fun tick_price_for_grid_swap(self: &Curve, index: u32): u256 {
    let price = tick_price(self, index);
    prover::prover::ensures(price == tick_math::grid_price(index));
    price
}
"""

SWAP_GRID_STEP_SPEC = """\
// The Z3 step lemmas supply directional price bounds under clipping.
#[mode(spec), ext(spec(target = swap_step, ignore_abort))]
fun step_for_grid_swap(
    self: &ContinuousPath, start: u256, limit: u256, liquidity: u128, budget: u64, up: bool,
): (u256, u64, u256, u64) {
    let (price, spent, output, fee) = swap_step(self, start, limit, liquidity, budget, up);
    prover::prover::ensures(if (up) start > limit || (start <= price && price <= limit)
        else limit > start || (limit <= price && price <= start));
    (price, spent, output, fee)
}
"""

SWAP_GRID_SPEC = """\
#[mode(spec), ext(spec_only(loop_inv(target = swap_amounts)), no_abort)]
#[allow(unused_function)]
fun swap_grid_invariant<Asset, Quote>(
    self: &Pool<Asset, Quote>, spot: u256, sqrt_price_limit_x96: u256, up: bool,
): bool {
    let max = 2 * constants::max_tick!();
    self.curve.spot_bracket(spot) && spot < blast_fun_dex::tick_math::grid_price(max)
        && (if (up) spot <= sqrt_price_limit_x96 else spot >= sqrt_price_limit_x96)
}

#[mode(spec), ext(spec(prove, target = swap_amounts, ignore_abort, include(
    a = continuous_fee::step_for_grid_swap,
    b = blast_fun_dex::curve::next_tick_for_grid_swap,
    c = blast_fun_dex::curve::tick_price_for_grid_swap,
    d = blast_fun_dex::curve::credit_spec,
    e = blast_fun_dex::curve::cross_spec,
    f = blast_fun_dex::curve::move_inside_grid_spec,
), extra_bpl = b"curve/grid_price.bpl", boogie_opt = b"vcsSplitOnEveryAssert"))]
fun swap_grid_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    input_value: u64,
    sqrt_price_limit_x96: u256,
    fee_path: ContinuousPath,
    allow_zero_partial: bool,
): (u64, u64, u256, u64) {
    let start = self.sqrt_price_x96;
    let max_price = blast_fun_dex::tick_math::grid_price(2 * constants::max_tick!());
    prover::prover::requires(self.curve.spot_bracket(start) && start < max_price);
    prover::prover::requires(blast_fun_dex::tick_math::grid_price(0) < sqrt_price_limit_x96
        && sqrt_price_limit_x96 < max_price);
    prover::prover::requires(if (is_asset_input) sqrt_price_limit_x96 <= start else start <= sqrt_price_limit_x96);
    let (spent, output, price, fee) = swap_amounts(
        self, is_asset_input, input_value, sqrt_price_limit_x96, fee_path, allow_zero_partial,
    );
    prover::prover::ensures(self.curve.spot_bracket(price));
    prover::prover::ensures(price < max_price);
    (spent, output, price, fee)
}
"""
