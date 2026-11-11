// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Continuous LP fee pricing for one frozen reference.
/// Directed Q96 enclosures include series truncation and fixed-point rounding.
module blast_fun_dex::continuous_fee;

// === Constants ===

const ONE: u256 = 1 << 96;
const PPM: u256 = 1_000_000;
const SERIES_TERMS: u64 = 65;
// |d(f/(1-f))/dx| < 45 for x=s/r or x=r/s throughout the admitted domain.
// Budget interpolation can add one further coordinate ulp.
const COORDINATE_ROUNDING_ALLOWANCE: u256 = 90;

// === Public Types ===

public struct Interval has copy, drop {
    lower: u256,
    upper: u256,
}

public struct ContinuousPath has drop {
    reference_x96: u256,
    max_fee_ppm: u32,
    base: Interval,
    maximum: Interval,
    sensitivity: Interval,
    pole_distance: Interval,
    prefactor: Interval,
    lower_cap: Interval,
    upper_cap: Interval,
}

/// An exact-input step uses this integer net amount and fee at the returned price.
public struct SwapStep has copy, drop {
    price_x96: u256,
    net: u64,
    fee: u64,
}

/// Real-valued LP fee in Q96 input atoms, before the single terminal ceiling.
public struct FeeQuote has copy, drop {
    lower_x96: u256,
    upper_x96: u256,
}

// === Package Functions ===

public(package) fun new(settings: LpFee, reference_x96: u256): ContinuousPath {
    assert_price(reference_x96);
    let base = fraction(settings.base_fee_ppm() as u256, PPM);
    let maximum = fraction(settings.max_fee_ppm() as u256, PPM);
    if (settings.base_fee_ppm() == settings.max_fee_ppm()) {
        return ContinuousPath {
            reference_x96, max_fee_ppm: settings.max_fee_ppm(), base, maximum, sensitivity: point(0),
            pole_distance: point(0), prefactor: point(0),
            lower_cap: point(ONE), upper_cap: point(ONE),
        }
    };

    let sensitivity = fraction(settings.sensitivity_ppm().destroy_some() as u256, PPM);
    let complement = fraction(PPM - (settings.base_fee_ppm() as u256), PPM);
    let headroom = fraction((settings.max_fee_ppm() - settings.base_fee_ppm()) as u256, PPM);
    let cap_gap = square_root(divide(headroom, sensitivity));
    let pole_distance = square_root(divide(complement, sensitivity));
    let prefactor = divide(point(ONE), times_integer(square_root(multiply(sensitivity, complement)), 2));
    let lower_cap = square_root(subtract(point(ONE), cap_gap));
    let upper_cap = square_root(add(point(ONE), cap_gap));
    ContinuousPath { reference_x96, max_fee_ppm: settings.max_fee_ppm(), base, maximum, sensitivity, pole_distance, prefactor, lower_cap, upper_cap }
}

/// Quotes fees on the supplied net input over one constant-liquidity path.
/// The caller owns the CLMM net delta and initialized-tick changes.
public(package) fun quote(
    self: &ContinuousPath,
    start_x96: u256,
    end_x96: u256,
    net_input: u64,
): FeeQuote {
    assert_price(start_x96);
    assert_price(end_x96);
    if (net_input == 0) return FeeQuote { lower_x96: 0, upper_x96: 0 };
    assert!(start_x96 != end_x96);
    if (self.sensitivity.upper == 0) return constant_fee(net_input, self.max_fee_ppm);

    // Each coordinate is affine in net input. Endpoint normalization loses at
    // most one Q96 unit, independently of absolute prices or liquidity.
    let up = end_x96 > start_x96;
    let start = coordinate(self, start_x96, up);
    let end = coordinate(self, end_x96, up);
    quote_coordinates(self, start, end, up, net_input)
}

public(package) fun fee_up(self: &FeeQuote): u64 { self.upper_x96.div_ceil(ONE) as u64 }

