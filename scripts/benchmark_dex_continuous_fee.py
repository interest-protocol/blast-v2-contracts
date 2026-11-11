#!/usr/bin/env python3
"""Compare the Move continuous fee integrator with the historical 512-band baseline.

Run under the repository heavy-job guard. All packages are isolated copies;
no production fee policy is changed. Independent Decimal quadrature supplies
fee oracles; Move asserts its directed enclosures overlap those oracles.
"""
from __future__ import annotations

import argparse
from decimal import Decimal, localcontext, ROUND_CEILING, ROUND_FLOOR
from functools import cache
from math import cos, pi
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import benchmark_dex_fee_bands as band

ROOT = band.ROOT
ONE = band.Q96
D = Decimal
U64_MAX = (1 << 64) - 1
MIN_PRICE = 4_295_128_739
MAX_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1


@cache
def gauss_rule(order: int) -> list[tuple[Decimal, Decimal]]:
    """Construct the symmetric Gauss–Legendre nodes and weights at Decimal90."""
    with localcontext() as ctx:
        ctx.prec = 90
        out = []
        for i in range(1, order // 2 + 1):
            x = D(str(cos(pi * (i - .25) / (order + .5))))
            for _ in range(15):
                p0, p1 = D(1), x
                for j in range(2, order + 1):
                    p0, p1 = p1, ((2 * j - 1) * x * p1 - (j - 1) * p0) / j
                derivative = order * (x * p1 - p0) / (x * x - 1)
                next_x = x - p1 / derivative
                if abs(next_x - x) < D('1e-85'):
                    break
                x = next_x
            else:
                raise ArithmeticError('Gauss–Legendre node did not converge')
            weight = 2 / ((1 - x * x) * derivative * derivative)
            out.extend([(x, weight), (-x, weight)])
        return out


def gauss_integrate(fn, a, b, tolerance, depth=32):
    def fixed(n):
        middle, scale = (a + b) / 2, (b - a) / 2
        return scale * sum(w * fn(middle + scale * x) for x, w in gauss_rule(n))
    coarse, fine = fixed(16), fixed(32)
    if abs(coarse - fine) < tolerance:
        return fine
    assert depth, 'quadrature did not converge'
    middle = (a + b) / 2
    return (gauss_integrate(fn, a, middle, tolerance / 2, depth - 1)
            + gauss_integrate(fn, middle, b, tolerance / 2, depth - 1))


def reference_average(case: dict, start: int | Decimal, end: int | Decimal, tolerance=D('1e-25')) -> Decimal:
    """Independent quadrature on unit net-input position, 90-digit arithmetic."""
    with localcontext() as context:
        context.prec = 90
        base, cap, sensitivity = (D(case[k]) / 1_000_000 for k in ('base', 'cap', 'sensitivity'))
        if base == cap:
            return cap / (1 - cap)
        reference = D(case.get('reference', ONE))
        up = end > start
        first = D(start) / reference if up else reference / start
        last = D(end) / reference if up else reference / end
        gap = ((cap - base) / sensitivity).sqrt()
        edges = [(1 - gap).sqrt(), D(1), (1 + gap).sqrt()]
        if not up:
            edges = [1 / value for value in edges]
        cuts = sorted(set([D(0), D(1)] + [(edge - first) / (last - first)
            for edge in edges if first < edge < last]))

        def integrand(q):
            coordinate = first + (last - first) * q
            price = coordinate if up else 1 / coordinate
            rate = min(cap, base + sensitivity * (price * price - 1) ** 2)
            return rate / (1 - rate)

        total = D(0)
        for a, b in zip(cuts, cuts[1:]):
            fm = integrand((a + b) / 2)
            if fm == cap / (1 - cap):
                total += (b - a) * fm
            else:
                total += gauss_integrate(integrand, a, b, tolerance)
        return +total


def segments(case: dict) -> list[dict]:
    start = case['start']
    output = []
    for index, end in enumerate(case['boundaries']):
        if end == start:
            continue
        if 'net_input' in case:
            net = case['net_input']
        else:
            liquidity = case['liquidity'] * (1 + index % 2)
            numerator = liquidity * abs(end - start) * (1 if end > start else ONE)
            denominator = ONE if end > start else start * end
            net = band.ceil_div(numerator, denominator)
        first = reference_average(case, start, end)
        refined = reference_average(case, start, end, D('1e-25') / 16)
        with localcontext() as context:
            context.prec = 90
            fee = refined * net
            convergence = abs(first - refined) * net
            assert convergence < D('0.000001'), (case['name'], convergence)
            epsilon = max(D('1e-7'), 64 * convergence)
            low = max(0, int(((fee - epsilon) * ONE).to_integral_value(rounding=ROUND_FLOOR)))
            high = int(((fee + epsilon) * ONE).to_integral_value(rounding=ROUND_CEILING))
            ceil_fee = int(fee.to_integral_value(rounding=ROUND_CEILING))
        output.append(dict(start=start, end=end, net=net, smooth_fee_atoms=str(fee),
                           reference_refinement_atoms=str(convergence), oracle_lower_x96=low,
                           oracle_upper_x96=high, expected_fee_atoms=ceil_fee))
        start = end
    return output


def edge_cases() -> list[dict]:
    result = []
    def add(name, start, end, *, reference=ONE, base=1, cap=100000, sensitivity=100000, net_input=U64_MAX):
        result.append(dict(name=name, start=start, boundaries=[end], reference=reference,
                           base=base, cap=cap, sensitivity=sensitivity, net_input=net_input))
    add('maximum_net_up', ONE, 7 * ONE // 5)
    add('maximum_net_down', 7 * ONE // 5, ONE // 1000)
    add('zero_lower_pole', ONE, 103 * ONE // 100, base=1000, sensitivity=999000)
    add('positive_lower_pole', ONE, 103 * ONE // 100, base=1000, sensitivity=999001)
    add('negative_lower_pole', ONE, 103 * ONE // 100, base=1000, sensitivity=998999)
    add('minimum_reference_up', MIN_PRICE, 7 * MIN_PRICE // 5, reference=MIN_PRICE)
    add('minimum_reference_down', 7 * MIN_PRICE // 5, MIN_PRICE, reference=MIN_PRICE)
    add('maximum_reference_up', MAX_PRICE // 2, MAX_PRICE, reference=MAX_PRICE)
    add('maximum_reference_down', MAX_PRICE, MAX_PRICE // 2, reference=MAX_PRICE)
    add('one_absolute_step_up', MAX_PRICE - 1, MAX_PRICE, reference=MAX_PRICE)
    add('one_absolute_step_down', MAX_PRICE, MAX_PRICE - 1, reference=MAX_PRICE)
    add('extreme_ratio_up', MIN_PRICE, MAX_PRICE, reference=MIN_PRICE)
    add('extreme_ratio_down', MAX_PRICE, MIN_PRICE, reference=MIN_PRICE)
    add('extreme_inverse_up', MIN_PRICE, MAX_PRICE, reference=MAX_PRICE)
    add('extreme_inverse_down', MAX_PRICE, MIN_PRICE, reference=MAX_PRICE)
    add('one_net_atom', ONE, 11 * ONE // 10, net_input=1)
    return result


def reference_fill(case: dict, capacity: int, budget: int) -> tuple[int, int, int]:
    """Independent integer bisection, with numerical integration at each probe."""
    with localcontext() as context:
        context.prec = 90
        start, end = D(case['start']), D(case['boundaries'][0])
        up = end > start
        first, last = (start, end) if up else (1 / start, 1 / end)

        def fee(net):
            if not net:
                return 0
            coordinate = first + (last - first) * net / capacity
            stop = coordinate if up else 1 / coordinate
            return int((reference_average(case, start, stop) * net).to_integral_value(rounding=ROUND_CEILING))

        lower, upper = 0, min(capacity, budget)
        while lower < upper:
            middle = (lower + upper + 1) // 2
            if middle + fee(middle) <= budget:
                lower = middle
            else:
                upper = middle - 1
        charge = fee(lower)
        return lower, charge, budget - lower - charge


def inverse_records(records: list[dict]) -> list[dict]:
    """Budget exhaustion on the same prescribed, constant-liquidity path."""
    names = {'one_pct_up', 'one_pct_down', 'cross_reference_up', 'cross_reference_down',
             'high_sensitivity_up', 'high_sensitivity_down', 'full_span_up', 'full_span_down',
             'thin_liquidity_up', 'thin_liquidity_down'}
    result = []
    for record in records:
        case = record['case']
        if case['name'] not in names:
            continue
        budget = record['continuous']['gross_atoms'] * 3 // 4
        capacity = record['continuous']['net_atoms']
        smooth_net, smooth_fee, smooth_refund = reference_fill(case, capacity, budget)
        remaining, net_total, fee_total, steps = budget, 0, 0, 0
        spot, limit = case['start'], case['boundaries'][0]
        while spot != limit and remaining:
            end, rate = band.next_step(spot, limit, case, 512)
            numerator = case['liquidity'] * abs(end - spot) * (1 if end > spot else ONE)
            denominator = ONE if end > spot else spot * end
            step_capacity = band.ceil_div(numerator, denominator)
            net = min(step_capacity, remaining * (1_000_000 - rate) // 1_000_000)
            fee = band.ceil_div(net * rate, 1_000_000 - rate)
            remaining -= net + fee
            net_total += net
            fee_total += fee
            steps += 1
            if net < step_capacity:
                break
            spot = end
        result.append(dict(name=case['name'], budget=budget, capacity=capacity,
                           continuous_net=smooth_net, continuous_fee=smooth_fee, continuous_refund=smooth_refund,
                           bands_net=net_total, bands_fee=fee_total, bands_refund=remaining, bands_steps=steps))
    return result


def generated_tests(records: list[dict], inverses: list[dict]) -> str:
    tests = []
    for record in records:
        case, rows = record['case'], record['segments']
        reference = case.get('reference', ONE)
        boundaries = ', '.join(str(x) for x in case['boundaries'])
        if 'net_input' not in case:
            net = sum(x['net'] for x in rows)
            fee = sum(x['expected_fee_atoms'] for x in rows)
            expected_band = band.walk(case, 512)
            tests.append(f'''#[test]
fun continuous_{case['name']}() {{
    let path = continuous_fee::new(settings({case['base']}, {case['cap']}, {case['sensitivity']}), {reference});
    let (net, fee) = walk_continuous(&path, {case['start']}, vector[{boundaries}], {case['liquidity']});
    assert_eq!(net, {net});
    assert_eq!(fee, {fee});
}}

#[test]
fun bands_{case['name']}() {{
    let path = lp_fee::new_fee_path(settings({case['base']}, {case['cap']}, {case['sensitivity']}), {reference});
    let (net, fee) = walk_bands(&path, {case['start']}, vector[{boundaries}], {case['liquidity']});
    assert_eq!(net, {expected_band['net_atoms']});
    assert_eq!(fee, {expected_band['fee_atoms']});
}}
''')
        checks = []
        for row in rows:
            # The max-net enclosures have a separately asserted sub-atom width;
            # quoted ceil may exceed the real ceil by one atom at an integer edge.
            checks.append(f'''    let quote = path.quote({row['start']}, {row['end']}, {row['net']});
    assert!(quote.lower_x96() <= {row['oracle_upper_x96']});
    assert!(quote.upper_x96() >= {row['oracle_lower_x96']});
    assert!(quote.width_x96() < ONE / 4);
    assert!(quote.fee_up() >= {max(0, row['expected_fee_atoms'] - 1)} && quote.fee_up() <= {row['expected_fee_atoms'] + 1});''')
        if not rows:
            continue
        for offset in range(0, len(checks), 16):
            tests.append(f'''#[test]
fun enclosure_{case['name']}_{offset // 16}() {{
    let path = continuous_fee::new(settings({case['base']}, {case['cap']}, {case['sensitivity']}), {reference});
''' + '\n'.join(checks[offset:offset + 16]) + '\n}\n')
    for inverse in inverses:
        case = next(record['case'] for record in records if record['case']['name'] == inverse['name'])
        setup = f"settings({case['base']}, {case['cap']}, {case['sensitivity']})"
        tests.append(f'''#[test]
fun inverse_continuous_{case['name']}() {{
    let path = continuous_fee::new({setup}, ONE);
    let fill = path.solve_budget({case['start']}, {case['boundaries'][0]}, {inverse['capacity']}, {inverse['budget']});
    assert_eq!(fill.net_input() + fill.fee() + fill.unspent(), {inverse['budget']});
    assert_eq!(fill.net_input(), {inverse['continuous_net']});
    assert_eq!(fill.fee(), {inverse['continuous_fee']});
    assert!(fill.iterations() <= 37);
}}

#[test]
fun inverse_bands_{case['name']}() {{
    let path = lp_fee::new_fee_path({setup}, ONE);
    let (net, fee, refund) = solve_bands(&path, {case['start']}, {case['boundaries'][0]}, {case['liquidity']}, {inverse['budget']});
    assert_eq!(net, {inverse['bands_net']});
    assert_eq!(fee, {inverse['bands_fee']});
    assert_eq!(refund, {inverse['bands_refund']});
}}
''')
    return '''#[test_only]
module blast_fun_dex::continuous_fee_comparison_tests;

// === Constants ===

const ONE: u256 = 1 << 96;

// === Tests ===

#[test]
fun empty() {}

''' + '\n'.join(tests) + '''
// === Test Helpers ===

fun settings(base: u32, cap: u32, sensitivity: u32): LpFee {
    lp_fee::new_dynamic_unchecked_for_testing(base, cap, sensitivity)
}

fun net_delta(start: u256, end: u256, liquidity: u256): u64 {
    let delta = start.diff(end);
    if (end > start) (liquidity * delta).div_ceil(ONE) as u64
    else (liquidity * delta * ONE).div_ceil(start * end) as u64
}

fun walk_continuous(path: &ContinuousPath, start: u256, boundaries: vector<u256>, liquidity: u256): (u64, u64) {
    let mut spot = start;
    let mut total_net = 0;
    let mut total_fee = 0;
    boundaries.length().do!(|index| {
        let end = &boundaries[index];
        if (*end != spot) {
            let net = net_delta(spot, *end, liquidity * (1 + (index as u256) % 2));
            let quote = path.quote(spot, *end, net);
            total_net = total_net + net;
            total_fee = total_fee + quote.fee_up();
            spot = *end;
        };
    });
    (total_net, total_fee)
}

fun walk_bands(path: &FeePath, start: u256, boundaries: vector<u256>, liquidity: u256): (u64, u64) {
    let mut spot = start;
    let end = boundaries[boundaries.length() - 1];
    let mut index = 0;
    let mut total_net = 0;
    let mut total_fee = 0;
    while (spot != end) {
        let step = path.next_step(spot, boundaries[index]);
        let next = step.limit_x96();
        assert!(next != spot);
        let net = net_delta(spot, next, liquidity * (1 + (index as u256) % 2));
        let fee = step.fee_up(net);
        total_net = total_net + net;
        total_fee = total_fee + fee;
        spot = next;
        if (spot == boundaries[index]) index = index + 1;
    };
    (total_net, total_fee)
}

fun solve_bands(path: &FeePath, start: u256, limit: u256, liquidity: u256, budget: u64): (u64, u64, u64) {
    let mut spot = start;
    let mut remaining = budget;
    let mut total_net = 0;
    let mut total_fee = 0;
    while (spot != limit && remaining > 0) {
        let step = path.next_step(spot, limit);
        let next = step.limit_x96();
        let capacity = net_delta(spot, next, liquidity);
        let net = capacity.min(step.net_budget_down(remaining));
        let fee = step.fee_up(net);
        remaining = remaining - net - fee;
        total_net = total_net + net;
        total_fee = total_fee + fee;
        if (net < capacity) break;
        spot = next;
    };
    (total_net, total_fee, remaining)
}

// === Imports ===

use blast_fun_dex::{
    continuous_fee::{Self, ContinuousPath},
    lp_fee::{Self, LpFee, FeePath},
};
use std::unit_test::assert_eq;
'''


def run_move(records: list[dict], inverses: list[dict], output: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix='blast-continuous-fee-') as temporary:
        package = Path(temporary)
        original = ROOT / 'scratch-sui/dex'
        for folder in ('sources', 'tests'):
            shutil.copytree(original / folder, package / folder)
        manifest = (original / 'Move.toml').read_text().replace('"../../sui/governance/admin"', json.dumps(str(ROOT / 'sui/governance/admin')))
        (package / 'Move.toml').write_text(manifest)
        (package / 'tests/continuous_fee_comparison_tests.move').write_text(generated_tests(records, inverses))
        command = ['sui', 'move', 'test', '--path', str(package), '--threads', '1', '--statistics', 'csv', '--lint', '--warnings-are-errors', 'continuous_fee_comparison_tests']
        completed = subprocess.run(command, text=True, capture_output=True)
        log = completed.stdout + completed.stderr
        (output / 'move.log').write_text(log)
        if completed.returncode:
            raise RuntimeError(log)
        statistics = {}
        for line in log.splitlines():
            parts = line.strip().split(',')
            if len(parts) == 3 and '::continuous_fee_comparison_tests::' in parts[0]:
                statistics[parts[0].rsplit('::', 1)[-1]] = dict(elapsed_nanoseconds=int(parts[1]), raw_reported_gas=int(parts[2]))
        assert len(statistics) == 1 + 2 * len(inverses) + sum((2 if 'net_input' not in r['case'] else 0) + (len(r['segments']) + 15) // 16 for r in records)
        baseline = statistics['empty']['raw_reported_gas']
        for row in statistics.values():
            row['gas_units_above_empty_test'] = row['raw_reported_gas'] - baseline
        command[4] = '<isolated-package>'
        return dict(command=command, statistics=statistics)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--numerics-only', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = band.cases() + band.adverse_cases(512) + edge_cases()
    records = []
    for case in cases:
        record = dict(case=case, segments=segments(case))
        if 'net_input' not in case:
            record['bands'] = band.walk(case, 512)
            net = sum(row['net'] for row in record['segments'])
            fee = sum(row['expected_fee_atoms'] for row in record['segments'])
            record['continuous'] = dict(net_atoms=net, fee_atoms=fee, gross_atoms=net + fee)
        records.append(record)
    inverses = inverse_records(records)
    dex = ROOT / 'scratch-sui/dex'
    inputs = [Path(band.__file__), dex / 'Move.toml', dex / 'Move.lock',
              *sorted((dex / 'sources').rglob('*.move')), *sorted((dex / 'tests').rglob('*.move'))]
    report = dict(schema_version=1, sui_version=subprocess.check_output(['sui', '--version'], text=True).strip(),
                  gas_scope='Pinned Sui VM arithmetic harness, empty-test-normalized; no storage or full PTB',
                  script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  input_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
                  records=records, inverse_cases=inverses)
    if not args.numerics_only:
        report['move'] = run_move(records, inverses, args.output)
    (args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Completed continuous comparison',flush=True)


if __name__ == '__main__':
    main()
