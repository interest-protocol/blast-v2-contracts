"""Check the compiled rounding and direction wiring for principal deltas."""

# Mathematical integer operations can describe products larger than u256
# without adding overflow conditions to the specification itself.
ROUND_BPL = """\
function $DexRoundedProduct(a: int, b: int, d: int, up: bool): int {
    a * b div d + (if up && a * b mod d != 0 then 1 else 0)
}
procedure {:inline 1} $0_sqrt_price_math_product_admitted(a: int, b: int, d: int, up: bool)
    returns (ok: bool) {
    ok := 0 <= a && 0 <= b && 0 < d
        && (a * b < 115792089237316195423570985008687907853269984665640564039457584007913129639936
            || (a < 26959946667150639794667015087019630673637144422540572481103610249216
                && b < 1461501637330902918203684832716283019655932542976
                && d < 53919893334301279589334030174039261347274288845081144962207220498432
                && $DexRoundedProduct(a, b, d, up) < 115792089237316195423570985008687907853269984665640564039457584007913129639936));
}
procedure {:inline 1} $0_sqrt_price_math_rounded_product(a: int, b: int, d: int, up: bool)
    returns (r: int) {
    r := $DexRoundedProduct(a, b, d, up);
}
"""

PRINCIPAL_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
public(package) native fun rounded_product(a: u256, b: u256, d: u256, up: bool): u256;

#[mode(spec), ext(spec_only, no_abort)]
public(package) native fun product_admitted(a: u256, b: u256, d: u256, up: bool): bool;

#[mode(spec), ext(spec(prove, target = divide, extra_bpl = b"principal_round.bpl"))]
fun divide_rounding_spec(numerator: u256, denominator: u256, up: bool): u256 {
    prover::prover::requires(numerator >= 0 && denominator > 0);
    prover::prover::asserts(true);
    let result = divide(numerator, denominator, up);
    prover::prover::ensures(result == rounded_product(numerator, 1, denominator, up));
    result
}

"""

FAST_MUL_DIV_SPEC = """\
#[mode(spec), ext(spec(prove, target = mul_div, ignore_abort,
    include = divide_rounding_spec, extra_bpl = b"principal_round.bpl"))]
fun mul_div_fast_spec(a: u256, b: u256, d: u256, up: bool): u256 {
    prover::prover::requires(a >= 0 && b >= 0 && d > 0);
    prover::prover::requires(a == 0 || b <= std::u256::max_value!() / a);
    let result = mul_div(a, b, d, up);
    prover::prover::ensures(result == rounded_product(a, b, d, up));
    result
}

"""

PRINCIPAL_WRAPPER_SPECS = """\
// The direction and nesting contracts are conditional on the exact
// subroutine contract within the fast or bounded limb domains.
#[mode(spec), ext(spec(target = mul_div))]
fun mul_div_for_principal(a: u256, b: u256, d: u256, up: bool): u256 {
    prover::prover::requires(product_admitted(a, b, d, up));
    prover::prover::asserts(true);
    let result = mul_div(a, b, d, up);
    prover::prover::ensures(result == rounded_product(a, b, d, up));
    result
}

#[mode(spec), ext(spec(prove, target = asset_delta,
    include(a = mul_div_for_principal, b = divide_rounding_spec), extra_bpl = b"principal_round.bpl"))]
public(package) fun asset_delta_rounding_spec(lower: u256, upper: u256, liquidity: u128, up: bool): u256 {
    prover::prover::requires(0 < lower && lower <= upper && liquidity >= 0);
    let scaled = (liquidity as u256) << 96;
    prover::prover::requires(product_admitted(scaled, upper - lower, upper, up));
    prover::prover::asserts(true);
    let first = rounded_product(scaled, upper - lower, upper, up);
    let result = asset_delta(lower, upper, liquidity, up);
    prover::prover::ensures(result == rounded_product(first, 1, lower, up));
    result
}

#[mode(spec), ext(spec(prove, target = quote_delta,
    include = mul_div_for_principal, extra_bpl = b"principal_round.bpl"))]
public(package) fun quote_delta_rounding_spec(lower: u256, upper: u256, liquidity: u128, up: bool): u256 {
    prover::prover::requires(0 < lower && lower <= upper && liquidity >= 0);
    prover::prover::requires(product_admitted(liquidity as u256, upper - lower, Q96, up));
    prover::prover::asserts(true);
    let result = quote_delta(lower, upper, liquidity, up);
    prover::prover::ensures(result == rounded_product(liquidity as u256, upper - lower, Q96, up));
    result
}