/// Executes the exact-input search in net atoms. Each probe uses the farthest
/// representable price affordable at its net budget and reprices that endpoint.
/// This also handles paths whose full net delta exceeds u64.
public(package) fun swap_step(
    self: &ContinuousPath,
    start: u256,
    limit: u256,
    liquidity: u128,
    budget: u64,
    up: bool,
): (u256, u64, u256, u64) {
    let max_rate_budget = budget.mul_div((PPM as u64) - (self.max_fee_ppm as u64), PPM as u64);
    let mut best = self.trial(start, limit, liquidity, max_rate_budget, up);
    if (self.sensitivity.upper > 0 && best.price_x96 != limit) {
        let furthest = self.trial(start, limit, liquidity, budget, up);
        if (affordable(&furthest, budget)) {
            best = furthest;
        } else {
            let mut upper = preceding_budget(&furthest, budget);
            while (upper > max_rate_budget) {
                let candidate = self.trial(start, limit, liquidity, upper, up);
                if (affordable(&candidate, budget)) {
                    best = candidate;
                    break
                };
                upper = preceding_budget(&candidate, budget);
            };
        };
    };
    assert!(affordable(&best, budget));
    let output = sqrt_price_math::output_delta_x64(start, best.price_x96, liquidity, up);
    (best.price_x96, best.net + best.fee, output, best.fee)
}

// === Private Functions ===

fun trial(
    self: &ContinuousPath,
    start: u256,
    limit: u256,
    liquidity: u128,
    net_budget: u64,
    up: bool,
): SwapStep {
    let next = sqrt_price_math::next_price(start, liquidity, net_budget, up);
    let price_x96 = if (up) next.min(limit) else next.max(limit);
    let net = sqrt_price_math::input_delta(start, price_x96, liquidity, up);
    assert!(net <= (net_budget as u256));
    let net = net as u64;
    let quote = self.quote(start, price_x96, net);
    // The enclosure width is below 1/16 atom over the admitted domain.
    // Keep the wider guard below one atom for monotone integer search.
    assert!(quote.upper_x96 - quote.lower_x96 < ONE / 4);
    SwapStep { price_x96, net, fee: quote.fee_up() }
}

fun affordable(step: &SwapStep, budget: u64): bool {
    step.net <= budget && step.fee <= budget - step.net
}

/// For distinct endpoints the gross charge grows by less than 10/9 times
/// the canonical net difference plus two atoms. An unaffordable quote
/// therefore excludes its whole price plateau and these nearby budgets.
fun preceding_budget(step: &SwapStep, budget: u64): u64 {
    let excess = step.fee - (budget - step.net);
    let skip = excess.saturating_sub(2).mul_div(9, 10);
    step.net - 1 - skip
}

fun quote_coordinates(self: &ContinuousPath, start: u256, end: u256, up: bool, net_input: u64): FeeQuote {
    if (net_input == 0) return FeeQuote { lower_x96: 0, upper_x96: 0 };
    if (self.sensitivity.upper == 0) return constant_fee(net_input, self.max_fee_ppm);
    let (lower_cap, upper_cap) = if (up) {
        (self.lower_cap, self.upper_cap)
    } else {
        (reciprocal(self.upper_cap), reciprocal(self.lower_cap))
    };
    // Normalization and prefix interpolation can each floor by one ulp.
    if (end + 2 <= lower_cap.lower || start >= upper_cap.upper) {
        return constant_fee(net_input, self.max_fee_ppm)
    };
    let mut average = if (end == start) {
        pointwise_average(self, start, end, up)
    } else {
        average_over_path(self, start, end, lower_cap, upper_cap, up)
    };
    average.lower = average.lower.saturating_sub(COORDINATE_ROUNDING_ALLOWANCE);
    average.upper = average.upper + COORDINATE_ROUNDING_ALLOWANCE;
    // The mathematical fee remains between base and cap, including all pads.
    let base = fee_on_net(self.base);
    let maximum = fee_on_net(self.maximum);
    average.lower = average.lower.max(base.lower);
    average.upper = average.upper.min(maximum.upper);
    assert!(average.lower <= average.upper);
    let mut fee = fee_amount(average, net_input);
    fee.upper_x96 = fee.upper_x96.min(constant_fee(net_input, self.max_fee_ppm).upper_x96);
    fee
}

