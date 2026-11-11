"""Return contracts for continuous fee arithmetic."""

FEE_RETURN_SPECS = """\
#[mode(spec), ext(spec_only(loop_inv(target = series)), no_abort)]
#[allow(unused_function)]
fun series_invariant(argument: Interval, offset: u64, midpoint: u256, index: u64, power: u256, sum: u256): bool {
    let unit = ONE;
    let divisor = offset as u256;
    (offset == 1 || offset == 3)
        && argument.lower >= 0 && argument.lower <= argument.upper && argument.upper <= unit / 2
        && midpoint >= 0 && midpoint <= unit / 2
        && index >= 0 && index < SERIES_TERMS && power >= 0 && power <= unit
        && sum >= 0 && sum <= ((index as u256) + 1) * unit
        && sum * divisor + divisor - 1 >= power
}

#[mode(spec), ext(spec(prove, target = series, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun series_return_spec(argument: Interval, negative: bool, offset: u64): Interval {
    let unit = ONE;
    prover::prover::requires(argument.lower >= 0 && argument.lower <= argument.upper && argument.upper <= unit / 2);
    prover::prover::requires(offset == 1 || offset == 3);
    prover::prover::asserts(true);
    let result = series(argument, negative, offset);
    prover::prover::ensures(result.lower <= result.upper && result.upper <= 128 * ONE);
    result
}

#[mode(spec), ext(spec(prove, target = constant_fee, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun constant_fee_return_spec(net_input: u64, fee_ppm: u32): FeeQuote {
    prover::prover::requires(fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::asserts(true);
    constant_fee(net_input, fee_ppm)
}
"""

QUOTE_ENTRY_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
fun quote_price_domain(price: u256): bool {
    price >= constants::min_sqrt_price_x96!() && price < constants::max_sqrt_price_x96!()
}

#[mode(spec), ext(spec(prove, target = coordinate))]
fun coordinate_return_spec(self: &ContinuousPath, price_x96: u256, up: bool): u256 {
    prover::prover::requires(quote_price_domain(price_x96));
    prover::prover::requires(quote_price_domain(self.reference_x96));
    prover::prover::asserts(true);
    coordinate(self, price_x96, up)
}

#[mode(spec), ext(spec(prove, target = quote, include = constant_fee_return_spec))]
fun quote_constant_or_zero_return_spec(self: &ContinuousPath, start_x96: u256, end_x96: u256, net_input: u64): FeeQuote {
    prover::prover::requires(quote_price_domain(start_x96) && quote_price_domain(end_x96));
    prover::prover::requires(quote_price_domain(self.reference_x96));
    prover::prover::requires(self.max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::requires(net_input == 0 || (self.sensitivity.upper == 0 && start_x96 != end_x96));
    prover::prover::asserts(true);
    quote(self, start_x96, end_x96, net_input)
}
"""

ORDERED_INTERVAL = """\
#[mode(spec), ext(spec_only, no_abort)]
fun ordered_interval(value: Interval): bool {
    value.lower >= 0 && value.lower <= value.upper
}
"""

INTERVAL_RETURN_SPECS = ORDERED_INTERVAL + """\
#[mode(spec), ext(spec(prove, target = multiply, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun multiply_return_spec(first: Interval, second: Interval): Interval {
    let maximum = 340282366920938463463374607431768211455u256;
    prover::prover::requires(ordered_interval(first) && ordered_interval(second));
    prover::prover::requires(first.upper <= maximum && second.upper <= maximum);
    prover::prover::asserts(true);
    multiply(first, second)
}

#[mode(spec), ext(spec(prove, target = divide, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun divide_return_spec(first: Interval, second: Interval): Interval {
    prover::prover::requires(ordered_interval(first) && ordered_interval(second));
    prover::prover::requires(first.upper < (1u256 << 160) && second.lower > 0);
    prover::prover::asserts(true);
    divide(first, second)
}