#[mode(spec), ext(spec(prove, target = input_delta,
    include(a = asset_delta_rounding_spec, b = quote_delta_rounding_spec), extra_bpl = b"principal_round.bpl"))]
public(package) fun swap_input_rounding_spec(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    let (lower, upper) = if (up) (start, end) else (end, start);
    prover::prover::requires(0 < lower && lower <= upper && liquidity >= 0);
    prover::prover::requires(if (up) product_admitted(liquidity as u256, upper - lower, Q96, true)
        else product_admitted((liquidity as u256) << 96, upper - lower, upper, true));
    prover::prover::asserts(true);
    let result = input_delta(start, end, liquidity, up);
    prover::prover::ensures(result == principal_input(start, end, liquidity, (liquidity as u256) << 96, up));
    result
}

#[mode(spec), ext(spec(prove, target = output_delta_x64,
    include = mul_div_for_principal, extra_bpl = b"principal_round.bpl"))]
public(package) fun swap_output_rounding_spec(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    let (lower, upper) = if (up) (start, end) else (end, start);
    prover::prover::requires(0 < lower && lower <= upper && liquidity >= 0);
    let scaled = (liquidity as u256) << 96;
    prover::prover::requires(if (up) {
        product_admitted(scaled, upper - lower, upper, false)
            && product_admitted(rounded_product(scaled, upper - lower, upper, false), 1 << 64, lower, false)
    } else product_admitted(liquidity as u256, upper - lower, 1 << 32, false));
    prover::prover::asserts(true);
    let result = output_delta_x64(start, end, liquidity, up);
    prover::prover::ensures(result == principal_output(start, end, liquidity, (liquidity as u256) << 96, up));
    result
}
"""

POSITION_PRICING_SPECS = """\
#[mode(spec), ext(spec(prove, target = position_amounts, ignore_abort,
    include(a = tick_math::tick_price_on_grid,
        b = sqrt_price_math::asset_delta_rounding_spec,
        c = sqrt_price_math::quote_delta_rounding_spec),
    extra_bpl = b"position_principal.bpl", boogie_opt = b"vcsSplitOnEveryAssert"))]
fun position_amounts_grid_spec(
    price_x96: u256, lower: u32, upper: u32, liquidity: u128, up: bool,
): (u256, u256) {
    let lower_price = tick_math::grid_price(lower);
    let upper_price = tick_math::grid_price(upper);
    prover::prover::requires(lower <= upper && upper <= 2 * constants::max_tick!());
    prover::prover::requires(0 < lower_price && lower_price <= upper_price);
    let spot = if (price_x96 < lower_price) lower_price
        else if (price_x96 > upper_price) upper_price else price_x96;
    let scaled = (liquidity as u256) << 96;
    prover::prover::requires(sqrt_price_math::product_admitted(scaled, upper_price - spot, upper_price, up));
    prover::prover::requires(sqrt_price_math::product_admitted(liquidity as u256, spot - lower_price, 1 << 96, up));
    let first = sqrt_price_math::rounded_product(scaled, upper_price - spot, upper_price, up);
    let expected_asset = sqrt_price_math::rounded_product(first, 1, spot, up);
    let expected_quote = sqrt_price_math::rounded_product(liquidity as u256, spot - lower_price, 1 << 96, up);
    let (asset, quote) = position_amounts(price_x96, lower, upper, liquidity, up);
    prover::prover::ensures(asset == expected_asset && quote == expected_quote);
    (asset, quote)
}
"""

SWAP_PRINCIPAL_BPL = """\
function {:inline} $0_sqrt_price_math_principal_input$pure(
    start: int, end: int, stake: int, scaled: int, up: bool): int {
    if up then $DexRoundedProduct(stake, end - start, 79228162514264337593543950336, true)
    else $DexRoundedProduct($DexRoundedProduct(scaled, start - end, start, true), 1, end, true)
}
function {:inline} $0_sqrt_price_math_principal_output$pure(
    start: int, end: int, stake: int, scaled: int, up: bool): int {
    if up then $DexRoundedProduct($DexRoundedProduct(scaled, end - start, end, false),
        18446744073709551616, start, false)
    else $DexRoundedProduct(stake, start - end, 4294967296, false)
}
procedure {:inline 1} $0_sqrt_price_math_principal_input(start: int, end: int, stake: int, scaled: int, up: bool)
    returns (amount: int) {
    amount := $0_sqrt_price_math_principal_input$pure(start, end, stake, scaled, up);
}
procedure {:inline 1} $0_sqrt_price_math_principal_output(start: int, end: int, stake: int, scaled: int, up: bool)
    returns (amount: int) {
    amount := $0_sqrt_price_math_principal_output$pure(start, end, stake, scaled, up);
}
"""

# The fee selection proof needs deterministic function symbols only.
# Their concrete meanings are verified in the rounding-wrapper run.
SWAP_PRINCIPAL_WIRING_BPL = """\
function $0_sqrt_price_math_principal_input$pure(start: int, end: int, stake: int, scaled: int, up: bool): int;
function $0_sqrt_price_math_principal_output$pure(start: int, end: int, stake: int, scaled: int, up: bool): int;
""" + SWAP_PRINCIPAL_BPL[SWAP_PRINCIPAL_BPL.index("procedure"):]

SWAP_PRINCIPAL_MATH = """\
#[mode(spec), ext(spec_only, no_abort, pure)]
public(package) native fun principal_input(start: u256, end: u256, stake: u128, scaled: u256, up: bool): u256;