// Registry error macros expand to numeric literals under the pinned abort lint.
#[allow(lint(abort_without_constant))]
fun assert_price(price_x96: u256) {
    assert!(
        price_x96 >= constants::min_sqrt_price_x96!() && price_x96 < constants::max_sqrt_price_x96!(),
        blast_fun_dex::errors::invalid_sqrt_price!(),
    );
}

fun coordinate(self: &ContinuousPath, price_x96: u256, up: bool): u256 {
    // Both numerator values are below 2^160; shifting by 96 retains all bits.
    if (up) (price_x96 << 96) / self.reference_x96 else (self.reference_x96 << 96) / price_x96
}

fun average_over_path(
    self: &ContinuousPath,
    start: u256,
    end: u256,
    lower_cap: Interval,
    upper_cap: Interval,
    up: bool,
): Interval {
    let mut cuts = vector[start];
    let candidates = vector[lower_cap.lower, lower_cap.upper, ONE, upper_cap.lower, upper_cap.upper];
    candidates.do_ref!(|cut| {
        if (*cut > start && *cut < end && *cut > cuts[cuts.length() - 1]) cuts.push_back(*cut);
    });
    cuts.push_back(end);
    let mut average = point(0);
    let mut index = 0;
    while (index + 1 < cuts.length()) {
        let low = cuts[index];
        let high = cuts[index + 1];
        let weight = bounded_fraction(high - low, end - start);
        let segment = segment_average(self, low, high, lower_cap, upper_cap, up);
        average = add(average, multiply(weight, segment));
        index = index + 1;
    };
    average
}

fun segment_average(
    self: &ContinuousPath,
    low: u256,
    high: u256,
    lower_cap: Interval,
    upper_cap: Interval,
    up: bool,
): Interval {
    if (high <= lower_cap.lower || low >= upper_cap.upper) return fee_on_net(self.maximum);
    if (low < lower_cap.upper || high > upper_cap.lower || high - low <= 1_024) {
        return pointwise_average(self, low, high, up)
    };
    let (low_price, high_price) = if (up) {
        (point(low), point(high))
    } else {
        (reciprocal(point(high)), reciprocal(point(low)))
    };
    let gross = analytic_average(self, low_price, high_price, up);
    // Gross/net is >=1. Rounding enclosures may extend just below that.
    Interval { lower: gross.lower.saturating_sub(ONE), upper: gross.upper.saturating_sub(ONE) }
}

fun pointwise_average(self: &ContinuousPath, low: u256, high: u256, up: bool): Interval {
    let first = rate_at_coordinate(self, low, up);
    let second = rate_at_coordinate(self, high, up);
    fee_on_net(Interval { lower: first.lower.min(second.lower), upper: first.upper.max(second.upper) })
}

fun rate_at_coordinate(self: &ContinuousPath, coordinate: u256, up: bool): Interval {
    let lower = if (up) self.lower_cap else reciprocal(self.upper_cap);
    let upper = if (up) self.upper_cap else reciprocal(self.lower_cap);
    if (coordinate <= lower.lower || coordinate >= upper.upper) return self.maximum;
    let price = if (up) point(coordinate) else reciprocal(point(coordinate));
    let gap = absolute_difference(multiply(price, price), point(ONE));
    let rate = add(self.base, multiply(self.sensitivity, multiply(gap, gap)));
    Interval { lower: rate.lower.min(self.maximum.lower), upper: rate.upper.min(self.maximum.upper) }
}