#[mode(spec), ext(spec(prove, target = subtract))]
fun subtract_return_spec(first: Interval, second: Interval): Interval {
    prover::prover::requires(ordered_interval(first) && ordered_interval(second));
    prover::prover::requires(first.lower >= second.upper);
    prover::prover::asserts(true);
    subtract(first, second)
}
"""

DYNAMIC_LEAF_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
fun bounded_rate(value: Interval): bool {
    ordered_interval(value) && value.upper <= ONE / 8
}

#[mode(spec), ext(spec(prove, target = fee_on_net, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun fee_on_net_return_spec(rate: Interval): Interval {
    prover::prover::requires(bounded_rate(rate));
    prover::prover::asserts(true);
    let result = fee_on_net(rate);
    prover::prover::ensures(ordered_interval(result) && result.upper <= ONE / 4);
    result
}

#[mode(spec), ext(spec(prove, target = multiply, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun multiply_for_rate_spec(first: Interval, second: Interval): Interval {
    let maximum = 340282366920938463463374607431768211455u256;
    prover::prover::requires(ordered_interval(first) && ordered_interval(second));
    prover::prover::requires(first.upper <= maximum && second.upper <= maximum);
    prover::prover::asserts(true);
    let result = multiply(first, second);
    prover::prover::ensures(ordered_interval(result));
    prover::prover::ensures(first.upper > 2 * ONE || second.upper > 2 * ONE || result.upper <= 4 * ONE);
    prover::prover::ensures(first.upper > 4 * ONE || second.upper > 4 * ONE || result.upper <= 16 * ONE);
    prover::prover::ensures(first.upper > 101 * ONE || second.upper > 16 * ONE || result.upper <= 1616 * ONE);
    result
}

#[mode(spec), ext(spec(prove, target = rate_at_coordinate, include(
    a = reciprocal_return_spec, b = multiply_for_rate_spec,
),
    boogie_opt = b"vcsSplitOnEveryAssert"))]
fun rate_at_coordinate_return_spec(self: &ContinuousPath, coordinate: u256, up: bool): Interval {
    prover::prover::requires(bounded_rate(self.base) && bounded_rate(self.maximum));
    prover::prover::requires(ordered_interval(self.sensitivity) && self.sensitivity.upper <= 101 * ONE);
    prover::prover::requires(ordered_interval(self.lower_cap) && self.lower_cap.lower >= ONE / 512);
    prover::prover::requires(ordered_interval(self.upper_cap) && self.upper_cap.lower >= ONE / 512
        && self.upper_cap.upper <= 2 * ONE);
    prover::prover::asserts(true);
    let result = rate_at_coordinate(self, coordinate, up);
    prover::prover::ensures(bounded_rate(result));
    result
}

#[mode(spec), ext(spec(prove, target = pointwise_average, include(
    a = rate_at_coordinate_return_spec, b = fee_on_net_return_spec,
), boogie_opt = b"vcsSplitOnEveryAssert"))]
fun pointwise_average_return_spec(self: &ContinuousPath, low: u256, high: u256, up: bool): Interval {
    prover::prover::requires(bounded_rate(self.base) && bounded_rate(self.maximum));
    prover::prover::requires(ordered_interval(self.sensitivity) && self.sensitivity.upper <= 101 * ONE);
    prover::prover::requires(ordered_interval(self.lower_cap) && self.lower_cap.lower >= ONE / 512);
    prover::prover::requires(ordered_interval(self.upper_cap) && self.upper_cap.lower >= ONE / 512
        && self.upper_cap.upper <= 2 * ONE);
    prover::prover::asserts(true);
    let result = pointwise_average(self, low, high, up);
    prover::prover::ensures(ordered_interval(result) && result.upper <= ONE / 4);
    result
}
"""

RECIPROCAL_RETURN_SPEC = """\
#[mode(spec), ext(spec(prove, target = reciprocal, boogie_opt = b"vcsSplitOnEveryAssert"))]
fun reciprocal_return_spec(value: Interval): Interval {
    prover::prover::requires(ordered_interval(value) && value.lower > 0);
    prover::prover::asserts(true);
    let result = reciprocal(value);
    prover::prover::ensures(ordered_interval(result) && result.upper <= ONE * ONE);
    prover::prover::ensures(value.upper > 2 * ONE || result.lower >= ONE / 2);
    prover::prover::ensures(value.lower < ONE / 2 || result.upper <= 2 * ONE);
    prover::prover::ensures(value.lower < ONE / 512 || result.upper <= 512 * ONE);
    result
}
"""