#[mode(spec), ext(spec_only, no_abort, pure)]
public(package) native fun principal_output(start: u256, end: u256, stake: u128, scaled: u256, up: bool): u256;

"""

SWAP_PRINCIPAL_SUMMARIES = """\
// The inverse-direction result is supplied by the Z3 price model.
#[mode(spec), ext(spec(target = next_price, ignore_abort))]
public(package) fun inverse_direction_for_principal(start: u256, liquidity: u128, net: u64, up: bool): u256 {
    let result = next_price(start, liquidity, net, up);
    prover::prover::ensures(liquidity == 0 || start < (1u256 << 32) || start >= (1u256 << 160)
        || (if (up) result >= start else result <= start));
    result
}

#[mode(spec), ext(spec(target = input_delta, ignore_abort))]
public(package) fun step_input_on_grid(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    let result = input_delta(start, end, liquidity, up);
    prover::prover::ensures(!priced_step_domain(start, end, up)
        || result == principal_input(start, end, liquidity, (liquidity as u256) << 96, up));
    result
}

#[mode(spec), ext(spec(target = output_delta_x64, ignore_abort))]
public(package) fun step_output_on_grid(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    let result = output_delta_x64(start, end, liquidity, up);
    prover::prover::ensures(!priced_step_domain(start, end, up)
        || result == principal_output(start, end, liquidity, (liquidity as u256) << 96, up));
    result
}

#[mode(spec), ext(spec_only, no_abort)]
fun priced_step_domain(start: u256, end: u256, up: bool): bool {
    start >= (1u256 << 32) && start < (1u256 << 160)
        && end >= (1u256 << 32) && end < (1u256 << 160)
        && (if (up) start <= end else end <= start)
}

"""

SWAP_PRINCIPAL_FEE = """\
#[mode(spec), ext(spec(target = quote, ignore_abort))]
fun quote_for_principal(self: &ContinuousPath, start: u256, end: u256, net: u64): FeeQuote {
    quote(self, start, end, net)
}

#[mode(spec), ext(spec(target = fee_up, ignore_abort))]
fun fee_up_for_principal(self: &FeeQuote): u64 {
    fee_up(self)
}

#[mode(spec), ext(spec(target = preceding_budget, ignore_abort))]
fun preceding_for_principal(step: &SwapStep, budget: u64): u64 {
    preceding_budget(step, budget)
}

#[mode(spec), ext(spec(prove, target = trial, ignore_abort,
    include(a = sqrt_price_math::inverse_direction_for_principal,
        b = sqrt_price_math::step_input_on_grid, c = quote_for_principal, d = fee_up_for_principal),
    extra_bpl = b"swap_principal.bpl"))]
fun trial_principal_spec(
    self: &ContinuousPath, start: u256, limit: u256, liquidity: u128, net_budget: u64, up: bool,
): SwapStep {
    prover::prover::requires(start >= (1u256 << 32) && start < (1u256 << 160));
    prover::prover::requires(limit >= (1u256 << 32) && limit < (1u256 << 160));
    prover::prover::requires(if (up) start <= limit else limit <= start);
    prover::prover::requires(liquidity > 0);
    let result = trial(self, start, limit, liquidity, net_budget, up);
    prover::prover::ensures(if (up) start <= result.price_x96 && result.price_x96 <= limit
        else limit <= result.price_x96 && result.price_x96 <= start);
    prover::prover::ensures((result.net as u256) ==
        sqrt_price_math::principal_input(start, result.price_x96, liquidity, (liquidity as u256) << 96, up));
    result
}