/// With D(t)=k(A-t²)(t²-z), w=sqrt((1-b)/k), A=1+w, z=1-w,
/// p=t0*t1 and delta=t1-t0, evaluate positive stable primitives.
/// Splitting at the reference guarantees |x1|,|x2|<1/2.
fun analytic_average(self: &ContinuousPath, low: Interval, high: Interval, up: bool): Interval {
    let product = multiply(low, high);
    let delta = subtract_nonnegative(high, low);
    let delta_squared = multiply(delta, delta);
    // In the uncapped interval, p is in [1-g, 1+g] for the cap gap g.
    // g/w = sqrt((cap-base)/(1-base)) < 1/3, so both denominators
    // exceed 2w/3 before rounding. The interval pads are below 2^-80.
    let upper_pole = add(point(ONE), self.pole_distance);
    let first_denominator = subtract(upper_pole, product);
    let second_denominator = subtract(add(product, self.pole_distance), point(ONE));
    let first_squared = multiply(first_denominator, first_denominator);
    let second_squared = multiply(second_denominator, second_denominator);
    let first_argument = divide(multiply(upper_pole, delta_squared), first_squared);
    let signed_magnitude = absolute_difference(self.pole_distance, point(ONE));
    let second_argument = divide(multiply(signed_magnitude, delta_squared), second_squared);
    let negative = self.pole_distance.lower >= ONE;
    let crosses_zero = self.pole_distance.lower < ONE && self.pole_distance.upper > ONE;
    let offset = if (up) 1 else 3;
    let first_series = series(first_argument, false, offset);
    let second_series = if (crosses_zero) {
        let center = fraction(1, offset as u256);
        let uncertainty = 2 * second_argument.upper;
        Interval { lower: center.lower.saturating_sub(uncertainty), upper: center.upper + uncertainty }
    } else {
        series(second_argument, negative, offset)
    };
    if (up) {
        return multiply(self.prefactor, add(divide(first_series, first_denominator), divide(second_series, second_denominator)))
    };

    let constant = add(reciprocal(first_denominator), reciprocal(second_denominator));
    let first_cubed = multiply(first_squared, first_denominator);
    let second_cubed = multiply(second_squared, second_denominator);
    let correction = multiply(multiply(product, delta_squared), add(divide(first_series, first_cubed), divide(second_series, second_cubed)));
    multiply(self.prefactor, add(constant, correction))
}

/// Enclose H(x)=sum x^n/(2n+1), or J3(x)=sum x^n/(2n+3).
/// Power-floor error is <2 ulps; each term adds <3 ulps error. The tail
/// uses a geometric bound; 2*argument width covers derivative <=4/3.
fun series(argument: Interval, negative: bool, offset: u64): Interval {
    assert!(argument.upper <= ONE / 2);
    let midpoint = argument.lower + (argument.upper - argument.lower) / 2;
    let mut power = ONE;
    let mut sum = ONE / (offset as u256);
    let mut index = 0u64;
    while (index + 1 < SERIES_TERMS && power > 0) {
        index = index + 1;
        power = power * midpoint / ONE;
        let term = power / ((2 * index + offset) as u256);
        if (negative && index % 2 == 1) sum = sum - term else sum = sum + term;
    };
    let next_power_up = ((power + 2) * midpoint).div_ceil(ONE);
    let tail = (next_power_up * ONE).div_ceil(ONE - midpoint).div_ceil((2 * index + 2 + offset) as u256);
    let error = 3 * ((index + 1) as u256) + tail + 2 * (argument.upper - argument.lower);
    Interval { lower: sum.saturating_sub(error), upper: sum + error }
}

fun fee_on_net(rate: Interval): Interval { divide(rate, subtract(point(ONE), rate)) }
fun fee_amount(average: Interval, net_input: u64): FeeQuote {
    FeeQuote { lower_x96: average.lower * (net_input as u256), upper_x96: average.upper * (net_input as u256) }
}

fun constant_fee(net_input: u64, fee_ppm: u32): FeeQuote {
    let numerator = (net_input as u256) * (fee_ppm as u256) * ONE;
    let denominator = PPM - (fee_ppm as u256);
    FeeQuote { lower_x96: numerator / denominator, upper_x96: numerator.div_ceil(denominator) }
}

