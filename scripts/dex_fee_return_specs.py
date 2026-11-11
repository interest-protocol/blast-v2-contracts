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
    series(argument, negative, offset)
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

INTERVAL_RETURN_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
fun ordered_interval(value: Interval): bool {
    value.lower >= 0 && value.lower <= value.upper
}

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