#[mode(spec), ext(spec_only(loop_inv(target = swap_step)), no_abort)]
#[allow(unused_function)]
fun selected_principal_step(best: SwapStep, start: u256, limit: u256, liquidity: u128, up: bool): bool {
    (if (up) start <= best.price_x96 && best.price_x96 <= limit
        else limit <= best.price_x96 && best.price_x96 <= start)
        && (best.net as u256) == sqrt_price_math::principal_input(start, best.price_x96, liquidity, (liquidity as u256) << 96, up)
}

#[mode(spec), ext(spec(prove, target = swap_step, ignore_abort,
    include(a = trial_principal_spec, b = sqrt_price_math::step_output_on_grid, c = preceding_for_principal),
    extra_bpl = b"swap_principal.bpl"))]
fun swap_step_principal_spec(
    self: &ContinuousPath, start: u256, limit: u256, liquidity: u128, budget: u64, up: bool,
): (u256, u64, u256, u64) {
    prover::prover::requires(start >= (1u256 << 32) && start < (1u256 << 160));
    prover::prover::requires(limit >= (1u256 << 32) && limit < (1u256 << 160));
    prover::prover::requires(if (up) start <= limit else limit <= start);
    prover::prover::requires(liquidity > 0);
    let (end, spent, output, fee) = swap_step(self, start, limit, liquidity, budget, up);
    prover::prover::ensures(if (up) start <= end && end <= limit else limit <= end && end <= start);
    prover::prover::ensures(fee <= spent);
    prover::prover::ensures(fee > spent ||
        ((spent - fee) as u256) == sqrt_price_math::principal_input(start, end, liquidity, (liquidity as u256) << 96, up));
    prover::prover::ensures(output == sqrt_price_math::principal_output(start, end, liquidity, (liquidity as u256) << 96, up));
    (end, spent, output, fee)
}
"""

INVERSE_SPECS = """\
// Sui Prover uses this summary. The compiled branch checks and Z3 establish
// its rounding and arithmetic bounds independently.
#[mode(spec), ext(spec(target = mul_div))]
fun inverse_product_for_price(a: u256, b: u256, d: u256, up: bool): u256 {
    let admitted = product_admitted(a, b, d, up);
    prover::prover::requires(admitted);
    prover::prover::asserts(true);
    let result = mul_div(a, b, d, up);
    prover::prover::ensures(result == rounded_product(a, b, d, up));
    result
}

#[mode(spec), ext(spec(prove, target = next_price,
    include = inverse_product_for_price, extra_bpl = b"principal_round.bpl"))]
fun next_price_exact_spec(start: u256, liquidity: u128, net: u64, up: bool): u256 {
    // The swap clips the preceding step to an in-grid target before reusing its price.
    let price_in_range = start >= (1u256 << 32) && start < (1u256 << 160);
    let stake = liquidity as u256;
    let amount = net as u256;
    let scaled_stake = stake << 96;
    let scaled_net = amount << 96;
    prover::prover::requires(price_in_range && stake > 0);
    prover::prover::requires(scaled_net < (1u256 << 160));
    // These integer bounds are independently derived from the compiled shifts
    // and the admitted types by the Z3 caller and inverse obligations.
    let net_product_fits = amount == 0 || start <= std::u256::max_value!() / amount;
    let product = if (net_product_fits) amount * start else 0;
    let sum_fits = product <= std::u256::max_value!() - scaled_stake;
    let denominator = if (sum_fits) scaled_stake + product else 0;
    prover::prover::requires(up || (net_product_fits && sum_fits
        && product_admitted(scaled_stake, start, denominator, true)));
    let expected = if (up && stake > 0 && scaled_net < (1u256 << 160) && price_in_range) {
        start + scaled_net / stake
    } else if (!up) {
        rounded_product(scaled_stake, start, denominator, true)
    } else 0;
    prover::prover::asserts(true);
    let result = next_price(start, liquidity, net, up);
    prover::prover::ensures(result == expected);
    result
}
"""