// Directed interval arithmetic. All values except amount-scaled FeeQuote are Q96.

fun point(value: u256): Interval { Interval { lower: value, upper: value } }
fun fraction(numerator: u256, denominator: u256): Interval {
    Interval { lower: (numerator * ONE) / denominator, upper: (numerator * ONE).div_ceil(denominator) }
}
fun add(first: Interval, second: Interval): Interval {
    Interval { lower: first.lower + second.lower, upper: first.upper + second.upper }
}
fun subtract(first: Interval, second: Interval): Interval {
    Interval { lower: first.lower - second.upper, upper: first.upper - second.lower }
}
fun subtract_nonnegative(first: Interval, second: Interval): Interval {
    Interval { lower: first.lower.saturating_sub(second.upper), upper: first.upper.saturating_sub(second.lower) }
}
fun absolute_difference(first: Interval, second: Interval): Interval {
    let lower = if (first.lower >= second.upper) first.lower - second.upper else second.lower.saturating_sub(first.upper);
    Interval { lower, upper: first.lower.diff(second.upper).max(first.upper.diff(second.lower)) }
}
fun times_integer(value: Interval, multiplier: u256): Interval {
    Interval { lower: value.lower * multiplier, upper: value.upper * multiplier }
}
fun multiply(first: Interval, second: Interval): Interval {
    Interval { lower: first.lower * second.lower / ONE, upper: (first.upper * second.upper).div_ceil(ONE) }
}
fun divide(first: Interval, second: Interval): Interval {
    Interval { lower: first.lower * ONE / second.upper, upper: (first.upper * ONE).div_ceil(second.lower) }
}
fun reciprocal(value: Interval): Interval { divide(point(ONE), value) }
fun square_root(value: Interval): Interval {
    let lower = integer_sqrt(value.lower * ONE);
    let upper_radicand = value.upper * ONE;
    let upper_floor = integer_sqrt(upper_radicand);
    let upper = upper_floor + if (upper_floor * upper_floor < upper_radicand) 1 else 0;
    Interval { lower, upper }
}

/// The pinned std::u256 has no sqrt. A power-of-two upper seed and at most
/// twelve integer Newton steps cover u256; normalized radicands use <200 bits.
fun integer_sqrt(radicand: u256): u256 {
    if (radicand == 0) return 0;
    let mut reduced = radicand;
    let mut bits = 0u8;
    vector[128u8, 64, 32, 16, 8, 4, 2, 1].do!(|shift| {
        if (reduced >> shift > 0) {
            reduced = reduced >> shift;
            bits = bits + shift;
        };
    });
    let mut root = 1u256 << (bits / 2 + 1);
    let mut iteration = 0u64;
    while (iteration < 12) {
        let next = (root + radicand / root) / 2;
        if (next >= root) return root;
        root = next;
        iteration = iteration + 1;
    };
    assert!(root * root <= radicand && radicand / (root + 1) < root + 1);
    root
}

/// Coordinates can occupy 224 bits, so compute the fractional quotient in
/// three 32-bit limbs rather than overflowing numerator<<96.
fun bounded_fraction(numerator: u256, denominator: u256): Interval {
    if (numerator == denominator) return point(ONE);
    assert!(numerator < denominator);
    let mut remainder = numerator;
    let mut quotient = 0;
    3u64.do!(|_| {
        let shifted = remainder << 32;
        quotient = (quotient << 32) + shifted / denominator;
        remainder = shifted % denominator;
    });
    Interval { lower: quotient, upper: quotient + if (remainder > 0) 1 else 0 }
}

// === Test-Only Types ===

/// Experimental exact-input fill in affine net-coordinate space. The caller
/// supplies the integer capacity of one prescribed constant-liquidity path.
#[test_only]
public struct BudgetFill has copy, drop {
    net_input: u64,
    fee: u64,
    unspent: u64,
    iterations: u64,
}