CAPPED_COORDINATE_SPECS = """\
#[mode(spec), ext(spec(target = pointwise_average))]
fun pointwise_unreachable_on_cap(self: &ContinuousPath, low: u256, high: u256, up: bool): Interval {
    prover::prover::requires(false);
    pointwise_average(self, low, high, up)
}

#[mode(spec), ext(spec(target = average_over_path))]
fun path_unreachable_on_cap(
    self: &ContinuousPath, start: u256, end: u256, lower_cap: Interval, upper_cap: Interval, up: bool,
): Interval {
    prover::prover::requires(false);
    average_over_path(self, start, end, lower_cap, upper_cap, up)
}

#[mode(spec), ext(spec(prove, target = quote_coordinates, include(
    a = reciprocal_return_spec, b = constant_fee_return_spec,
    c = pointwise_unreachable_on_cap, d = path_unreachable_on_cap,
), boogie_opt = b"vcsSplitOnEveryAssert"))]
fun quote_capped_coordinates_return_spec(
    self: &ContinuousPath, start: u256, end: u256, up: bool, net_input: u64,
): FeeQuote {
    prover::prover::requires(start <= end && end <= std::u256::max_value!() - 2);
    prover::prover::requires(self.max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::requires(ordered_interval(self.lower_cap) && self.lower_cap.lower >= ONE / 512);
    prover::prover::requires(ordered_interval(self.upper_cap) && self.upper_cap.lower >= ONE / 512
        && self.upper_cap.upper <= 2 * ONE);
    prover::prover::requires(if (up) {
        end + 2 <= self.lower_cap.lower || start >= self.upper_cap.upper
    } else {
        end + 2 <= ONE / 2 || start >= 512 * ONE
    });
    prover::prover::asserts(true);
    quote_coordinates(self, start, end, up, net_input)
}
"""

QUOTE_CLAMP_SPEC = """\
#[mode(spec), ext(spec(prove, target = clamp_quote, include = constant_fee_return_spec,
    boogie_opt = b"vcsSplitOnEveryAssert"))]
fun clamp_quote_return_spec(
    average: Interval, base: Interval, maximum: Interval, net_input: u64, max_fee_ppm: u32,
): FeeQuote {
    prover::prover::requires(ordered_interval(average) && average.upper <= ONE);
    prover::prover::requires(ordered_interval(base) && ordered_interval(maximum) && maximum.upper <= ONE);
    prover::prover::requires(base.lower <= maximum.upper);
    prover::prover::requires(base.lower <= average.upper + COORDINATE_ROUNDING_ALLOWANCE);
    prover::prover::requires(average.lower.saturating_sub(COORDINATE_ROUNDING_ALLOWANCE) <= maximum.upper);
    prover::prover::requires(max_fee_ppm <= constants::max_lp_fee_ppm!());
    prover::prover::asserts(true);
    clamp_quote(average, base, maximum, net_input, max_fee_ppm)
}
"""


def isolate_quote_clamp(source):
    """Extract the final quote arithmetic after the base and maximum are known."""
    start = "    average.lower = average.lower.saturating_sub(COORDINATE_ROUNDING_ALLOWANCE);\n"
    end = "\n}\n\n// Registry error macros"
    if source.count(start) != 1 or source.count(end) != 1:
        raise SystemExit("Could not locate the final continuous quote clamp.")
    before, tail = source.split(start)
    tail, after = tail.split(end)
    base_and_maximum = (
        "    let base = fee_on_net(self.base);\n"
        "    let maximum = fee_on_net(self.maximum);\n"
    )
    if tail.count(base_and_maximum) != 1 or tail.count("self.max_fee_ppm") != 1:
        raise SystemExit("Continuous quote clamp inputs changed.")
    declaration = "    let mut average = if (end == start) {\n"
    if before.count(declaration) != 1:
        raise SystemExit("Could not locate the continuous quote average.")
    before = before.replace(declaration, "    let average = if (end == start) {\n")
    return (
        before + base_and_maximum
        + "    clamp_quote(average, base, maximum, net_input, self.max_fee_ppm)\n}\n\n"
        + "fun clamp_quote(mut average: Interval, base: Interval, maximum: Interval, net_input: u64, max_fee_ppm: u32): FeeQuote {\n"
        + start + tail.replace(base_and_maximum, "").replace("self.max_fee_ppm", "max_fee_ppm")
        + end + after
    )