// === Test-Only Functions ===

#[test_only]
public(package) fun width_x96(self: &FeeQuote): u256 { self.upper_x96 - self.lower_x96 }

#[test_only]
public(package) fun upper_x96(self: &FeeQuote): u256 { self.upper_x96 }

#[test_only]
public(package) fun lower_x96(self: &FeeQuote): u256 { self.lower_x96 }

/// The real root n=B-F(n) contracts by <=1/9. Alternate directed endpoint
/// maps, then inspect the remaining integer candidates using the upper fee.
/// This tests fee inversion; it does not implement rounded CLMM outputs.
#[test_only]
public(package) fun solve_budget(
    self: &ContinuousPath,
    start_x96: u256,
    end_x96: u256,
    net_capacity: u64,
    budget: u64,
): BudgetFill {
    assert_price(start_x96);
    assert_price(end_x96);
    if (budget == 0 || net_capacity == 0) return BudgetFill { net_input: 0, fee: 0, unspent: budget, iterations: 0 };
    assert!(start_x96 != end_x96);
    let up = end_x96 > start_x96;
    let start = coordinate(self, start_x96, up);
    let end = coordinate(self, end_x96, up);
    let full_fee = quote_coordinates(self, start, end, up, net_capacity).fee_up();
    if ((net_capacity as u128) + (full_fee as u128) <= (budget as u128)) {
        return BudgetFill { net_input: net_capacity, fee: full_fee, unspent: budget - net_capacity - full_fee, iterations: 1 }
    };
    let mut lower = (((budget as u128) * 9 / 10) as u64).min(net_capacity);
    let mut upper = budget.min(net_capacity);
    let mut iterations = 0u64;
    while (upper - lower > 4 && iterations < 28) {
        if (iterations % 2 == 0) {
            let quote = prefix_quote(self, start, end, up, net_capacity, upper);
            lower = lower.max(budget.saturating_sub(quote.fee_up()).min(upper));
        } else {
            let quote = prefix_quote(self, start, end, up, net_capacity, lower);
            upper = upper.min(budget.saturating_sub((quote.lower_x96 / ONE) as u64).max(lower));
        };
        iterations = iterations + 1;
    };
    assert!(upper - lower <= 4);
    let mut candidate = upper;
    let mut inspected = 0u64;
    while (inspected < 8) {
        let quote = prefix_quote(self, start, end, up, net_capacity, candidate);
        let fee = quote.fee_up();
        if ((candidate as u128) + (fee as u128) <= (budget as u128)) {
            return BudgetFill { net_input: candidate, fee, unspent: budget - candidate - fee, iterations: iterations + inspected + 2 }
        };
        assert!(candidate > 0);
        candidate = candidate - 1;
        inspected = inspected + 1;
    };
    abort EInversionDidNotConverge
}

#[test_only]
public(package) fun net_input(self: &BudgetFill): u64 { self.net_input }
#[test_only]
public(package) fun fee(self: &BudgetFill): u64 { self.fee }
#[test_only]
public(package) fun unspent(self: &BudgetFill): u64 { self.unspent }
#[test_only]
public(package) fun iterations(self: &BudgetFill): u64 { self.iterations }


#[test_only]
fun prefix_quote(self: &ContinuousPath, start: u256, end: u256, up: bool, capacity: u64, net_input: u64): FeeQuote {
    let span = end - start;
    let denominator = capacity as u256;
    // Quotient/remainder decomposition avoids a 224-bit * 64-bit product.
    let delta = (span / denominator) * (net_input as u256)
        + (span % denominator) * (net_input as u256) / denominator;
    quote_coordinates(self, start, start + delta, up, net_input)
}

// === Errors ===

#[test_only]
#[error(code = 0)]
const EInversionDidNotConverge: vector<u8> = b"The experimental inverse did not find an affordable integer candidate within its bound.";

// === Imports ===

use blast_fun_dex::{constants, lp_fee::LpFee, sqrt_price_math};
